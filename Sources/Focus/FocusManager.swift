import AppKit
import Foundation

final class FocusManager: Sendable {
    static let shared = FocusManager()

    private init() {}

    func inject(text: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let result = self.performInjection(text: text)
                continuation.resume(returning: result)
            }
        }
    }

    private func performInjection(text: String) -> Bool {
        TNTLog.info("[FocusManager] Injecting text (length: \(text.count))")

        // 保存原剪贴板
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let originalContents = pasteboard.string(forType: .string)

        // 退出当前输入法
        exitInputMethod()

        // 写入剪贴板
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 模拟 Cmd+V
        sendKeyDown(keyCode: 0x09, flags: .maskCommand) // V key

        // 恢复原剪贴板（延迟等待文字注入完成）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if pasteboard.changeCount != originalChangeCount {
                pasteboard.clearContents()
                if let original = originalContents {
                    pasteboard.setString(original, forType: .string)
                }
                TNTLog.debug("[FocusManager] Clipboard restored")
            }
        }

        TNTLog.info("[FocusManager] Text injected successfully")
        return true
    }

    private func exitInputMethod() {
        // 发送 Escape 键退出当前输入法（中文输入法）
        let escapeKey = CGEvent(keyboardEventSource: nil, virtualKey: 0x66, keyDown: true)
        escapeKey?.post(tap: .cghidEventTap)
        let escapeKeyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x66, keyDown: false)
        escapeKeyUp?.post(tap: .cghidEventTap)
    }

    private func sendKeyDown(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)

        guard let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        eventUp.flags = flags
        eventUp.post(tap: .cghidEventTap)
    }

    func getFocusedWindowFrame() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp else {
            return nil
        }

        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow else {
            return nil
        }

        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return NSRect(origin: position, size: size)
    }
}
