import AppKit

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    var onSettingsRequested: (() -> Void)?
    var onAboutRequested: (() -> Void)?
    var onQuitRequested: (() -> Void)?

    override init() {
        super.init()
        setupStatusItem()
        setupMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = makeMicIcon(active: false)
            // Don't use template for better visibility
            button.image?.isTemplate = false
            button.toolTip = "TNT — Touch and Talk"
        }

        statusItem?.menu = nil
    }

    private func setupMenu() {
        menu = NSMenu()

        let aboutItem = NSMenuItem(title: "关于 TNT", action: #selector(aboutAction), keyEquivalent: "")
        aboutItem.target = self
        menu?.addItem(aboutItem)

        menu?.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu?.addItem(settingsItem)

        menu?.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 TNT", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu?.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func aboutAction() {
        onAboutRequested?()
    }

    @objc private func settingsAction() {
        onSettingsRequested?()
    }

    @objc private func quitAction() {
        onQuitRequested?()
    }

    func toggleMenu() {
        statusItem?.button?.performClick(nil)
    }

    func setLoadingState(_ loading: Bool) {
        if let button = statusItem?.button {
            button.image = makeMicIcon(active: false, loading: loading)
            button.image?.isTemplate = false
            button.toolTip = loading ? "模型加载中..." : "TNT — 就绪"
        }
    }

    func setRecordingState(_ recording: Bool) {
        if let button = statusItem?.button {
            button.image = makeMicIcon(active: recording)
            button.image?.isTemplate = false
            if recording {
                startPulseAnimation()
            } else {
                stopPulseAnimation()
            }
        }
    }

    private func startPulseAnimation() {
        guard let button = statusItem?.button else { return }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.4
        animation.duration = 0.6
        animation.autoreverses = true
        animation.repeatCount = .infinity
        button.layer?.add(animation, forKey: "pulse")
    }

    private func stopPulseAnimation() {
        statusItem?.button?.layer?.removeAnimation(forKey: "pulse")
    }

    private func makeMicIcon(active: Bool, loading: Bool = false) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            // Background circle for better visibility
            let bgCircle = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 18, height: 18))
            if active {
                NSColor.systemRed.withAlphaComponent(0.15).setFill()
                bgCircle.fill()
            } else if loading {
                NSColor.systemGray.withAlphaComponent(0.1).setFill()
                bgCircle.fill()
            }

            let color: NSColor
            if loading {
                color = NSColor.systemGray
            } else if active {
                color = NSColor.systemRed
            } else {
                // Use a more prominent color for idle state
                color = NSColor.controlAccentColor
            }

            // Draw microphone icon with thicker lines
            let micPath = NSBezierPath()

            // Mic body (rounded rect)
            let micBody = NSRect(x: 8, y: 6, width: 6, height: 9)
            micPath.appendRoundedRect(micBody, xRadius: 3, yRadius: 3)

            // Mic stand (vertical line)
            micPath.move(to: NSPoint(x: 11, y: 4))
            micPath.line(to: NSPoint(x: 11, y: 2))

            // Base line
            micPath.move(to: NSPoint(x: 7, y: 2))
            micPath.line(to: NSPoint(x: 15, y: 2))

            // Side arcs
            micPath.move(to: NSPoint(x: 6, y: 8))
            micPath.curve(
                to: NSPoint(x: 6, y: 11),
                controlPoint1: NSPoint(x: 4, y: 9),
                controlPoint2: NSPoint(x: 4, y: 10)
            )

            micPath.move(to: NSPoint(x: 16, y: 8))
            micPath.curve(
                to: NSPoint(x: 16, y: 11),
                controlPoint1: NSPoint(x: 18, y: 9),
                controlPoint2: NSPoint(x: 18, y: 10)
            )

            color.setStroke()
            micPath.lineWidth = 1.8
            micPath.lineCapStyle = .round
            micPath.lineJoinStyle = .round
            micPath.stroke()

            return true
        }
        return image
    }
}
