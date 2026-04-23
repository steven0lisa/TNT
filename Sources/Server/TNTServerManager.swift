import Foundation

/// Manages the Python HTTP server that hosts ASR + LLM models.
/// Starts on app launch, stops on app quit. Models are pre-loaded at server startup.
final class TNTServerManager: @unchecked Sendable {
    static let shared = TNTServerManager()
    static let port = 18765
    static let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
    static let asrURL = URL(string: "http://127.0.0.1:\(port)/asr")!
    static let refineURL = URL(string: "http://127.0.0.1:\(port)/refine")!

    private var process: Process?
    private var isRunning = false

    private init() {}

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    func start() async -> Bool {
        guard process == nil else {
            TNTLog.info("[TNTServerManager] Server already running")
            return true
        }

        let python = findPythonExecutable()
        guard let script = findScript() else {
            TNTLog.error("[TNTServerManager] tnt_server.py not found")
            return false
        }

        TNTLog.info("[TNTServerManager] Starting Python server: \(python) \(script)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script]
        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["TNT_SERVER_PORT"] = "\(Self.port)"
        proc.environment?["TNT_ASR_MODEL"] = ModelManager.shared.selectedASRModel
        proc.environment?["TNT_LLM_MODEL"] = ModelManager.shared.selectedLLMModel

        // Capture stderr for diagnostics
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        // Read stderr asynchronously so the pipe doesn't fill up
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }
            TNTLog.info("[PythonServer] \(line)")
        }

        do {
            try proc.run()
        } catch {
            TNTLog.error("[TNTServerManager] Failed to start server: \(error)")
            return false
        }

        process = proc

        // Poll /health until ready (max 120s — model loading can take a while)
        TNTLog.info("[TNTServerManager] Waiting for server to be ready...")
        let ready = await waitForReady(timeout: 120)

        if ready {
            TNTLog.info("[TNTServerManager] Server ready")
            isRunning = true
        } else {
            TNTLog.error("[TNTServerManager] Server failed to become ready")
            proc.terminate()
            process = nil
        }
        return ready
    }

    func stop() {
        guard let proc = process else { return }

        TNTLog.info("[TNTServerManager] Stopping server...")
        proc.terminate()

        // Give it 3s to exit gracefully
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if proc.isRunning {
            TNTLog.warning("[TNTServerManager] Force killing server")
            kill(proc.processIdentifier, SIGKILL)
        }

        process = nil
        isRunning = false
        TNTLog.info("[TNTServerManager] Server stopped")
    }

    // MARK: - Health Check

    private func waitForReady(timeout: Int) async -> Bool {
        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }

        for _ in 0..<timeout {
            do {
                let (_, response) = try await session.data(from: Self.healthURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            } catch {
                // Server not up yet
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    // MARK: - Helpers (mirrors ASREngine / LLMRefiner logic)

    private func findScript() -> String? {
        if let path = Bundle.main.path(forResource: "tnt_server", ofType: "py") {
            return path
        }
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/tnt_server.py"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let candidates = [
            Bundle.main.bundlePath + "/Resources/tnt_server.py",
            Bundle.main.bundlePath + "/../Resources/tnt_server.py",
            Bundle.main.bundlePath + "/../../Resources/tnt_server.py",
            "scripts/tnt_server.py",
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func findPythonExecutable() -> String {
        let candidates = [
            "/opt/anaconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        // Verify by trying to import either mlx_audio or mlx_lm (server needs both)
        for py in candidates {
            guard FileManager.default.isExecutableFile(atPath: py) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: py)
            process.arguments = ["-c", "import mlx_audio; import mlx_lm"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return py
                }
            } catch {
                continue
            }
        }

        TNTLog.warning("[TNTServerManager] No Python with mlx-audio+mlx-lm found, falling back")
        return "/usr/bin/python3"
    }
}
