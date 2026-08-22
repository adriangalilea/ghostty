import AppKit
import SwiftUI

/// Per-window controls in the titlebar: the session's face chip (the door
/// to the identity editor), the pin-on-top, and the tab's dock toggle.
/// Native titlebar accessory, composes with tabs and titlebar theming.
final class VigilTitlebarAccessory: NSTitlebarAccessoryViewController {}

struct VigilWindowMark: View {
    /// The session label; shown only on hover (help), never inline.
    let label: String?
    /// The session's emoji face, shown inline (colour carries itself; no
    /// class semantics). nil session emoji shows a faint placeholder.
    let emoji: String?
    let pinned: Bool
    /// Whether this tab's dock (the right bar) is open.
    let dockOpen: Bool
    /// Opens the identity editor; nil for session-less windows (safety-net
    /// strays have no identity to edit) which then show no chip at all.
    var onEditIdentity: (() -> Void)?
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

            roundButton(
                // Floating (on top): a window hovering over another. Neutral.
                icon: pinned ? "macwindow.on.rectangle" : "macwindow",
                on: pinned,
                color: .primary,
                action: onTogglePin,
                help: pinned ? "Floating above other windows. Click to drop it back."
                             : "Float this window above the others.")

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

    /// A subtle round button, glyph always in its colour on a faint disc:
    /// a touch stronger when ON, fainter when OFF. No harsh fills or
    /// borders; sized like the native traffic lights next to it.
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
