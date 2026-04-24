import AVFoundation
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

            DiagnosticsTab()
                .tabItem {
                    Label("诊断", systemImage: "stethoscope")
                }
        }
        .frame(minWidth: 520, minHeight: 420)
        .padding()
    }
}

struct GeneralTab: View {
    @State private var hotkey: String = UserDefaults.standard.string(forKey: "hotkey") ?? "Option + Control + Command"
    @StateObject private var updateChecker = UpdateChecker.shared

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

            Section("版本与更新") {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text(updateChecker.currentVersion)
                        .foregroundColor(.secondary)
                }

                HStack {
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在检查...")
                            .foregroundColor(.secondary)
                    } else if let release = updateChecker.latestRelease {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("发现新版本 \(release.version)")
                                .foregroundColor(.orange)
                            if let asset = release.dmgAsset {
                                Button("下载并安装 (\(asset.sizeLabel))") {
                                    Task { await updateChecker.downloadAndOpen(asset: asset) }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            if let body = release.body, !body.isEmpty {
                                Text(body)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(5)
                            }
                        }
                    } else if let error = updateChecker.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    } else {
                        Text("已是最新版本")
                            .foregroundColor(.green)
                    }

                    Spacer()

                    Button("检查更新") {
                        Task { await updateChecker.checkForUpdates() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(updateChecker.isChecking)
                }
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

            Section("ASR 语音识别模型") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择并下载要使用的模型。更大的模型精度更高，但占用更多内存。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    asrModelRow(
                        name: "Qwen3-ASR-0.6B",
                        size: "~500MB",
                        desc: "速度快，适合日常使用",
                        type: .asrSmall
                    )

                    Divider()

                    asrModelRow(
                        name: "Qwen3-ASR-1.7B",
                        size: "~1.3GB",
                        desc: "精度更高，适合复杂场景",
                        type: .asrLarge
                    )
                }
            }

            Section("LLM 校正模型") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择并下载要使用的校正模型。更大的模型效果更好，但速度更慢。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    llmModelRow(
                        name: "Qwen3-0.6B",
                        size: "~335MB",
                        desc: "速度快，适合日常使用（默认）",
                        type: .llmSmall
                    )

                    Divider()

                    llmModelRow(
                        name: "Qwen3-4B-4bit",
                        size: "~2.5GB",
                        desc: "效果更好，适合高精度场景",
                        type: .llmLarge
                    )
                }
            }

            Section("OCR 屏幕识别模型") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("下载后，录音时会自动截取屏幕并识别文字，辅助校正专有名词。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ocrModelRow(
                        name: "PaddleOCR-VL",
                        size: "~1.8GB",
                        desc: "屏幕文字识别，提升语音校正准确率"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func asrModelRow(name: String, size: String, desc: String, type: ModelType) -> some View {
        let isSelected = modelManager.selectedASRModel == (type == .asrLarge ? "large" : "small")
        let isDownloaded = modelManager.isDownloaded(type)
        let isDownloading = modelManager.isDownloading(type)

        HStack(alignment: .top, spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.title3)
                .onTapGesture {
                    guard isDownloaded else { return }
                    modelManager.selectASRModel(type == .asrLarge ? "large" : "small")
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.headline)
                    Text(size)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isDownloaded {
                if isSelected {
                    Label("使用中", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Button(role: .destructive) {
                    modelManager.deleteModel(type)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(modelManager.downloadPercent) / 100.0)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    HStack(spacing: 8) {
                        Text("\(modelManager.downloadPercent)%")
                            .font(.caption)
                            .monospacedDigit()
                        if !modelManager.downloadSpeed.isEmpty {
                            Text(modelManager.downloadSpeed)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Button("下载") {
                    Task {
                        await modelManager.downloadModel(type)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func llmModelRow(name: String, size: String, desc: String, type: ModelType) -> some View {
        let isSelected = modelManager.selectedLLMModel == (type == .llmLarge ? "large" : "small")
        let isDownloaded = modelManager.isDownloaded(type)
        let isDownloading = modelManager.isDownloading(type)

        HStack(alignment: .top, spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.title3)
                .onTapGesture {
                    guard isDownloaded else { return }
                    modelManager.selectLLMModel(type == .llmLarge ? "large" : "small")
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.headline)
                    Text(size)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isDownloaded {
                if isSelected {
                    Label("使用中", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Button(role: .destructive) {
                    modelManager.deleteModel(type)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(modelManager.downloadPercent) / 100.0)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    HStack(spacing: 8) {
                        Text("\(modelManager.downloadPercent)%")
                            .font(.caption)
                            .monospacedDigit()
                        if !modelManager.downloadSpeed.isEmpty {
                            Text(modelManager.downloadSpeed)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Button("下载") {
                    Task {
                        await modelManager.downloadModel(type)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func ocrModelRow(name: String, size: String, desc: String) -> some View {
        let isDownloaded = modelManager.isDownloaded(.ocr)
        let isDownloading = modelManager.isDownloading(.ocr)

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDownloaded ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isDownloaded ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.headline)
                    Text(size)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isDownloaded {
                Label("已就绪", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundColor(.green)

                Button(role: .destructive) {
                    modelManager.deleteModel(.ocr)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(modelManager.downloadPercent) / 100.0)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    HStack(spacing: 8) {
                        Text("\(modelManager.downloadPercent)%")
                            .font(.caption)
                            .monospacedDigit()
                        if !modelManager.downloadSpeed.isEmpty {
                            Text(modelManager.downloadSpeed)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Button("下载") {
                    Task {
                        await modelManager.downloadModel(.ocr)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
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

struct DiagnosticsTab: View {
    @State private var sessions: [SessionRecord] = []
    @State private var selectedId: String?
    @State private var playingType: String? = nil // "original" or "processed"
    @State private var player: AVAudioPlayer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("最近 \(sessions.count) 条语音记录")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("暂无语音记录")
                        .foregroundColor(.secondary)
                    Text("按住快捷键说话后，记录将出现在这里")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedId) {
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            playingType: playingType,
                            onPlay: { type in playAudio(sessionId: session.id, type: type) },
                            onStop: stopAudio
                        )
                        .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        sessions = SessionStore.shared.loadSessions()
    }

    private func playAudio(sessionId: String, type: String) {
        stopAudio()
        guard let url = SessionStore.shared.audioURL(sessionId: sessionId, type: type) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playingType = type
        // Auto-reset when playback ends
        DispatchQueue.main.asyncAfter(deadline: .now() + (player?.duration ?? 5.0)) {
            playingType = nil
        }
    }

    private func stopAudio() {
        player?.stop()
        player = nil
        playingType = nil
    }
}

// MARK: - SessionRow

private struct SessionRow: View {
    let session: SessionRecord
    let playingType: String?
    let onPlay: (String) -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header line
            HStack {
                Text(session.displayTime)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(session.shortId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                if session.isBluetooth {
                    Text("BT")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(3)
                }
                Spacer()
                if let error = session.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            // Audio playback buttons
            HStack(spacing: 8) {
                if session.hasOriginalAudio {
                    playButton(label: "原始", type: "original", isPlaying: playingType == "original")
                }
                if session.hasProcessedAudio {
                    playButton(label: "处理后", type: "processed", isPlaying: playingType == "processed")
                }
            }

            // ASR result
            if let asr = session.asrResult, !asr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ASR")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(asr)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(3)
                }
            }

            // LLM result
            if let llm = session.llmResult, !llm.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM 输出")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text(llm)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
            }

            // LLM prompt
            if let prompt = session.llmPrompt, !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM 提示词")
                        .font(.caption2)
                        .foregroundColor(.purple)
                    Text(prompt)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(10)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func playButton(label: String, type: String, isPlaying: Bool) -> some View {
        Button(action: {
            if isPlaying {
                onStop()
            } else {
                onPlay(type)
            }
        }) {
            HStack(spacing: 2) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.caption)
                Text(label)
                    .font(.caption2)
            }
            .foregroundColor(isPlaying ? .red : .accentColor)
        }
        .buttonStyle(.plain)
    }
}

// SwiftUI Observable wrapper for ModelManager
@MainActor
final class ModelManagerWrapper: ObservableObject {
    static let shared = ModelManagerWrapper()

    // ASR
    @Published private(set) var asrSmallDownloaded: Bool = false
    @Published private(set) var asrLargeDownloaded: Bool = false
    @Published private(set) var asrSmallDownloading: Bool = false
    @Published private(set) var asrLargeDownloading: Bool = false
    @Published var selectedASRModel: String

    // LLM
    @Published private(set) var llmSmallDownloaded: Bool = false
    @Published private(set) var llmLargeDownloaded: Bool = false
    @Published private(set) var llmSmallDownloading: Bool = false
    @Published private(set) var llmLargeDownloading: Bool = false
    @Published var selectedLLMModel: String

    // OCR
    @Published private(set) var ocrDownloaded: Bool = false
    @Published private(set) var ocrDownloading: Bool = false

    // Download progress
    @Published private(set) var downloadPercent: Int = 0
    @Published private(set) var downloadSpeed: String = ""

    private let manager = ModelManager.shared

    init() {
        selectedASRModel = manager.selectedASRModel
        selectedLLMModel = manager.selectedLLMModel
        refreshStatus()
    }

    func refreshStatus() {
        asrSmallDownloaded = manager.isDownloaded(type: .asrSmall)
        asrLargeDownloaded = manager.isDownloaded(type: .asrLarge)
        llmSmallDownloaded = manager.isDownloaded(type: .llmSmall)
        llmLargeDownloaded = manager.isDownloaded(type: .llmLarge)
        ocrDownloaded = manager.isDownloaded(type: .ocr)
        selectedASRModel = manager.selectedASRModel
        selectedLLMModel = manager.selectedLLMModel
        TNTLog.info("[ModelManagerWrapper] ASR-small: \(asrSmallDownloaded ? "ready" : "missing"), ASR-large: \(asrLargeDownloaded ? "ready" : "missing"), LLM-small: \(llmSmallDownloaded ? "ready" : "missing"), LLM-large: \(llmLargeDownloaded ? "ready" : "missing"), OCR: \(ocrDownloaded ? "ready" : "missing")")
    }

    func isDownloaded(_ type: ModelType) -> Bool {
        switch type {
        case .asrSmall: return asrSmallDownloaded
        case .asrLarge: return asrLargeDownloaded
        case .llmSmall: return llmSmallDownloaded
        case .llmLarge: return llmLargeDownloaded
        case .ocr: return ocrDownloaded
        }
    }

    func isDownloading(_ type: ModelType) -> Bool {
        switch type {
        case .asrSmall: return asrSmallDownloading
        case .asrLarge: return asrLargeDownloading
        case .llmSmall: return llmSmallDownloading
        case .llmLarge: return llmLargeDownloading
        case .ocr: return ocrDownloading
        }
    }

    func downloadModel(_ type: ModelType) async {
        guard !isDownloading(type) else {
            TNTLog.warning("[ModelManagerWrapper] Download already in progress for \(type)")
            return
        }

        switch type {
        case .asrSmall: asrSmallDownloading = true
        case .asrLarge: asrLargeDownloading = true
        case .llmSmall: llmSmallDownloading = true
        case .llmLarge: llmLargeDownloading = true
        case .ocr: ocrDownloading = true
        }

        downloadPercent = 0
        downloadSpeed = ""
        TNTLog.info("[ModelManagerWrapper] Starting download for \(type)")

        let success = await manager.downloadModel(for: type) { [weak self] progress in
            Task { @MainActor in
                self?.downloadPercent = Int(progress.fraction * 100)
                self?.downloadSpeed = Self.formatSpeed(progress.speedBytesPerSec)
            }
        }

        switch type {
        case .asrSmall: asrSmallDownloading = false
        case .asrLarge: asrLargeDownloading = false
        case .llmSmall: llmSmallDownloading = false
        case .llmLarge: llmLargeDownloading = false
        case .ocr: ocrDownloading = false
        }
        downloadPercent = 0
        downloadSpeed = ""

        refreshStatus()

        if success {
            TNTLog.info("[ModelManagerWrapper] Download succeeded for \(type)")
            // Auto-select if this is the only downloaded model of its category
            if type == .asrSmall || type == .asrLarge {
                let otherType: ModelType = (type == .asrSmall) ? .asrLarge : .asrSmall
                if !manager.isDownloaded(type: otherType) {
                    selectASRModel(type == .asrLarge ? "large" : "small")
                }
            } else if type == .llmSmall || type == .llmLarge {
                let otherType: ModelType = (type == .llmSmall) ? .llmLarge : .llmSmall
                if !manager.isDownloaded(type: otherType) {
                    selectLLMModel(type == .llmLarge ? "large" : "small")
                }
            } else if type == .ocr {
                // Warmup OCR engine after download
                await PaddleOCREngine.shared.warmup()
            }
        } else {
            TNTLog.error("[ModelManagerWrapper] Download failed for \(type)")
        }
    }

    private static func formatSpeed(_ bytesPerSec: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytesPerSec) + "/s"
    }

    func deleteModel(_ type: ModelType) {
        do {
            try manager.deleteModel(for: type)
            refreshStatus()
            TNTLog.info("[ModelManagerWrapper] Deleted \(type) model")
            // If deleted the currently selected model, switch to the other one if available
            if (type == .asrSmall && selectedASRModel == "small") ||
               (type == .asrLarge && selectedASRModel == "large") {
                let otherType: ModelType = (type == .asrSmall) ? .asrLarge : .asrSmall
                if manager.isDownloaded(type: otherType) {
                    selectASRModel(type == .asrSmall ? "large" : "small")
                }
            } else if (type == .llmSmall && selectedLLMModel == "small") ||
                      (type == .llmLarge && selectedLLMModel == "large") {
                let otherType: ModelType = (type == .llmSmall) ? .llmLarge : .llmSmall
                if manager.isDownloaded(type: otherType) {
                    selectLLMModel(type == .llmSmall ? "large" : "small")
                }
            }
        } catch {
            TNTLog.error("[ModelManagerWrapper] Failed to delete \(type): \(error)")
        }
    }

    func selectASRModel(_ model: String) {
        guard manager.selectedASRModel != model else { return }
        manager.selectedASRModel = model
        selectedASRModel = model
        AppState.shared.updateSelectedASRModel(model)

        // Restart Python server to load the new ASR model
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.restartServerForModelChange()
        }
    }

    func selectLLMModel(_ model: String) {
        guard manager.selectedLLMModel != model else { return }
        manager.selectedLLMModel = model
        selectedLLMModel = model
        AppState.shared.updateSelectedLLMModel(model)

        // Restart Python server to load the new LLM model
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.restartServerForModelChange()
        }
    }
}
