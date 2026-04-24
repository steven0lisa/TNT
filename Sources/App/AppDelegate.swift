import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var hotkeyManager: HotkeyManager?
    private var toastWindow: ToastWindow?
    private var permissionCheckTimer: Timer?
    private var screenText: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        TNTLog.info("[TNT-App] applicationDidFinishLaunching")
        setupStatusBar()
        setupHotkey()

        // 预热模型（异步）
        Task { @MainActor in
            self.statusBarController?.setLoadingState(true)

            // 预热 ASR（优先 Qwen3-ASR，未下载则使用 SFSpeechRecognizer）
            let asrType = ModelManager.shared.activeASRType
            if ModelManager.shared.isDownloaded(type: asrType) {
                await QwenASREngine.shared.warmup()
                if QwenASREngine.shared.isReady {
                    TNTLog.info("[TNT-App] Qwen3-ASR engine ready")
                } else {
                    ASREngine.shared.warmup()
                    TNTLog.info("[TNT-App] Qwen3-ASR warmup failed, using SFSpeechRecognizer")
                }
            } else {
                ASREngine.shared.warmup()
                TNTLog.info("[TNT-App] Qwen3-ASR not downloaded, using SFSpeechRecognizer")
            }

            // 预热 LLM
            await LLMRefiner.shared.warmup()

            // 预热 OCR（可选，仅当模型已下载）
            if PaddleOCREngine.isModelDownloaded() {
                await PaddleOCREngine.shared.warmup()
            }

            AppState.shared.modelsReady = true
            self.statusBarController?.setLoadingState(false)
            TNTLog.info("[TNT-App] Models warmed up")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TNTLog.info("[TNT-App] applicationWillTerminate")
        hotkeyManager?.stop()
        permissionCheckTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.toggleMenu()
        return true
    }

    /// 模型切换后的重启（当前版本使用本地模型，无需重启服务）
    func restartServerForModelChange() {
        TNTLog.info("[TNT-App] Model change detected, no server restart needed")
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

    // MARK: - Hotkey Handlers

    private var audioRecorder: AudioRecorder?
    private var recordingFile: URL?
    private var currentSessionId: String?

    private func handleHotkeyDown() {
        guard AppState.shared.modelsReady else {
            TNTLog.info("[TNT-App] Hotkey pressed but models not ready")
            showToast("模型未就绪，请等待加载", duration: 2.0)
            return
        }

        TNTLog.info("[TNT-App] >>> Combo DOWN — starting recording")
        AppState.shared.mode = .recording
        statusBarController?.setRecordingState(true)
        showRecordingToast()

        // 异步截图+OCR（与录音并行，不阻塞录音）
        Task.detached {
            if PaddleOCREngine.isModelDownloaded(),
               let image = await ScreenCapture.captureMainScreen() {
                let text = await PaddleOCREngine.shared.recognize(image: image)
                await MainActor.run {
                    self.screenText = text
                    TNTLog.info("[TNT-App] Screenshot OCR: \(String(text.prefix(100)))")
                }
            }
        }

        audioRecorder = AudioRecorder()
        audioRecorder?.onAudioBuffer = { [weak self] buffer in
            self?.handleAudioBuffer(buffer)
        }
        audioRecorder?.onAmplitude = { [weak self] level in
            Task { @MainActor in
                self?.toastWindow?.updateAmplitude(level)
            }
        }
        audioRecorder?.start()

        // 创建诊断会话
        let isBT = AudioRecorder.isBluetoothInputDevice()
        currentSessionId = SessionStore.shared.createSession(isBluetooth: isBT)
    }

    private func handleHotkeyUp() {
        TNTLog.info("[TNT-App] >>> Combo UP — stopping recording")
        audioRecorder?.stop()
        recordingFile = audioRecorder?.takeRecordingFile()

        // 保存音频文件到诊断会话
        if let sessionId = currentSessionId {
            if let original = audioRecorder?.originalFileURL {
                SessionStore.shared.saveOriginalAudio(sessionId: sessionId, from: original)
            }
            if let processed = recordingFile {
                SessionStore.shared.saveProcessedAudio(sessionId: sessionId, from: processed)
            }
        }

        audioRecorder = nil

        // Guard: no valid recording file (likely user released key before recording started)
        guard let file = recordingFile,
              FileManager.default.fileExists(atPath: file.path) else {
            TNTLog.warning("[TNT-App] No recording file, aborting silently")
            finishSilently()
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
        let sessionId = currentSessionId

        TNTLog.info("[TNT-App] Starting ASR...")
        var asrText: String

        if QwenASREngine.shared.isReady {
            asrText = await QwenASREngine.shared.transcribe(fileURL: audioFile)
            // QwenASR 失败时 fallback 到 SFSpeechRecognizer
            if asrText.hasPrefix("ERROR:") {
                TNTLog.warning("[TNT-App] QwenASR failed, falling back to SFSpeechRecognizer")
                asrText = await ASREngine.shared.transcribe(fileURL: audioFile)
            }
        } else {
            asrText = await ASREngine.shared.transcribe(fileURL: audioFile)
        }

        TNTLog.info("[TNT-App] ASR result: \(String(asrText.prefix(50)))")

        if let id = sessionId {
            SessionStore.shared.updateASRResult(sessionId: id, result: asrText)
        }

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
        let context = screenText.isEmpty ? nil : screenText
        let refineOutput = await LLMRefiner.shared.refine(text: asrText, context: context)
        TNTLog.info("[TNT-App] LLM result: \(String(refineOutput.text.prefix(50)))")

        if let id = sessionId {
            SessionStore.shared.updateLLMResult(sessionId: id, prompt: refineOutput.prompt, result: refineOutput.text)
        }

        await MainActor.run {
            AppState.shared.mode = .injecting
            showToast("注入中...")
        }

        let finalText = refineOutput.text.isEmpty || refineOutput.text.hasPrefix("ERROR:") ? asrText : refineOutput.text
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
        screenText = ""
        currentSessionId = nil
    }

    private func finishWithError(_ message: String) {
        TNTLog.info("[TNT-App] Error: \(message)")
        AppState.shared.mode = .error(message)
        showToast("✗ \(message)", duration: 2.0)
        statusBarController?.setRecordingState(false)
        cleanupRecordingFile()
        screenText = ""

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
        screenText = ""
        currentSessionId = nil
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
        toastWindow = ToastWindow()
        toastWindow?.showStatus(message)
        toastWindow?.show(duration: duration)
    }

    private func showRecordingToast() {
        toastWindow?.hide()
        toastWindow = ToastWindow()
        toastWindow?.showRecording()
        toastWindow?.show()
    }

    private func showSettings() {
        TNTLog.info("[TNT-App] Opening settings window")
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "TNT 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 580, height: 520))
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

        需要 Apple Silicon Mac，8GB+ 统一内存。
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
}
