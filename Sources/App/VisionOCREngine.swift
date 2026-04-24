import Foundation
import Vision

/// macOS 原生 Vision OCR 引擎
/// 无需下载模型，完全离线运行，系统内置
final class VisionOCREngine: @unchecked Sendable, OCREngineProtocol {
    static let shared = VisionOCREngine()

    var isAvailable: Bool { true }

    func recognize(image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                guard let observations = request.results, !observations.isEmpty else {
                    TNTLog.info("[VisionOCR] No text found in image")
                    return ""
                }
                let texts = observations.compactMap { $0.topCandidates(1).first?.string }
                let result = texts.joined(separator: "\n")
                TNTLog.info("[VisionOCR] Recognized \(texts.count) lines, \(result.count) chars")
                return result
            } catch {
                TNTLog.error("[VisionOCR] Recognition failed: \(error)")
                return ""
            }
        }.value
    }
}
