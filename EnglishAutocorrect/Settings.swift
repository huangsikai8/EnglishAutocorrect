import Cocoa

/// Which spelling engine decides corrections. The two differ in what
/// they know rather than in quality: SymSpell carries word *frequencies*
/// (and bigrams) but only a flat 80k list, so it ranks well and judges
/// membership poorly; Hunspell derives words from affix rules, so it
/// judges membership well and ranks with no frequency data at all.
enum CorrectionEngine: String, CaseIterable {
    /// SymSpell picks the correction, as it always has.
    case builtIn
    /// Hunspell decides both what's misspelled and what to replace it with.
    case hunspell
    /// Hunspell decides what counts as a word; SymSpell ranks the fix,
    /// playing each to its strength. Not the default only because
    /// changing engines shouldn't happen to someone silently on upgrade.
    case hybrid

    /// Menu labels. The stored rawValue stays `builtIn` whatever these
    /// say -- renaming a label must not orphan an existing preference.
    var title: String {
        switch self {
        case .builtIn: return "SymSpell (frequency-ranked)"
        case .hunspell: return "Hunspell"
        case .hybrid: return "Hybrid (Hunspell words, SymSpell ranking)"
        }
    }
}

/// UserDefaults-backed toggles and persisted rejection list.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let autocorrectEnabled = "autocorrectEnabled"
        static let capitalizeSentenceStart = "capitalizeSentenceStart"
        static let capitalizeStandaloneI = "capitalizeStandaloneI"
        static let expandContractions = "expandContractions"
        static let spellingCorrectionEnabled = "spellingCorrectionEnabled"
        static let maxCorrectionEditDistance = "maxCorrectionEditDistance"
        static let correctionEngine = "correctionEngine"
        static let showCorrectionIndicator = "showCorrectionIndicator"
        static let periodShortcutEnabled = "periodShortcutEnabled"
        static let emDashEnabled = "emDashEnabled"
        static let spellCheckLanguage = "spellCheckLanguage"
        static let undoHotKeyEnabled = "undoHotKeyEnabled"
        static let undoHotKeyCode = "undoHotKeyCode"
        static let undoHotKeyModifiers = "undoHotKeyModifiers"
        static let learnWordHotKeyEnabled = "learnWordHotKeyEnabled"
        static let learnWordHotKeyCode = "learnWordHotKeyCode"
        static let learnWordHotKeyModifiers = "learnWordHotKeyModifiers"
        static let excludedWords = "excludedWords"
        static let recentRejections = "recentRejections"
        static let rejectionThreshold = "rejectionThreshold"
        static let rejectionWindowMinutes = "rejectionWindowMinutes"
        static let indicatorX = "indicatorX"
        static let indicatorY = "indicatorY"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Keys.autocorrectEnabled: true,
            Keys.capitalizeSentenceStart: true,
            Keys.capitalizeStandaloneI: true,
            Keys.expandContractions: true,
            Keys.spellingCorrectionEnabled: true,
            Keys.maxCorrectionEditDistance: 2,
            Keys.correctionEngine: CorrectionEngine.builtIn.rawValue,
            Keys.showCorrectionIndicator: true,
            Keys.periodShortcutEnabled: true,
            Keys.emDashEnabled: true,
            Keys.spellCheckLanguage: "en_US",
            Keys.undoHotKeyEnabled: true,
            Keys.undoHotKeyCode: Int(HotKeyCombo.undoDefault.keyCode),
            Keys.undoHotKeyModifiers: Int(HotKeyCombo.undoDefault.modifiers.rawValue),
            Keys.learnWordHotKeyEnabled: true,
            Keys.learnWordHotKeyCode: Int(HotKeyCombo.default.keyCode),
            Keys.learnWordHotKeyModifiers: Int(HotKeyCombo.default.modifiers.rawValue),
            Keys.rejectionThreshold: 2,
            Keys.rejectionWindowMinutes: 5, // 0 = no time limit
        ])
        migrateLegacyRejectionsIfNeeded()
    }

    /// One-time migration from earlier storage formats (a flat array with
    /// instant-exclude, then a bare rejection counter) to the current
    /// time-windowed one. Words already learned under either old scheme
    /// stay fully excluded rather than silently losing their learned
    /// status.
    private static func migrateLegacyRejectionsIfNeeded() {
        var excluded = excludedWords

        if let legacyArray = defaults.stringArray(forKey: "rejectedWords"), !legacyArray.isEmpty {
            excluded.formUnion(legacyArray)
            defaults.removeObject(forKey: "rejectedWords")
        }
        if let legacyCounts = defaults.dictionary(forKey: "rejectionCounts") as? [String: Int], !legacyCounts.isEmpty {
            excluded.formUnion(legacyCounts.filter { $0.value >= rejectionThreshold }.keys)
            defaults.removeObject(forKey: "rejectionCounts")
        }

        if !excluded.isEmpty {
            defaults.set(Array(excluded), forKey: Keys.excludedWords)
        }
    }

    static var autocorrectEnabled: Bool {
        get { defaults.bool(forKey: Keys.autocorrectEnabled) }
        set { defaults.set(newValue, forKey: Keys.autocorrectEnabled) }
    }

    static var capitalizeSentenceStart: Bool {
        get { defaults.bool(forKey: Keys.capitalizeSentenceStart) }
        set { defaults.set(newValue, forKey: Keys.capitalizeSentenceStart) }
    }

    static var capitalizeStandaloneI: Bool {
        get { defaults.bool(forKey: Keys.capitalizeStandaloneI) }
        set { defaults.set(newValue, forKey: Keys.capitalizeStandaloneI) }
    }

    static var expandContractions: Bool {
        get { defaults.bool(forKey: Keys.expandContractions) }
        set { defaults.set(newValue, forKey: Keys.expandContractions) }
    }

    static var spellingCorrectionEnabled: Bool {
        get { defaults.bool(forKey: Keys.spellingCorrectionEnabled) }
        set { defaults.set(newValue, forKey: Keys.spellingCorrectionEnabled) }
    }

    /// The furthest a correction may sit from what was actually typed,
    /// in edits. A word with no near neighbour is far more often a real
    /// term the dictionaries simply don't carry -- jargon, a surname, a
    /// transliteration -- than a typo, and swapping it for a distant
    /// guess mangles the text badly. 0 means no limit.
    static var maxCorrectionEditDistance: Int {
        get { max(0, defaults.integer(forKey: Keys.maxCorrectionEditDistance)) }
        set { defaults.set(max(0, newValue), forKey: Keys.maxCorrectionEditDistance) }
    }

    /// Which engine decides corrections. Falls back to the built-in one
    /// for an unrecognized stored value.
    static var correctionEngine: CorrectionEngine {
        get {
            guard let raw = defaults.string(forKey: Keys.correctionEngine),
                  let engine = CorrectionEngine(rawValue: raw) else { return .builtIn }
            return engine
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.correctionEngine) }
    }

    static var showCorrectionIndicator: Bool {
        get { defaults.bool(forKey: Keys.showCorrectionIndicator) }
        set { defaults.set(newValue, forKey: Keys.showCorrectionIndicator) }
    }

    static var periodShortcutEnabled: Bool {
        get { defaults.bool(forKey: Keys.periodShortcutEnabled) }
        set { defaults.set(newValue, forKey: Keys.periodShortcutEnabled) }
    }

    static var emDashEnabled: Bool {
        get { defaults.bool(forKey: Keys.emDashEnabled) }
        set { defaults.set(newValue, forKey: Keys.emDashEnabled) }
    }

    /// Whether a configured hotkey (see HotKeyOption) instantly, permanently
    /// excludes the word immediately before the cursor -- an explicit
    /// "never correct this" without needing to trigger-then-revert a
    /// correction first.
    /// Which dictionary decides what counts as a word. English has
    /// several and they genuinely disagree -- "behaviour" is correct in
    /// en_GB and a misspelling in en_US -- so this has to be the user's
    /// call, not a constant. Note it steers NSSpellChecker only: the
    /// bundled frequency list and Hunspell dictionary are US English
    /// whatever this says, so a non-US choice makes the app more
    /// conservative (it stops "correcting" your spellings) rather than
    /// fully fluent in that variant.
    static var spellCheckLanguage: String {
        get { defaults.string(forKey: Keys.spellCheckLanguage) ?? "en_US" }
        set { defaults.set(newValue, forKey: Keys.spellCheckLanguage) }
    }

    static var undoHotKeyEnabled: Bool {
        get { defaults.bool(forKey: Keys.undoHotKeyEnabled) }
        set { defaults.set(newValue, forKey: Keys.undoHotKeyEnabled) }
    }

    /// Undoes the most recent still-undoable correction, however long ago
    /// it was made. Backspace and Escape only reach the correction that
    /// happened on the *previous* keystroke; this reaches the ones you
    /// only noticed a sentence later.
    static var undoHotKeyCombo: HotKeyCombo {
        get {
            let keyCode = UInt16(defaults.integer(forKey: Keys.undoHotKeyCode))
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Keys.undoHotKeyModifiers)))
            return HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.undoHotKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Keys.undoHotKeyModifiers)
        }
    }

    static var learnWordHotKeyEnabled: Bool {
        get { defaults.bool(forKey: Keys.learnWordHotKeyEnabled) }
        set { defaults.set(newValue, forKey: Keys.learnWordHotKeyEnabled) }
    }

    static var learnWordHotKeyCombo: HotKeyCombo {
        get {
            let keyCode = UInt16(defaults.integer(forKey: Keys.learnWordHotKeyCode))
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Keys.learnWordHotKeyModifiers)))
            return HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.learnWordHotKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Keys.learnWordHotKeyModifiers)
        }
    }

    /// How many rejections (backspace/Esc immediately after a correction)
    /// on the same word, all within `rejectionWindowMinutes` of each
    /// other, before it's permanently excluded. The time clustering is the
    /// actual signal: two rejections five minutes apart mean "I'm clearly
    /// rejecting this correction right now," which two rejections months
    /// apart don't necessarily mean -- a bare count can't tell those
    /// apart, so this tracks *when* each rejection happened, not just how
    /// many. Once a word crosses the threshold it's excluded permanently
    /// (this doesn't later expire). Explicitly adding a word via the
    /// Learned Words window bypasses this and excludes it immediately,
    /// since that's a deliberate action, not an implicit signal.
    /// Both values are user-adjustable in Preferences.
    static var rejectionThreshold: Int {
        get { max(1, defaults.integer(forKey: Keys.rejectionThreshold)) }
        set { defaults.set(max(1, newValue), forKey: Keys.rejectionThreshold) }
    }

    /// Minutes within which `rejectionThreshold` rejections must land to
    /// trigger permanent exclusion. 0 means no time limit -- rejections
    /// count toward the threshold no matter how far apart they happened.
    static var rejectionWindowMinutes: Int {
        get { max(0, defaults.integer(forKey: Keys.rejectionWindowMinutes)) }
        set { defaults.set(max(0, newValue), forKey: Keys.rejectionWindowMinutes) }
    }

    /// nil when rejectionWindowMinutes is 0 (no time limit).
    private static var rejectionWindow: TimeInterval? {
        let minutes = rejectionWindowMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    static var rejectedWordCount: Int {
        excludedWords.count
    }

    /// All permanently excluded words, alphabetically.
    static var rejectedWordsList: [String] {
        excludedWords.sorted()
    }

    static func isRejected(_ word: String) -> Bool {
        excludedWords.contains(word.lowercased())
    }

    /// Records one rejection. Once `rejectionThreshold` rejections have
    /// landed within `rejectionWindow` of each other, the word is
    /// promoted to permanently excluded.
    ///
    /// Returns true when this rejection was the one that promoted it, so
    /// the caller can say so. A permanent change to how the app behaves
    /// shouldn't happen silently -- being unable to tell what the app has
    /// quietly decided is exactly what makes it feel unpredictable.
    @discardableResult
    static func recordRejection(_ word: String) -> Bool {
        let key = word.lowercased()
        let now = Date().timeIntervalSince1970

        var timestamps = recentRejections[key] ?? []
        if let window = rejectionWindow {
            timestamps = timestamps.filter { now - $0 <= window }
        }
        timestamps.append(now)

        var updated = recentRejections
        let promoted = timestamps.count >= rejectionThreshold
        if promoted {
            excludeImmediately(key)
            updated.removeValue(forKey: key) // no longer need to track it
        } else {
            updated[key] = timestamps
        }
        defaults.set(updated, forKey: Keys.recentRejections)
        return promoted
    }

    /// Excludes a word immediately, bypassing the rejection window -- for
    /// explicit user action (typing a word into the Learned Words window),
    /// as opposed to the implicit, time-clustered signal from repeated
    /// reverts.
    static func excludeImmediately(_ word: String) {
        var set = excludedWords
        set.insert(word.lowercased())
        defaults.set(Array(set), forKey: Keys.excludedWords)
    }

    static func removeRejection(_ word: String) {
        let key = word.lowercased()
        var set = excludedWords
        set.remove(key)
        defaults.set(Array(set), forKey: Keys.excludedWords)

        var timestamps = recentRejections
        timestamps.removeValue(forKey: key)
        defaults.set(timestamps, forKey: Keys.recentRejections)
    }

    static func clearRejections() {
        defaults.removeObject(forKey: Keys.excludedWords)
        defaults.removeObject(forKey: Keys.recentRejections)
    }

    private static var excludedWords: Set<String> {
        Set(defaults.stringArray(forKey: Keys.excludedWords) ?? [])
    }

    private static var recentRejections: [String: [Double]] {
        defaults.dictionary(forKey: Keys.recentRejections) as? [String: [Double]] ?? [:]
    }

    /// Where the user last dragged the correction indicator to (its
    /// center point, in screen coordinates), or nil if it's never been
    /// moved.
    static var indicatorPosition: NSPoint? {
        get {
            guard let x = defaults.object(forKey: Keys.indicatorX) as? Double,
                  let y = defaults.object(forKey: Keys.indicatorY) as? Double else {
                return nil
            }
            return NSPoint(x: x, y: y)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.indicatorX)
                defaults.removeObject(forKey: Keys.indicatorY)
                return
            }
            defaults.set(Double(newValue.x), forKey: Keys.indicatorX)
            defaults.set(Double(newValue.y), forKey: Keys.indicatorY)
        }
    }
}
