import AppKit
import NaturalLanguage

/// Prefers SymSpellChecker's frequency-ranked correction (built from a
/// bundled dictionary of real-world word usage), falling back to
/// NSSpellChecker's own single-best-guess API whenever SymSpell's index
/// isn't ready yet or has no candidate within its edit-distance cutoff.
/// Validity itself -- is `word` even misspelled -- is always decided by
/// NSSpellChecker's full system dictionary, never by SymSpell's smaller
/// 80k-word list, so an uncommon-but-real word never gets miscorrected just
/// because it's missing from that list.
final class SpellCorrector {
    static let shared = SpellCorrector()

    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()

    /// The dictionary NSSpellChecker judges membership and suggestions
    /// against. Read fresh each time rather than captured, so changing it
    /// in Preferences takes effect on the next word rather than the next
    /// launch. This was hardcoded to en_US, which quietly Americanized
    /// every British spelling typed ("behaviour" is simply not a word to
    /// en_US, so it was corrected rather than left alone).
    private var language: String { Settings.spellCheckLanguage }

    /// Returns a correction for `word`, or nil if the word is already
    /// correctly spelled (or neither checker has a better suggestion).
    /// `previousWord` is the word immediately before this one, used only to
    /// choose between candidates -- never to decide whether to correct.
    func correction(for word: String, previousWord: String? = nil) -> String? {
        guard let candidate = candidate(for: word, previousWord: previousWord),
              !isCapitalizationOnly(candidate, of: word),
              isWithinDistanceLimit(from: word, to: candidate) else { return nil }
        return candidate
    }

    /// Whether the only thing "wrong" with the word was its
    /// capitalization. Hunspell reports lowercase proper nouns as
    /// misspelled and offers the capitalized form ("matthew" ->
    /// "Matthew"), but quietly capitalizing someone's name mid-sentence
    /// is a change of meaning, not a spelling fix -- and it's the exact
    /// behaviour the built-in engine already declines to do. Sentence
    /// capitalization is a separate, explicit preference.
    private func isCapitalizationOnly(_ candidate: String, of word: String) -> Bool {
        candidate.lowercased() == word.lowercased()
    }

    /// Whether a proposed correction sits close enough to what was actually
    /// typed, per the user's configured limit (Preferences; 0 = no limit).
    ///
    /// The single-word and split paths already police their own distance,
    /// but NSSpellChecker's fallback has no cutoff at all -- and it runs
    /// precisely on the words SymSpell found no near neighbour for, which
    /// are disproportionately real terms rather than typos. Measuring the
    /// finished replacement covers every path uniformly, including splits
    /// (the inserted space counts as the one edit it is).
    private func isWithinDistanceLimit(from word: String, to candidate: String) -> Bool {
        let limit = Settings.maxCorrectionEditDistance
        guard limit > 0 else { return true }
        let distance = SymSpellChecker.damerauLevenshteinDistance(word.lowercased(), candidate.lowercased())
        return distance <= limit
    }

    /// The best correction the selected engine can offer, before the
    /// distance limit gets a say.
    ///
    /// Whichever engine is chosen, NSSpellChecker's system dictionary
    /// always gets a veto first, and the engine's own dictionary is a
    /// second opinion on top of it: a word either of them recognizes is
    /// left alone. NSSpellChecker rejects lowercase proper nouns
    /// ("matthew" is "wrong", only "Matthew" is right), which are
    /// ordinary things to type, so a second dictionary that knows better
    /// is what keeps them from being swapped for a near-neighbour.
    private func candidate(for word: String, previousWord: String?) -> String? {
        guard !isNeverCorrected(word) else { return nil }
        guard !isKnownWord(word) else { return nil }

        switch Settings.correctionEngine {
        case .builtIn:
            return builtInCandidate(for: word, previousWord: previousWord)
        case .hunspell where HunspellChecker.shared.isReady:
            guard !HunspellChecker.shared.knowsWord(word) else { return nil }
            return HunspellChecker.shared.suggestions(for: word).first {
                meetsConfidenceBar($0, for: word)
            }
        case .hybrid where HunspellChecker.shared.isReady:
            guard !HunspellChecker.shared.knowsWord(word) else { return nil }
            return hybridCandidate(for: word)
        case .hunspell, .hybrid:
            // The dictionary hasn't opened yet (it loads in the
            // background at launch) or failed to. Falling back to the
            // built-in engine beats the alternative, which is treating
            // every word as unknown until it's ready.
            return builtInCandidate(for: word, previousWord: previousWord)
        }
    }

