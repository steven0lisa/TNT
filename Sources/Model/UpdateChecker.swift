import AppKit
import Foundation

// MARK: - GitHub Release Models

struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlUrl = "html_url"
        case assets
    }

    var version: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }

    var dmgAsset: GitHubAsset? {
        assets.first { $0.name.hasSuffix(".dmg") }
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }

    var sizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - UpdateChecker

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var isChecking = false
    @Published var latestRelease: GitHubRelease?
    @Published var errorMessage: String?
    @Published var downloadProgress: Double = 0

    private let repoOwner = "steven0lisa"
    private let repoName = "TNT"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private init() {}

    func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        latestRelease = nil

        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                errorMessage = "无法获取更新信息"
                isChecking = false
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            if isNewerVersion(release.version, current: currentVersion) {
                latestRelease = release
                TNTLog.info("[UpdateChecker] New version: \(release.version) (current: \(currentVersion))")
            } else {
                TNTLog.info("[UpdateChecker] Already up to date (\(currentVersion))")
            }
        } catch {
            errorMessage = "检查失败: \(error.localizedDescription)"
            TNTLog.error("[UpdateChecker] Check failed: \(error)")
        }

        isChecking = false
    }

    func downloadAndOpen(asset: GitHubAsset) async {
        guard let url = URL(string: asset.browserDownloadUrl) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let tempDir = FileManager.default.temporaryDirectory
            let dest = tempDir.appendingPathComponent(asset.name)
            try data.write(to: dest)
            NSWorkspace.shared.open(dest)
            TNTLog.info("[UpdateChecker] Downloaded and opened: \(dest.path)")
        } catch {
            errorMessage = "下载失败: \(error.localizedDescription)"
            TNTLog.error("[UpdateChecker] Download failed: \(error)")
        }
    }

    func openReleasesPage() {
        let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases")!
        NSWorkspace.shared.open(url)
    }

    private func isNewerVersion(_ latest: String, current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}
