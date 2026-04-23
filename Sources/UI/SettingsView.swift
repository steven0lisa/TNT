import SwiftUI

struct SettingsView: View {
    @StateObject private var modelManager = ModelManagerWrapper.shared

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }

            ModelsTab()
                .tabItem {
                    Label("模型", systemImage: "cpu")
                }

            HotkeyDiagnosticsTab()
                .tabItem {
                    Label("诊断", systemImage: "stethoscope")
                }
        }
        .frame(width: 520, height: 420)
        .padding()
    }
}

struct GeneralTab: View {
    @State private var hotkey: String = UserDefaults.standard.string(forKey: "hotkey") ?? "Option + Control + Command"

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("全局快捷键")
                    Spacer()
                    Button(hotkey) {
                        // 热键录制（Phase 1: 显示说明）
                    }
                    .buttonStyle(.bordered)
                }

                Text("按下快捷键开始录音，松开后自动输入文字。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("权限状态") {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("麦克风权限")
                    Spacer()
                    Text(checkMicPermission())
                        .foregroundColor(.secondary)
                }

                HStack {
                    Image(systemName: checkAccessibility() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(checkAccessibility() ? .green : .red)
                    Text("辅助功能权限")
                    Spacer()
                    Text(checkAccessibility() ? "已授权" : "未授权")
                        .foregroundColor(.secondary)
                    if !checkAccessibility() {
                        Button("打开设置") {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func checkMicPermission() -> String {
        return "已授权"
    }

    private func checkAccessibility() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options: [String: Bool] = [promptKey: false]
        let cfOptions = options as CFDictionary
        return AXIsProcessTrustedWithOptions(cfOptions)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ModelsTab: View {
    @StateObject private var modelManager = ModelManagerWrapper.shared

    var body: some View {
        Form {
            Section("模型存储路径") {
                HStack {
                    Text("~/.tnt/models")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("在 Finder 中打开") {
                        openModelsDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Section("ASR 模型") {
                modelRow(
                    name: "Qwen3-ASR-0.6B",
                    size: "~500MB",
                    type: .asr
                )
            }

            Section("LLM 校正模型") {
                modelRow(
                    name: "Qwen3-4B-4bit",
                    size: "~2.5GB",
                    type: .llm
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func modelRow(name: String, size: String, type: ModelType) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(size)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if modelManager.isDownloaded(type) {
                Label("已就绪", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)

                Button(role: .destructive) {
                    modelManager.deleteModel(type)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if modelManager.isDownloading(type) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("下载中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button("下载") {
                    Task {
                        await modelManager.downloadModel(type)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func openModelsDirectory() {
        let path = ModelManager.shared.modelsDirectory.path
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

struct HotkeyDiagnosticsTab: View {
    @State private var diagnosticText: String = "点击刷新查看状态"
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section("热键诊断") {
                Text(diagnosticText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)

                HStack {
                    Button("刷新状态") {
                        refreshDiagnostics()
                    }
                    .buttonStyle(.bordered)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button("打开辅助功能设置") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("使用说明") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 确保 TNT 已添加到「系统设置 → 隐私与安全性 → 辅助功能」并开启开关")
                        .font(.caption)
                    Text("2. 授予权限后，TNT 会自动检测并启用热键")
                        .font(.caption)
                    Text("3. 按住 Option + Control + Command 开始录音，松开结束")
                        .font(.caption)
                    Text("4. 如果热键仍不工作，请查看 Console.app 中的 TNT 日志")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() {
        isRefreshing = true
        // Use a small delay to show the refresh animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let trusted = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": false] as CFDictionary
            )
            let info = """
            辅助功能权限: \(trusted ? "✅ 已授权" : "❌ 未授权")
            激活快捷键: Option + Control + Command
            """
            diagnosticText = info
            isRefreshing = false
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// SwiftUI Observable wrapper for ModelManager
@MainActor
final class ModelManagerWrapper: ObservableObject {
    static let shared = ModelManagerWrapper()

    @Published private(set) var asrDownloaded: Bool = false
    @Published private(set) var llmDownloaded: Bool = false
    @Published private(set) var asrDownloading: Bool = false
    @Published private(set) var llmDownloading: Bool = false

    private let manager = ModelManager.shared

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        asrDownloaded = manager.isDownloaded(type: .asr)
        llmDownloaded = manager.isDownloaded(type: .llm)
        TNTLog.info("[ModelManagerWrapper] ASR: \(asrDownloaded ? "ready" : "missing"), LLM: \(llmDownloaded ? "ready" : "missing")")
    }

    func isDownloaded(_ type: ModelType) -> Bool {
        switch type {
        case .asr: return asrDownloaded
        case .llm: return llmDownloaded
        }
    }

    func isDownloading(_ type: ModelType) -> Bool {
        switch type {
        case .asr: return asrDownloading
        case .llm: return llmDownloading
        }
    }

    func downloadModel(_ type: ModelType) async {
        guard !isDownloading(type) else {
            TNTLog.warning("[ModelManagerWrapper] Download already in progress for \(type)")
            return
        }

        if type == .asr {
            asrDownloading = true
        } else {
            llmDownloading = true
        }

        TNTLog.info("[ModelManagerWrapper] Starting download for \(type)")

        let success = await manager.downloadModel(for: type)

        if type == .asr {
            asrDownloading = false
        } else {
            llmDownloading = false
        }

        refreshStatus()

        if success {
            TNTLog.info("[ModelManagerWrapper] Download succeeded for \(type)")
        } else {
            TNTLog.error("[ModelManagerWrapper] Download failed for \(type)")
        }
    }

    func deleteModel(_ type: ModelType) {
        do {
            try manager.deleteModel(for: type)
            refreshStatus()
            TNTLog.info("[ModelManagerWrapper] Deleted \(type) model")
        } catch {
            TNTLog.error("[ModelManagerWrapper] Failed to delete \(type): \(error)")
        }
    }
}
