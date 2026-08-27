import SwiftUI
import AppKit

/// One row in a Liquid Glass context menu. Either a leaf (has `action`) or a
/// parent that pushes a `submenu`.
struct GlassMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String?
    var isDestructive: Bool = false
    var action: (() -> Void)?
    var submenu: [GlassMenuItem]?

    static func item(_ title: String, systemImage: String? = nil,
                     destructive: Bool = false, action: @escaping () -> Void) -> GlassMenuItem {
        GlassMenuItem(title: title, systemImage: systemImage, isDestructive: destructive, action: action)
    }

    static func menu(_ title: String, systemImage: String? = nil,
                     _ submenu: [GlassMenuItem]) -> GlassMenuItem {
        GlassMenuItem(title: title, systemImage: systemImage, submenu: submenu)
    }
}

/// App-wide presenter for the custom glass context menu. Injected into the
/// environment; any view triggers it via `.glassContextMenu { … }`, and a single
/// `GlassMenuHost` (in RootView) renders whatever is active.
@MainActor
final class GlassMenuController: ObservableObject {
    static let shared = GlassMenuController()

    @Published var items: [GlassMenuItem] = []
    @Published var anchor: CGPoint = .zero
    @Published var isPresented = false

    func show(_ items: [GlassMenuItem], at point: CGPoint) {
        guard !items.isEmpty else { return }
        self.items = items
        self.anchor = point
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            isPresented = true
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.14)) { isPresented = false }
    }
}

/// An invisible AppKit overlay that reports right-clicks (and passes every other
/// event straight through, so normal taps/drags still work).
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class RightClickNSView: NSView {
        var onRightClick: ((CGPoint) -> Void)?

        // Only intercept right-clicks; return nil for everything else so left
        // clicks / drags reach the SwiftUI content underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp:
                return self
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let content = window?.contentView else { return }
            let loc = event.locationInWindow
            // Window uses a bottom-left origin; flip to the top-left space SwiftUI uses.
            onRightClick?(CGPoint(x: loc.x, y: content.bounds.height - loc.y))
        }
    }
}

private struct GlassContextMenuModifier: ViewModifier {
    @EnvironmentObject private var controller: GlassMenuController
    let items: () -> [GlassMenuItem]

    func body(content: Content) -> some View {
        content.overlay(
            RightClickCatcher { point in
                controller.show(items(), at: point)
            }
        )
    }
}

extension View {
    /// Presents a Liquid Glass context menu (instead of the native gray one) on
    /// right-click. Requires a `GlassMenuHost` in the window and a
    /// `GlassMenuController` in the environment.
    func glassContextMenu(_ items: @escaping () -> [GlassMenuItem]) -> some View {
        modifier(GlassContextMenuModifier(items: items))
    }
}
