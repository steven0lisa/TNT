import Foundation

protocol LLMRefinerProtocol: Sendable {
    func refine(text: String) async -> String
}

final class LLMRefiner: @unchecked Sendable, LLMRefinerProtocol {
    static let shared = LLMRefiner()

    private let session = URLSession(configuration: .default)

    private init() {}

    func refine(text: String) async -> String {
        let requestBody: [String: Any] = ["text": text]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            TNTLog.error("[LLMRefiner] Failed to encode request")
            return "ERROR: Failed to encode refine request"
        }

        var request = URLRequest(url: TNTServerManager.refineURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return "ERROR: Invalid response from LLM server"
            }

            guard httpResponse.statusCode == 200 else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                TNTLog.error("[LLMRefiner] Server error \(httpResponse.statusCode): \(errorText)")
                return "ERROR: LLM server error \(httpResponse.statusCode)"
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let refined = json["text"] else {
                TNTLog.error("[LLMRefiner] Invalid response format")
                return "ERROR: Invalid LLM response"
            }

            TNTLog.info("[LLMRefiner] Result: \(String(refined.prefix(50)))")
            return refined

        } catch {
            TNTLog.error("[LLMRefiner] Request failed: \(error)")
            return "ERROR: LLM request failed: \(error.localizedDescription)"
        }
    }
}

// Mock LLM Refiner for testing
final class MockLLMRefiner: @unchecked Sendable, LLMRefinerProtocol {
    static let shared = MockLLMRefiner()

    private init() {}

    func refine(text: String) async -> String {
        try? await Task.sleep(nanoseconds: 300_000_000)
        var refined = text
        if refined.hasSuffix("s") && refined.count < 30 {
            refined = String(refined.dropLast())
        }
        return refined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
