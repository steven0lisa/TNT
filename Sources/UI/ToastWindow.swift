import AppKit
import Foundation

@MainActor
final class ToastWindow: NSObject {
    private var panel: NSPanel?
    private var hideTimer: Timer?

    init(message: String) {
        super.init()
        createPanel(message: message)
    }

    private func createPanel(message: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))

        let textField = NSTextField(labelWithString: message)
        textField.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        textField.textColor = .white
        textField.alignment = .center
        textField.lineBreakMode = .byTruncatingTail
        textField.frame = NSRect(x: 20, y: 18, width: 360, height: 24)

        contentView.addSubview(textField)
        panel.contentView = contentView

        positionWindow(panel)
        self.panel = panel
    }

    private func positionWindow(_ panel: NSPanel) {
        if let windowFrame = FocusManager.shared.getFocusedWindowFrame() {
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect.zero
            let x = windowFrame.midX - 200
            let y = windowFrame.minY - 80
            panel.setFrameOrigin(NSPoint(
                x: max(screenFrame.minX, min(x, screenFrame.maxX - 400)),
                y: max(screenFrame.minY, y)
            ))
        } else {
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - 200
                let y = screenFrame.minY + 40
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }

    func show(duration: TimeInterval = 0) {
        guard let panel else { return }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
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

    func update(message: String) {
        guard let contentView = panel?.contentView,
              let textField = contentView.subviews.first as? NSTextField else {
            return
        }
        textField.stringValue = message
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { @Sendable in
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }
}
