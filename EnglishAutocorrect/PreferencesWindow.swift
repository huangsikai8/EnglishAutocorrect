import Cocoa

/// Checkbox preferences window, opened from the input method's menu.
final class PreferencesWindow: NSObject {
    static let shared = PreferencesWindow()

    /// (title, minutes) -- 0 means no time limit.
    private static let windowOptions: [(String, Int)] = [
        ("no time limit", 0),
        ("1 minute", 1),
        ("5 minutes", 5),
        ("15 minutes", 15),
        ("30 minutes", 30),
        ("1 hour", 60),
        ("1 day", 1440),
    ]

    /// (title, max edit distance) -- 0 means no limit.
    private static let distanceOptions: [(String, Int)] = [
        ("1 edit", 1),
        ("2 edits", 2),
        ("3 edits", 3),
        ("4 edits", 4),
        ("any distance", 0),
    ]

    /// English variants NSSpellChecker can be asked for, in the order
    /// they're offered. Filtered at build time against what this system
    /// actually has installed, so the menu never offers a dictionary that
    /// isn't there -- except en_US, which is the default and is always
    /// accepted even though it isn't in `availableLanguages`.
    private static let languageOptions: [String] = {
        let preferred = ["en_US", "en_GB", "en_AU", "en_CA", "en_IN", "en_NZ", "en_ZA", "en_SG"]
        let available = Set(NSSpellChecker.shared.availableLanguages)
        return preferred.filter { $0 == "en_US" || available.contains($0) }
    }()

    private var window: NSWindow?
    private var learnedLabel: NSTextField?
    private var thresholdLabel: NSTextField?
    private var windowPopup: NSPopUpButton?
    private var distancePopup: NSPopUpButton?
    private var enginePopup: NSPopUpButton?
    private var languagePopup: NSPopUpButton?

