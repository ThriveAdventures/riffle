import AppKit

// Small floating pill near the bottom of the screen showing recording state,
// live input level, and short status flashes. Never takes focus.
final class HUD {

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView(frame: NSRect(x: 18, y: 17, width: 10, height: 10))
    private let spinner = NSProgressIndicator(frame: NSRect(x: 15, y: 14, width: 16, height: 16))
    private let bars = LevelBarsView(frame: NSRect(x: 192, y: 12, width: 64, height: 20))
    private var hideTimer: Timer?

    init() {
        let rect = NSRect(x: 0, y: 0, width: 272, height: 44)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .vibrantDark)

        let effect = NSVisualEffectView(frame: rect)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true

        label.frame = NSRect(x: 38, y: 13, width: 220, height: 18)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        effect.addSubview(dot)
        effect.addSubview(spinner)
        effect.addSubview(label)
        effect.addSubview(bars)
        panel.contentView = effect
    }

    func showListening(handsFree: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        dot.isHidden = false
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        bars.isHidden = false
        label.stringValue = handsFree ? "Listening, tap to stop" : "Listening"
        present()
    }

    func showProcessing() {
        hideTimer?.invalidate()
        hideTimer = nil
        dot.isHidden = true
        bars.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.stringValue = "Polishing"
        present()
    }

    func flash(_ message: String, ok: Bool) {
        hideTimer?.invalidate()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        bars.isHidden = true
        dot.isHidden = false
        dot.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        label.stringValue = message
        present()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func setLevel(_ level: Float) {
        bars.push(level)
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let x = f.midX - panel.frame.width / 2
        let y = f.minY + 84
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}

final class LevelBarsView: NSView {
    private var levels: [Float] = Array(repeating: 0.05, count: 13)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, min(1, level)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        let h = bounds.height
        NSColor.white.withAlphaComponent(0.9).setFill()
        for (i, level) in levels.enumerated() {
            let barHeight = max(2, CGFloat(level) * h)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = NSRect(x: x, y: (h - barHeight) / 2, width: barWidth, height: barHeight)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
