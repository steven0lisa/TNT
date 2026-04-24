import Foundation

enum AppMode: Equatable, Sendable {
    case idle
    case recording
    case recognizing
    case refining
    case injecting
    case error(String)

    var statusDescription: String {
        switch self {
        case .idle: return "就绪"
        case .recording: return "倾听中..."
        case .recognizing: return "识别中"
        case .refining: return "校正中"
        case .injecting: return "注入中..."
        case .error(let msg): return "错误: \(msg)"
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var mode: AppMode = .idle
    @Published var modelsReady: Bool = false
    @Published var asrModelLoaded: Bool = false
    @Published var llmModelLoaded: Bool = false
    @Published var selectedASRModel: String = ModelManager.shared.selectedASRModel
    @Published var selectedLLMModel: String = ModelManager.shared.selectedLLMModel
    @Published var lastRecognizedText: String = ""
    @Published var toastMessage: String = ""

    private init() {}

    func setMode(_ newMode: AppMode) {
        mode = newMode
    }

    func updateSelectedASRModel(_ model: String) {
        selectedASRModel = model
        ModelManager.shared.selectedASRModel = model
    }

    func updateSelectedLLMModel(_ model: String) {
        selectedLLMModel = model
        ModelManager.shared.selectedLLMModel = model
    }
}
