import CoreImage
import Foundation

protocol OCREngineProtocol: Sendable {
    func recognize(image: CGImage) async -> String
    var isAvailable: Bool { get }
}

final class PaddleOCREngine: @unchecked Sendable, OCREngineProtocol {
    static let shared = PaddleOCREngine()
    static let modelDirectoryName = "PaddleOCR-VL"

    private var pipeline: PaddleOCRVLPipeline?
    private let lock = NSLock()

    var isAvailable: Bool {
        lock.withLock { pipeline != nil }
    }

    static func isModelDownloaded() -> Bool {
        let path = modelPath()
        let fm = FileManager.default
        return fm.fileExists(atPath: path.path)
            && fm.fileExists(atPath: path.appendingPathComponent("config.json").path)
    }

    static func modelPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".tnt/models/\(modelDirectoryName)")
    }

    func warmup() async {
        guard Self.isModelDownloaded() else { return }
        do {
            let p = try await PaddleOCRVLPipeline(
                modelURL: Self.modelPath(),
                mode: .base
            )
            lock.withLock {
                self.pipeline = p
            }
            TNTLog.info("[OCREngine] PaddleOCR-VL warmed up")
        } catch {
            TNTLog.error("[OCREngine] Warmup failed: \(error)")
        }
    }

    func recognize(image: CGImage) async -> String {
        guard let pipeline = lock.withLock({ pipeline }) else {
            return ""
        }
        let ciImage = CIImage(cgImage: image)
        return pipeline.recognize(image: ciImage, task: .ocr, maxTokens: 256)
    }
}
