import CoreGraphics
import ScreenCaptureKit

enum ScreenCapture {
    static func captureMainScreen() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return image
        } catch {
            TNTLog.error("[ScreenCapture] Failed: \(error)")
            return nil
        }
    }
}
