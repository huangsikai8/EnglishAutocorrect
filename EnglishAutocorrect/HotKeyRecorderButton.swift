import Cocoa
import Carbon.HIToolbox

/// Click-to-record control for a single keyboard shortcut: click it, then
/// press the desired combo. Requires at least one of Command/Control/Option
/// -- Shift alone would just be normal typing (an uppercase letter), and
/// since this input method sees every keystroke while active, a "shortcut"
/// with no such modifier could never be told apart from the user just
/// typing that character.
///
/// Captures the keystroke via a local event monitor rather than overriding
/// keyDown(with:)/becomeFirstResponder() -- the latter depends on this
/// control actually holding first-responder status, which is exactly the
/// kind of thing that can silently fail to establish itself, particularly
/// in this app (a background agent with no Dock icon / normal activation
/// policy). A local monitor catches the keystroke regardless of which view
/// in the window currently has focus.
final class HotKeyRecorderButton: NSButton {
    var onChange: ((HotKeyCombo) -> Void)?

    private var combo: HotKeyCombo
    private var isRecording = false {
        didSet { updateTitle() }
    }
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(combo: HotKeyCombo) {
        self.combo = combo
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    @objc private func startRecording() {
        DebugLog.write("recorder: startRecording, isKeyWindow=\(window?.isKeyWindow ?? false)")
        guard !isRecording else { return }
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DebugLog.write("recorder: monitor saw keyDown keyCode=\(event.keyCode) mods=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)")
            guard let self else { return event }
            // Returning nil swallows the event entirely -- for both a
            // successful capture and Escape-to-cancel, nothing else in the
            // window should react to the same keystroke.
            return self.handleRecordingKeyDown(event) ? nil : event
        }
        DebugLog.write("recorder: monitor installed=\(localMonitor != nil)")

        // Safety net: if the window loses key status mid-recording (user
        // clicks away, closes the window) without ever pressing a combo,
        // stop listening instead of leaving the monitor running forever.
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.stopRecording()
            }
        }
    }

    private func stopRecording() {
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func handleRecordingKeyDown(_ event: NSEvent) -> Bool {
        // Escape with no modifiers cancels recording without changing
        // anything, matching the system shortcut recorder's convention.
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            stopRecording()
            return true
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) else {
            NSSound.beep()
            return true
        }

        combo = HotKeyCombo(keyCode: event.keyCode, modifiers: modifiers)
        stopRecording()
        onChange?(combo)
        return true
    }

    private func updateTitle() {
        title = isRecording ? "Press keys\u{2026}" : combo.displayString
    }
}
