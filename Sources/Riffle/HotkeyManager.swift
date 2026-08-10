import AppKit
import CoreGraphics

// Watches for the push-to-talk key using a CGEvent tap. An active tap needs
// the Accessibility permission, which the app also needs for pasting, so one
// permission covers both.
final class HotkeyManager {

    enum HotKey {
        case fn
        case rightCommand
        case rightOption

        static func parse(_ raw: String) -> HotKey {
            switch raw {
            case "right_command": return .rightCommand
            case "right_option": return .rightOption
            default: return .fn
            }
        }

        var displayName: String {
            switch self {
            case .fn: return "fn"
            case .rightCommand: return "right command"
            case .rightOption: return "right option"
            }
        }
    }

    var key: HotKey = .fn
    // Callbacks carry the event-arrival time. Hold duration must be
    // measured between hardware events, never on the main thread, where a
    // slow synchronous start (cold mic spin-up) would inflate a quick tap
    // into a "hold" and stop the recording immediately.
    // The Bool is true when shift was held at press time (edit mode).
    var onDown: ((Bool, Date) -> Void)?
    var onUp: ((Date) -> Void)?
    var onCancel: (() -> Void)?

    // Set from the main thread while recording so the tap thread knows
    // whether Escape should cancel. A torn read here is harmless.
    var capturing = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, keycode == 53, capturing {  // Escape cancels an active recording
                DispatchQueue.main.async { self.onCancel?() }
                return nil
            }
            // Modern Macs also emit a Globe key event (keycode 63 or 179)
            // for a bare fn tap; that event is what summons the emoji
            // palette inside apps. When fn is our hotkey it is swallowed.
            if key == .fn, keycode == 63 || keycode == 179 {
                Log.write("hotkey: swallowed globe \(type == .keyDown ? "keyDown" : "keyUp") keycode \(keycode)")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        var down = isDown
        var consumeTransition = false
        switch key {
        case .fn:
            down = flags.contains(.maskSecondaryFn)
            let physicalFnKey = keycode == 63 || keycode == 179
            // Only the physical fn/Globe key may START a recording. macOS
            // posts synthetic fn-flag events with keycode 0 during focus
            // transitions (app or tab switches, Mission Control via F3),
            // and those made the recorder appear out of nowhere, sometimes
            // pasting transcribed room noise. Fingerprint logging settled
            // the discriminator: every genuine press on both keyboards
            // seen in the field arrived as keycode 63 (226 of 226), every
            // ghost as keycode 0. Releases stay permissive: the fn bit can
            // clear on another key's event (a shift keyUp, another ghost),
            // and ignoring one would leave a recording stuck on.
            if down, !isDown, !physicalFnKey {
                Log.write("hotkey: ghost fn down ignored (keycode \(keycode))")
                return Unmanaged.passUnretained(event)
            }
            // A physical-key release with no press on record means a real
            // press went invisible because a ghost had already set the
            // flag bit; logged so that collision is observable.
            if !down, !isDown, physicalFnKey {
                Log.write("hotkey: orphan fn release (press swallowed by a ghost?)")
            }
            // fn is Riffle's push-to-talk key, so its press and release are
            // consumed outright. Apps never see the transition, which also
            // stops macOS's per-app fn handling (emoji palette, input
            // switching) from firing on taps, even in apps that cached an
            // old "Press fn key to" setting. fn-plus-key combos are
            // unaffected: those carry the fn flag inside their own keyDown
            // events. Never done for the right-modifier hotkeys, which
            // other shortcuts legitimately depend on. Ghost events and
            // transitions riding on other keys' events pass through
            // unconsumed.
            consumeTransition = physicalFnKey
        case .rightCommand:
            if keycode == 54 { down = flags.contains(.maskCommand) }
        case .rightOption:
            if keycode == 61 { down = flags.contains(.maskAlternate) }
        }
        if down != isDown {
            isDown = down
            let at = Date()
            if key == .fn {
                let kbd = event.getIntegerValueField(.keyboardEventKeyboardType)
                let src = event.getIntegerValueField(.eventSourceUnixProcessID)
                Log.write("hotkey: fn \(down ? "down" : "up") keycode \(keycode) kbd \(kbd) src \(src) flags 0x\(String(flags.rawValue, radix: 16))")
            }
            if down {
                let shiftHeld = flags.contains(.maskShift)
                let callback = onDown
                DispatchQueue.main.async { callback?(shiftHeld, at) }
            } else {
                let callback = onUp
                DispatchQueue.main.async { callback?(at) }
            }
            if consumeTransition {
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handle(type: type, event: event)
}
