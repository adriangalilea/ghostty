import AppKit
import SwiftUI

/// The mark of vigilance: persistent session windows carry an eye + label
/// pill in the titlebar; ephemeral windows carry nothing, absence IS the
/// state. Native titlebar accessory, so it composes with tabs and any
/// titlebar theming instead of fighting it.
final class VigilTitlebarAccessory: NSTitlebarAccessoryViewController {}

struct VigilWindowMark: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.fill")
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        .padding(.trailing, 8)
    }
}
