import AudioCommon
import Foundation
import Qwen3ASR

final class QwenASREngine: @unchecked Sendable, ASREngineProtocol {
    static let shared = QwenASREngine()

    private var model: Qwen3ASRModel?
    private let lock = NSLock()
    private(set) var isReady = false

    private init() {}

    func warmup() async {
        let modelType = ModelManager.shared.activeASRType
        let localPath = ModelManager.shared.modelPath(for: modelType)

        guard FileManager.default.fileExists(atPath: localPath) else {
            TNTLog.warning("[QwenASR] Model not found at \(localPath), skipping warmup")
            return
        }

        do {
            // modelId 用于检测模型大小（0.6B/1.7B）和量化位数（4/8）
            let modelId: String
            switch modelType {
            case .asrLarge:
                modelId = "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
            default:
                modelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            }

            let localDir = URL(fileURLWithPath: localPath)
            TNTLog.info("[QwenASR] Loading model from \(localPath) (modelId=\(modelId))")

            let loaded = try await Qwen3ASRModel.fromPretrained(
                modelId: modelId,
                cacheDir: localDir,
                offlineMode: true
            )

            lock.withLock {
                self.model = loaded
                self.isReady = true
            }
            TNTLog.info("[QwenASR] Model warmed up successfully")
        } catch {
            TNTLog.error("[QwenASR] Warmup failed: \(error)")
        }
    }

    func transcribe(fileURL: URL) async -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            TNTLog.error("[QwenASR] Audio file not found: \(fileURL.path)")
            return "ERROR: Audio file not found"
        }

        guard let currentModel = lock.withLock({ model }) else {
            TNTLog.error("[QwenASR] Model not loaded")
            return "ERROR: Model not loaded"
        }

        do {
            let audio = try AudioFileLoader.load(url: fileURL, targetSampleRate: 16000)
            let text = currentModel.transcribe(audio: audio, sampleRate: 16000)
            TNTLog.info("[QwenASR] Result: \(String(text.prefix(100)))")
            return text
        } catch {
            TNTLog.error("[QwenASR] Transcription failed: \(error)")
            return "ERROR: \(error.localizedDescription)"
        }
    }
}