    /// Hunspell proposes, SymSpell's frequency data disposes. Hunspell's
    /// own ordering comes from edit and phonetic heuristics with no sense
    /// of how common a word is, which is how it arrives at "popp" ->
    /// "poop"; ranking its candidates by real-world frequency, and by how
    /// plausible the slip is on the keyboard, plays each to its strength.
    private func hybridCandidate(for word: String) -> String? {
        let lower = word.lowercased()

        let scored = HunspellChecker.shared.suggestions(for: word).compactMap {
            suggestion -> (text: String, cost: Double, frequency: Int64)? in
            // Hunspell sometimes suggests a split ("alot" -> "a lot").
            // Score one on its weaker half, the way SymSpell's own
            // segmentation is judged -- any string can be cut into one
            // common word plus a rare fragment.
            let parts = suggestion.lowercased().split(separator: " ").map(String.init)
            guard !parts.isEmpty else { return nil }
            var weakest = Int64.max
            for part in parts {
                guard let frequency = SymSpellChecker.shared.frequency(of: part) else { return nil }
                weakest = min(weakest, frequency)
            }
            let cost = SymSpellChecker.keyboardWeightedDistance(lower, suggestion.lowercased())
            return (suggestion, cost, weakest)
        }

        let ranked = scored.sorted { a, b in
            if a.cost != b.cost { return a.cost < b.cost }
            return a.frequency > b.frequency
        }

        // The same bar the built-in engine holds its own candidates to.
        guard let best = ranked.first,
              best.frequency >= SymSpellChecker.frequencyFloor,
              best.cost <= 1 || word.count >= SymSpellChecker.lengthAllowingTwoEdits else {
            return nil
        }
        return best.text
    }

    private func builtInCandidate(for word: String, previousWord: String?) -> String? {
        guard !SymSpellChecker.shared.knowsWord(word) else { return nil }

        let single = SymSpellChecker.shared.bestCorrection(for: word, previousWord: previousWord)
        let split = SymSpellChecker.shared.segmentation(for: word)

        // A one-edit fix is usually a simple slip and beats splitting --
        // unless even the weaker half of the split is clearly more common
        // than the word the one-edit fix proposes. That margin is what
        // separates "alot" (-> "a lot", since "lot" far outranks "plot")
        // from "pesta" (-> "pests", since "pest" barely outranks it, so
        // there's no real reason to believe a space was missed).
        if let single, single.editDistance <= 1 {
            if let split, split.weakestHalfFrequency >= single.frequency * 2 {
                return split.text
            }
            return single.word
        }
        if let split {
            return split.text
        }
        if let single {
            return single.word
        }

        return systemCandidate(for: word)
    }

    /// NSSpellChecker's own answer, for the words SymSpell found no
    /// neighbour for.
    ///
    /// `correction(forWordRange:)` gives a single take-it-or-leave-it
    /// answer, so a first choice that can't clear the confidence bar used
    /// to mean giving up on the word entirely. `guesses(forWordRange:)`
    /// returns the whole ranked list, so the next one gets a turn.
    /// Apple's ordering is kept as-is -- this only ever filters, and only
    /// looks at the head of the list, since a guess Apple ranked sixth is
    /// not evidence of anything.
    private func systemCandidate(for word: String) -> String? {
        let range = NSRange(location: 0, length: word.utf16.count)
        var ordered: [String] = []
        if let best = checker.correction(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: tag) {
            ordered.append(best)
        }
        if let guesses = checker.guesses(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: tag) {
            ordered.append(contentsOf: guesses.prefix(5))
        }

        return ordered.first { candidate in
            // NSSpellChecker sometimes "corrects" by splitting into
            // multiple words ("pesta" -> "pest a"). Substituting that for
            // a single typed word mangles the text far more than the
            // original typo did.
            !candidate.contains(where: \.isWhitespace) && meetsConfidenceBar(candidate, for: word)
        }
    }

