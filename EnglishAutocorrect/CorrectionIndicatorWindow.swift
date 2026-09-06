import Cocoa

/// A small, draggable, non-activating chip shown briefly whenever a
/// correction is made. Styled after iPadOS's own predictive-text suggestion
/// chip (small, light, adaptive to system appearance, subtle shadow) rather
/// than a forced-dark system HUD -- confirmed against real screenshots of
/// that chip, not guessed.
///
/// Position is entirely user-driven: drag it once, and it remembers that
/// spot (its center point, persisted in Settings) for every future
/// correction. This replaced an earlier attempt at automatic
/// caret-anchoring via the Accessibility API -- correct in principle, but
/// unnecessary complexity (a new system permission, a background-queue
/// hop to avoid blocking typing on a cross-process call) once dragging
/// solves the same "put it where I want it" problem more simply, with the
/// user deciding directly instead of the app guessing.
///
/// Stays visible well past the single-keystroke undo window (Backspace/Esc
/// immediately after a correction) -- those are decoupled: the undo window
/// is still exactly one keystroke, but the indicator itself lingers so you
/// can actually notice a correction while still typing, not just in the
/// instant it happens.
final class CorrectionIndicator: NSObject, NSWindowDelegate {
    static let shared = CorrectionIndicator()

    private let height: CGFloat = 24
    private let cornerRadius: CGFloat = 8
    private let horizontalPadding: CGFloat = 10
    private let iconSize: CGFloat = 13
    private let iconTextGap: CGFloat = 5
    private let minWidth: CGFloat = 44
    private let bottomInset: CGFloat = 90 // default position (never dragged yet): above the Dock

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var label: NSTextField?
    private var dismissWorkItem: DispatchWorkItem?
    private var animationGeneration = 0

    func show(word: String) {
        animationGeneration += 1
        let panel = panel ?? makePanel()
        self.panel = panel
        label?.stringValue = word

        let font = label?.font ?? NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = (word as NSString).size(withAttributes: [.font: font]).width
        let contentWidth = horizontalPadding * 2 + iconSize + iconTextGap + textWidth
        let width = max(minWidth, contentWidth)

        guard let origin = savedOrigin(width: width) ?? defaultOrigin(width: width) else { return }

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        effectView?.frame = NSRect(x: 0, y: 0, width: width, height: height)

        dismissWorkItem?.cancel()
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        fadeOut()
    }

    /// Persists wherever the user just dragged the chip to.
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        Settings.indicatorPosition = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    /// The user's saved drag position (its center), if it's still within a
    /// connected screen -- a saved position from a since-disconnected
    /// external display shouldn't strand the chip off-screen.
    private func savedOrigin(width: CGFloat) -> NSPoint? {
        guard let center = Settings.indicatorPosition,
              NSScreen.screens.contains(where: { $0.frame.contains(center) }) else {
            return nil
        }
        return NSPoint(x: center.x - width / 2, y: center.y - height / 2)
    }

    /// Used only until the chip has ever been dragged: bottom-center of
    /// whichever screen the user is actually on (found via the mouse
    /// pointer, since this background-only process never has a key window
    /// for NSScreen.main to reflect).
    private func defaultOrigin(width: CGFloat) -> NSPoint? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return nil
        }
        return NSPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + bottomInset)
    }

    private func fadeOut() {
        guard let panel else { return }
        animationGeneration += 1
        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, self.animationGeneration == generation else { return }
            panel?.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: minWidth, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        // Draggable by clicking anywhere on it -- .nonactivatingPanel means
        // this never steals keyboard focus or activates this background
        // process, even though it now accepts mouse events for the drag.
        panel.isMovableByWindowBackground = true
        // Follow the user into full-screen apps too -- without this, an
        // auxiliary window only shows on the Space it was created on, and a
        // full-screen app gets its own dedicated Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // No forced appearance -- iPadOS's own suggestion chip is a plain
        // light chip that follows the system appearance, not a forced-dark
        // HUD, so this should too.

        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: minWidth, height: height))
        // .popover: a light, adaptive material meant for exactly this kind
        // of small transient content bubble (as opposed to .hudWindow,
        // which is built for a persistently-dark overlay).
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        self.effectView = effectView

        let icon = NSImageView()
        // "wand.and.stars" reads as "automatically fixed" (Apple's own
        // convention, e.g. Photos' Auto Enhance) -- a checkmark reads as
        // "verified/correct," which is a different message than "I changed
        // what you typed."
        icon.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        self.label = label

        effectView.addSubview(icon)
        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: horizontalPadding),
            icon.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: iconTextGap),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -horizontalPadding),
        ])

        panel.contentView = effectView
        return panel
    }
}
