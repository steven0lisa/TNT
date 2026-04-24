import AppKit

/// macOS port of SCSiriWaveformView — draws animated sine waves driven by audio amplitude
final class SiriWaveformView: NSView {
    // MARK: - Configurable Properties

    var numberOfWaves: Int = 5
    var waveColor: NSColor = .white
    var primaryWaveLineWidth: CGFloat = 3.0
    var secondaryWaveLineWidth: CGFloat = 1.0
    var idleAmplitude: CGFloat = 0.01
    var frequency: CGFloat = 1.5
    var density: CGFloat = 5.0
    var phaseShift: CGFloat = -0.15

    // MARK: - Internal State

    private(set) var amplitude: CGFloat = 1.0
    private var smoothedAmplitude: CGFloat = 0
    private var phase: CGFloat = 0
    private var displayLink: Timer?

    // MARK: - Public API

    /// Feed normalized amplitude (0..1) to animate the waveform
    func update(withLevel level: CGFloat) {
        amplitude = max(level, idleAmplitude)
    }

    func startAnimating() {
        guard displayLink == nil else { return }
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Animation Loop

    private func tick() {
        phase += phaseShift
        // 平滑过渡：快速响应增长，缓慢衰减
        if amplitude > smoothedAmplitude {
            smoothedAmplitude = smoothedAmplitude + (amplitude - smoothedAmplitude) * 0.4
        } else {
            smoothedAmplitude = smoothedAmplitude * 0.92 + amplitude * 0.08
        }
        smoothedAmplitude = max(smoothedAmplitude, idleAmplitude)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.clear(bounds)
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(bounds)

        let height = bounds.height
        let width = bounds.width
        let halfHeight = height / 2.0
        let mid = width / 2.0

        for i in 0..<numberOfWaves {
            let strokeLineWidth = (i == 0) ? primaryWaveLineWidth : secondaryWaveLineWidth
            context.setLineWidth(strokeLineWidth)

            let maxAmplitude = halfHeight - strokeLineWidth * 2
            let progress = 1.0 - CGFloat(i) / CGFloat(numberOfWaves)
            let normedAmplitude = (1.5 * progress - 2.0 / CGFloat(numberOfWaves)) * smoothedAmplitude

            let multiplier = min(1.0, (progress / 3.0 * 2.0) + (1.0 / 3.0))
            let alpha = multiplier * waveColor.alphaComponent
            context.setStrokeColor(waveColor.withAlphaComponent(alpha).cgColor)

            context.move(to: CGPoint(x: 0, y: halfHeight))

            var firstPoint = true
            var x: CGFloat = 0
            while x <= width + density {
                let scaling = -pow(1 / mid * (x - mid), 2) + 1
                let y = scaling * maxAmplitude * normedAmplitude * sin(2 * .pi * (x / width) * frequency + phase) + halfHeight

                if firstPoint {
                    context.move(to: CGPoint(x: x, y: y))
                    firstPoint = false
                } else {
                    context.addLine(to: CGPoint(x: x, y: y))
                }
                x += density
            }

            context.strokePath()
        }
    }
}
