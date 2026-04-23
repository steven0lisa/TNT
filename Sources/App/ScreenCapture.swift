import CoreGraphics

enum ScreenCapture {
    static func captureMainScreen() -> CGImage? {
        CGDisplayCreateImage(CGMainDisplayID())
    }
}
