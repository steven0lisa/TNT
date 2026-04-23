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

    func refine(text: String, context: String? = nil) async -> RefineOutput {
        guard !text.isEmpty else { return RefineOutput(text: text, prompt: "") }

        do {
            let container = try await loadModel()

            let systemPrompt = "你是一个专业的语音输入助手。只输出校正后的文字，不要添加任何前缀、解释或思考过程。严禁输出<think> 标签及其内容。"
            let refinePrompt = """
                请对以下语音识别结果进行校正，直接输出结果，不要解释：
                1. 修正同音字错误
                2. 删除口吃、重复、填充词（如嗯、啊、那个、就是说、呃、这个这个、重复的字词）
                3. 如果是中文数字（一二三四...），转为阿拉伯数字（1234...）
                4. 添加合适的标点符号
                5. 调整语序使表达更通顺
                6. 如果开头或结尾出现孤立的无意义单字（如"嗯"、"啊"、"呃"、生僻字、乱码），直接删除
                7. 如果识别结果整体无意义（全是语气词或杂音），直接返回空字符串
                """

            var userContent = "语音识别原始结果：\(text)\n\n\(refinePrompt)"
            if let context = context, !context.isEmpty {
                userContent += "\n\n<screenshot-text>\(context)</screenshot-text>\n\n注意：如果识别结果包含屏幕截图中的专有名词或界面元素名称，请根据截图内容进行校正。"
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
                maxTokens: 1024,
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

            TNTLog.info("[LLMRefiner] Result: \(String(result.prefix(100)))")
            let finalText = result.isEmpty ? text : result
            return RefineOutput(text: finalText, prompt: userContent)

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
