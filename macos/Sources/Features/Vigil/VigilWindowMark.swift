import AppKit
import SwiftUI

/// Per-window controls in the titlebar: the survival eye ON/OFF (click to
/// flip ephemeral <-> persistent) and the pin-on-top, on EVERY window. The
/// eye's color is the survival class, cold on purpose (persisted =
/// preserved): teal = daemon-backed (survives quit), icy cyan =
/// capture+resume fallback, yellow = ephemeral (the class that just dies).
/// Native titlebar accessory, composes with tabs and titlebar theming.
final class VigilTitlebarAccessory: NSTitlebarAccessoryViewController {}

struct VigilWindowMark: View {
    /// The session label; shown only on hover (help), never inline. What
    /// the titlebar shows is one thing: is this window persistent or not.
    let label: String?
    let persistent: Bool
    let daemonBacked: Bool
    let pinned: Bool
    var onTogglePersist: () -> Void
    var onTogglePin: () -> Void

    private var eyeColor: Color {
        guard persistent else { return .yellow }
        return daemonBacked ? .teal : .cyan
    }

    var body: some View {
        HStack(spacing: 7) {
            roundButton(
                icon: pinned ? "pin.fill" : "pin",
                on: pinned,
                color: .accentColor,
                action: onTogglePin,
                help: pinned ? "Pinned above other windows. Click to unpin."
                             : "Pin this window above the others.")

            roundButton(
                // Anchor = persistent (anchored, stays through quit/reboot);
                // bolt = ephemeral (fleeting, dies on close).
                icon: persistent ? "anchor" : "bolt.fill",
                on: persistent,
                color: eyeColor,
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

    /// A real, round, high-contrast button: filled in its color when ON,
    /// an outlined neutral disc when OFF. No washed-out tints.
    private func roundButton(
        icon: String, on: Bool, color: Color, action: @escaping () -> Void, help: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(on ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(on ? color : Color.primary.opacity(0.08)))
                .overlay(
                    Circle().strokeBorder(
                        on ? Color.white.opacity(0.25) : Color.primary.opacity(0.2),
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
