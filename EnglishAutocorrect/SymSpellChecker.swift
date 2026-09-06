import Foundation

/// Frequency-ranked spelling correction using the symmetric delete
/// algorithm (SymSpell: https://github.com/wolfgarbe/SymSpell). Builds a
/// delete-variant index from a bundled word-frequency dictionary once, on a
/// background queue, then answers lookups by generating the input's own
/// delete-variants and matching them against that index -- this catches
/// insertions, deletions, substitutions, and transpositions without needing
/// to enumerate each edit type separately, and lets candidates be ranked by
/// real-world frequency instead of returning just one guess.
final class SymSpellChecker {
    static let shared = SymSpellChecker()

    private struct Suggestion {
        let word: String
        let editDistance: Int
        /// `editDistance`, but with substitutions between keys that aren't
        /// neighbours charged more than one edit -- see
        /// keyboardWeightedDistance.
        let cost: Double
        let frequency: Int64
    }

    private let maxEditDistance = 2

    /// Building happens entirely into local variables (see buildIndex) and
    /// is only ever swapped into these under `lock`, so a correction()
    /// lookup blocks at most for that instant swap -- never for the whole
    /// (roughly one-time, ~1s) index build.
    private let lock = NSLock()
    private var frequencies: [String: Int64] = [:]
    private var deletes: [String: [String]] = [:]
    /// "previous next" -> how often that pair occurs. Used to pick between
    /// candidates that are otherwise equally good: what usually follows
    /// the word you just typed is far better evidence than which candidate
    /// is commonest in isolation.
    private var bigrams: [String: Int64] = [:]
    private var isReady = false

    private init() {}

