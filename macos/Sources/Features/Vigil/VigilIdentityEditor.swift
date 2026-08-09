import AppKit
import FoundationModels
import SwiftUI

/// A session's face: its emoji and its label, one identity edited together.
/// The editor is a single row (emoji well · name field · sparkle) plus a
/// strip of emoji already used across sessions; it lives inline on the
/// overview card and inside an alert for the menu-bar / titlebar paths.
/// The sparkle asks the on-device model for the PAIR (an emoji chosen with
/// the name is coherent; two separate generations never meet), constrained
/// by guided generation so an invalid emoji cannot be produced.

/// Shared mutable draft so the surface that ran the editor (overview,
/// alert) reads the result at commit time regardless of how the commit was
/// triggered (Enter in the field, the alert's Save button).
@MainActor
final class VigilIdentityDraft: ObservableObject {
    @Published var label: String
    @Published var emoji: String {
        didSet {
            let filtered = VigilIdentity.filterEmoji(emoji)
            if filtered != emoji { emoji = filtered }
        }
    }

    init(label: String, emoji: String) {
        self.label = label
        self.emoji = VigilIdentity.filterEmoji(emoji)
    }
}

enum VigilIdentity {
    /// Emoji the model may pick from. anyOf-constrained generation makes a
    /// valid, renderable emoji a property of the grammar, not a hope; the
    /// manual well covers the full Unicode space via the character palette.
    static let palette: [String] = [
        // animals (the id nouns live here on purpose)
        "🦦", "🐼", "🦅", "🦉", "🐙", "🐋", "🦈", "🐢", "🐍", "🦎", "🐝", "🦋",
        "🐌", "🦀", "🦭", "🐺", "🦊", "🐻", "🐘", "🦒", "🦌", "🐎", "🐐", "🐇",
        "🐿️", "🦔", "🦇", "🐸", "🐟", "🐬", "🦩", "🦜", "🦚", "🕊️", "🦢", "🪶",
        "🐉", "🦖", "🦕", "🕷️", "🐚",
        // nature
        "🌲", "🌳", "🌵", "🌿", "🍀", "🍁", "🌸", "🌻", "🪷", "🌾", "🍄", "🪨",
        "⛰️", "🌋", "🏔️", "🏜️", "🏝️", "🌊",
        // sky and space
        "🌌", "🚀", "🛰️", "🪐", "⭐", "🌟", "☄️", "🌙", "☀️", "🌈", "⚡", "❄️",
        "🔥", "💧", "🌪️", "⛈️", "🌅",
        // tools and build
        "🔧", "🔨", "🛠️", "⚙️", "🧰", "⛏️", "🪓", "🪚", "🔩", "🧲", "🪛", "🗜️",
        // science
        "🔬", "🔭", "🧪", "🧫", "🧬", "⚗️", "📡",
        // objects and office
        "📦", "📚", "📖", "📝", "✏️", "🖋️", "📌", "📎", "🔑", "🗝️", "💡", "🔦",
        "🕯️", "🔋", "🖥️", "💾", "📀", "🗄️", "🗃️", "📁", "🗂️", "📊", "📈", "📉",
        "🧮", "⌨️", "🖱️", "☎️", "📻", "📷", "🎥", "🎬", "⏰", "⏳", "⌛", "🧭",
        "🗺️", "🔍", "📐", "📏", "✂️", "🧵", "🪢", "🧶", "🪜", "🧹", "🪞", "🚪",
        "🛎️", "🔔", "📮", "📬", "✉️", "📜", "🏷️", "🔖", "💼", "🎒", "👓",
        // security
        "🔒", "🔓", "🛡️", "🗡️", "⚔️", "🏹",
        // money
        "💰", "💎", "🪙", "🏦", "⚖️",
        // transport and places
        "🚂", "✈️", "⛵", "⚓", "🚁", "🛶", "🚲", "🏎️", "🛸", "🗼", "🏰", "🏗️",
        "🌉", "🗿",
        // food
        "🍎", "🍋", "🍉", "🍇", "🍒", "🥝", "🌶️", "🥕", "🌽", "🍯", "🧊", "🍞",
        "🧀", "☕", "🍵", "🧂",
        // games and art
        "🎲", "🎯", "🎮", "♟️", "🧩", "🪁", "🎨", "🎭", "🎪", "🎵", "🎸", "🎹",
        "🥁", "🎻", "🏆", "🎁", "🎈",
        // spirits and sparks
        "🤖", "👻", "💀", "👾", "🧠", "👁️", "🦾", "🧿", "✨", "🌀", "💫", "🕳️",
        "🪄", "♻️", "🫧", "🧨", "🎇",
    ]

