import SwiftUI

/// THE face control. One component, one look, everywhere a thing has a
/// name: sidebar session/tab/pane rows, and mounted persistently in every
/// native tab. A classic pull-down: content, hairline separator, chevron,
/// inside a container that lights under the cursor so the hit area is
/// visible before you commit to it. Always present, never gated behind
/// being in some edit mode.
struct VigilFaceButton<Fallback: View>: View {
    let emoji: String?
    let onPick: (String?) -> Void
    @ViewBuilder var fallback: () -> Fallback

    @State private var picking = false
    @State private var hovering = false

    var body: some View {
        Button(action: { picking = true }) {
            HStack(spacing: 3) {
                Group {
                    if let emoji, let first = emoji.first {
                        Text(String(first)).font(.system(size: 11))
                    } else {
                        fallback()
                    }
                }
                .frame(width: 16)
                Divider().frame(height: 9)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(hovering ? 0.15 : 0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(hovering ? 0.28 : 0.10), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Pick a face")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VigilEmojiPickerView(selected: emoji) { picked in
                onPick(picked)
                picking = false
            }
        }
    }
}
