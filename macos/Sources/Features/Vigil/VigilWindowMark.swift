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
    /// The session label; shown only on hover (help), never inline. The
    /// titlebar shows two things: the session's emoji face (its chip is the
    /// door to the identity editor) and whether the window is persistent.
    let label: String?
    /// The session's emoji face, shown inline (colour carries itself; no
    /// class semantics). nil session emoji shows a faint placeholder.
    let emoji: String?
    let persistent: Bool
    let pinned: Bool
    /// Whether this tab's dock (the right bar) is open.
    let dockOpen: Bool
    /// Opens the identity editor; nil for session-less windows (safety-net
    /// strays have no identity to edit) which then show no chip at all.
    var onEditIdentity: (() -> Void)?
    /// The mounted TAB's face and name, and the door to its editor.
    var tabEmoji: String?
    var tabLabel: String?
    var onEditTab: (() -> Void)?
    var onTogglePersist: () -> Void
    var onTogglePin: () -> Void
    /// Toggles the tab's dock; nil for session-less windows.
    var onToggleDock: (() -> Void)?

    var body: some View {
        content
            // Match the titlebar height and centre, so the buttons line up
            // with the native traffic lights instead of floating above them.
            .frame(height: 28)
    }

    private var content: some View {
        HStack(spacing: 7) {
            if let onEditIdentity {
                Button(action: onEditIdentity) {
                    Group {
                        if let emoji, !emoji.isEmpty {
                            Text(emoji).font(.system(size: 11))
                        } else {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(minWidth: 18)
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(identityHelp)
            }

            // The TAB's own face, right where the tab bar is: the session
            // chip names the workspace, this names the tab you are looking
            // at. Clicking either opens the same editor (emoji picker
            // included) on the thing it belongs to, so a name is never
            // something you have to hunt through a context menu for.
            if let onEditTab {
                Button(action: onEditTab) {
                    Group {
                        if let tabEmoji, !tabEmoji.isEmpty {
                            Text(tabEmoji).font(.system(size: 11))
                        } else {
                            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(minWidth: 18)
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(tabLabel.map { "Tab: \($0). Click to rename it or give it a face." }
                      ?? "Name this tab, or give it a face.")
            }

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

            if let onToggleDock {
                roundButton(
                    // The tab's dock: a collapsible stack of tool panes
                    // (lazygit, dev server) on the right. Collapse never
                    // kills; the tenants' daemons keep running.
                    icon: "sidebar.right",
                    on: dockOpen,
                    color: .primary,
                    action: onToggleDock,
                    help: dockOpen
                        ? "Collapse this tab's dock (its panes keep running)."
                        : "Open this tab's dock: side panes like lazygit or a dev server.")
            }
        }
        .padding(.trailing, 8)
    }

    private var identityHelp: String {
        let name = label.map { "“\($0)”. " } ?? ""
        return "\(name)Edit this session's emoji and name."
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