    /// Whether the word is being used as a name -- a person, place or
    /// organization -- judged by NaturalLanguage's named-entity tagger
    /// reading the surrounding text rather than the word alone.
    ///
    /// Dictionary membership is a poor stand-in for this: "Rahul" and
    /// "Nadella" are ordinary names that neither bundled list carries,
    /// and `isNeverCorrected`'s uppercase rule only protects capitals
    /// *after* the first letter -- so a normally-capitalized surname had
    /// nothing at all between it and its nearest dictionary neighbour.
    ///
    /// Only asked about capitalized words: the tagger leans on
    /// capitalization itself, so on a lowercase word its answer is not
    /// worth the microseconds.
    ///
    /// This is a trade, not a free win, and it was measured rather than
    /// assumed. On a 20-case sample it protected 5 of 10 real names
    /// (Nadella, Rahul, Priya, Kwame, Mumbai) and wrongly shielded 2 of
    /// 10 capitalized typos (a mid-sentence "Teh", "Diferent"), which
    /// then go uncorrected. Confidence scores don't separate the two --
    /// "Teh" comes back a 1.000 personal name -- so there is no threshold
    /// to tune here. It ships that way on the same principle the built-in
    /// engine's confidence rules rest on: a correction nobody asked for
    /// costs far more trust than a typo left alone, and few corrections
    /// cost more than one that misspells a person's name.
    static func isLikelyName(_ word: String, in context: String, wordRange: NSRange) -> Bool {
        guard word.first?.isUppercase == true else { return false }
        guard let range = Range(wordRange, in: context) else { return false }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = context
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
        switch tag {
        case .personalName, .placeName, .organizationName: return true
        default: return false
        }
    }

    /// The bar a candidate has to clear before it's applied, for the
    /// engines that don't police their own.
    ///
    /// The built-in engine holds its candidates to SymSpellChecker's
    /// `isConfident`, and the hybrid engine to an equivalent test of its
    /// own -- but Hunspell's first suggestion and NSSpellChecker's
    /// fallback arrived with no confidence test of any kind. The fallback
    /// is the worse of the two, because it runs precisely on the words
    /// SymSpell found no neighbour for, which are disproportionately real
    /// terms rather than typos. That is how "kubernets" became
    /// "cabernets": two edits, a target so rare it isn't in the frequency
    /// list at all, and nothing in the way.
    private func meetsConfidenceBar(_ candidate: String, for word: String) -> Bool {
        // Adding an apostrophe to what was typed ("shes" -> "she's") is a
        // punctuation fix, not a swap for some other word. The commonness
        // test below would refuse it -- the frequency list barely records
        // contractions ("she's" sits at 5,447, far under the floor) --
        // and refusing it would throw away the best corrections this
        // path makes.
        let bare = candidate.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        if bare.lowercased() == word.lowercased() { return true }

        // Correcting *to* a word too rare to reach the frequency list is
        // how a technical term gets swapped for a wine.
        guard let frequency = SymSpellChecker.shared.frequency(of: candidate),
              frequency >= SymSpellChecker.frequencyFloor else { return false }

        // And the same "is this the kind of slip a finger actually makes"
        // test the built-in engine applies to its own candidates.
        let cost = SymSpellChecker.keyboardWeightedDistance(word.lowercased(), candidate.lowercased())
        return cost <= 1 || word.count >= SymSpellChecker.lengthAllowingTwoEdits
    }

    /// Technical vocabulary loaded from the bundled tech-terms.txt --
    /// words typed on purpose that no English dictionary carries, so
    /// every checker treats them as misspelled and reaches for the
    /// nearest real word ("kubectl" -> "tubercle"). Parsed once, on
    /// first use.
    private static let technicalTerms: Set<String> = {
        guard let url = Bundle.main.url(forResource: "tech-terms", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            DebugLog.write("tech-terms.txt missing from bundle")
            return []
        }
        var terms: Set<String> = []
        contents.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            for term in trimmed.split(whereSeparator: \.isWhitespace) {
                terms.insert(term.lowercased())
            }
        }
        return terms
    }()

    /// Word shapes that should never be auto-corrected, whatever any
    /// dictionary says about them. These are overwhelmingly deliberate --
    /// identifiers, acronyms, names, version numbers -- and "corrected"
    /// versions of them are always wrong.
    private func isNeverCorrected(_ word: String) -> Bool {
        // Too short to guess at: the edit-distance neighbourhood of a
        // 1-2 letter token is essentially the whole alphabet.
        if word.count <= 2 { return true }

        // Contains a digit: version numbers, IDs, measurements.
        if word.contains(where: \.isNumber) { return true }

        // An uppercase letter anywhere but the front: acronyms (API),
        // camelCase identifiers (insertText), brand spellings (iPhone).
        if word.dropFirst().contains(where: \.isUppercase) { return true }

        // Known technical vocabulary. Checked here, ahead of every
        // engine, so the protection holds whichever one is selected.
        if Self.technicalTerms.contains(word.lowercased()) { return true }

        return false
    }

    private func isKnownWord(_ word: String) -> Bool {
        let misspelledRange = checker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: tag, wordCount: nil
        )
        return misspelledRange.location == NSNotFound
    }
}
