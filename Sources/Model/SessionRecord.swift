import AVFoundation
import Foundation

// MARK: - SessionRecord

struct SessionRecord: Codable, Identifiable {
    let id: String
    let timestamp: Date
    var isBluetooth: Bool
    var hasOriginalAudio: Bool
    var hasProcessedAudio: Bool
    var asrResult: String?
    var llmPrompt: String?
    var llmResult: String?
    var errorMessage: String?

    // 模型信息
    var asrModel: String?
    var llmModel: String?

    // 各阶段耗时（毫秒）
    var recordingDurationMs: Int?
    var asrDurationMs: Int?
    var llmDurationMs: Int?
    var injectDurationMs: Int?

    var displayTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var shortId: String {
        String(id.prefix(8))
    }
}

// MARK: - SessionStore

final class SessionStore: @unchecked Sendable {
    static let shared = SessionStore()

    private let lock = NSLock()
    private let sessionsDirectory: URL
    private let maxSessions = 50

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        sessionsDirectory = home.appendingPathComponent(".tnt/sessions")
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - CRUD

    @discardableResult
    func createSession(isBluetooth: Bool) -> String {
        lock.withLock {
            let id = UUID().uuidString
            let dir = sessionsDirectory.appendingPathComponent(id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let record = SessionRecord(
                id: id,
                timestamp: Date(),
                isBluetooth: isBluetooth,
                hasOriginalAudio: false,
                hasProcessedAudio: false
            )
            saveRecordLocked(record)
            cleanupOldSessionsLocked()
            return id
        }
    }

    func saveOriginalAudio(sessionId: String, from url: URL) {
        lock.withLock {
            let dest = sessionsDirectory.appendingPathComponent("\(sessionId)/original.wav")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
            updateRecordLocked(id: sessionId) { $0.hasOriginalAudio = true }
        }
    }

    func saveProcessedAudio(sessionId: String, from url: URL) {
        lock.withLock {
            let dest = sessionsDirectory.appendingPathComponent("\(sessionId)/processed.wav")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
            updateRecordLocked(id: sessionId) { $0.hasProcessedAudio = true }
        }
    }

    func updateASRResult(sessionId: String, result: String) {
        lock.withLock {
            updateRecordLocked(id: sessionId) { $0.asrResult = result }
        }
    }

    func updateLLMResult(sessionId: String, prompt: String, result: String) {
        lock.withLock {
            updateRecordLocked(id: sessionId) { r in
                r.llmPrompt = prompt
                r.llmResult = result
            }
        }
    }

    func updateError(sessionId: String, error: String) {
        lock.withLock {
            updateRecordLocked(id: sessionId) { $0.errorMessage = error }
        }
    }

    func updateModels(sessionId: String, asrModel: String, llmModel: String) {
        lock.withLock {
            updateRecordLocked(id: sessionId) { r in
                r.asrModel = asrModel
                r.llmModel = llmModel
            }
        }
    }

    func updateTiming(sessionId: String, recordingMs: Int? = nil, asrMs: Int? = nil, llmMs: Int? = nil, injectMs: Int? = nil) {
        lock.withLock {
            updateRecordLocked(id: sessionId) { r in
                if let v = recordingMs { r.recordingDurationMs = v }
                if let v = asrMs { r.asrDurationMs = v }
                if let v = llmMs { r.llmDurationMs = v }
                if let v = injectMs { r.injectDurationMs = v }
            }
        }
    }

    // MARK: - Query

    func loadSessions() -> [SessionRecord] {
        lock.withLock {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }

            var records: [SessionRecord] = []
            for dir in contents {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

                let recordURL = dir.appendingPathComponent("record.json")
                guard let data = try? Data(contentsOf: recordURL),
                      let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { continue }
                records.append(record)
            }

            records.sort { $0.timestamp > $1.timestamp }
            return records
        }
    }

    func audioURL(sessionId: String, type: String) -> URL? {
        let url = sessionsDirectory.appendingPathComponent("\(sessionId)/\(type).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private (must be called within lock)

    private func saveRecordLocked(_ record: SessionRecord) {
        let url = sessionsDirectory.appendingPathComponent("\(record.id)/record.json")
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func updateRecordLocked(id: String, update: (inout SessionRecord) -> Void) {
        let url = sessionsDirectory.appendingPathComponent("\(id)/record.json")
        guard let data = try? Data(contentsOf: url),
              var record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return }
        update(&record)
        guard let encoded = try? JSONEncoder().encode(record) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    private func cleanupOldSessionsLocked() {
        var records: [(String, Date)] = []
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for dir in contents {
            let recordURL = dir.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { continue }
            records.append((record.id, record.timestamp))
        }

        records.sort { $0.1 > $1.1 }

        guard records.count > maxSessions else { return }

        for i in maxSessions..<records.count {
            let dir = sessionsDirectory.appendingPathComponent(records[i].0)
            try? FileManager.default.removeItem(at: dir)
        }
        TNTLog.info("[SessionStore] Cleaned up \(records.count - maxSessions) old sessions")
    }
}
