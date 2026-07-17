import AppKit
import SwiftUI

/// Per-window controls in the titlebar: the survival eye ON/OFF (click to
/// flip ephemeral <-> persistent) and the pin-on-top, on EVERY window. The
/// eye's color is the survival class, cold on purpose (persisted =
/// preserved): teal = daemon-backed (survives quit), icy cyan =
/// capture+resume fallback, yellow = ephemeral (the class that just dies).
/// Native titlebar accessory, composes with tabs and titlebar theming.
final class VigilTitlebarAccessory: NSTitlebarAccessoryViewController {}

/// The survival ring: a click-through overlay whose layer border traces
/// the window frame's own rounded shape.
final class VigilBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct VigilWindowMark: View {
    /// nil for an ephemeral window (no session label yet).
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
    private var eyeIcon: String { persistent ? "eye.fill" : "eye.slash" }

    var body: some View {
        HStack(spacing: 6) {
            // Pin on top.
            Button(action: onTogglePin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(pinned ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(pinned ? "Pinned above other windows. Click to unpin."
                         : "Pin this window above the others.")

            // Survival eye ON/OFF: click to flip persistent <-> ephemeral.
            Button(action: onTogglePersist) {
                HStack(spacing: 4) {
                    Image(systemName: eyeIcon).font(.system(size: 9, weight: .bold))
                    if let label {
                        Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                }
                .foregroundColor(eyeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(eyeColor.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .help(persistent
                ? "Persistent: survives closing the window and quitting the app. Click to make ephemeral."
                : "Ephemeral: dies when the window closes. Click to make it survive quit.")
        }
        .padding(.trailing, 8)
    }
}