    func showWindow() {
        let window = window ?? buildWindow()
        self.window = window
        refresh()
        window.center()
        // This is a background-only agent, not a normal foreground app, so
        // the window server doesn't treat it as "active" by default --
        // activate() has to run before ordering the window front (not
        // after), and orderFrontRegardless() is needed on top of that
        // since it's specifically meant to bring a window forward even
        // when the owning app isn't the active one.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func buildWindow() -> NSWindow {
        let checkboxes = [
            makeCheckbox("Enable autocorrect", isOn: Settings.autocorrectEnabled, action: #selector(toggleAutocorrectEnabled)),
            makeCheckbox("Fix misspellings", isOn: Settings.spellingCorrectionEnabled, action: #selector(toggleSpellingCorrection)),
            makeCheckbox("Capitalize first word of sentence", isOn: Settings.capitalizeSentenceStart, action: #selector(toggleCapitalizeSentenceStart)),
            makeCheckbox("Change \u{201c}i\u{201d} to \u{201c}I\u{201d}", isOn: Settings.capitalizeStandaloneI, action: #selector(toggleCapitalizeStandaloneI)),
            makeCheckbox("Expand contractions (dont \u{2192} don't)", isOn: Settings.expandContractions, action: #selector(toggleExpandContractions)),
            makeCheckbox("Show indicator when I correct a word", isOn: Settings.showCorrectionIndicator, action: #selector(toggleShowIndicator)),
            makeCheckbox("Double-space for a period", isOn: Settings.periodShortcutEnabled, action: #selector(togglePeriodShortcut)),
            makeCheckbox("Replace -- with an em dash", isOn: Settings.emDashEnabled, action: #selector(toggleEmDash)),
        ]
        let languageRow = makeLanguageRow()
        let engineRow = makeEngineRow()
        let distanceRow = makeDistanceRow()
        let learningRow = makeLearningRow()
        let hotKeyRow = makeHotKeyRow()
        let undoHotKeyRow = makeUndoHotKeyRow()

        // The natural content width, from the widest row -- used below to
        // give the separator an explicit width, since it has no intrinsic
        // content of its own to size from.
        let contentWidth = (checkboxes + [languageRow, engineRow, distanceRow, learningRow, hotKeyRow, undoHotKeyRow]).map(\.fittingSize.width).max() ?? 300

        let stack = NSStackView(views: checkboxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let learnedLabel = NSTextField(labelWithString: "")
        learnedLabel.textColor = .secondaryLabelColor
        self.learnedLabel = learnedLabel
        let manageButton = NSButton(title: "Manage Learned Words\u{2026}", target: self, action: #selector(openLearnedWords))

        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(languageRow)
        stack.addArrangedSubview(engineRow)
        stack.addArrangedSubview(distanceRow)
        stack.addArrangedSubview(learningRow)
        stack.addArrangedSubview(hotKeyRow)
        stack.addArrangedSubview(undoHotKeyRow)
        stack.addArrangedSubview(learnedLabel)
        stack.addArrangedSubview(manageButton)

        // Size the window to the stack's actual content instead of a
        // hardcoded guess -- with 8 checkboxes plus the footer controls, a
        // fixed height risks clipping the bottom of the content.
        let fittingSize = stack.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "EnglishAutocorrect"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        return window
    }

    private func makeCheckbox(_ title: String, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        return button
    }

    /// Which English the spell checker judges against. This matters more
    /// than it sounds: to en_US, "behaviour" and "organisation" are
    /// simply misspellings, and the app duly corrected them. The bundled
    /// frequency list is US English regardless, so a non-US choice makes
    /// the app leave those words alone rather than teaching it the
    /// variant outright.
    private func makeLanguageRow() -> NSView {
        let popup = NSPopUpButton()
        for identifier in Self.languageOptions {
            let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
            popup.addItem(withTitle: name)
            popup.lastItem?.representedObject = identifier
        }
        popup.selectItem(at: Self.languageOptions.firstIndex(of: Settings.spellCheckLanguage) ?? 0)
        popup.target = self
        popup.action = #selector(languageChanged)
        self.languagePopup = popup

        let row = NSStackView(views: [
            NSTextField(labelWithString: "Dictionary:"),
            popup,
        ])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    /// A checkbox plus click-to-record button for "undo the last
    /// correction". Backspace and Escape only reach a correction on the
    /// keystroke right after it happened; this one reaches back several
    /// words, for the correction you only spotted at the end of the
    /// sentence.
    private func makeUndoHotKeyRow() -> NSView {
        let checkbox = makeCheckbox("Hotkey to undo the last correction:", isOn: Settings.undoHotKeyEnabled, action: #selector(toggleUndoHotKeyEnabled))

        let recorder = HotKeyRecorderButton(combo: Settings.undoHotKeyCombo)
        recorder.onChange = { combo in
            Settings.undoHotKeyCombo = combo
        }

        let row = NSStackView(views: [checkbox, recorder])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    /// Which engine decides corrections. They trade off against each
    /// other rather than one being better: the built-in one knows how
    /// common words are, Hunspell knows how words are *built* (so it
    /// recognizes inflections and compounds a flat list misses), and the
    /// hybrid takes Hunspell's candidates and ranks them by frequency.
    private func makeEngineRow() -> NSView {
        let popup = NSPopUpButton()
        for engine in CorrectionEngine.allCases {
            popup.addItem(withTitle: engine.title)
            popup.lastItem?.representedObject = engine.rawValue
        }
        popup.selectItem(withTitle: Settings.correctionEngine.title)
        popup.target = self
        popup.action = #selector(engineChanged)
        self.enginePopup = popup

        let row = NSStackView(views: [
            NSTextField(labelWithString: "Correction engine:"),
            popup,
        ])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    /// "Never correct a word more than [2 edits] from what I typed" --
    /// how far a replacement may sit from the original before it's
    /// dropped. Words with no close neighbour are usually real terms the
    /// dictionaries don't carry, so a distant guess is far more likely to
    /// mangle the text than fix it. "any distance" restores the old
    /// unrestricted behaviour.
    private func makeDistanceRow() -> NSView {
        let popup = NSPopUpButton()
        for (title, distance) in Self.distanceOptions {
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = distance
        }
        popup.selectItem(withTag: Settings.maxCorrectionEditDistance)
        popup.target = self
        popup.action = #selector(distanceChanged)
        self.distancePopup = popup

        let row = NSStackView(views: [
            NSTextField(labelWithString: "Never correct a word more than"),
            popup,
            NSTextField(labelWithString: "from what I typed"),
        ])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    /// "Learn after [2] rejections within [5 minutes]" -- the stepper
    /// controls how many, the popup controls the time window (or none).
    private func makeLearningRow() -> NSView {
        let thresholdLabel = NSTextField(labelWithString: "\(Settings.rejectionThreshold)")
        thresholdLabel.alignment = .center
        self.thresholdLabel = thresholdLabel

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 10
        stepper.integerValue = Settings.rejectionThreshold
        stepper.target = self
        stepper.action = #selector(thresholdChanged)

        let windowPopup = NSPopUpButton()
        for (title, minutes) in Self.windowOptions {
            windowPopup.addItem(withTitle: title)
            windowPopup.lastItem?.tag = minutes
        }
        windowPopup.selectItem(withTag: Settings.rejectionWindowMinutes)
        windowPopup.target = self
        windowPopup.action = #selector(windowChanged)
        self.windowPopup = windowPopup

        let row = NSStackView(views: [
            NSTextField(labelWithString: "Learn after"),
            thresholdLabel,
            stepper,
            NSTextField(labelWithString: "rejections within"),
            windowPopup,
        ])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    /// A checkbox plus click-to-record button for the "learn the word
    /// before the cursor" hotkey -- pressing it permanently excludes that
    /// word right away, without needing to trigger-then-revert a
    /// correction first. Click the button, then press the desired combo.
    private func makeHotKeyRow() -> NSView {
        let checkbox = makeCheckbox("Hotkey to instantly learn the word before the cursor:", isOn: Settings.learnWordHotKeyEnabled, action: #selector(toggleHotKeyEnabled))

        let recorder = HotKeyRecorderButton(combo: Settings.learnWordHotKeyCombo)
        recorder.onChange = { combo in
            Settings.learnWordHotKeyCombo = combo
        }

        let row = NSStackView(views: [checkbox, recorder])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func refresh() {
        learnedLabel?.stringValue = "\(Settings.rejectedWordCount) learned word(s)"
    }

    @objc private func toggleAutocorrectEnabled(_ sender: NSButton) { Settings.autocorrectEnabled = sender.state == .on }
    @objc private func toggleCapitalizeSentenceStart(_ sender: NSButton) { Settings.capitalizeSentenceStart = sender.state == .on }
    @objc private func toggleCapitalizeStandaloneI(_ sender: NSButton) { Settings.capitalizeStandaloneI = sender.state == .on }
    @objc private func toggleExpandContractions(_ sender: NSButton) { Settings.expandContractions = sender.state == .on }
    @objc private func toggleSpellingCorrection(_ sender: NSButton) { Settings.spellingCorrectionEnabled = sender.state == .on }
    @objc private func toggleShowIndicator(_ sender: NSButton) { Settings.showCorrectionIndicator = sender.state == .on }
    @objc private func togglePeriodShortcut(_ sender: NSButton) { Settings.periodShortcutEnabled = sender.state == .on }
    @objc private func toggleEmDash(_ sender: NSButton) { Settings.emDashEnabled = sender.state == .on }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else { return }
        Settings.spellCheckLanguage = identifier
    }

    @objc private func toggleUndoHotKeyEnabled(_ sender: NSButton) {
        Settings.undoHotKeyEnabled = sender.state == .on
    }

    @objc private func engineChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let engine = CorrectionEngine(rawValue: raw) else { return }
        Settings.correctionEngine = engine
    }

    @objc private func distanceChanged(_ sender: NSPopUpButton) {
        Settings.maxCorrectionEditDistance = sender.selectedItem?.tag ?? 2
    }

    @objc private func thresholdChanged(_ sender: NSStepper) {
        Settings.rejectionThreshold = sender.integerValue
        thresholdLabel?.stringValue = "\(sender.integerValue)"
    }

    @objc private func windowChanged(_ sender: NSPopUpButton) {
        Settings.rejectionWindowMinutes = sender.selectedItem?.tag ?? 5
    }

    @objc private func openLearnedWords() {
        LearnedWordsWindow.shared.showWindow()
    }

    @objc private func toggleHotKeyEnabled(_ sender: NSButton) {
        Settings.learnWordHotKeyEnabled = sender.state == .on
    }
}
