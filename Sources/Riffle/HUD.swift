import AppKit

// Floating dark-glass pill near the bottom of the screen: recording state,
// live input level, short status flashes. Never takes focus.
final class HUD {

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView(frame: NSRect(x: 20, y: 19, width: 10, height: 10))
    private let spinner = NSProgressIndicator(frame: NSRect(x: 17, y: 16, width: 16, height: 16))
    private let bars = LevelBarsView(frame: NSRect(x: 206, y: 13, width: 62, height: 22))
    private var hideTimer: Timer?
    private var visible = false

    init() {
        let rect = NSRect(x: 0, y: 0, width: 288, height: 48)
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
        effect.layer?.cornerRadius = 24
        effect.layer?.masksToBounds = true

        // Dark glass: deepen the material and add a hairline light border
        // plus a faint top sheen.
        let darken = NSView(frame: rect)
        darken.autoresizingMask = [.width, .height]
        darken.wantsLayer = true
        darken.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        effect.addSubview(darken)

        let sheen = NSView(frame: NSRect(x: 0, y: rect.height - 24, width: rect.width, height: 24))
        sheen.autoresizingMask = [.width, .minYMargin]
        sheen.wantsLayer = true
        let sheenLayer = CAGradientLayer()
        sheenLayer.frame = sheen.bounds
        sheenLayer.colors = [NSColor.white.withAlphaComponent(0.10).cgColor,
                             NSColor.white.withAlphaComponent(0.0).cgColor]
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 1)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.layer?.addSublayer(sheenLayer)
        effect.addSubview(sheen)

        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true

        label.frame = NSRect(x: 40, y: 15, width: 230, height: 18)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        label.lineBreakMode = .byTruncatingTail

        effect.addSubview(dot)
        effect.addSubview(spinner)
        effect.addSubview(label)
        effect.addSubview(bars)
        panel.contentView = effect
    }

    func showListening(handsFree: Bool, edit: Bool = false) {
        hideTimer?.invalidate()
        hideTimer = nil
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        dot.isHidden = false
        dot.layer?.backgroundColor = (edit ? NSColor.systemPurple : NSColor.systemRed).cgColor
        startPulse()
        bars.isHidden = false
        if edit {
            label.stringValue = handsFree ? "Editing, tap to stop" : "Editing selection"
        } else {
            label.stringValue = handsFree ? "Listening, tap to stop" : "Listening"
        }
        present()
    }

    func showProcessing() {
        hideTimer?.invalidate()
        hideTimer = nil
        stopPulse()
        dot.isHidden = true
        bars.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.stringValue = "Polishing"
        present()
    }

    func flash(_ message: String, ok: Bool) {
        hideTimer?.invalidate()
        stopPulse()
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
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !visible else { return }
            panel.orderOut(nil)
        })
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let x = f.midX - panel.frame.width / 2
        let y = f.minY + 84
        if visible {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 1
            return
        }
        visible = true
        panel.setFrameOrigin(NSPoint(x: x, y: y - 8))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(x: x, y: y, width: panel.frame.width,
                                             height: panel.frame.height), display: true)
        }
    }

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        dot.layer?.removeAnimation(forKey: "pulse")
        dot.layer?.opacity = 1
    }
}

final class LevelBarsView: NSView {
    private var levels: [Float] = Array(repeating: 0.06, count: 12)

    func push(_ level: Float) {
        // Fast attack, slow decay reads as a natural meter.
        let last = levels.last ?? 0.06
        let smoothed = max(level, last * 0.72)
        levels.removeFirst()
        levels.append(max(0.06, min(1, smoothed)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2.2
        let h = bounds.height
        let count = levels.count
        for (i, level) in levels.enumerated() {
            // Newer bars (right side) brighter, with a faint cool tint.
            let age = CGFloat(i + 1) / CGFloat(count)
            let alpha = 0.30 + 0.62 * age
            NSColor(calibratedRed: 0.82, green: 0.93, blue: 1.0, alpha: alpha).setFill()
            let barHeight = max(2.5, CGFloat(level) * h)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = NSRect(x: x, y: (h - barHeight) / 2, width: barWidth, height: barHeight)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
