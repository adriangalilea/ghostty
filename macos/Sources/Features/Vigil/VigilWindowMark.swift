import AppKit
import SwiftUI

/// The mark of vigilance: persistent session windows carry an eye + label
/// pill in the titlebar; ephemeral windows carry nothing, absence IS the
/// state. Native titlebar accessory, so it composes with tabs and any
/// titlebar theming instead of fighting it.
///
/// The pill's COLOR is the survival class, mirrored by the window border,
/// and the palette is COLD ON PURPOSE (persisted = preserved, frozen):
/// teal = every pane lives in a daemon, the session survives the app
/// dying; icy cyan = capture+resume class, processes die with the app
/// (content and claude come back on resurrection). Clicking an icy pill
/// upgrades the whole window into daemons in place. Warm colors are for
/// what actually dies: the overview marks ephemeral windows orange.
final class VigilTitlebarAccessory: NSTitlebarAccessoryViewController {}

/// The survival ring: a click-through overlay whose layer border traces
/// the window frame's own rounded shape.
final class VigilBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct VigilWindowMark: View {
    let label: String
    let daemonBacked: Bool
    var onUpgrade: (() -> Void)?

    private var color: Color { daemonBacked ? .teal : .cyan }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: daemonBacked ? "eye.fill" : "eye")
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if !daemonBacked {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
        .padding(.trailing, 8)
        .help(daemonBacked
            ? "Every pane lives in a daemon: this session survives closing the window, quitting the app, crashes and reboots."
            : "Capture+resume class: these processes die with the app (content and claude resume afterwards). Click to move every pane into a daemon now.")
        .onTapGesture { onUpgrade?() }
    }
}
