import Foundation

struct HFRepoFile: Codable, Sendable {
    let type: String
    let oid: String
    let size: Int64?
    let path: String
}

final class ModelDownloader: @unchecked Sendable {
    static let shared = ModelDownloader()

    private let session: URLSession
    private let hfEndpoint = "hf-mirror.com"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
        TNTLog.info("[ModelDownloader] Initialized")
    }

    // MARK: - Public API

    func download(type: ModelType, onProgress: @escaping (Double) -> Void) async -> Bool {
        let repoId = repoId(for: type)
        let modelDirName = directoryName(for: type)
        let targetDir = ModelManager.shared.modelsDirectory.appendingPathComponent(modelDirName)

        TNTLog.info("[ModelDownloader] Starting download for \(type) from \(repoId)")
        TNTLog.info("[ModelDownloader] Target: \(targetDir.path)")

        // 1. Fetch file list
        TNTLog.info("[ModelDownloader] Fetching file list...")
        guard let files = await fetchFileList(repoId: repoId) else {
            TNTLog.error("[ModelDownloader] Failed to fetch file list for \(repoId)")
            return false
        }

        let neededFiles = files.filter { shouldDownload($0) }
        let totalSize = neededFiles.reduce(0) { $0 + ($1.size ?? 0) }

        TNTLog.info("[ModelDownloader] Files to download: \(neededFiles.count), total size: \(formatBytes(totalSize))")

        if neededFiles.isEmpty {
            TNTLog.warning("[ModelDownloader] No files to download")
            return false
        }

        // 2. Create target directory
        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            TNTLog.info("[ModelDownloader] Created target directory")
        } catch {
            TNTLog.error("[ModelDownloader] Failed to create directory: \(error)")
            return false
        }

        // 3. Download files with progress
        var downloadedBytes: Int64 = 0

        for (index, file) in neededFiles.enumerated() {
            let fileURL = fileURL(repoId: repoId, filePath: file.path)
            let destURL = targetDir.appendingPathComponent(file.path)

            TNTLog.info("[ModelDownloader] [\(index + 1)/\(neededFiles.count)] Downloading \(file.path) (\(formatBytes(file.size ?? 0)))")

            let success = await downloadSingleFile(from: fileURL, to: destURL, expectedSize: file.size)

            if success {
                downloadedBytes += file.size ?? 0
                let progress = Double(downloadedBytes) / Double(max(totalSize, 1))
                onProgress(progress)
                TNTLog.info("[ModelDownloader] Progress: \(Int(progress * 100))%")
            } else {
                TNTLog.error("[ModelDownloader] Failed to download \(file.path)")
                return false
            }
        }

        TNTLog.info("[ModelDownloader] Download complete for \(type)")
        return true
    }

    // MARK: - File List

    private func fetchFileList(repoId: String) async -> [HFRepoFile]? {
        guard let url = apiURL(repoId: repoId) else {
            TNTLog.error("[ModelDownloader] Failed to construct API URL for \(repoId)")
            return nil
        }

        TNTLog.info("[ModelDownloader] API URL: \(url.absoluteString)")

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                TNTLog.error("[ModelDownloader] API response is not HTTP")
                return nil
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                TNTLog.error("[ModelDownloader] API returned HTTP \(httpResponse.statusCode)")
                return nil
            }
            let files = try JSONDecoder().decode([HFRepoFile].self, from: data)
            TNTLog.info("[ModelDownloader] API returned \(files.count) entries")
            return files
        } catch {
            TNTLog.error("[ModelDownloader] Failed to fetch file list: \(error)")
            return nil
        }
    }

    // MARK: - Single File Download

    private func downloadSingleFile(from fileURL: URL, to destination: URL, expectedSize: Int64?) async -> Bool {
        // Check if already downloaded (with size match)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let existingSize = attrs[.size] as? Int64,
           let expected = expectedSize,
           existingSize == expected {
            TNTLog.info("[ModelDownloader] Skipping already downloaded file: \(destination.lastPathComponent)")
            return true
        }

        TNTLog.info("[ModelDownloader] Downloading from: \(fileURL.absoluteString)")

        do {
            let (tempURL, response) = try await session.download(from: fileURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                TNTLog.error("[ModelDownloader] Response is not HTTP")
                return false
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                TNTLog.error("[ModelDownloader] HTTP error: \(httpResponse.statusCode)")
                return false
            }

            // Remove existing file if any
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }

            // Ensure parent directory exists
            let parentDir = destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            try FileManager.default.moveItem(at: tempURL, to: destination)
            TNTLog.info("[ModelDownloader] Saved to: \(destination.path)")
            return true

        } catch {
            TNTLog.error("[ModelDownloader] Download error: \(error)")
            return false
        }
    }

    // MARK: - URL Construction

    private func apiURL(repoId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = hfEndpoint
        components.path = "/api/models/\(repoId)/tree/main"
        return components.url
    }

    private func fileURL(repoId: String, filePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = hfEndpoint
        components.path = "/\(repoId)/resolve/main/\(filePath)"
        // URLComponents automatically encodes the path
        return components.url!
    }

    // MARK: - Helpers

    private func shouldDownload(_ file: HFRepoFile) -> Bool {
        guard file.type == "file" else { return false }
        let skipFiles = [".gitattributes", "README.md", "LICENSE", ".gitignore"]
        return !skipFiles.contains(file.path)
    }

    private func repoId(for type: ModelType) -> String {
        switch type {
        case .asrSmall:
            return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case .asrLarge:
            return "mlx-community/Qwen3-ASR-1.7B-4bit"
        case .llmSmall:
            return "mlx-community/Qwen3.6-0.5B-4bit"
        case .llmLarge:
            return "mlx-community/Qwen3-4B-4bit"
        }
    }

    private func directoryName(for type: ModelType) -> String {
        switch type {
        case .asrSmall:
            return "Qwen3-ASR-0.6B"
        case .asrLarge:
            return "Qwen3-ASR-1.7B"
        case .llmSmall:
            return "Qwen3.6-0.5B-4bit"
        case .llmLarge:
            return "Qwen3-4B-4bit"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}
