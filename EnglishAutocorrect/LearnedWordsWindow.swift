import Cocoa

/// Lists every word that's been learned (permanently excluded from
/// autocorrect, via backspace/Esc-reverting a correction), with the
/// ability to remove individual words or add one directly without having
/// to trigger-then-revert a correction first.
final class LearnedWordsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = LearnedWordsWindow()

    private var window: NSWindow?
    private var tableView: NSTableView?
    private var addField: NSTextField?
    private var words: [String] = []

    func showWindow() {
        let window = window ?? buildWindow()
        self.window = window
        reload()
        window.center()
        // See PreferencesWindow.showWindow() -- same background-agent
        // activation-ordering fix.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func buildWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Learned Words"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 260, height: 240)

        let wordColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        wordColumn.title = "Never auto-corrected"
        wordColumn.resizingMask = .autoresizingMask

        let removeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remove"))
        removeColumn.title = ""
        removeColumn.width = 24
        removeColumn.minWidth = 24
        removeColumn.maxWidth = 24
        removeColumn.resizingMask = []

        let tableView = NSTableView()
        tableView.addTableColumn(wordColumn)
        tableView.addTableColumn(removeColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        self.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let addField = NSTextField()
        addField.placeholderString = "Add a word to never auto-correct"
        addField.target = self
        addField.action = #selector(addWord)
        self.addField = addField

        let addButton = NSButton(title: "Add", target: self, action: #selector(addWord))
        let addRow = NSStackView(views: [addField, addButton])
        addRow.orientation = .horizontal
        addRow.spacing = 8
        addField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let removeButton = NSButton(title: "Remove Selected", target: self, action: #selector(removeSelected))
        let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        let bottomRow = NSStackView(views: [removeButton, clearButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8

        let mainStack = NSStackView(views: [scrollView, addRow, bottomRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        addRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        window.contentView = mainStack
        return window
    }

    private func reload() {
        words = Settings.rejectedWordsList
        tableView?.reloadData()
    }

    @objc private func addWord() {
        guard let field = addField else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        Settings.excludeImmediately(word)
        field.stringValue = ""
        reload()
    }

    @objc private func removeSelected() {
        guard let tableView else { return }
        let selectedWords = tableView.selectedRowIndexes.compactMap { words.indices.contains($0) ? words[$0] : nil }
        for word in selectedWords {
            Settings.removeRejection(word)
        }
        reload()
    }

    @objc private func clearAll() {
        Settings.clearRejections()
        reload()
    }

    /// Per-row delete button, an alternative to select-then-"Remove
    /// Selected" for the common case of removing just one word.
    @objc private func removeRow(_ sender: NSButton) {
        guard words.indices.contains(sender.tag) else { return }
        Settings.removeRejection(words[sender.tag])
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        words.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard words.indices.contains(row) else { return nil }

        if tableColumn?.identifier.rawValue == "remove" {
            let button = NSButton(
                image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")
                    ?? NSImage(),
                target: self, action: #selector(removeRow(_:))
            )
            button.tag = row
            button.isBordered = false
            button.bezelStyle = .inline
            button.contentTintColor = .systemRed
            button.imageScaling = .scaleProportionallyUpOrDown
            return button
        }

        let textField = NSTextField(labelWithString: words[row])
        textField.isEditable = false
        textField.isSelectable = false
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }
}
