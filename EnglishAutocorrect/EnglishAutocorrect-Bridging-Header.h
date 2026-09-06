//  Exposes Hunspell's C API to Swift. Hunspell itself is C++, but it
//  ships a flat C wrapper (Hunspell_create / _spell / _suggest), which is
//  all HunspellChecker needs -- so the Swift side never has to deal with
//  C++ interop, and the library links as a plain static archive.

#import "hunspell.h"
