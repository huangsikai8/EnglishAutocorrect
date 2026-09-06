import Foundation

func correctionRulesTests() {
    // MARK: - Case preservation

    expect(CorrectionRules.matchingCase(of: "doesn't", typed: "DOESNT"), "DOESN'T", "all-caps preserved")
    expect(CorrectionRules.matchingCase(of: "doesn't", typed: "Doesnt"), "Doesn't", "leading capital preserved")
    expect(CorrectionRules.matchingCase(of: "doesn't", typed: "doesnt"), "doesn't", "lowercase untouched")
    expect(CorrectionRules.matchingCase(of: "I've", typed: "ive"), "I've", "deliberate capital kept")
    expect(CorrectionRules.matchingCase(of: "I'm", typed: "IM"), "I'M", "all-caps contraction")
    expect(CorrectionRules.matchingCase(of: "a", typed: "A"), "A", "single letter is not shouting, but keeps its capital")
    expect(CorrectionRules.matchingCase(of: "the", typed: "teh"), "the", "plain correction unchanged")

    // MARK: - Contractions

    expect(CorrectionRules.contraction(for: "doesnt", atSentenceStart: false), "doesn't", "plain contraction")
    expect(CorrectionRules.contraction(for: "DOESNT", atSentenceStart: false), "doesn't", "lookup is case-insensitive")
    expect(CorrectionRules.contraction(for: "lets", atSentenceStart: false), nil, "\"lets\" is a real verb")
    expect(CorrectionRules.contraction(for: "wont", atSentenceStart: false), nil, "\"wont\" is a real noun")
    expect(CorrectionRules.contraction(for: "ive", atSentenceStart: false), "I've", "lowercase ive still expands")
    expect(CorrectionRules.contraction(for: "Ive", atSentenceStart: false), nil, "capitalized Ive mid-sentence is a surname")
    expect(CorrectionRules.contraction(for: "Ive", atSentenceStart: true), "I've", "capitalized Ive at sentence start expands")
    expect(CorrectionRules.contraction(for: "Im", atSentenceStart: false), nil, "capitalized Im mid-sentence is a name")
    expect(CorrectionRules.contraction(for: "Dont", atSentenceStart: false), "don't", "unambiguous entries ignore capitals")

    // MARK: - Sentence starts and abbreviations

    expect(CorrectionRules.startsNewSentence(after: ""), true, "start of document")
    expect(CorrectionRules.startsNewSentence(after: "That is done. "), true, "after a full stop")
    expect(CorrectionRules.startsNewSentence(after: "one\n"), true, "after a newline")
    expect(CorrectionRules.startsNewSentence(after: "in the middle "), false, "mid-sentence")
    expect(CorrectionRules.startsNewSentence(after: "in the U.S. "), false, "after U.S.")
    expect(CorrectionRules.startsNewSentence(after: "apples, oranges, etc. "), false, "after etc.")
    expect(CorrectionRules.startsNewSentence(after: "e.g. "), false, "after e.g.")
    expect(CorrectionRules.startsNewSentence(after: "spoke to Dr. "), false, "after Dr.")
    expect(CorrectionRules.startsNewSentence(after: "signed J. "), false, "after an initial")

    expect(CorrectionRules.capitalizingIfSentenceStart("and", precedingText: "in the U.S. "), "and", "no capital after abbreviation")
    expect(CorrectionRules.capitalizingIfSentenceStart("and", precedingText: "That is done. "), "And", "capital after a real full stop")

    // MARK: - Standalone I

    expect(CorrectionRules.capitalizedStandaloneI("i"), "I", "bare i")
    expect(CorrectionRules.capitalizedStandaloneI("i'm"), "I'm", "typed apostrophe")
    expect(CorrectionRules.capitalizedStandaloneI("in"), nil, "not a standalone i")
}
