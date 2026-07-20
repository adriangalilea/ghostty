import AppKit
import SwiftUI

/// Per-window controls in the titlebar: the survival eye ON/OFF (click to
/// flip ephemeral <-> persistent) and the pin-on-top, on EVERY window.
/// Persistent wears teal, cold on purpose (persisted = preserved);
/// ephemeral is neutral. Native titlebar accessory, composes with tabs and
/// titlebar theming.
final class VigilTitlebarAccessory: NSTitlebarAccessoryViewController {}

/// The survival-class border: a click-through overlay INSIDE the window's
/// contentView (the same safe surface the glass effect uses), tracing the
/// window's real rounded corners via `_cornerRadius`. NOT a subview of the
/// private frame view (NSThemeFrame) — that destabilized window teardown
/// and left zombie windows (2026-07-18). ARC-owned by contentView, so it
/// tears down with the window and never touches close.
final class VigilBorderOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { true }
}


struct VigilWindowMark: View {
    /// The session label; shown only on hover (help), never inline. What
    /// the titlebar shows is one thing: is this window persistent or not.
    let label: String?
    let persistent: Bool
    let pinned: Bool
    var onTogglePersist: () -> Void
    var onTogglePin: () -> Void

    var body: some View {
        content
            // Match the titlebar height and centre, so the buttons line up
            // with the native traffic lights instead of floating above them.
            .frame(height: 28)
    }

    private var content: some View {
        HStack(spacing: 7) {
            roundButton(
                // Floating (on top): a window hovering over another. Neutral.
                icon: pinned ? "macwindow.on.rectangle" : "macwindow",
                on: pinned,
                color: .primary,
                action: onTogglePin,
                help: pinned ? "Floating above other windows. Click to drop it back."
                             : "Float this window above the others.")

            roundButton(
                // Persistent = infinity (endures, keeps running in the
                // background); ephemeral = hourglass (time-limited, dies on
                // close). Persistent in the cold class colour, ephemeral neutral.
                icon: persistent ? "infinity" : "hourglass",
                on: persistent,
                color: persistent ? .teal : .secondary,
                action: onTogglePersist,
                help: persistHelp)
        }
        .padding(.trailing, 8)
    }

    private var persistHelp: String {
        let name = label.map { "“\($0)” " } ?? ""
        return persistent
            ? "\(name)persistent: survives closing the window and quitting the app. Click to make ephemeral."
            : "Ephemeral: dies when the window closes. Click to make it survive quit."
    }

    /// A subtle round button, glyph always in its class colour (so the
    /// class reads at a glance) on a faint disc: a touch stronger when ON,
    /// fainter when OFF. No harsh fills or borders; sized like the native
    /// traffic lights next to it.
    private func roundButton(
        icon: String, on: Bool, color: Color, action: @escaping () -> Void, help: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color.opacity(on ? 0.20 : 0.10)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
