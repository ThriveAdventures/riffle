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
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
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

        if type == .keyDown {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == 53, capturing {  // Escape cancels an active recording
                DispatchQueue.main.async { self.onCancel?() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        var down = isDown
        switch key {
        case .fn:
            down = flags.contains(.maskSecondaryFn)
        case .rightCommand:
            if keycode == 54 { down = flags.contains(.maskCommand) }
        case .rightOption:
            if keycode == 61 { down = flags.contains(.maskAlternate) }
        }
        if down != isDown {
            isDown = down
            let callback = down ? onDown : onUp
            DispatchQueue.main.async { callback?() }
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
