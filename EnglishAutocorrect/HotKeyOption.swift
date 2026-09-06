import Cocoa
import Carbon.HIToolbox

/// A single recorded key combo for the "learn the word before the cursor"
/// hotkey -- user-typed via HotKeyRecorderButton in Preferences, not picked
/// from a fixed list.
struct HotKeyCombo: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static let `default` = HotKeyCombo(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .shift])

    /// For "undo the last correction" -- Z for undo, on the same
    /// Control-Shift base as the learn-word default so the two read as a
    /// pair, and clear of Command-Z so an app's own undo is untouched.
    static let undoDefault = HotKeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.control, .shift])

    /// Matches on keyCode (physical key position) rather than the produced
    /// character -- correct for a shortcut combo, unlike plain typed
    /// characters (see the punctuation-trigger check in
    /// AutocorrectInputController), since shortcuts are conventionally
    /// bound to physical key position across layouts.
    func matches(_ event: NSEvent) -> Bool {
        let relevant = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == keyCode && relevant == modifiers
    }

    /// e.g. "\u{2303}\u{21e7}L" for Control-Shift-L -- Apple's standard
    /// modifier symbols and ordering, with the key label itself resolved
    /// through the current keyboard layout (so e.g. a French layout shows
    /// the right character for that physical key) rather than assuming US.
    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "\u{2303}" }
        if modifiers.contains(.option) { symbols += "\u{2325}" }
        if modifiers.contains(.shift) { symbols += "\u{21e7}" }
        if modifiers.contains(.command) { symbols += "\u{2318}" }
        return symbols + Self.characterForKeyCode(keyCode)
    }

    private static func characterForKeyCode(_ keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { rawBuffer -> String in
            guard let keyLayoutPtr = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "?" }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                keyLayoutPtr, keyCode, UInt16(kUCKeyActionDisplay),
                0, 0, UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
