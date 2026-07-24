import AppKit
import CoreGraphics

// Inserts text into whatever field currently has focus. Default mode puts
// the text on the clipboard, sends cmd-v, then restores the previous
// clipboard contents. Type mode synthesizes keystrokes instead.
enum TextInserter {

    typealias ClipboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshotClipboard() -> ClipboardSnapshot {
        let pb = NSPasteboard.general
        var saved: ClipboardSnapshot = []
        for item in pb.pasteboardItems ?? [] {
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            if !copy.isEmpty { saved.append(copy) }
        }
        return saved
    }

    // presaved: a clipboard snapshot taken earlier (edit mode copies the
    // selection first, so the snapshot from before that copy is the one to
    // restore).
    static func insert(text: String, mode: String, restoreClipboard: Bool,
                       presaved: ClipboardSnapshot? = nil) {
        if mode == "type" {
            typeText(text)
        } else {
            paste(text: text, restore: restoreClipboard, presaved: presaved)
        }
    }

    private static func paste(text: String, restore: Bool, presaved: ClipboardSnapshot?) {
        let pb = NSPasteboard.general
        let savedItems: ClipboardSnapshot = presaved ?? (restore ? snapshotClipboard() : [])

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        sendCmdV()

        guard restore else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            // If something else already wrote to the clipboard, leave it be.
            guard pb.changeCount == ourChange, !savedItems.isEmpty else { return }
            pb.clearContents()
            let items = savedItems.map { saved -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in saved { item.setData(data, forType: type) }
                return item
            }
            pb.writeObjects(items)
        }
    }

    private static func sendCmdV() {
        sendCmdKey(9)  // kVK_ANSI_V
    }

    static func sendCmdKey(_ keyCode: CGKeyCode) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(25_000)
        up.post(tap: .cghidEventTap)
    }

    private static func typeText(_ text: String) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        for chunk in chunks(of: text, size: 20) {
            let utf16 = Array(chunk.utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            usleep(12_000)
        }
    }

    private static func chunks(of text: String, size: Int) -> [String] {
        var result: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[idx..<end]))
            idx = end
        }
        return result
    }
}

// Reads the current selection by simulating cmd-c and watching the
// clipboard. Returns the selected text (nil if nothing was selected) plus a
// snapshot of the clipboard from before the copy, for later restoration.
enum SelectionGrabber {
    static func grab(completion: @escaping (String?, TextInserter.ClipboardSnapshot) -> Void) {
        let pb = NSPasteboard.general
        let saved = TextInserter.snapshotClipboard()
        let before = pb.changeCount
        TextInserter.sendCmdKey(8)  // kVK_ANSI_C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if pb.changeCount != before,
               let s = pb.string(forType: .string),
               !s.isEmpty {
                completion(s, saved)
            } else {
                completion(nil, saved)
            }
        }
    }
}
