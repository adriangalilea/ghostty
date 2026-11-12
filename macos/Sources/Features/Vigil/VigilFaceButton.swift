import SwiftUI

/// THE face control. One component, one look, everywhere a thing has a
/// name: sidebar workspace, tab and pane rows. The face itself is the
/// button that opens the picker, in a well that lights under the cursor
/// so the hit area is visible before you commit to it. Always present,
/// never gated behind being in some edit mode.
struct VigilFaceButton<Fallback: View>: View {
    let emoji: String?
    var scale: CGFloat = 1
    let onPick: (String?) -> Void
    @ViewBuilder var fallback: () -> Fallback

    @State private var picking = false
    @State private var hovering = false

    var body: some View {
        Button {
            picking = true
        } label: {
            // The face alone, as wide as a face that cannot be picked
            // (`VigilNameCell.face`): a row's name starts in one place
            // either way. Its well shows under the pointer, which is where
            // it says it can be pressed; at rest a row is its face and its
            // words, with no box around either.
            Group {
                if let emoji, let first = emoji.first {
                    Text(String(first)).font(.system(size: 11 * scale))
                } else {
                    fallback()
                }
            }
            .frame(width: VigilNameCell<Fallback>.face * scale, height: 16 * scale)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(hovering ? 0.15 : 0)))
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