    static var modelAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    /// Emoji-only, exactly ONE: every surface (card, tab row, pane row,
    /// menu, kill confirm) renders a single face, so accepting more stored
    /// a name nothing could ever show. The well accepts anything (typed,
    /// pasted, character palette) and keeps the first face.
    static func filterEmoji(_ s: String) -> String {
        let clusters = s.filter { ch in
            let scalars = ch.unicodeScalars
            return scalars.contains { $0.properties.isEmojiPresentation }
                || (scalars.contains { $0.properties.isEmoji }
                    && scalars.contains { $0.value == 0xFE0F })
        }
        return String(clusters.prefix(1))
    }

    /// One coherent suggestion: emoji chosen WITH the name. Guided
    /// generation constrains the emoji to the palette and the shape to the
    /// schema, so there is nothing to parse and nothing to validate.
    /// `avoiding` carries earlier suggestions so a re-roll diversifies.
    static func suggest(context: String, avoiding: [String]) async -> (emoji: String, label: String)? {
        guard #available(macOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let lm = LanguageModelSession(instructions: """
            You give terminal workspace sessions an identity: one or two \
            emoji plus a short evocative name, 2 to 4 lowercase words, no \
            punctuation. Name the task being done, not the tools.
            """)
        var prompt = context
        if !avoiding.isEmpty {
            prompt += "\nAlready suggested, answer with something different: \(avoiding.joined(separator: ", "))"
        }
        guard let response = try? await lm.respond(to: prompt, generating: SuggestedIdentity.self) else { return nil }
        let label = response.content.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !label.isEmpty, label.count <= 48 else { return nil }
        return (filterEmoji(response.content.emoji.joined()), label)
    }

    /// The modal identity editor (menu bar "Rename…", the titlebar chip):
    /// same editor view, alert chrome. The overview edits inline instead.
    @MainActor
    static func editModal(name: String) {
        let manager = VigilSessionManager.shared
        guard let session = manager.sessions[name] else { return }
        editModal(
            title: "Session identity",
            label: session.label,
            emoji: session.emoji,
            context: manager.identityContext(name: name)
        ) { label, emoji in
            manager.rename(
                name: name,
                label: label ?? session.label,
                emoji: emoji)
        }
    }

    /// The SAME editor for any identity (tabs, panes): alert chrome,
    /// emoji well, sparkle. onCommit receives nil label for "unchanged/
    /// cleared", nil emoji for none.
    @MainActor
    static func editModal(
        title: String,
        label: String,
        emoji: String?,
        context: String,
        onCommit: @escaping (String?, String?) -> Void
    ) {
        let manager = VigilSessionManager.shared
        let draft = VigilIdentityDraft(label: label, emoji: emoji ?? "")
        let alert = NSAlert()
        alert.messageText = title
        let view = VigilIdentityEditor(
            draft: draft,
            context: context,
            recents: manager.recentEmoji(),
            onSubmit: { NSApp.stopModal(withCode: .alertFirstButtonReturn) })
        let hosting = NSHostingView(rootView: view)
        // Size in TWO passes: fittingSize is measured against the current
        // frame, so asking before the width is applied returns a height for
        // some other layout and the bottom row (the emoji strip and its
        // pickers) is clipped out of the alert entirely - it is there, you
        // just cannot see it.
        hosting.setFrameSize(NSSize(width: 320, height: 1))
        hosting.layoutSubtreeIfNeeded()
        hosting.setFrameSize(NSSize(width: 320, height: hosting.fittingSize.height))
        alert.accessoryView = hosting
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = hosting

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = draft.label.trimmingCharacters(in: .whitespaces)
        onCommit(
            trimmed.isEmpty ? nil : trimmed,
            draft.emoji.isEmpty ? nil : draft.emoji)
    }
}

/// The generation target. anyOf over the palette + a count guide: the model
/// physically cannot emit an invalid emoji or a wrong shape.
@available(macOS 26.0, *)
@Generable(description: "An identity for a terminal workspace session")
private struct SuggestedIdentity {
    @Guide(description: "emoji evoking the task", .count(1), .element(.anyOf(VigilIdentity.palette)))
    var emoji: [String]
    @Guide(description: "short evocative name: 2 to 4 lowercase words, no punctuation, the task not the tools")
    var label: String
}

struct VigilIdentityEditor: View {
    @ObservedObject var draft: VigilIdentityDraft
    let context: String
    let recents: [String]
    /// Commit is the OWNER's move (it reads the draft): Enter here only says
    /// "now". Cancel is also the owner's (esc in the overview monitor, the
    /// alert's Cancel button); the editor never destroys anything itself.
    let onSubmit: () -> Void

    @State private var thinking = false
    @State private var picking = false
    @State private var rejected: [String] = []
    @FocusState private var focus: Field?
    private enum Field { case emoji, name }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $draft.emoji)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focus, equals: .emoji)
                    .frame(width: 52, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    .overlay {
                        if draft.emoji.isEmpty {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    .help("Emoji for this session. Click, then pick from the palette or type.")

                TextField("name", text: $draft.label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focus, equals: .name)
                    .onSubmit(onSubmit)
                    .frame(height: 24)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))

                if VigilIdentity.modelAvailable {
                    Button(action: suggest) {
                        if thinking {
                            ProgressView().controlSize(.small).frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.yellow)
                                .frame(width: 18, height: 18)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(thinking)
                    .help("Let the on-device model propose an emoji + name from what this session is doing. Click again for a different one.")
                }
            }

            HStack(spacing: 6) {
                ForEach(recents.prefix(8), id: \.self) { emoji in
                    Button(action: { draft.emoji = emoji }) {
                        Text(emoji).font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button(action: { picking.toggle() }) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Pick an emoji.")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    emojiPicker
                }
                Button(action: {
                    focus = .emoji
                    NSApp.orderFrontCharacterPalette(nil)
                }) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open the system emoji palette, for anything outside the picker.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .onAppear {
            DispatchQueue.main.async { focus = .name }
        }
    }

    /// The curated palette as a grid: one click IS the choice (a face is a
    /// single character, so there is nothing to confirm). Same list the
    /// on-device model draws from, so picked and suggested faces look like
    /// one family.
    private var emojiPicker: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 2), count: 10),
                      spacing: 2) {
                ForEach(VigilIdentity.palette, id: \.self) { emoji in
                    Button(action: {
                        draft.emoji = emoji
                        picking = false
                    }) {
                        Text(emoji)
                            .font(.system(size: 16))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(draft.emoji == emoji
                                          ? Color.accentColor.opacity(0.35) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 300, height: 240)
    }

    private func suggest() {
        thinking = true
        Task { @MainActor in
            if let got = await VigilIdentity.suggest(context: context, avoiding: rejected) {
                rejected.append(got.label)
                withAnimation(.easeOut(duration: 0.15)) {
                    draft.emoji = got.emoji
                    draft.label = got.label
                }
            }
            thinking = false
        }
    }
}
