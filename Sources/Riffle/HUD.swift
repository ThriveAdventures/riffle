import AppKit

// Floating dark-glass pill near the bottom of the screen: recording state,
// live input level, short status flashes. Never takes focus.
final class HUD {

    private let panel: NSPanel
    // Exposed for --hudtest self-capture only.
    var testWindow: NSWindow { panel }
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView(frame: NSRect(x: 20, y: 19, width: 10, height: 10))
    private let spinner = NSProgressIndicator(frame: NSRect(x: 17, y: 16, width: 16, height: 16))
    private let appIconView = NSImageView(frame: NSRect(x: 170, y: 14, width: 20, height: 20))
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

        let root = NSView(frame: rect)

        // maskImage shapes BOTH the vibrancy material and the window shadow.
        // Rounding with a plain CALayer mask leaves the window server drawing
        // material and shadow for the full rectangle, which shows up as faint
        // light wedges at the corners.
        let effect = NSVisualEffectView(frame: rect)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.maskImage = Self.roundedMask(radius: 24)
        root.addSubview(effect)

        // Chrome overlay: dark tint, top sheen, hairline border. A regular
        // layer-clipped view rounds these correctly; only the vibrancy
        // material needs the maskImage treatment above.
        let chrome = NSView(frame: rect)
        chrome.autoresizingMask = [.width, .height]
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 24
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 1
        chrome.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        root.addSubview(chrome)

        let darken = NSView(frame: rect)
        darken.autoresizingMask = [.width, .height]
        darken.wantsLayer = true
        darken.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        chrome.addSubview(darken)

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
        chrome.addSubview(sheen)

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

        bars.autoresizingMask = [.minXMargin]  // pin to the right edge during the entrance stretch
        appIconView.autoresizingMask = [.minXMargin]
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.isHidden = true
        chrome.addSubview(dot)
        chrome.addSubview(spinner)
        chrome.addSubview(label)
        chrome.addSubview(appIconView)
        chrome.addSubview(bars)
        panel.contentView = root
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func showListening(handsFree: Bool, edit: Bool = false,
                       appIcon: NSImage? = nil, prime: Bool = false) {
        hideTimer?.invalidate()
        hideTimer = nil
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        dot.isHidden = false
        dot.layer?.backgroundColor = (edit ? NSColor.systemPurple : NSColor.systemRed).cgColor
        startPulse()
        bars.isHidden = false
        appIconView.image = appIcon
        appIconView.isHidden = (appIcon == nil)
        label.frame = NSRect(x: 40, y: 15, width: 124, height: 18)
        if edit {
            label.stringValue = handsFree ? "Editing, tap to stop" : "Editing selection"
        } else {
            label.stringValue = handsFree ? "Listening, tap to stop" : "Listening"
        }
        if prime { bars.prime() }
        present()
    }

    func showProcessing() {
        hideTimer?.invalidate()
        hideTimer = nil
        stopPulse()
        dot.isHidden = true
        bars.isHidden = true
        appIconView.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.frame = NSRect(x: 40, y: 15, width: 224, height: 18)
        label.stringValue = "Polishing"
        present()
    }

    func flash(_ message: String, ok: Bool) {
        hideTimer?.invalidate()
        stopPulse()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        bars.isHidden = true
        appIconView.isHidden = true
        dot.isHidden = false
        dot.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        label.frame = NSRect(x: 40, y: 15, width: 224, height: 18)
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
        let w: CGFloat = 288
        let h: CGFloat = 48
        let x = f.midX - w / 2
        let y = f.minY + 84
        let target = NSRect(x: x, y: y, width: w, height: h)
        if visible {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            return
        }
        visible = true

        // Entrance: rise and stretch open with a small overshoot, then settle.
        let small = NSRect(x: x + w * 0.06, y: y - 8, width: w * 0.88, height: h)
        let over = NSRect(x: x - w * 0.012, y: y, width: w * 1.024, height: h)
        panel.setFrame(small, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ [weak self] ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self?.panel.animator().alphaValue = 1
            self?.panel.animator().setFrame(over, display: true)
        }, completionHandler: { [weak self] in
            guard let self, visible else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel.animator().setFrame(target, display: true)
            }
        })
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
    private var primeTimer: Timer?

    // A quick left-to-right wave before live levels arrive, like the meter
    // is stretching. Real audio pushes are ignored until it finishes.
    func prime() {
        primeTimer?.invalidate()
        levels = Array(repeating: 0.06, count: levels.count)
        var tick = 0
        primeTimer = Timer.scheduledTimer(withTimeInterval: 0.028, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            tick += 1
            let center = Double(tick) - 3
            for i in 0..<levels.count {
                let distance = Double(i) - center
                let bump = exp(-distance * distance / 3.0)
                levels[i] = Float(max(0.06, bump * 0.85))
            }
            needsDisplay = true
            if tick > levels.count + 4 {
                timer.invalidate()
                primeTimer = nil
                levels = levels.map { _ in 0.06 }
                needsDisplay = true
            }
        }
    }

    func push(_ level: Float) {
        guard primeTimer == nil else { return }
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
