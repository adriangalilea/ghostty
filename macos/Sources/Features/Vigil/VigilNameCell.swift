import SwiftUI

/// ONE naming control, used by every row that has a name: the face on the
/// left with a chevron (the classic "there are others" affordance, so it
/// reads as a picker), then the name, which you rename by double-clicking
/// the text exactly like a native tab. Two gestures, no context menus, no
/// layout shift: the row looks identical whether or not you can edit it.
struct VigilNameCell<Fallback: View>: View {
    let emoji: String?
    let title: String
    let font: Font
    let color: Color
    /// nil = this row cannot be renamed (no identity to write to).
    var onRename: ((String?) -> Void)?
    var onPickEmoji: ((String?) -> Void)?
    /// What the face slot shows when there is no emoji (the row's own icon).
    @ViewBuilder var fallback: () -> Fallback

    @State private var editing = false
    @State private var draft = ""
    @State private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            face
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .focused($focused)
                    .onSubmit(commit)
                    // Esc leaves it exactly as it was.
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    // Clicking away commits, like every inline rename on
                    // this platform. (Deployment target is 13, so this is
                    // the single-argument onChange.)
                    .onChange(of: focused) { now in if !now { commit() } }
            } else {
                Text(title)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard onRename != nil else { return }
                        draft = title
                        editing = true
                    }
            }
        }
    }

    private var face: some View {
        Group {
            if onPickEmoji == nil {
                slot
            } else {
                Button(action: { picking = true }) {
                    HStack(spacing: 1) {
                        slot
                        Image(systemName: "chevron.down")
                            .font(.system(size: 6, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Pick a face")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    VigilEmojiPickerView(selected: emoji) { picked in
                        onPickEmoji?(picked)
                        picking = false
                    }
                }
            }
        }
    }

    private var slot: some View {
        Group {
            if let emoji, let first = emoji.first {
                Text(String(first)).font(.system(size: 11))
            } else {
                fallback()
            }
        }
        .frame(width: 20)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        onRename?(trimmed.isEmpty ? nil : trimmed)
    }
}
