import AppKit

// Editor for the two vocabulary layers, so neither one requires hand-editing
// JSON. Edits are held here until Save, which hands them back to the app to
// persist and apply. Preview runs the pending edits, not the saved ones, so a
// rule can be proven before it is committed.
final class VocabularyWindowController: NSWindowController, NSTableViewDataSource,
                                        NSTableViewDelegate, NSWindowDelegate {

    typealias Rule = RiffleConfig.Replacement

    private enum Column {
        static let word = NSUserInterfaceItemIdentifier("word")
        static let heard = NSUserInterfaceItemIdentifier("heard")
        static let replacement = NSUserInterfaceItemIdentifier("replacement")
    }

    private var words: [String]
    private var rules: [Rule]
    private let onSave: ([String], [Rule]) -> Void
    private let onPreview: (String, [String], [Rule], Bool, @escaping (String) -> Void) -> Void

    private let wordsTable = NSTableView()
    private let rulesTable = NSTableView()
    private let inputField = NSTextField()
    private let outputField = NSTextField(labelWithString: "")
    private let cleanupCheck = NSButton(checkboxWithTitle: "Run the AI cleanup too", target: nil,
                                        action: nil)
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var dirty = false {
        didSet { saveButton.isEnabled = dirty }
    }

    init(words: [String], rules: [Rule],
         onSave: @escaping ([String], [Rule]) -> Void,
         onPreview: @escaping (String, [String], [Rule], Bool, @escaping (String) -> Void) -> Void) {
        self.words = words
        self.rules = rules
        self.onSave = onSave
        self.onPreview = onPreview

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Riffle Vocabulary"
        window.minSize = NSSize(width: 640, height: 460)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        // Accessory apps do not take focus on their own; without this the
        // window opens behind whatever the user was working in.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app, otherwise Riffle keeps a Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let wordsSection = section(
            title: "Dictionary",
            help: "Names, brands, and jargon. Riffle hints these to Whisper before transcribing and names them again during cleanup.",
            table: wordsTable,
            columns: [(Column.word, "Word or phrase", 240)],
            add: #selector(addWord), remove: #selector(removeWord))

        let rulesSection = section(
            title: "Replacements",
            help: "Always-applied rewrites, for mis-hearings that land on real words. Case-insensitive, whole word.",
            table: rulesTable,
            columns: [(Column.heard, "Heard as", 150), (Column.replacement, "Replace with", 150)],
            add: #selector(addRule), remove: #selector(removeRule))

        let tables = NSStackView(views: [wordsSection, rulesSection])
        tables.orientation = .horizontal
        tables.distribution = .fillEqually
        tables.spacing = 16

        inputField.placeholderString = "Type or paste a transcript to test your vocabulary"
        inputField.font = .systemFont(ofSize: 13)
        outputField.font = .systemFont(ofSize: 13)
        outputField.textColor = .secondaryLabelColor
        outputField.lineBreakMode = .byWordWrapping
        outputField.maximumNumberOfLines = 4
        outputField.stringValue = "The result appears here."

        previewButton.target = self
        previewButton.action = #selector(runPreview)
        previewButton.keyEquivalent = "\r"
        cleanupCheck.state = .on

        let previewRow = NSStackView(views: [inputField, previewButton])
        previewRow.orientation = .horizontal
        previewRow.spacing = 8
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let testTitle = NSTextField(labelWithString: "Preview")
        testTitle.font = .boldSystemFont(ofSize: 13)

        saveButton.target = self
        saveButton.action = #selector(saveChanges)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, saveButton])
        buttonRow.orientation = .horizontal

        let root = NSStackView(views: [tables, separator(), testTitle, previewRow, cleanupCheck,
                                       outputField, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setHuggingPriority(.defaultLow, for: .vertical)
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            tables.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tables.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outputField.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outputField.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func section(title: String, help: String, table: NSTableView,
                         columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)],
                         add: Selector, remove: Selector) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)

        let subtitle = NSTextField(wrappingLabelWithString: help)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        for (id, name, width) in columns {
            let column = NSTableColumn(identifier: id)
            column.title = name
            column.width = width
            column.minWidth = 80
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 22

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let addButton = NSButton(title: "+", target: self, action: add)
        let removeButton = NSButton(title: "\u{2212}", target: self, action: remove)
        for b in [addButton, removeButton] {
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        let controls = NSStackView(views: [addButton, removeButton, NSView()])
        controls.orientation = .horizontal
        controls.spacing = 6

        let stack = NSStackView(views: [heading, subtitle, scroll, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        subtitle.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        subtitle.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === wordsTable ? words.count : rules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let field = NSTextField()
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.target = self
        field.action = #selector(cellEdited(_:))
        switch id {
        case Column.word:
            field.stringValue = words[row]
        case Column.heard:
            field.stringValue = rules[row].find
        default:
            field.stringValue = rules[row].replace
        }
        return field
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordRow = wordsTable.row(for: sender)
        if wordRow >= 0 {
            guard wordRow < words.count else { return }
            words[wordRow] = text
            dirty = true
            return
        }
        let ruleRow = rulesTable.row(for: sender)
        let ruleColumn = rulesTable.column(for: sender)
        guard ruleRow >= 0, ruleRow < rules.count, ruleColumn >= 0 else { return }
        if ruleColumn == 0 {
            rules[ruleRow].find = text
        } else {
            rules[ruleRow].replace = text
        }
        dirty = true
    }

    // MARK: - Row actions

    @objc private func addWord() {
        words.append("")
        wordsTable.reloadData()
        let row = words.count - 1
        wordsTable.scrollRowToVisible(row)
        wordsTable.editColumn(0, row: row, with: nil, select: true)
        dirty = true
    }

    @objc private func removeWord() {
        remove(rows: wordsTable.selectedRowIndexes, from: &words, in: wordsTable)
    }

    @objc private func addRule() {
        rules.append(Rule(find: "", replace: ""))
        rulesTable.reloadData()
        let row = rules.count - 1
        rulesTable.scrollRowToVisible(row)
        rulesTable.editColumn(0, row: row, with: nil, select: true)
        dirty = true
    }

    @objc private func removeRule() {
        remove(rows: rulesTable.selectedRowIndexes, from: &rules, in: rulesTable)
    }

    private func remove<T>(rows: IndexSet, from list: inout [T], in table: NSTableView) {
        guard !rows.isEmpty else { return }
        for index in rows.sorted(by: >) where index < list.count {
            list.remove(at: index)
        }
        table.reloadData()
        dirty = true
    }

    // Hooks for --vocabtest, so the capture exercises the real controls.
    func testFill(input: String) {
        inputField.stringValue = input
    }

    func testPreview() {
        runPreview()
    }

    // MARK: - Preview and save

    @objc private func runPreview() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            outputField.stringValue = "Type something above first."
            return
        }
        outputField.stringValue = "Working..."
        previewButton.isEnabled = false
        onPreview(text, cleanWords(), cleanRules(), cleanupCheck.state == .on) { [weak self] result in
            guard let self else { return }
            outputField.stringValue = result
            previewButton.isEnabled = true
        }
    }

    @objc private func saveChanges() {
        // Committing an in-progress cell edit first, so a word typed but not
        // yet confirmed with Return is not lost by clicking Save.
        window?.makeFirstResponder(nil)
        onSave(cleanWords(), cleanRules())
        dirty = false
    }

    private func cleanWords() -> [String] {
        words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func cleanRules() -> [Rule] {
        rules.map {
            Rule(find: $0.find.trimmingCharacters(in: .whitespacesAndNewlines),
                 replace: $0.replace.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.find.isEmpty }
    }
}