    /// Kicks off the one-time background index build. Safe to call more
    /// than once. Lookups made before it finishes just return nil, which
    /// SpellCorrector treats as "fall back to NSSpellChecker."
    func loadIfNeeded() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.buildIndex()
        }
    }

    private func buildIndex() {
        lock.lock()
        let alreadyReady = isReady
        lock.unlock()
        guard !alreadyReady else { return }

        guard let url = Bundle.main.url(forResource: "en-frequency-dictionary", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        var freqs: [String: Int64] = [:]
        freqs.reserveCapacity(90_000)
        var deleteMap: [String: [String]] = [:]
        deleteMap.reserveCapacity(2_500_000)

        contents.enumerateLines { line, _ in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let frequency = Int64(parts[1]) else { return }
            let word = String(parts[0])
            freqs[word] = frequency

            for deleted in Self.deleteVariants(of: word, maxEditDistance: self.maxEditDistance) where deleted != word {
                deleteMap[deleted, default: []].append(word)
            }
        }

        var bigramMap: [String: Int64] = [:]
        if let bigramURL = Bundle.main.url(forResource: "en-bigram-dictionary", withExtension: "txt"),
           let bigramContents = try? String(contentsOf: bigramURL, encoding: .utf8) {
            bigramMap.reserveCapacity(250_000)
            bigramContents.enumerateLines { line, _ in
                // "<first> <second> <count>"
                let parts = line.split(separator: " ")
                guard parts.count == 3, let frequency = Int64(parts[2]) else { return }
                bigramMap["\(parts[0]) \(parts[1])"] = frequency
            }
        }

        lock.lock()
        frequencies = freqs
        deletes = deleteMap
        bigrams = bigramMap
        isReady = true
        lock.unlock()
    }

    /// True once the bundled dictionary has been indexed.
    var isIndexReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady
    }

    /// Whether this word appears in the bundled real-usage dictionary.
    /// This is a second opinion on validity, not a correction: NSSpellChecker
    /// rejects lowercase proper nouns ("matthew"), but they're perfectly
    /// ordinary things to type, and correcting them to some unrelated
    /// near-neighbour is far worse than leaving them alone.
    func knowsWord(_ word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady && frequencies[word.lowercased()] != nil
    }

    /// How often `word` occurs in the bundled real-usage corpus, or nil if
    /// it isn't in the list. Exposed so the hybrid engine can rank
    /// Hunspell's suggestions -- Hunspell orders by its own edit and
    /// phonetic heuristics and has no frequency data of its own.
    func frequency(of word: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard isReady else { return nil }
        return frequencies[word.lowercased()]
    }

    /// A chosen correction and how far it was from what was typed. The
    /// distance is exposed because it's the caller's main evidence signal:
    /// a distance-1 fix is strong, a distance-2 one is a guess worth
    /// weighing against a clean word split.
    struct Correction {
        let word: String
        let editDistance: Int
        let frequency: Int64
    }

    /// A split, plus how common its *weaker* half is -- the weaker half is
    /// what decides whether a split is believable, since any string can be
    /// cut into one common word plus a rare fragment.
    struct Segmentation {
        let text: String
        let weakestHalfFrequency: Int64
    }

    /// Best-ranked correction for `word` (lowest edit distance, ties broken
    /// by highest real-world frequency), or nil if the index isn't ready
    /// yet or nothing within `maxEditDistance` was found. Callers are
    /// expected to have already established that `word` needs correcting --
    /// this only picks *what* to correct it to.
    func bestCorrection(for word: String, previousWord: String? = nil) -> Correction? {
        lock.lock()
        guard isReady else { lock.unlock(); return nil }
        let freqsSnapshot = frequencies
        let deletesSnapshot = deletes
        let bigramsSnapshot = bigrams
        lock.unlock()

        let lower = word.lowercased()

        // A word the dictionary already contains is not a typo, whatever
        // NSSpellChecker thinks of its capitalization.
        guard freqsSnapshot[lower] == nil else { return nil }

        var candidates: Set<String> = []
        for variant in Self.deleteVariants(of: lower, maxEditDistance: maxEditDistance) {
            if freqsSnapshot[variant] != nil {
                candidates.insert(variant)
            }
            if let originals = deletesSnapshot[variant] {
                candidates.formUnion(originals)
            }
        }
        candidates.remove(lower)

        let scored = candidates.compactMap { candidate -> Suggestion? in
            guard let frequency = freqsSnapshot[candidate] else { return nil }
            let distance = Self.damerauLevenshteinDistance(lower, candidate)
            guard distance <= maxEditDistance else { return nil }
            let cost = Self.keyboardWeightedDistance(lower, candidate)
            return Suggestion(word: candidate, editDistance: distance, cost: cost, frequency: frequency)
        }

        // Rank by closeness first, then by how plausible the slip itself
        // is: among candidates the same number of edits away, one reachable
        // by hitting a neighbouring key beats one that needs a reach across
        // the keyboard. Then by context -- a candidate that actually
        // follows the preceding word in real usage ("thank yuo" -> "you",
        // not "yo") beats one that's merely common on its own -- falling
        // back to plain frequency whenever there's no preceding word or no
        // pair on record.
        let previous = previousWord?.lowercased()
        func contextScore(_ suggestion: Suggestion) -> Int64 {
            guard let previous, let paired = bigramsSnapshot["\(previous) \(suggestion.word)"] else { return 0 }
            return paired
        }

        let ranked = scored.sorted { a, b in
            if a.editDistance != b.editDistance { return a.editDistance < b.editDistance }
            if a.cost != b.cost { return a.cost < b.cost }
            let aContext = contextScore(a), bContext = contextScore(b)
            if aContext != bContext { return aContext > bContext }
            return a.frequency > b.frequency
        }

        // Candidates that are just the typed word with one end lopped off
        // are missing-space signals, not misspellings -- drop them here
        // rather than in the confidence check, so that a single bad top
        // candidate ("pesta" -> "pest") doesn't sink a good one further
        // down the list ("pesta" -> "pasta").
        //
        // Undoubling a repeated letter is exempt: "popp" starts with "pop"
        // and so trips that rule, but a key struck twice is a bounced
        // finger, not a missing space -- and suppressing the obvious fix
        // just leaves the field to whatever else happens to sit one edit
        // away ("poppy").
        let undoubled = Self.undoubledVariants(of: lower)
        let viable = ranked.filter { candidate in
            if undoubled.contains(candidate.word) { return true }
            return !(lower.count >= 4 && (lower.hasPrefix(candidate.word) || lower.hasSuffix(candidate.word)))
        }

        guard let best = viable.first, Self.isConfident(best, ranked: viable, original: lower) else { return nil }
        return Correction(
            word: Self.applyingCase(of: word, to: best.word),
            editDistance: best.editDistance,
            frequency: best.frequency
        )
    }

    /// Splits a run-together pair into two words ("helloworld" -> "hello
    /// world", "rentinga" -> "renting a") when there's a clearly good
    /// split, else nil. Only ever tried after single-word correction has
    /// declined, so a plain typo ("pesta" -> "pasta") is never turned into
    /// a split when a better one-word answer exists.
    ///
    /// Both halves must be real words *and* common ones: the frequency bar
    /// here is deliberately much higher than for single-word correction,
    /// because almost any long string can be cut into two obscure
    /// dictionary words, and doing that to someone's text is worse than
    /// leaving the typo alone.
    func segmentation(for word: String) -> Segmentation? {
        lock.lock()
        guard isReady else { lock.unlock(); return nil }
        let freqsSnapshot = frequencies
        lock.unlock()

        let lower = word.lowercased()
        guard lower.count >= 4, freqsSnapshot[lower] == nil else { return nil }

        let characters = Array(lower)
        var best: (score: Double, text: String, weakest: Int64)?

        for splitIndex in 1..<characters.count {
            let left = String(characters[0..<splitIndex])
            let right = String(characters[splitIndex...])
            // Neither half may be a fragment. Two-letter "words" are what
            // turn "gitops" into "gi tops" and "Nadella" into "Na della":
            // "gi", "na", "ho" and friends all clear the frequency bar
            // below on their own, because they're common *strings*, not
            // because anyone meant to type them as words.
            guard left.count >= 3, right.count >= 3 else { continue }
            guard let leftFrequency = freqsSnapshot[left],
                  let rightFrequency = freqsSnapshot[right],
                  leftFrequency >= Self.segmentFrequencyFloor,
                  rightFrequency >= Self.segmentFrequencyFloor else {
                continue
            }
            // Independent-probability score: favours splits where *both*
            // halves are common, rather than one very common word plus a
            // barely-attested fragment.
            let score = log(Double(leftFrequency)) + log(Double(rightFrequency))
            if best == nil || score > best!.score {
                best = (score, left + " " + right, min(leftFrequency, rightFrequency))
            }
        }

        guard let best else { return nil }
        return Segmentation(
            text: Self.applyingCase(of: word, to: best.text),
            weakestHalfFrequency: best.weakest
        )
    }

    /// Both halves of a split must clear this, on top of being at least
    /// three letters long. Well above the single-word floor (see
    /// segmentation(for:)), but not so high that ordinary words fail it --
    /// "renting" and "hello" both sit under a few million.
    private static let segmentFrequencyFloor: Int64 = 500_000

    /// The commonness a correction target has to clear. The bundled list
    /// runs from ~26 billion down to ~3,800; this sits around the
    /// 50,000th most common word. Shared with the hybrid engine so both
    /// hold candidates to the same bar.
    static let frequencyFloor: Int64 = 50_000

    /// How long a word must be before more than one edit's worth of
    /// evidence is believable. Also shared with the hybrid engine.
    static let lengthAllowingTwoEdits = 7

    /// Whether a candidate is strong enough to apply without asking.
    /// Silently replacing what someone typed needs real evidence, not just
    /// "this was the least-bad match in the neighbourhood" -- an
    /// unrequested wrong correction costs far more trust than a tolerated
    /// typo. All four rules are subtractive: they only ever decline to
    /// correct.
    private static func isConfident(_ best: Suggestion, ranked: [Suggestion], original: String) -> Bool {
        // Rare target: correcting *to* an obscure word is rarely right.
        guard best.frequency >= frequencyFloor else { return false }

        // More than one edit's worth of evidence needs a longer word to be
        // believable -- in a short word, two edits is most of the word, and
        // the distance-2 neighbourhood is enormous. Because this reads the
        // keyboard-weighted cost, a single far-key substitution ("popp" ->
        // "pope") lands on the wrong side of this too: one edit on paper,
        // but not the kind of edit a finger actually makes.
        guard best.cost <= 1 || original.count >= lengthAllowingTwoEdits else { return false }

        // An ambiguous field is a bad place to guess -- but only really at
        // distance 2, where the neighbourhood is wide and the candidates
        // are all mediocre. At distance 1 the match is usually obvious
        // (a transposition or single slip), so demanding a wide margin
        // there just suppresses good corrections like "agnet" -> "agent".
        if best.editDistance >= 2,
           let runnerUp = ranked.dropFirst().first,
           runnerUp.editDistance == best.editDistance,
           best.frequency < runnerUp.frequency * 3 {
            return false
        }

        return true
    }

    /// Every string reachable by dropping one letter of a doubled pair
    /// ("popp" -> "pop", "helllo" -> "hello", "buss" -> "bus").
    private static func undoubledVariants(of word: String) -> Set<String> {
        let chars = Array(word)
        guard chars.count >= 2 else { return [] }
        var results: Set<String> = []
        for index in 1..<chars.count where chars[index] == chars[index - 1] {
            var copy = chars
            copy.remove(at: index)
            results.insert(String(copy))
        }
        return results
    }

    /// All strings reachable from `word` by deleting up to
    /// `maxEditDistance` characters, including `word` itself (distance 0).
    private static func deleteVariants(of word: String, maxEditDistance: Int) -> Set<String> {
        var results: Set<String> = [word]
        var frontier: Set<String> = [word]
        for _ in 0..<maxEditDistance {
            var next: Set<String> = []
            for term in frontier where term.count > 1 {
                for index in term.indices {
                    var copy = term
                    copy.remove(at: index)
                    next.insert(copy)
                }
            }
            guard !next.isEmpty else { break }
            results.formUnion(next)
            frontier = next
        }
        return results
    }

    /// Edit distance counting insertions, deletions, substitutions and
    /// transpositions. Exposed so SpellCorrector can measure any proposed
    /// correction -- including ones from NSSpellChecker, which never
    /// reports a distance of its own -- against the user's limit.
    static func damerauLevenshteinDistance(_ s1: String, _ s2: String) -> Int {
        Int(editCost(s1, s2, substitutionCost: { _, _ in 1 }).rounded())
    }

    /// The same alignment, but a substitution between two keys that don't
    /// neighbour each other on the keyboard costs more than a single edit.
    ///
    /// Plain edit distance treats every substitution alike, so "popp" sits
    /// one edit from "pope" exactly as it sits one edit from "pop" -- and
    /// "pope" wins on raw frequency. But `p` and `e` are at opposite ends
    /// of the top row: no finger slips between them. Charging for that
    /// reach is what separates a mistyping from a different word that
    /// merely happens to be spelled similarly.
    ///
    /// Insertions and deletions stay flat, and so do transpositions -- a
    /// transposition is a slip in finger *order*, which says nothing about
    /// where the two keys sit.
    static func keyboardWeightedDistance(_ s1: String, _ s2: String) -> Double {
        editCost(s1, s2, substitutionCost: Self.substitutionCost)
    }

    /// What one far-apart substitution costs. Set so that a single one
    /// exceeds the one-edit bar in isConfident (making short words with a
    /// far-key substitution decline rather than guess) while staying under
    /// 2, so it never outranks a genuinely two-edit candidate.
    private static let farKeyCost: Double = 1.7

    private static func substitutionCost(_ typed: Character, _ intended: Character) -> Double {
        guard let neighbours = qwertyNeighbours[typed], qwertyNeighbours[intended] != nil else {
            // Not a pair of letters with a place on the layout (an
            // apostrophe, an accented vowel): no basis for a penalty, so
            // charge it as the ordinary single edit it is.
            return 1
        }
        return neighbours.contains(intended) ? 1 : farKeyCost
    }

    /// Which keys touch which on a QWERTY layout, diagonals included.
    private static let qwertyNeighbours: [Character: Set<Character>] = {
        let rows: [Character: String] = [
            "q": "was", "w": "qeasd", "e": "wrsdf", "r": "etdfg", "t": "ryfgh",
            "y": "tughj", "u": "yihjk", "i": "uojkl", "o": "ipkl", "p": "ol",
            "a": "qwszx", "s": "qweadzxc", "d": "wersfxcv", "f": "ertdgcvb",
            "g": "rtyfhvbn", "h": "tyugjbnm", "j": "yuihknm", "k": "uiojlm",
            "l": "iopk",
            "z": "asx", "x": "asdzc", "c": "sdfxv", "v": "dfgcb", "b": "fghvn",
            "n": "ghjbm", "m": "hjkn",
        ]
        return rows.mapValues { Set($0) }
    }()

    /// Damerau-Levenshtein with a caller-supplied substitution cost.
    private static func editCost(
        _ s1: String, _ s2: String,
        substitutionCost: (Character, Character) -> Double
    ) -> Double {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count, n = b.count
        if m == 0 { return Double(n) }
        if n == 0 { return Double(m) }

        var d = Array(repeating: Array(repeating: 0.0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = Double(i) }
        for j in 0...n { d[0][j] = Double(j) }

        for i in 1...m {
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : substitutionCost(a[i - 1], b[j - 1])
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[m][n]
    }

    /// The dictionary is all lowercase; this reapplies whatever
    /// capitalization pattern the original input had (all-caps, or just a
    /// capitalized first letter) so e.g. "Teh" corrects to "The", not "the".
    private static func applyingCase(of original: String, to suggestion: String) -> String {
        if original == original.uppercased(), original != original.lowercased() {
            return suggestion.uppercased()
        }
        if let first = original.first, first.isUppercase {
            return suggestion.prefix(1).uppercased() + suggestion.dropFirst()
        }
        return suggestion
    }
}
