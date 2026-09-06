import Cocoa
import InputMethodKit
import Carbon.HIToolbox

@objc(AutocorrectInputController)
final class AutocorrectInputController: IMKInputController {

    /// The most recent correction, valid only until the next keydown: if
    /// that next key is Backspace or Escape, we undo it; anything else
    /// clears this and the correction sticks. Escape only does anything
    /// while this is set -- with no pending correction it's untouched and
    /// passes straight through, so it never interferes with an app's own
    /// use of Esc otherwise.
    private struct PendingCorrection {
        let originalWord: String
        let correctedWord: String
        /// Whatever character ended the word and triggered the
        /// correction -- a space, or one of wordBoundaryPunctuation --
        /// so a revert can put back exactly what was there.
        let terminator: String
    }
    private var pendingCorrection: PendingCorrection?

    /// One correction that has already been written, remembered with the
    /// absolute range its replacement occupies.
    private struct AppliedCorrection {
        let originalWord: String
        let correctedWord: String
        /// Where `correctedWord` starts in the client's text. Stays right
        /// as long as the user has only typed forward since, which is why
        /// it's read back and compared before it's ever used.
        let location: Int
    }

    /// The last few corrections, oldest first. Backspace and Escape reach
    /// only `pendingCorrection` -- the one made on the previous keystroke
    /// -- because past that point both keys have their own meanings and
    /// swallowing them would be worse than the typo. The undo hotkey
    /// walks this list instead, so a correction noticed a sentence later
    /// is still reversible: that, more than any tuning, is what makes a
    /// wrong correction survivable.
    private var recentCorrections: [AppliedCorrection] = []
    private static let undoDepth = 8

    /// The word just undone by a Backspace/Escape revert, valid only for
    /// the very next autocorrect attempt: if that attempt is on this same
    /// word (the user simply continuing on rather than retyping something
    /// new), it's suppressed without asking again -- one revert already
    /// said no, so it shouldn't take a second correct-then-revert cycle
    /// (and a second rejection logged) to make that stick. This is
    /// separate from Settings' longer-term rejectionThreshold, which still
    /// governs permanent exclusion across the rest of the session.
    private var justRevertedWord: String?

    /// Timestamp of the last space keydown, used to detect two space
    /// presses in quick succession (the "Period Shortcut" gesture) --
    /// reset on any other key, matching Apple's documented behavior that
    /// a single accepted space in between cancels the gesture.
    private var lastSpaceAt: Date?

    /// Punctuation that ends a word just like a space does -- checked
    /// against the character the key actually produces (event.characters),
    /// not its keyCode, since comma/period/etc. sit at different physical
    /// positions on non-US keyboard layouts.
    private static let wordBoundaryPunctuation: Set<Character> = [",", ".", "!", "?", ";", ":"]

    /// The least context that can support a decision about the word
    /// before the cursor. Below this the client is not describing a
    /// document -- see the guard in autocorrectWordBeforeCursor.
    private static let minimumContextLength = 2

