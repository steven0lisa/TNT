import Foundation

enum ModelType: String, Sendable {
    case asrSmall
    case asrLarge
    case llmSmall
    case llmLarge
    case ocr
}

struct ModelInfo: Codable, Sendable {
    let name: String
    let quantization: String
    let size: String
    let source: String
    let path: String
    var downloaded: Bool
    let urls: ModelURLs

    struct ModelURLs: Codable, Sendable {
        let huggingface: String
        let modelscope: String
    }
}

struct PackageConfig: Codable, Sendable {
    let name: String
    let version: String
    let models: Models

    struct Models: Codable, Sendable {
        let asrSmall: ModelInfo
        let asrLarge: ModelInfo
        let llmSmall: ModelInfo
        let llmLarge: ModelInfo
    }
}

final class ModelManager: @unchecked Sendable {
    static let shared = ModelManager()

    private var config: PackageConfig?
    private let lock = NSLock()

    /// User-selected ASR model: "small" or "large"
    var selectedASRModel: String {
        get { UserDefaults.standard.string(forKey: "selectedASRModel") ?? "small" }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectedASRModel")
            TNTLog.info("[ModelManager] Selected ASR model changed to: \(newValue)")
        }
    }

    /// User-selected LLM model: "small" (0.5B) or "large" (4B)
    var selectedLLMModel: String {
        get { UserDefaults.standard.string(forKey: "selectedLLMModel") ?? "small" }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectedLLMModel")
            TNTLog.info("[ModelManager] Selected LLM model changed to: \(newValue)")
        }
    }

    /// User-selected OCR engine: "vision" (default, system native) or "paddleocr"
    var selectedOCREngine: String {
        get { UserDefaults.standard.string(forKey: "selectedOCREngine") ?? "vision" }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectedOCREngine")
            TNTLog.info("[ModelManager] Selected OCR engine changed to: \(newValue)")
        }
    }

    /// The active ASR model type based on user selection
    var activeASRType: ModelType {
        selectedASRModel == "large" ? .asrLarge : .asrSmall
    }

    /// The active LLM model type based on user selection
    var activeLLMType: ModelType {
        selectedLLMModel == "large" ? .llmLarge : .llmSmall
    }

    var modelsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".tnt/models", isDirectory: true)
    }

    private init() {
        loadConfigSync()
        ensureModelsDirectory()
    }

    // MARK: - Config

    private func loadConfigSync() {
        setenv("HF_ENDPOINT", "https://hf-mirror.com", 1)

        let possiblePaths = [
            Bundle.main.bundlePath + "/Resources/package.json",
            Bundle.main.bundlePath + "/../package.json",
            "package.json",
        ]

        for configPath in possiblePaths {
            if let data = FileManager.default.contents(atPath: configPath),
               let parsed = try? JSONDecoder().decode(PackageConfig.self, from: data) {
                lock.lock()
                config = parsed
                lock.unlock()
                TNTLog.info("[ModelManager] Loaded config from: \(configPath)")
                return
            }
        }
        TNTLog.warning("[ModelManager] package.json not found, using defaults")
    }

    private func ensureModelsDirectory() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        TNTLog.info("[ModelManager] Models directory: \(modelsDirectory.path)")
    }

    func modelInfo(for type: ModelType) -> ModelInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let config else { return nil }
        switch type {
        case .asrSmall: return config.models.asrSmall
        case .asrLarge: return config.models.asrLarge
        case .llmSmall: return config.models.llmSmall
        case .llmLarge: return config.models.llmLarge
        case .ocr: return nil
        }
    }

    func modelPath(for type: ModelType) -> String {
        if let info = modelInfo(for: type) {
            let expanded = (info.path as NSString).expandingTildeInPath
            return expanded
        }
        let modelDir = modelsDirectory.path
        switch type {
        case .asrSmall: return modelDir + "/Qwen3-ASR-0.6B"
        case .asrLarge: return modelDir + "/Qwen3-ASR-1.7B"
        case .llmSmall: return modelDir + "/Qwen3-0.6B-4bit"
        case .llmLarge: return modelDir + "/Qwen3-4B-4bit"
        case .ocr: return modelDir + "/PaddleOCR-VL"
        }
    }

    func isDownloaded(type: ModelType) -> Bool {
        let path = modelPath(for: type)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard exists && isDir.boolValue else { return false }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
            let hasFiles = contents.contains { !$0.hasPrefix(".") }
            return hasFiles
        }
        return false
    }

    // MARK: - Ensure Ready

    func ensureModelReady(for type: ModelType) async -> Bool {
        if isDownloaded(type: type) {
            TNTLog.info("[ModelManager] Model \(type) already downloaded")
            return true
        }
        TNTLog.info("[ModelManager] Model \(type) not found, will auto-download on first use")
        return false
    }

    // MARK: - Download with progress

    func downloadModel(for type: ModelType, onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async -> Bool {
        let downloader = ModelDownloader.shared
        return await downloader.download(type: type, onProgress: { progress in
            onProgress?(progress)
        })
    }

    // MARK: - Delete

    func deleteModel(for type: ModelType) throws {
        let path = modelPath(for: type)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            TNTLog.info("[ModelManager] Deleted model at \(path)")
        }
    }
}
