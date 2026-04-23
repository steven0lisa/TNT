import AppKit
import Foundation

final class HotkeyManager: NSObject, @unchecked Sendable {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var comboActive = false
    private let lock = NSLock()

    // 组合键：Option + Control + Command (任意左右)
    private let requiredFlags: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand]

    // Modifier key codes to suppress (prevent system shortcuts)
    private let modifierKeyCodes: Set<CGKeyCode> = [
        0x37, // Left Command
        0x36, // Right Command
        0x3A, // Left Option
        0x3D, // Right Option
        0x3B, // Left Control
        0x3E, // Right Control
    ]

    override init() {
        super.init()
    }

    deinit {
        stop()
    }

    func checkPermissions() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        TNTLog.info("[HotkeyManager] Accessibility permission: \(trusted ? "GRANTED" : "DENIED")")
        return trusted
    }

    func start() {
        guard eventTap == nil else {
            TNTLog.info("[HotkeyManager] Already started, skipping")
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        TNTLog.info("[HotkeyManager] Creating event tap with mask=0x\(String(eventMask, radix: 16))")

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                TNTLog.info("[HotkeyManager] Tap disabled by system, re-enabling...")
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passRetained(event)
            }

            let flags = event.flags
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            // flagsChanged: detect combo key state changes
            if type == .flagsChanged {
                let hasCombo = flags.contains(manager.requiredFlags)

                manager.lock.lock()
                let wasActive = manager.comboActive

                if hasCombo && !wasActive {
                    manager.comboActive = true
                    manager.lock.unlock()
                    TNTLog.info("[HotkeyManager] >>> COMBO DOWN (Option+Control+Command)")
                    DispatchQueue.main.async {
                        manager.onKeyDown?()
                    }
                } else if !hasCombo && wasActive {
                    manager.comboActive = false
                    manager.lock.unlock()
                    TNTLog.info("[HotkeyManager] >>> COMBO UP (Option+Control+Command)")
                    DispatchQueue.main.async {
                        manager.onKeyUp?()
                    }
                } else {
                    manager.lock.unlock()
                }

                return Unmanaged.passRetained(event)
            }

            // keyDown / keyUp: suppress modifier keys to prevent system shortcuts
            guard type == .keyDown || type == .keyUp else {
                return Unmanaged.passRetained(event)
            }

            if manager.modifierKeyCodes.contains(keyCode) {
                // Suppress modifier key events while combo logic is handled by flagsChanged
                TNTLog.debug("[HotkeyManager] Suppressed modifier key \(type == .keyDown ? "DOWN" : "UP") code=0x\(String(format: "%02X", keyCode))")
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            TNTLog.error("[HotkeyManager] FAILED: CGEvent.tapCreate returned nil")
            TNTLog.error("[HotkeyManager] Check: System Settings -> Privacy & Security -> Accessibility")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let source = runLoopSource else {
            TNTLog.error("[HotkeyManager] FAILED: CFMachPortCreateRunLoopSource returned nil")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        TNTLog.info("[HotkeyManager] STARTED — listening for Option+Control+Command")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        lock.lock()
        comboActive = false
        lock.unlock()
        TNTLog.info("[HotkeyManager] STOPPED")
    }
}
