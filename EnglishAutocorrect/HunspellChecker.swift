import Foundation

/// Spelling via Hunspell (https://hunspell.github.io), the checker behind
/// LibreOffice and Firefox, using the SCOWL-derived en_US dictionary
/// bundled alongside it.
///
/// Hunspell differs from SymSpellChecker in what it's good at, which is
/// why both are offered. Its dictionary is ~50k stems plus affix rules,
/// so it derives inflections and compounds instead of listing them --
/// that makes it markedly better at judging whether something is a real
/// word. What it has no notion of at all is *frequency*: its suggestion
/// order comes from its own edit and phonetic heuristics, so it will
/// happily rank a rare word above a common one ("popp" -> "poop").
final class HunspellChecker {
    static let shared = HunspellChecker()

    /// Guards `handle`. Hunspell's C API keeps mutable state inside the
    /// handle and is not thread-safe, and lookups arrive on whatever
    /// thread the input method is servicing a keystroke on.
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var didAttemptLoad = false

    private init() {}

    /// Opens the bundled dictionary. Safe to call more than once; a
    /// failure is remembered so it isn't retried on every keystroke.
    /// Like SymSpellChecker's index build this is deferred off the
    /// keystroke path, and lookups before it finishes simply report
    /// "no opinion."
    func loadIfNeeded() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.load()
        }
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        guard let aff = Bundle.main.path(forResource: "en_US", ofType: "aff"),
              let dic = Bundle.main.path(forResource: "en_US", ofType: "dic") else {
            DebugLog.write("Hunspell: bundled en_US dictionary missing")
            return
        }
        handle = Hunspell_create(aff, dic)
        DebugLog.write("Hunspell: dictionary \(handle == nil ? "failed to open" : "ready")")
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    /// Whether Hunspell recognizes `word`, affix rules included. Returns
    /// false when the dictionary isn't open, so callers fall back rather
    /// than treating "unknown" as "misspelled".
    func knowsWord(_ word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        return Hunspell_spell(handle, word) != 0
    }

    /// Hunspell's suggestions, in its own order, best first. Empty when
    /// the dictionary isn't open or it has nothing to offer.
    func suggestions(for word: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [] }

        var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        let count = Hunspell_suggest(handle, &list, word)
        // `list` has to stay the optional var Hunspell wrote into, since
        // freeing the list takes the same inout pointer back.
        guard count > 0, let items = list else { return [] }
        defer { Hunspell_free_list(handle, &list, count) }

        return (0..<Int(count)).compactMap { index in
            items[index].map { String(cString: $0) }
        }
    }
}
