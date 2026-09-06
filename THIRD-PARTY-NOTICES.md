# Third-Party Notices

This project bundles the following third-party components. Each remains under
its own license, reproduced or referenced below.

---

## Hunspell

- **Files:** `Vendor/hunspell/libhunspell.a`, `Vendor/hunspell/include/hunspell.h`,
  `Vendor/hunspell/include/hunvisapi.h`
- **Upstream:** https://hunspell.github.io
- **License:** Tri-licensed under GPL 2.0 / LGPL 2.1 / MPL 1.1. The full GPL
  2.0 text as distributed with Hunspell is included at
  [`Vendor/hunspell/COPYING.hunspell`](Vendor/hunspell/COPYING.hunspell).

A prebuilt static library is vendored so the project builds without an
external package manager. It is linked by `HunspellChecker.swift` and used
only when the Hunspell or Hybrid correction engine is selected.

---

## SCOWL / en_US Hunspell dictionary

- **Files:** `EnglishAutocorrect/en_US.dic` (49,568 entries),
  `EnglishAutocorrect/en_US.aff`
- **Version:** 2020.12.07
- **Upstream:** http://wordlist.sourceforge.net
- **License:** Collective work Copyright 2000–2018 Kevin Atkinson, under the
  SCOWL permissive (BSD-style) license. The affix file derives from Ispell and
  carries its BSD license; portions of the underlying word lists are in the
  public domain. The complete copyright, source and credit statement as
  distributed with the dictionary is included at
  [`EnglishAutocorrect/en_US-dictionary-README.txt`](EnglishAutocorrect/en_US-dictionary-README.txt).

---

## SymSpell frequency data

- **Files:** `EnglishAutocorrect/en-frequency-dictionary.txt` (80,000 words),
  `EnglishAutocorrect/en-bigram-dictionary.txt` (242,342 bigrams)
- **Upstream:** https://github.com/wolfgarbe/SymSpell
- **License:** MIT.

Word and bigram frequency counts derived from the Google Books Ngram data.
The symmetric-delete algorithm these support is reimplemented in Swift in
`SymSpellChecker.swift`; no SymSpell source code is included.

---

## Technical vocabulary list

- **File:** `EnglishAutocorrect/tech-terms.txt` (1,158 terms)

Compiled for this project. The list only ever *protects* terms from
correction; it never introduces one.