    /// Characters that, when sitting immediately before a word, mean it's
    /// part of a path, URL, email, handle, or identifier rather than prose.
    private static let codeAdjacentCharacters: Set<Character> = ["/", "\\", "_", "@", "#", "$", ".", "(", "-", ":"]

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        pendingCorrection = nil
        justRevertedWord = nil
        lastSpaceAt = nil
        // Stored locations belong to whatever document was focused when
        // they were written; in a different one they address text that
        // has nothing to do with them.
        recentCorrections.removeAll()
    }

    override func deactivateServer(_ sender: Any!) {
        pendingCorrection = nil
        justRevertedWord = nil
        recentCorrections.removeAll()
        CorrectionIndicator.shared.dismiss()
        super.deactivateServer(sender)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let prefsItem = NSMenuItem(title: "Preferences\u{2026}", action: #selector(openPreferences), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let learnedWordsItem = NSMenuItem(title: "Learned Words\u{2026}", action: #selector(openLearnedWords), keyEquivalent: "")
        learnedWordsItem.target = self
        menu.addItem(learnedWordsItem)
        return menu
    }

    @objc private func openPreferences() {
        PreferencesWindow.shared.showWindow()
    }

    @objc private func openLearnedWords() {
        LearnedWordsWindow.shared.showWindow()
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? IMKTextInput else {
            return false
        }

        if Settings.learnWordHotKeyEnabled, Settings.learnWordHotKeyCombo.matches(event) {
            return learnWordBeforeCursor(client: client)
        }

        if Settings.undoHotKeyEnabled, Settings.undoHotKeyCombo.matches(event) {
            return undoLastCorrection(client: client)
        }

        // Let shortcuts (Cmd/Ctrl combos) pass through untouched. Global
        // hotkeys (Raycast, System Settings shortcuts) never reach here at
        // all -- they're intercepted before the OS routes the keystroke to
        // a focused text field.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            pendingCorrection = nil
            justRevertedWord = nil
            lastSpaceAt = nil
            return false
        }

        if let pending = pendingCorrection, event.keyCode == kVK_Delete {
            pendingCorrection = nil
            lastSpaceAt = nil
            return revertCorrectionOnBackspace(pending, client: client)
        }

        if let pending = pendingCorrection, event.keyCode == kVK_Escape {
            pendingCorrection = nil
            lastSpaceAt = nil
            return revertCorrectionOnEscape(pending, client: client)
        }

        // Any key other than an immediate revert means the previous
        // correction (if any) is accepted -- but the indicator itself stays
        // up on its own timer regardless, so it's actually visible while
        // you keep typing rather than vanishing the instant you do.
        pendingCorrection = nil

        guard event.keyCode == kVK_Space else {
            lastSpaceAt = nil
            if let punctuation = event.characters, punctuation.count == 1,
               let character = punctuation.first, Self.wordBoundaryPunctuation.contains(character) {
                return autocorrectWordBeforeCursor(client: client, terminator: punctuation)
            }
            return false
        }

        if applyEmDashIfNeeded(client: client) {
            lastSpaceAt = nil
            return true
        }

        if Settings.periodShortcutEnabled, let last = lastSpaceAt, Date().timeIntervalSince(last) < 0.3 {
            lastSpaceAt = nil
            return applyPeriodShortcut(client: client)
        }

        let handled = autocorrectWordBeforeCursor(client: client, terminator: " ")
        lastSpaceAt = Date()
        return handled
    }

    /// The word just before the one being corrected, if any. `precedingText`
    /// normally ends in the separating space, so that's trimmed first;
    /// returns nil when what precedes is punctuation or nothing at all,
    /// since there's then no pair to look up.
    private static func lastWord(of precedingText: String) -> String? {
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard let range = trimmed.trailingWordRange() else { return nil }
        return trimmed.substring(with: range)
    }

    /// Two space presses in quick succession, with nothing accepted in
    /// between, become ". " -- Apple's "Period Shortcut," a real double-tap
    /// gesture and a separate toggle from autocorrect itself.
    private func applyPeriodShortcut(client: IMKTextInput) -> Bool {
        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound, cursor.length == 0, cursor.location > 0 else { return false }
        let range = NSRange(location: cursor.location - 1, length: 1)
        guard client.attributedSubstring(from: range)?.string == " " else { return false }
        client.insertText(". ", replacementRange: range)
        return true
    }

    /// "--" immediately before the cursor becomes an em dash.
    private func applyEmDashIfNeeded(client: IMKTextInput) -> Bool {
        guard Settings.emDashEnabled else { return false }
        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound, cursor.length == 0, cursor.location >= 2 else { return false }
        let range = NSRange(location: cursor.location - 2, length: 2)
        guard client.attributedSubstring(from: range)?.string == "--" else { return false }
        client.insertText("\u{2014}", replacementRange: range)
        client.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    /// Looks at the word immediately before the cursor and runs it through
    /// the correction pipeline (rejection check -> i->I -> contractions ->
    /// spellcheck -> sentence capitalization). If the result differs from
    /// what was typed, replaces it and inserts `terminator` (a space, or
    /// the word-boundary punctuation that triggered this) ourselves
    /// (returning true). Returns false -- letting the terminator pass
    /// through untouched -- whenever we can't safely do this, including
    /// when the client doesn't support TSMDocumentAccess (selectedRange/
    /// attributedSubstring come back as NSNotFound/nil in that case).
    private func autocorrectWordBeforeCursor(client: IMKTextInput, terminator: String) -> Bool {
        guard Settings.autocorrectEnabled else { return false }

        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound, cursor.length == 0, cursor.location > 0 else {
            return false
        }

        let lookback = min(cursor.location, 60)
        let contextRange = NSRange(location: cursor.location - lookback, length: lookback)
        guard let contextText = client.attributedSubstring(from: contextRange)?.string as NSString? else {
            return false
        }

        // A client that hands back a single character isn't telling us
        // where we are, and the rules below have no way to know that.
        // Google Docs in Chrome reports the insertion point at offset 1
        // however much text the document holds, so the lookback above
        // asks for one character, gets the last letter typed, and finds
        // nothing before it -- which reads as the start of a document,
        // and so as the start of a sentence. That capitalized the last
        // letter of every word: "going" became "goinG".
        //
        // One character can't distinguish "the document begins here"
        // from "this client won't tell me". A genuine one-character
        // document loses nothing but the capital on a lone opening "a";
        // the next keystroke restores full behaviour.
        guard contextText.length >= Self.minimumContextLength else {
            DebugLog.write("ABORT \(contextText.length)-character context (client exposes no text)")
            return false
        }

        guard let wordRange = contextText.trailingWordRange() else { return false }
        let originalWord = contextText.substring(with: wordRange)
        let precedingText = contextText.substring(to: wordRange.location)

        // A revert just said no to this exact word -- honor that for this
        // one follow-up attempt without asking again, and without logging
        // a second rejection for what's really the same "no."
        if let justReverted = justRevertedWord {
            justRevertedWord = nil
            if justReverted.caseInsensitiveCompare(originalWord) == .orderedSame {
                return false
            }
        }

        guard !Settings.isRejected(originalWord) else { return false }

        // A word sitting directly against one of these is part of a path,
        // URL, email, handle, or identifier -- "correcting" a fragment of
        // one is never right. Note this is the character immediately
        // before the word with no space between, so ordinary sentences
        // ending in "." are unaffected.
        if let previous = precedingText.last, Self.codeAdjacentCharacters.contains(previous) {
            return false
        }

        // Capitalization rules apply only when a space ended the word.
        // Ending on punctuation usually means an abbreviation rather than
        // a finished sentence -- "i.e." should stay "i.e.", not become
        // "I.e." -- and a word before a comma is mid-sentence by
        // definition.
        let endedWithSpace = terminator == " "
        let atSentenceStart = CorrectionRules.startsNewSentence(after: precedingText)

        var word = originalWord
        if Settings.capitalizeStandaloneI, endedWithSpace, let capped = CorrectionRules.capitalizedStandaloneI(word) {
            word = capped
        } else if Settings.expandContractions,
                  let expanded = CorrectionRules.contraction(for: word, atSentenceStart: atSentenceStart) {
            word = expanded
        } else if Settings.spellingCorrectionEnabled,
                  !SpellCorrector.isLikelyName(word, in: contextText as String, wordRange: wordRange),
                  let corrected = SpellCorrector.shared.correction(for: word, previousWord: Self.lastWord(of: precedingText)),
                  corrected != word {
            word = corrected
        }

        // Everything above answers in dictionary case. Put back the case
        // that was actually typed, so shouting stays shouted ("DOESNT" ->
        // "DOESN'T", not "doesn't") and a capitalized word stays
        // capitalized.
        word = CorrectionRules.matchingCase(of: word, typed: originalWord)

        if Settings.capitalizeSentenceStart, endedWithSpace {
            word = CorrectionRules.capitalizingIfSentenceStart(word, precedingText: precedingText)
        }

        guard word != originalWord else { return false }

        let absoluteWordRange = NSRange(location: cursor.location - wordRange.length, length: wordRange.length)

        // The range above is derived from selectedRange(), while the word
        // itself came from attributedSubstring() -- two separate calls into
        // the client. A client whose coordinate spaces disagree between
        // them (the same class of client that doesn't fully support
        // TSMDocumentAccess) would have us read the right word and
        // overwrite the wrong characters, silently corrupting text. Read
        // the exact range back and only write if it really holds what we
        // think we're replacing.
        guard client.attributedSubstring(from: absoluteWordRange)?.string == originalWord else {
            // Rare and worth knowing about: this is the corruption case,
            // now caught instead of written. Logs word lengths only, never
            // the text itself.
            DebugLog.write("ABORT range mismatch (expected \(originalWord.count) chars)")
            return false
        }

        client.insertText(word, replacementRange: absoluteWordRange)
        client.insertText(terminator, replacementRange: NSRange(location: NSNotFound, length: 0))

        pendingCorrection = PendingCorrection(originalWord: originalWord, correctedWord: word, terminator: terminator)
        recentCorrections.append(AppliedCorrection(
            originalWord: originalWord, correctedWord: word, location: absoluteWordRange.location
        ))
        if recentCorrections.count > Self.undoDepth {
            recentCorrections.removeFirst(recentCorrections.count - Self.undoDepth)
        }
        if Settings.showCorrectionIndicator {
            // Show what was replaced, not just the replacement -- seeing
            // only the result gives no way to tell what was taken away.
            CorrectionIndicator.shared.show(word: "\(originalWord) \u{2192} \(word)")
        }
        return true
    }

    /// The configured hotkey: grabs the word immediately before the cursor
    /// and permanently excludes it right away (Settings.excludeImmediately,
    /// the same "deliberate action" path the Learned Words window uses) --
    /// no need to trigger a correction and then revert it just to teach the
    /// app a word it should leave alone.
    private func learnWordBeforeCursor(client: IMKTextInput) -> Bool {
        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound, cursor.length == 0, cursor.location > 0 else {
            return false
        }

        let lookback = min(cursor.location, 60)
        let contextRange = NSRange(location: cursor.location - lookback, length: lookback)
        guard let contextText = client.attributedSubstring(from: contextRange)?.string as NSString? else {
            return false
        }
        guard let wordRange = contextText.trailingWordRange() else { return false }
        let word = contextText.substring(with: wordRange)

        Settings.excludeImmediately(word)
        pendingCorrection = nil
        justRevertedWord = nil
        if Settings.showCorrectionIndicator {
            CorrectionIndicator.shared.show(word: "Learned \u{201c}\(word)\u{201d}")
        }
        return true
    }

    /// The configured undo hotkey: reverts the most recent correction
    /// that is still where it was written, however many words ago that
    /// was. Walks backwards, discarding entries whose text no longer
    /// matches -- the user edited over them, or the client's coordinates
    /// have moved on -- until one verifies or the list runs out.
    ///
    /// One caveat is unavoidable: IMKTextInput has no way to *set* the
    /// selection, only to read it, so replacing text away from the
    /// insertion point leaves the caret at the reverted word in most
    /// clients. The empty insert afterwards is a best-effort nudge back
    /// to where the user was typing; it changes no text, so a client that
    /// ignores it costs nothing.
    private func undoLastCorrection(client: IMKTextInput) -> Bool {
        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound else { return false }

        while let candidate = recentCorrections.popLast() {
            let range = NSRange(location: candidate.location, length: candidate.correctedWord.utf16.count)
            guard range.location >= 0, range.location + range.length <= cursor.location,
                  client.attributedSubstring(from: range)?.string == candidate.correctedWord else {
                continue
            }

            client.insertText(candidate.originalWord, replacementRange: range)

            let delta = candidate.originalWord.utf16.count - candidate.correctedWord.utf16.count
            let restored = cursor.location + delta
            client.insertText("", replacementRange: NSRange(location: restored, length: 0))

            pendingCorrection = nil
            let learned = Settings.recordRejection(candidate.originalWord)
            justRevertedWord = candidate.originalWord
            announceRevert(word: candidate.originalWord, learned: learned)
            return true
        }

        if Settings.showCorrectionIndicator {
            CorrectionIndicator.shared.show(word: "Nothing to undo")
        }
        return true
    }

    /// Undoes a just-made correction on Backspace. Some host apps apply
    /// their own default single-character deletion for Backspace regardless
    /// of what handle(_:client:) returns, which would otherwise eat an extra
    /// character on top of our own revert. Rather than fight that (it's not
    /// reliably suppressible), this cooperates with it: swap
    /// "<correctedWord><terminator>" for "<originalWord><terminator>" --
    /// same terminator, whether that's a space or the punctuation that
    /// triggered the correction -- and return false so the guaranteed
    /// native Backspace consumes that trailing character itself. Either way
    /// the buffer ends up as exactly "<originalWord>" with the cursor right
    /// after it. Also remembers the original word so it won't be
    /// auto-corrected the same way again.
    private func revertCorrectionOnBackspace(_ pending: PendingCorrection, client: IMKTextInput) -> Bool {
        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound, cursor.length == 0 else { return false }

        let correctedLength = pending.correctedWord.utf16.count + pending.terminator.utf16.count
        guard cursor.location >= correctedLength else { return false }

        let range = NSRange(location: cursor.location - correctedLength, length: correctedLength)
        client.insertText(pending.originalWord + pending.terminator, replacementRange: range)
        _ = recentCorrections.popLast()

        let learned = Settings.recordRejection(pending.originalWord)
        justRevertedWord = pending.originalWord
        announceRevert(word: pending.originalWord, learned: learned)
        return false
    }

    /// After a revert, either say the word is now permanently learned or
    /// just clear the chip. Silently changing behavior forever is the
    /// thing that makes the app feel unpredictable, so the promotion is
    /// always surfaced.
    private func announceRevert(word: String, learned: Bool) {
        guard learned, Settings.showCorrectionIndicator else {
            CorrectionIndicator.shared.dismiss()
            return
        }
        CorrectionIndicator.shared.show(word: "Learned \u{201c}\(word)\u{201d} \u{2014} won't fix again")
    }

    /// Undoes a just-made correction on Escape. Escape has no default
    /// character-deleting behavior to lean on, so this does the exact
    /// replacement itself and swallows the event.
    private func revertCorrectionOnEscape(_ pending: PendingCorrection, client: IMKTextInput) -> Bool {
        let cursor = client.selectedRange()
        guard cursor.location != NSNotFound, cursor.length == 0 else { return false }

        let correctedLength = pending.correctedWord.utf16.count + pending.terminator.utf16.count
        guard cursor.location >= correctedLength else { return false }

        let range = NSRange(location: cursor.location - correctedLength, length: correctedLength)
        client.insertText(pending.originalWord, replacementRange: range)
        _ = recentCorrections.popLast()

        let learned = Settings.recordRejection(pending.originalWord)
        justRevertedWord = pending.originalWord
        announceRevert(word: pending.originalWord, learned: learned)
        return true
    }
}

private extension NSString {
    /// The range of the run of letters -- including apostrophes between
    /// letters, e.g. "don't", "i'm" -- at the end of the string, if any.
    func trailingWordRange() -> NSRange? {
        var start = length
        while start > 0 {
            if isLetter(at: start - 1) {
                start -= 1
                continue
            }
            if isApostrophe(character(at: start - 1)), start < length, isLetter(at: start - 2), isLetter(at: start) {
                start -= 1
                continue
            }
            break
        }
        guard start < length else { return nil }
        return NSRange(location: start, length: length - start)
    }

    private func isLetter(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        guard let scalar = UnicodeScalar(UInt32(character(at: index))) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private func isApostrophe(_ code: unichar) -> Bool {
        code == 0x27 || code == 0x2019 // straight ' or curly (smart-quoted) '
    }
}
