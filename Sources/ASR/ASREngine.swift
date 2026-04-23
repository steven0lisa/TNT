import Foundation

protocol ASREngineProtocol: Sendable {
    func transcribe(fileURL: URL) async -> String
}

final class ASREngine: @unchecked Sendable, ASREngineProtocol {
    static let shared = ASREngine()

    private let session = URLSession(configuration: .default)

    private init() {}

    func transcribe(fileURL: URL) async -> String {
        let audioPath = fileURL.path
        let requestBody: [String: Any] = ["audio_path": audioPath]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            TNTLog.error("[ASREngine] Failed to encode request")
            return "ERROR: Failed to encode ASR request"
        }

        var request = URLRequest(url: TNTServerManager.asrURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return "ERROR: Invalid response from ASR server"
            }

            guard httpResponse.statusCode == 200 else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                TNTLog.error("[ASREngine] Server error \(httpResponse.statusCode): \(errorText)")
                return "ERROR: ASR server error \(httpResponse.statusCode)"
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let text = json["text"] else {
                TNTLog.error("[ASREngine] Invalid response format")
                return "ERROR: Invalid ASR response"
            }

            TNTLog.info("[ASREngine] Result: \(String(text.prefix(50)))")
            return text

        } catch {
            TNTLog.error("[ASREngine] Request failed: \(error)")
            return "ERROR: ASR request failed: \(error.localizedDescription)"
        }
    }
}

// Mock ASR Engine for testing without models
final class MockASREngine: @unchecked Sendable, ASREngineProtocol {
    static let shared = MockASREngine()

    private init() {}

    func transcribe(fileURL: URL) async -> String {
        try? await Task.sleep(nanoseconds: 500_000_000)
        return "这是语音识别的模拟结果，实际识别需要运行 Qwen3-ASR 模型。"
    }
}
