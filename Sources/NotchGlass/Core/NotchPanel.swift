import AppKit
import SwiftUI

/// An `NSHostingView` that reports zero safe-area insets. The panel lives over
/// the notch, so its window has a nonzero top safe area; without this override the
/// hosting view re-derives safe area on every frame change and loops the AppKit
/// constraint-update cycle until it aborts.
final class NotchHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// A borderless, floating, non-activating panel that can still become key
/// so the note editor and text fields accept keyboard input when clicked.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // The panel is a dark surface by design. Pin its appearance to dark so
        // Liquid Glass (`.glassEffect`) always frosts *dark* — under a light system
        // theme a `.regular` glass renders bright and drowns the white content on
        // it, which is exactly the low-contrast the settings panes had.
        appearance = NSAppearance(named: .darkAqua)

        isFloatingPanel = true
        level = .statusBar + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true

        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
