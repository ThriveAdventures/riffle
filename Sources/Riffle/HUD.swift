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
    private let appIconView = NSImageView(frame: NSRect(x: 140, y: 14, width: 20, height: 20))
    private let bars = LevelBarsView(frame: NSRect(x: 172, y: 13, width: 62, height: 22))
    private var hideTimer: Timer?
    private var visible = false

    init() {
        let rect = NSRect(x: 0, y: 0, width: 252, height: 48)
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

        bars.autoresizingMask = []   // positioned explicitly per state
        appIconView.autoresizingMask = []
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
        bars.startAnimating()
        appIconView.image = appIcon
        appIconView.isHidden = (appIcon == nil)
        label.frame = NSRect(x: 40, y: 15, width: 96, height: 18)
        if edit {
            label.stringValue = handsFree ? "Tap to stop" : "Editing"
        } else {
            label.stringValue = handsFree ? "Tap to stop" : "Listening"
        }
        // Explicit left-to-right layout from the measured text, so the icon
        // and meter can never collide with the label at any width.
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let labelW = ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 6
        label.frame = NSRect(x: 40, y: 15, width: labelW, height: 18)
        var xCursor: CGFloat = 40 + labelW + 12
        if appIcon != nil {
            appIconView.frame = NSRect(x: xCursor, y: 14, width: 20, height: 20)
            xCursor += 28
        }
        bars.frame = NSRect(x: xCursor, y: 13, width: 62, height: 22)
        if prime { bars.prime() }
        present(width: xCursor + 62 + 20)
    }

    func showProcessing() {
        hideTimer?.invalidate()
        hideTimer = nil
        stopPulse()
        dot.isHidden = true
        bars.isHidden = true
        bars.stopAnimating()
        appIconView.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.frame = NSRect(x: 40, y: 15, width: 196, height: 18)
        label.stringValue = "Polishing"
        present(width: contentWidth(for: label.stringValue, meter: false, icon: false))
    }

    func flash(_ message: String, ok: Bool) {
        hideTimer?.invalidate()
        stopPulse()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        bars.isHidden = true
        bars.stopAnimating()
        appIconView.isHidden = true
        dot.isHidden = false
        dot.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        label.frame = NSRect(x: 40, y: 15, width: 196, height: 18)
        label.stringValue = message
        present(width: contentWidth(for: message, meter: false, icon: false))
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func setSpectrum(_ bands: [Float]) {
        bars.setSpectrum(bands)
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

    // Width hugs the content per state; changes animate centered, so the
    // pill visibly collapses into the small "Polishing" capsule and expands
    // back for the meter.
    private func contentWidth(for text: String, meter: Bool, icon: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let labelW = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        var w: CGFloat = 40 + labelW + 20
        if meter {
            w = 40 + labelW + 12 + (icon ? 28 : 0) + 62 + 20
        }
        return min(max(w, 120), 360)
    }

    private func present(width: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let w = width
        let h: CGFloat = 48
        let x = f.midX - w / 2
        let y = f.minY + 84
        let target = NSRect(x: x, y: y, width: w, height: h)
        if visible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
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

// Winamp-spirited 12-band spectrum analyzer: real FFT bands in, per-band
// fast-attack slow-decay physics, falling peak caps, energy-scaled glow.
final class LevelBarsView: NSView {
    private let count = 12
    private var targets: [Float]
    private var values: [Float]
    private var caps: [Float]
    private var capVelocity: [Float]
    private var animTimer: Timer?
    private var primeTicks = 0

    override init(frame frameRect: NSRect) {
        targets = Array(repeating: 0.08, count: count)
        values = Array(repeating: 0.08, count: count)
        caps = Array(repeating: 0.12, count: count)
        capVelocity = Array(repeating: 0, count: count)
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    func setSpectrum(_ bands: [Float]) {
        guard primeTicks == 0 else { return }
        for i in 0..<count {
            targets[i] = max(0.08, min(1, i < bands.count ? bands[i] : 0))
        }
    }

    // Left-to-right greeting wave before live audio arrives.
    func prime() {
        primeTicks = count + 6
    }

    func startAnimating() {
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
        primeTicks = 0
        targets = Array(repeating: 0.08, count: count)
        values = targets
        caps = Array(repeating: 0.12, count: count)
        capVelocity = Array(repeating: 0, count: count)
    }

    private func step() {
        if primeTicks > 0 {
            let center = Double(count + 6 - primeTicks) - 2
            for i in 0..<count {
                let d = Double(i) - center
                targets[i] = Float(max(0.08, exp(-d * d / 3.0) * 0.9))
            }
            primeTicks -= 1
            if primeTicks == 0 {
                targets = Array(repeating: 0.08, count: count)
            }
        }
        for i in 0..<count {
            let t = targets[i]
            let rate: Float = t > values[i] ? 0.55 : 0.16
            values[i] += (t - values[i]) * rate
            if values[i] >= caps[i] {
                caps[i] = values[i]
                capVelocity[i] = 0
            } else {
                capVelocity[i] += 0.006
                caps[i] = max(values[i], caps[i] - capVelocity[i])
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2.2
        let h = bounds.height
        for i in 0..<count {
            let v = CGFloat(values[i])
            let x = CGFloat(i) * (barWidth + gap)
            let barHeight = max(2.5, v * h * 0.85)
            let alpha = 0.38 + 0.5 * v
            NSColor(calibratedRed: 0.78, green: 0.93, blue: 1.0, alpha: alpha).setFill()
            let rect = NSRect(x: x, y: (h - barHeight) / 2, width: barWidth, height: barHeight)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()

            // Falling peak cap above the bar's top edge.
            let capValue = CGFloat(caps[i])
            if capValue > 0.14 {
                let capY = min(h - 1.6, (h + capValue * h * 0.85) / 2 + 1.2)
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSRect(x: x, y: capY, width: barWidth, height: 1.6).fill()
            }
        }
    }
}
