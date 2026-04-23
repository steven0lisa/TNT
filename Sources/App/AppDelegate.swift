import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var hotkeyManager: HotkeyManager?
    private var toastWindow: ToastWindow?
    private var permissionCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TNTLog.info("[TNT-App] applicationDidFinishLaunching")
        setupStatusBar()
        setupHotkey()

        // 1. Check Python environment first
        Task { @MainActor in
            let pythonOK = await self.checkPythonEnvironment()
            guard pythonOK else {
                self.showPythonSetupAlert()
                return
            }

            // 2. Start Python HTTP server (models pre-loaded inside)
            let serverReady = await TNTServerManager.shared.start()
            if serverReady {
                AppState.shared.modelsReady = true
                self.statusBarController?.setLoadingState(false)
                TNTLog.info("[TNT-App] Python server ready, models pre-loaded")
            } else {
                self.statusBarController?.setLoadingState(false)
                self.showToast("模型服务启动失败", duration: 3.0)
                TNTLog.error("[TNT-App] Python server failed to start")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TNTLog.info("[TNT-App] applicationWillTerminate")
        hotkeyManager?.stop()
        permissionCheckTimer?.invalidate()
        TNTServerManager.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.toggleMenu()
        return true
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusBarController = StatusBarController()
        statusBarController?.onSettingsRequested = { [weak self] in
            self?.showSettings()
        }
        statusBarController?.onAboutRequested = { [weak self] in
            self?.showAbout()
        }
        statusBarController?.onQuitRequested = {
            NSApplication.shared.terminate(nil)
        }
    }

    private func setupHotkey() {
        TNTLog.info("[TNT-App] setupHotkey begin")
        hotkeyManager = HotkeyManager()
        hotkeyManager?.onKeyDown = { [weak self] in
            Task { @MainActor in
                self?.handleHotkeyDown()
            }
        }
        hotkeyManager?.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.handleHotkeyUp()
            }
        }

        let hasPermission = hotkeyManager!.checkPermissions()
        TNTLog.info("[TNT-App] permission check result: \(hasPermission ? "GRANTED" : "DENIED")")

        if !hasPermission {
            TNTLog.info("[TNT-App] Permission denied, showing alert and polling...")
            showPermissionAlert()
            startPermissionPolling()
        } else {
            TNTLog.info("[TNT-App] Permission granted, starting hotkey manager...")
            hotkeyManager?.start()
        }
    }

    private func startPermissionPolling() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let nowGranted = self.hotkeyManager?.checkPermissions() ?? false
                TNTLog.info("[TNT-App] Poll: permission=\(nowGranted ? "GRANTED" : "DENIED")")
                if nowGranted {
                    TNTLog.info("[TNT-App] Permission now granted! Starting hotkey...")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.hotkeyManager?.start()
                    self.statusBarController?.setLoadingState(false)
                }
            }
        }
    }

    // MARK: - Python Environment Check

    private func checkPythonEnvironment() async -> Bool {
        let candidates = [
            "/opt/anaconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for py in candidates {
            guard FileManager.default.isExecutableFile(atPath: py) else { continue }
            let hasDeps = await verifyPythonDeps(python: py)
            if hasDeps {
                TNTLog.info("[TNT-App] Python env OK: \(py)")
                return true
            }
        }

        TNTLog.error("[TNT-App] No Python with mlx-audio + mlx-lm found")
        return false
    }

    private func verifyPythonDeps(python: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = ["-c", "import mlx_audio; import mlx_lm"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Hotkey Handlers

    private var audioRecorder: AudioRecorder?
    private var recordingFile: URL?

    private func handleHotkeyDown() {
        guard AppState.shared.modelsReady else {
            TNTLog.info("[TNT-App] Hotkey pressed but models not ready")
            showToast("模型未就绪，请等待服务启动", duration: 2.0)
            return
        }

        TNTLog.info("[TNT-App] >>> Combo DOWN — starting recording")
        AppState.shared.mode = .recording
        statusBarController?.setRecordingState(true)
        showToast("倾听中...")

        audioRecorder = AudioRecorder()
        audioRecorder?.onAudioBuffer = { [weak self] buffer in
            self?.handleAudioBuffer(buffer)
        }
        audioRecorder?.start()
    }

    private func handleHotkeyUp() {
        TNTLog.info("[TNT-App] >>> Combo UP — stopping recording")
        audioRecorder?.stop()
        recordingFile = audioRecorder?.takeRecordingFile()
        audioRecorder = nil

        // Guard: no valid recording file
        guard let file = recordingFile,
              FileManager.default.fileExists(atPath: file.path) else {
            TNTLog.warning("[TNT-App] No recording file, aborting")
            finishWithError("录音文件无效")
            return
        }

        // Guard: empty file
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? Int, size < 1024 {
            TNTLog.warning("[TNT-App] Recording file too small (\(size) bytes), aborting")
            cleanupRecordingFile()
            finishWithError("录音时间太短")
            return
        }

        AppState.shared.mode = .recognizing
        showToast("识别中...")

        TNTLog.info("[TNT-App] Audio file: \(file.path)")

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.recognizeAndInject(audioFile: file)
        }
    }

    private func handleAudioBuffer(_ buffer: Data) {
        // Phase 2: 实时 ASR 流式处理
    }

    private func recognizeAndInject(audioFile: URL) async {
        TNTLog.info("[TNT-App] Starting ASR...")
        let asrText = await ASREngine.shared.transcribe(fileURL: audioFile)
        TNTLog.info("[TNT-App] ASR result: \(String(asrText.prefix(50)))")

        await MainActor.run {
            AppState.shared.lastRecognizedText = asrText
        }

        // Guard: empty ASR result — silently dismiss
        if asrText.isEmpty {
            await MainActor.run {
                cleanupRecordingFile()
                finishSilently()
            }
            return
        }

        if asrText.hasPrefix("ERROR:") {
            await MainActor.run {
                cleanupRecordingFile()
                finishWithError(asrText)
            }
            return
        }

        await MainActor.run {
            AppState.shared.mode = .refining
            showToast("校正中...")
        }

        TNTLog.info("[TNT-App] Starting LLM refinement...")
        let refinedText = await LLMRefiner.shared.refine(text: asrText)
        TNTLog.info("[TNT-App] LLM result: \(String(refinedText.prefix(50)))")

        await MainActor.run {
            AppState.shared.mode = .injecting
            showToast("注入中...")
        }

        let finalText = refinedText.isEmpty || refinedText.hasPrefix("ERROR:") ? asrText : refinedText
        await injectText(finalText)
    }

    private func injectText(_ text: String) async {
        TNTLog.info("[TNT-App] Injecting text...")
        let success = await FocusManager.shared.inject(text: text)

        if success {
            await finishSuccessfullyAsync(text: text)
        } else {
            await finishWithErrorAsync("文字注入失败")
        }
    }

    private func finishSuccessfullyAsync(text: String) async {
        await MainActor.run {
            finishSuccessfully(text: text)
        }
    }

    private func finishWithErrorAsync(_ message: String) async {
        await MainActor.run {
            finishWithError(message)
        }
    }

    private func finishSuccessfully(text: String) {
        TNTLog.info("[TNT-App] Success: \(text)")
        // Toast disappears immediately on success (text already injected to cursor)
        toastWindow?.hide()
        AppState.shared.mode = .idle
        statusBarController?.setRecordingState(false)
        cleanupRecordingFile()
    }

    private func finishWithError(_ message: String) {
        TNTLog.info("[TNT-App] Error: \(message)")
        AppState.shared.mode = .error(message)
        showToast("✗ \(message)", duration: 2.0)
        statusBarController?.setRecordingState(false)
        cleanupRecordingFile()

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            AppState.shared.mode = .idle
        }
    }

    private func finishSilently() {
        TNTLog.info("[TNT-App] Silently dismissed (empty result)")
        toastWindow?.hide()
        AppState.shared.mode = .idle
        statusBarController?.setRecordingState(false)
        cleanupRecordingFile()
    }

    private func cleanupRecordingFile() {
        if let file = recordingFile {
            try? FileManager.default.removeItem(at: file)
            TNTLog.debug("[TNT-App] Cleaned up recording file: \(file.path)")
        }
        recordingFile = nil
    }

    // MARK: - UI Helpers

    private func showToast(_ message: String, duration: TimeInterval = 0) {
        toastWindow?.hide()
        toastWindow = ToastWindow(message: message)
        toastWindow?.show(duration: duration)
    }

    private func showSettings() {
        TNTLog.info("[TNT-App] Opening settings window")
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "TNT 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 400))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "TNT — Touch and Talk"
        alert.informativeText = """
        版本：1.0.0

        基于全局快捷键的智能语音输入法。
        按下快捷键说话，松开即完成输入，AI 帮你润色。

        需要 Apple Silicon Mac，32GB+ 统一内存（推荐）。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "TNT 需要访问辅助功能来监听全局快捷键和注入文字。\n\n请在 系统设置 → 隐私与安全性 → 辅助功能 中添加 TNT 并开启开关。\n\n授予权限后，TNT 会自动检测并启用热键。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showPythonSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "需要初始化 Python 环境"
        alert.informativeText = """
        TNT 需要 Python 3 以及以下依赖包：

        • mlx-audio  (语音转文字)
        • mlx-lm     (文本校正)

        请打开终端并运行：

        pip install -U mlx-audio mlx-lm

        安装完成后重启 TNT。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "复制命令")
        alert.addButton(withTitle: "好的")

        if alert.runModal() == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("pip install -U mlx-audio mlx-lm", forType: .string)
        }
    }
}
