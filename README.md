# EnglishAutocorrect

iOS-style autocorrect for macOS, everywhere you type.

macOS has never shipped the autocorrect that iOS has. The system offers
spell *checking* — red underlines, a context menu, a replacement you have to
go and click — but nothing that quietly fixes `teh` to `the` as you type and
gets out of the way. This is that, implemented as a macOS input method.

```
teh quick brown fox     →  the quick brown fox
i dont think so         →  I don't think so
recieve the fiel        →  receive the file
that was great..        →  that was great.
wait -- no              →  wait — no
```

## Why an input method

An input method sits in the documented text-input path, between the keyboard
and the focused text field. Every alternative — a global event tap, an
Accessibility-API observer — amounts to reading and rewriting the keystrokes
of every application on the machine, which is both a broader permission than
the job needs and a fragile place to live.

The practical consequences:

- **No Accessibility permission.** Nothing is granted the ability to observe
  or control other applications.
- **Nothing leaves the machine.** There is no networking code in this
  project. Corrections are computed locally against bundled dictionaries.
- **It works in ordinary text fields** across native macOS applications,
  wherever the standard input path is used.

## Features

**Corrections**

- Misspelling correction, frequency-ranked, with a configurable maximum edit
  distance so a correction is never wildly far from what was typed.
- Sentence-initial capitalization.
- Standalone `i` → `I`, including `i'm`, `i've`, `i'll`, `i'd`.
- Contraction expansion (`dont` → `don't`, `youre` → `you're`) — restricted
  to unambiguous cases. `its`/`it's` and `ill`/`I'll` are deliberately left
  alone, because guessing wrong silently is worse than not guessing.
- Double-space for a period, matching the iOS gesture.
- `--` → em dash.

**Staying out of the way**

- Words adjacent to `/`, `\`, `_`, `@`, `#`, `$`, `.`, `(`, `-` or `:` are
  treated as paths, URLs, handles or identifiers and left untouched.
- A bundled list of technical vocabulary (`kubectl`, `redis`, `nginx`, …) is
  protected, so a spell checker can't reach for the nearest real word.
- Proper nouns are not silently capitalized — that is a change of meaning,
  not a spelling fix.
- <kbd>Backspace</kbd> or <kbd>Esc</kbd> immediately after a correction
  reverts it. A word you revert is not re-corrected on the spot.
- Reject the same word often enough (default: twice within five minutes) and
  it is learned permanently.
- <kbd>⌃⇧Z</kbd> undoes any of the last 8 corrections, so one noticed a
  sentence later is still reversible.
- <kbd>⌃⇧L</kbd> immediately learns the word before the cursor.
- A small chip shows what was corrected. Drag it once and it stays where you
  put it.

## Requirements

- macOS 14.0 or later
- Xcode 15 or later

## Install

```sh
git clone https://github.com/huangsikai8/EnglishAutocorrect.git
cd EnglishAutocorrect
./rebuild.sh
```

`rebuild.sh` builds the target and installs the bundle into
`~/Library/Input Methods/`.

Then enable it as an input source:

1. **System Settings → Keyboard → Text Input → Input Sources → Edit…**
2. Click **+**, choose **English**, select **EnglishAutocorrect**, click **Add**.
3. Select it from the input-source menu in the menu bar.

Log out and back in if it does not appear in the list — macOS scans
`~/Library/Input Methods` at login.

The build is unsigned and intended to be built from source. It is not
notarized and is not distributed as a binary.

## Preferences

Open the input-source menu in the menu bar and choose **Preferences…** —
every behavior above can be toggled individually, along with:

- **Correction engine** — see below.
- **Dictionary** — `en_US` by default. Set it to `en_GB` and `behaviour` and
  `organisation` stop being treated as misspellings. Other English locales
  appear when macOS has them installed.
- **Maximum edit distance** — how far a correction may sit from what was
  typed (`0` = no limit).
- **Rejection threshold and window** — how many rejections within how long
  before a word is learned permanently.
- **Hotkeys** — both are rebindable.

**Manage Learned Words…** lists everything the app has been told to leave
alone, and lets you remove entries.

## Correction engines

Three are selectable, differing in what they know rather than in quality:

| Engine | Decides what's a word | Ranks the replacement |
| --- | --- | --- |
| **SymSpell** (default) | macOS system dictionary | Word/bigram frequency |
| **Hunspell** | Hunspell affix rules | Hunspell |
| **Hybrid** | Hunspell affix rules | Word/bigram frequency |

SymSpell carries real-world frequency data but only a flat 80k word list, so
it ranks well and judges membership poorly. Hunspell derives words from affix
rules, so it judges membership well but has no frequency data to rank with.
Hybrid plays each to its strength.

In every case the macOS system dictionary gets a veto first: a word it
recognizes is left alone, so an uncommon-but-real word is never corrected
merely for being absent from a smaller list.

## Project layout

```
EnglishAutocorrect/
  AutocorrectInputController.swift   IMKit entry point; keystroke handling,
                                     correction application, undo
  CorrectionRules.swift              Pure logic: contractions, capitalization
  SpellCorrector.swift               Engine selection and vetoes
  SymSpellChecker.swift              Symmetric-delete spelling correction
  HunspellChecker.swift              Hunspell bridge
  Settings.swift                     UserDefaults-backed preferences
  PreferencesWindow.swift            Preferences UI
  LearnedWordsWindow.swift           Learned-words UI
  CorrectionIndicatorWindow.swift    The correction chip
  HotKeyOption.swift                 Hotkey model
  HotKeyRecorderButton.swift         Hotkey recorder control
  *.txt, en_US.dic, en_US.aff        Bundled dictionaries

Tests/                               Logic tests
Vendor/hunspell/                     Prebuilt Hunspell static library
rebuild.sh                           Build and install
run-tests.sh                         Compile and run the tests
```

## Tests

```sh
./run-tests.sh
```

The suite covers `CorrectionRules`, which has no AppKit, IMKit or bundle
dependency and so needs no application host.

## Third-party components

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the licenses of the
bundled Hunspell library, dictionaries and word-frequency data.

## Status

Version 0.1 — working and in daily use, but early. Rough edges are expected,
particularly in non-native text fields.
