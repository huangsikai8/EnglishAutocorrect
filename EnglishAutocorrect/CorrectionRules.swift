import Foundation

/// Pure, self-contained correction logic: no NSSpellChecker, no IMKit.
enum CorrectionRules {
    /// Common no-apostrophe contractions. Deliberately excludes genuinely
    /// ambiguous cases ("its"/"it's", "ill"/"I'll" vs. "ill" meaning sick) --
    /// even iOS autocorrect gets those wrong regularly, so guessing wrong
    /// silently is worse than leaving them alone.
    ///
    /// "wont" and "lets" were removed for the same reason, having failed
    /// that test in practice: both are ordinary English words the system
    /// dictionary knows ("as is his wont", "he lets me go"), and this
    /// table is consulted in the controller ahead of every dictionary, so
    /// nothing downstream was in a position to stop them.
    static let contractions: [String: String] = [
        "dont": "don't",
        "cant": "can't",
        "youre": "you're",
        "theyre": "they're",
        "whats": "what's",
        "thats": "that's",
        "wasnt": "wasn't",
        "isnt": "isn't",
        "arent": "aren't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "didnt": "didn't",
        "doesnt": "doesn't",
        "couldnt": "couldn't",
        "wouldnt": "wouldn't",
        "shouldnt": "shouldn't",
        "youll": "you'll",
        "theyll": "they'll",
        "weve": "we've",
        "youve": "you've",
        "theyve": "they've",
        "ive": "I've",
        "im": "I'm",
    ]

    /// Standalone "i" forms that should capitalize to "I" unconditionally
    /// (not gated on sentence position) -- both the bare pronoun and its
    /// contractions when the user typed the apostrophe themselves (e.g.
    /// "i'm"). Un-apostrophized typed forms like "im" are handled by the
    /// contraction table below instead, which already produces "I'm".
    private static let iForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

    static func capitalizedStandaloneI(_ word: String) -> String? {
        iForms.contains(word) ? "I" + word.dropFirst() : nil
    }

    /// Entries whose lowercase form is almost always a dropped
    /// apostrophe, but whose capitalized form is almost always a name --
    /// Jony Ive, I. M. Pei. Mid-sentence, the capital is the evidence:
    /// nobody shouts one word of "I've" by accident, but they do write
    /// surnames.
    private static let nameWhenCapitalized: Set<String> = ["ive", "im"]

    static func contraction(for word: String, atSentenceStart: Bool) -> String? {
        let lower = word.lowercased()
        if !atSentenceStart, word.first?.isUppercase == true, nameWhenCapitalized.contains(lower) {
            return nil
        }
        return contractions[lower]
    }

    /// Re-applies the casing of what was actually typed to a correction
    /// that came back in dictionary form. Every table and engine here
    /// speaks lowercase, so "DOESNT" comes back as "doesn't" -- but
    /// shouting is deliberate, and a spelling fix has no business quietly
    /// turning it down. Only ever adds capitals: a correction that
    /// capitalizes on purpose ("ive" -> "I've") keeps what it chose.
    static func matchingCase(of correction: String, typed word: String) -> String {
        if isAllCaps(word) { return correction.uppercased() }
        guard let typedFirst = word.first, typedFirst.isUppercase,
              let correctedFirst = correction.first, correctedFirst.isLowercase else {
            return correction
        }
        return correctedFirst.uppercased() + correction.dropFirst()
    }

    /// A word typed entirely in capitals. Requires two cased letters, so a
    /// lone "I" -- or any single letter -- isn't mistaken for shouting.
    private static func isAllCaps(_ word: String) -> Bool {
        let cased = word.filter(\.isCased)
        return cased.count > 1 && cased.allSatisfy(\.isUppercase)
    }

    /// Capitalizes the first letter of `word` if `precedingText` (the text
    /// immediately before it in the document) indicates a new sentence:
    /// nothing precedes it, the nearest non-whitespace character before it
    /// is sentence-ending punctuation, or a paragraph break precedes it.
    static func capitalizingIfSentenceStart(_ word: String, precedingText: String) -> String {
        guard let firstChar = word.first, startsNewSentence(after: precedingText) else {
            return word
        }
        return firstChar.uppercased() + word.dropFirst()
    }

    static func startsNewSentence(after precedingText: String) -> Bool {
        var chars = Array(precedingText)
        var sawNewline = false
        while let last = chars.last, last == " " || last == "\t" || last == "\n" {
            if last == "\n" { sawNewline = true }
            chars.removeLast()
        }
        if sawNewline { return true }
        guard let last = chars.last else { return true } // nothing before -> start of document
        guard last == "." || last == "!" || last == "?" else { return false }
        return !endsWithAbbreviation(String(chars))
    }

    /// Abbreviations that end in a period without ending a sentence, so
    /// the next word isn't a sentence start: "in the U.S. and Canada",
    /// "apples, oranges, etc. and bread". Matched on the final
    /// period-terminated token, lowercased.
    private static let abbreviations: Set<String> = [
        "etc.", "e.g.", "i.e.", "vs.", "cf.", "approx.", "est.", "no.",
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.",
        "u.s.", "u.k.", "u.n.", "a.m.", "p.m.", "inc.", "ltd.", "co.",
        "fig.", "vol.", "ed.", "pp.", "al.",
    ]

    /// Whether `text` (already trimmed of trailing whitespace, ending in
    /// the period in question) ends in one of those. A single-letter
    /// token counts too -- "J. Smith", "U. Chicago" -- since an initial
    /// is never the end of a sentence either.
    private static func endsWithAbbreviation(_ text: String) -> Bool {
        let token = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).last
        guard let token else { return false }
        let lowered = String(token).lowercased()
        if abbreviations.contains(lowered) { return true }
        // "J." -- an initial, not a sentence end.
        return lowered.count == 2 && lowered.hasSuffix(".") && lowered.first?.isLetter == true
    }
}
