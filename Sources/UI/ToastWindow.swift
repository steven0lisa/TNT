import AppKit
import Foundation

@MainActor
final class ToastWindow: NSObject {
    private var panel: NSPanel?
    private var hideTimer: Timer?

    private let diameter: CGFloat = 120
    private var waveformView: SiriWaveformView?
    private var statusLabel: NSTextField?

    override init() {
        super.init()
        createPanel()
    }

    // MARK: - Panel Setup

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))

        // 圆形背景
        let circleBg = CircleBackgroundView(frame: containerView.bounds)
        circleBg.targetColor = NSColor.black.withAlphaComponent(0.75)
        containerView.addSubview(circleBg)

        // 波形视图
        let wave = SiriWaveformView(frame: containerView.bounds.insetBy(dx: 8, dy: 8))
        wave.waveColor = NSColor.white.withAlphaComponent(0.9)
        wave.numberOfWaves = 5
        wave.primaryWaveLineWidth = 2.5
        wave.secondaryWaveLineWidth = 1.0
        wave.frequency = 1.8
        wave.idleAmplitude = 0.008
        containerView.addSubview(wave)
        waveformView = wave

        // 状态文字（居中，识别中/校正中时显示）
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: diameter / 2 - 10, width: diameter, height: 20)
        label.isHidden = true
        containerView.addSubview(label)
        statusLabel = label

        panel.contentView = containerView
        positionWindow(panel)
        self.panel = panel
    }

    private func positionWindow(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - diameter / 2
        let y = screenFrame.minY + screenFrame.height * 0.08
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Show / Hide

    func show(duration: TimeInterval = 0) {
        guard let panel else { return }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        if duration > 0 {
            hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.hide()
                }
            }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        waveformView?.stopAnimating()

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { @Sendable in
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }

    // MARK: - Waveform Update

    /// 传入归一化振幅 (0..1) 驱动波形动画
    func updateAmplitude(_ level: CGFloat) {
        waveformView?.update(withLevel: level)
    }

    /// 切换到录音模式（显示波形，隐藏文字）
    func showRecording() {
        waveformView?.isHidden = false
        waveformView?.startAnimating()
        statusLabel?.isHidden = true
    }

    /// 切换到状态文字模式（隐藏波形，显示居中文字）
    func showStatus(_ text: String) {
        waveformView?.stopAnimating()
        waveformView?.isHidden = true
        statusLabel?.stringValue = text
        statusLabel?.isHidden = false
        // 固定宽度为 diameter，利用 alignment=.center 自然居中
        if let label = statusLabel {
            label.sizeToFit()
            label.frame = NSRect(
                x: 0,
                y: diameter / 2 - label.frame.height / 2,
                width: diameter,
                height: label.frame.height
            )
        }
    }
}

// MARK: - Circle Background View

private final class CircleBackgroundView: NSView {
    var targetColor: NSColor = .black

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let radius = min(rect.width, rect.height) / 2

        context.setFillColor(targetColor.cgColor)
        context.fillEllipse(in: NSRect(
            x: rect.midX - radius,
            y: rect.midY - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}
