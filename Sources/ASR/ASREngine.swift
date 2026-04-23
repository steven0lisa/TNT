import Foundation
import Speech

protocol ASREngineProtocol: Sendable {
    func transcribe(fileURL: URL) async -> String
}

/// 使用 Apple SFSpeechRecognizer 进行本地语音识别
final class ASREngine: @unchecked Sendable, ASREngineProtocol {
    static let shared = ASREngine()

    private var recognizer: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "com.tnt.asr")

    private init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    /// 预热：预加载语音识别器
    func warmup() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        TNTLog.info("[ASREngine] Speech recognizer warmed up")
    }

    func transcribe(fileURL: URL) async -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            TNTLog.error("[ASREngine] Audio file not found: \(fileURL.path)")
            return "ERROR: Audio file not found"
        }

        guard let recognizer = recognizer, recognizer.isAvailable else {
            TNTLog.error("[ASREngine] Speech recognizer not available")
            return "ERROR: Speech recognizer not available"
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        // 尽可能使用设备端识别（如果可用）
        if #available(macOS 14.0, *) {
            request.requiresOnDeviceRecognition = false
        }
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    TNTLog.error("[ASREngine] Recognition error: \(error)")
                    continuation.resume(returning: "ERROR: \(error.localizedDescription)")
                    return
                }

                guard let result = result else {
                    continuation.resume(returning: "")
                    return
                }

                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                    TNTLog.info("[ASREngine] Result: \(String(text.prefix(50)))")
                    continuation.resume(returning: text)
                }
            }
        }
    }
}

/// Mock ASR Engine for testing without speech recognition
final class MockASREngine: @unchecked Sendable, ASREngineProtocol {
    static let shared = MockASREngine()

    private init() {}

    func transcribe(fileURL: URL) async -> String {
        try? await Task.sleep(nanoseconds: 500_000_000)
        return "这是语音识别的模拟结果，实际识别需要运行语音识别模型。"
    }
}
