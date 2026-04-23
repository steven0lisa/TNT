import Foundation

struct HFRepoFile: Codable, Sendable {
    let type: String
    let oid: String
    let size: Int64?
    let path: String
}

struct DownloadProgress: Sendable {
    let fraction: Double
    let speedBytesPerSec: Int64
    let downloadedBytes: Int64
    let totalBytes: Int64
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

    func download(type: ModelType, onProgress: @escaping (DownloadProgress) -> Void) async -> Bool {
        let repoId = repoId(for: type)
        let modelDirName = directoryName(for: type)
        let targetDir = ModelManager.shared.modelsDirectory.appendingPathComponent(modelDirName)

        TNTLog.info("[ModelDownloader] Starting download for \(type) from \(repoId)")
        TNTLog.info("[ModelDownloader] Target: \(targetDir.path)")

        guard let files = await fetchFileList(repoId: repoId) else {
            TNTLog.error("[ModelDownloader] Failed to fetch file list for \(repoId)")
            return false
        }

        let neededFiles = files.filter { shouldDownload($0) }
        let totalSize = neededFiles.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        TNTLog.info("[ModelDownloader] Files to download: \(neededFiles.count), total size: \(formatBytes(totalSize))")

        if neededFiles.isEmpty {
            TNTLog.warning("[ModelDownloader] No files to download")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            TNTLog.error("[ModelDownloader] Failed to create directory: \(error)")
            return false
        }

        var globalDownloaded: Int64 = 0
        let totalSizeSafe = max(totalSize, 1)

        for (index, file) in neededFiles.enumerated() {
            let sourceURL = fileURL(repoId: repoId, filePath: file.path)
            let destURL = targetDir.appendingPathComponent(file.path)
            let fileSize = file.size ?? 0

            // Skip already downloaded
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
               let existingSize = attrs[.size] as? Int64,
               fileSize > 0, existingSize == fileSize {
                TNTLog.info("[ModelDownloader] Skipping \(file.path)")
                globalDownloaded += fileSize
                onProgress(DownloadProgress(
                    fraction: Double(globalDownloaded) / Double(totalSizeSafe),
                    speedBytesPerSec: 0,
                    downloadedBytes: globalDownloaded,
                    totalBytes: totalSize
                ))
                continue
            }

            TNTLog.info("[ModelDownloader] [\(index + 1)/\(neededFiles.count)] \(file.path) (\(formatBytes(fileSize)))")

            let fileBytes = await streamDownload(
                from: sourceURL,
                expectedSize: fileSize,
                totalDownloaded: &globalDownloaded,
                totalSize: totalSizeSafe,
                onProgress: onProgress
            )

            guard let fileBytes, !fileBytes.isEmpty else {
                TNTLog.error("[ModelDownloader] Failed to download \(file.path)")
                return false
            }

            // Write to file
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(atPath: destURL.path)
            }
            let parentDir = destURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            do {
                try fileBytes.write(to: destURL)
                TNTLog.info("[ModelDownloader] Saved \(file.path)")
            } catch {
                TNTLog.error("[ModelDownloader] Failed to write \(file.path): \(error)")
                return false
            }
        }

        TNTLog.info("[ModelDownloader] Download complete for \(type)")
        return true
    }

    // MARK: - Stream Download

    private func streamDownload(
        from url: URL,
        expectedSize: Int64,
        totalDownloaded: inout Int64,
        totalSize: Int64,
        onProgress: @escaping (DownloadProgress) -> Void
    ) async -> Data? {
        var result = Data()
        if expectedSize > 0 { result.reserveCapacity(Int(expectedSize)) }

        var speedSamples: [Int64] = []

        do {
            let (bytes, response) = try await session.bytes(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                TNTLog.error("[ModelDownloader] HTTP error: \(code)")
                return nil
            }

            var startTime = ContinuousClock.now
            var intervalBytes: Int64 = 0

            for try await byte in bytes {
                result.append(byte)
                intervalBytes += 1

                let elapsed = ContinuousClock.now - startTime
                if elapsed >= .milliseconds(500) {
                    let elapsedSec = Double(elapsed.components.attoseconds) / 1e18
                        + Double(elapsed.components.seconds)
                    let speed = elapsedSec > 0 ? Int64(Double(intervalBytes) / elapsedSec) : 0
                    speedSamples.append(speed)
                    if speedSamples.count > 4 { speedSamples.removeFirst() }
                    let avgSpeed = speedSamples.reduce(Int64(0), +) / Int64(max(speedSamples.count, 1))

                    totalDownloaded += intervalBytes
                    onProgress(DownloadProgress(
                        fraction: Double(totalDownloaded) / Double(totalSize),
                        speedBytesPerSec: avgSpeed,
                        downloadedBytes: totalDownloaded,
                        totalBytes: totalSize
                    ))
                    intervalBytes = 0
                    startTime = ContinuousClock.now
                }
            }

            if intervalBytes > 0 {
                totalDownloaded += intervalBytes
                let avgSpeed = speedSamples.isEmpty ? Int64(0) : speedSamples.reduce(Int64(0), +) / Int64(speedSamples.count)
                onProgress(DownloadProgress(
                    fraction: Double(totalDownloaded) / Double(totalSize),
                    speedBytesPerSec: avgSpeed,
                    downloadedBytes: totalDownloaded,
                    totalBytes: totalSize
                ))
            }

            return result
        } catch {
            TNTLog.error("[ModelDownloader] Stream error: \(error)")
            return nil
        }
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
        return components.url!
    }

    // MARK: - Helpers

    private func shouldDownload(_ file: HFRepoFile) -> Bool {
        guard file.type == "file" else { return false }
        let skipFiles = ["gitattributes", "README.md", "LICENSE", ".gitignore"]
        return !skipFiles.contains(file.path)
    }

    private func repoId(for type: ModelType) -> String {
        switch type {
        case .asrSmall: return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case .asrLarge: return "mlx-community/Qwen3-ASR-1.7B-4bit"
        case .llmSmall: return "mlx-community/Qwen3-0.6B-4bit"
        case .llmLarge: return "mlx-community/Qwen3-4B-4bit"
        case .ocr: return "PaddlePaddle/PaddleOCR-VL"
        }
    }

    private func directoryName(for type: ModelType) -> String {
        switch type {
        case .asrSmall: return "Qwen3-ASR-0.6B"
        case .asrLarge: return "Qwen3-ASR-1.7B"
        case .llmSmall: return "Qwen3-0.6B-4bit"
        case .llmLarge: return "Qwen3-4B-4bit"
        case .ocr: return "PaddleOCR-VL"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}
