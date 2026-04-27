import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

struct RefineOutput: Sendable {
    let text: String
    let prompt: String
}

protocol LLMRefinerProtocol: Sendable {
    func refine(text: String, context: String?) async -> RefineOutput
}

/// 使用 mlx-swift-lm 本地加载 Qwen3-4B 进行文本校正
final class LLMRefiner: @unchecked Sendable, LLMRefinerProtocol {
    static let shared = LLMRefiner()

    private var modelContainer: ModelContainer?
    private let modelPath: URL
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.modelPath = home.appendingPathComponent(".tnt/models/Qwen3-4B-4bit")
    }

    /// 预热模型（在 App 启动时调用）
    func warmup() async {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            TNTLog.error("[LLMRefiner] Model not found at \(modelPath.path)")
            return
        }
        do {
            let container = try await loadModel()
            lock.withLock {
                self.modelContainer = container
            }
            TNTLog.info("[LLMRefiner] Model warmed up")
        } catch {
            TNTLog.error("[LLMRefiner] Warmup failed: \(error)")
        }
    }

    /// 判断是否为长文本（需要结构化整理）
    private func isLongText(_ text: String) -> Bool {
        // 中文字符按1算，总字符数超过100视为长文本
        return text.count > 100
    }

    func refine(text: String, context: String? = nil) async -> RefineOutput {
        guard !text.isEmpty else { return RefineOutput(text: text, prompt: "") }

        do {
            let container = try await loadModel()
            let isLong = isLongText(text)

            let systemPrompt: String
            let refinePrompt: String
            let maxTokens: Int

            if isLong {
                // 长文本：结构化整理，提炼观点，输出正式文案
                systemPrompt = """
                    你是一位专业的语音输入文字整理助手。你的任务是将用户的语音转录结果整理成结构清晰、表达正式的文案。
                    只输出整理后的最终文字，不要添加任何前缀、解释或思考过程。严禁输出<think>标签及其内容。
                    严禁输出屏幕截图中的原文内容，只校正并输出语音输入部分的整理结果。
                    """
                refinePrompt = """
                    <instruction>
                    请对以下 <voice-input> 标签中的语音识别结果进行深度整理和校正，输出一份结构清晰、表达正式的文案：

                    1. 修正所有语音识别错误（同音字、近音词、断句错误等）
                    2. 删除口语化填充词和重复（如嗯、啊、那个、就是说、呃、这个这个、来回重复的字词）
                    3. 提炼用户的核心观点和论述逻辑，保持原意不变
                    4. 将散乱的内容整理成有条理的结构：按观点/要点分段，必要时使用编号（1. 2. 3.）或项目符号
                    5. 将口语化表达转为书面语，但保留用户原有的语气和风格
                    6. 如果是中文数字且适合转为阿拉伯数字的地方，进行转换
                    7. 添加合适的标点符号，确保长句有适当的断句
                    8. 如果开头或结尾有无意义的单字（如"嗯"、"啊"、"呃"），直接删除
                    9. 如果识别结果整体无意义，直接返回空字符串

                    注意：用户可能在反复调整论述，请识别出最终意图，忽略中间犹豫和反复的部分。
                    </instruction>
                    """
                maxTokens = 2048
            } else {
                // 短文本：简洁校正
                systemPrompt = """
                    你是一个专业的语音输入助手。只输出校正后的文字，不要添加任何前缀、解释或思考过程。
                    严禁输出<think>标签及其内容。
                    严禁输出屏幕截图中的原文内容，只校正并输出语音输入部分的结果。
                    """
                refinePrompt = """
                    <instruction>
                    请对以下 <voice-input> 标签中的语音识别结果进行校正，直接输出结果，不要解释：
                    1. 修正同音字错误
                    2. 删除口吃、重复、填充词（如嗯、啊、那个、就是说、呃、这个这个、重复的字词）
                    3. 如果是中文数字（一二三四...），转为阿拉伯数字（1234...）
                    4. 添加合适的标点符号
                    5. 调整语序使表达更通顺
                    6. 如果开头或结尾出现孤立的无意义单字（如"嗯"、"啊"、"呃"、生僻字、乱码），直接删除
                    7. 如果识别结果整体无意义（全是语气词或杂音），直接返回空字符串
                    </instruction>
                    """
                maxTokens = 1024
            }

            var userContent = """
                <voice-input>
                \(text)
                </voice-input>

                \(refinePrompt)
                """
            if let context = context, !context.isEmpty {
                userContent += """

                    <screenshot-text>
                    \(context)
                    </screenshot-text>

                    <instruction>
                    注意：屏幕截图中的内容仅作为专有名词校正的参考依据。
                    严禁将屏幕截图中的原文内容混入输出结果。
                    只输出对 <voice-input> 内容校正后的结果。
                    </instruction>
                    """
            }

            let messages: [Chat.Message] = [
                .system(systemPrompt),
                .user(userContent)
            ]

            let userInput = UserInput(
                chat: messages,
                additionalContext: ["enable_thinking": false]
            )
            let lmInput = try await container.prepare(input: userInput)

            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.1
            )

            let stream = try await container.generate(input: lmInput, parameters: parameters)
            var result = ""
            for await generation in stream {
                if case .chunk(let chunk) = generation {
                    result += chunk
                }
            }

            // 过滤 <think> 标签
            result = filterThinkTags(result)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)

            TNTLog.info("[LLMRefiner] Result (isLong=\(isLong)): \(String(result.prefix(100)))")
            let fullPrompt = "[System]\(systemPrompt)\n\n[User]\(userContent)"
            let finalText = result.isEmpty ? text : result
            return RefineOutput(text: finalText, prompt: fullPrompt)

        } catch {
            TNTLog.error("[LLMRefiner] Refinement failed: \(error)")
            return RefineOutput(text: text, prompt: "")
        }
    }

    private func loadModel() async throws -> ModelContainer {
        // 先检查是否已缓存
        if let container = lock.withLock({ modelContainer }) {
            return container
        }

        let configuration = ModelConfiguration(
            directory: modelPath,
            defaultPrompt: ""
        )

        let container = try await loadModelContainer(
            from: LocalDownloader(),
            using: LocalTokenizerLoader(),
            configuration: configuration
        )

        // 再次检查避免重复赋值
        lock.withLock {
            if modelContainer == nil {
                modelContainer = container
            }
        }

        return container
    }

    private func filterThinkTags(_ text: String) -> String {
        var result = text
        // 去除 <think>...</think>（支持多行，以及未闭合的情况）
        if let regex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        // 如果没有闭合标签，去除从 <think> 开始到末尾的所有内容
        if let startRange = result.range(of: "<think>") {
            result = String(result[..<startRange.lowerBound])
        }
        return result
    }
}

// MARK: - Local Downloader

struct LocalDownloader: MLXLMCommon.Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // 本地加载，直接返回 id 作为路径
        return URL(fileURLWithPath: id)
    }
}

// MARK: - Local Tokenizer Loader (手动实现，不依赖宏)

struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

// MARK: - Tokenizer Bridge (桥接 Tokenizers.Tokenizer -> MLXLMCommon.Tokenizer)

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// MARK: - Mock

final class MockLLMRefiner: @unchecked Sendable, LLMRefinerProtocol {
    static let shared = MockLLMRefiner()
    private init() {}

    func refine(text: String, context: String? = nil) async -> RefineOutput {
        try? await Task.sleep(nanoseconds: 300_000_000)
        var refined = text
        if refined.hasSuffix("s") && refined.count < 30 {
            refined = String(refined.dropLast())
        }
        let result = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        return RefineOutput(text: result, prompt: "")
    }
}
