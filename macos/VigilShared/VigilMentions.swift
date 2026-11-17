import Foundation
import Ink
import MarkdownText
import SwiftUI
import Syntax
import VigilWire

/// The files a message names, as links that open them (harness/README.md
/// "Messages"): found by VigilWire's one rule (`FileMentions`), asked of the
/// Mac they are on once per message (`MentionCall.look`), drawn as links
/// only where that Mac says a file or folder is, and opened in vigil's own
/// reader (`VigilFilePage`).

/// A file a message named, as its Mac answered it.
struct VigilMentionedFile: Hashable, Identifiable, Sendable {
    /// The tether root of the Mac it is on.
    var root: String
    /// Absolute, on that Mac.
    var path: String
    var folder: Bool
    var line: Int?
    var column: Int?
    /// That Mac's home, so the page writes `~`.
    var home: String

    var id: String { "\(root)\(path)#\(line ?? 0)" }
    var name: String { (path as NSString).lastPathComponent }
    var shown: String { FileMentions.shown(path, home: home) }

    /// The link a page follows to it: vigil's own scheme, opened by the
    /// conversation's `openURL`, never by the system.
    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "file"
        parts.queryItems = [
            .init(name: "root", value: root), .init(name: "path", value: path), .init(name: "home", value: home),
            .init(name: "folder", value: folder ? "1" : nil),
            .init(name: "line", value: line.map(String.init)), .init(name: "column", value: column.map(String.init)),
        ].filter { $0.value != nil }
        return parts.url!
    }

    static let scheme = "vigil-mention"

    init(root: String, path: String, folder: Bool, line: Int?, column: Int?, home: String) {
        self.root = root
        self.path = path
        self.folder = folder
        self.line = line
        self.column = column
        self.home = home
    }

    /// The file a link names; nil for any other URL.
    init?(_ url: URL) {
        guard url.scheme == Self.scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let root = value("root"), let path = value("path"), let home = value("home") else { return nil }
        self.init(
            root: root, path: path, folder: value("folder") == "1", line: value("line").flatMap(Int.init),
            column: value("column").flatMap(Int.init), home: home)
    }
}

/// What each message's Mac said of the paths it names, kept for the app's
/// life: asked once per message's words (its id and digest) and place.
@MainActor
final class VigilMentions {
    static let shared = VigilMentions()

    typealias Found = [String: MentionFound]

    private var found: [String: Found] = [:]
    /// The asks on their way: a message drawn twice (a window and an aside)
    /// waits on the one ask.
    private var asking: [String: Task<Found?, Never>] = [:]

    static func key(_ id: String, _ words: String, _ place: MentionPlace) -> String {
        "\(id)|\(Message.digest(of: words))|\(place.root)|\(place.pane ?? "")|\(place.folder ?? "")"
    }

    func cached(_ key: String) -> Found? { found[key] }

    /// What the message's Mac says of the paths in `words`: asked once,
    /// nil while it has not answered (or could not: the words stay words).
    func look(_ key: String, _ words: String, _ place: MentionPlace, host: VigilChatHost) async -> Found? {
        if let known = found[key] { return known }
        let paths = FileMentions.candidates(in: words)
        guard !paths.isEmpty else {
            found[key] = [:]
            return [:]
        }
        if let waiting = asking[key] { return await waiting.value }
        let mention = host.mention
        let ask = Task<Found?, Never> {
            do {
                let data = try await mention(.look(paths, pane: place.pane, folder: place.folder), place.root)
                let looks = try JSONDecoder().decode([MentionFound].self, from: data)
                return Dictionary(looks.map { ($0.written, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                // Not kept: the next time the message is drawn asks again.
                // The host's transport said why (its log, the phone's receipts).
                return nil
            }
        }
        asking[key] = ask
        let answer = await ask.value
        asking[key] = nil
        if let answer { found[key] = answer }
        return answer
    }

    /// The links a page draws from what the Mac said: a found path and a
    /// folder only where this device can show one.
    nonisolated static func links(_ found: Found, root: String, folders: Bool) -> MarkdownLinks {
        @Sendable func file(_ written: String, line: Int?, column: Int?) -> VigilMentionedFile? {
            guard let look = found[written], let path = look.path, let kind = look.kind, kind == .file || folders else { return nil }
            return VigilMentionedFile(root: root, path: path, folder: kind == .folder, line: line, column: column, home: look.home)
        }
        return MarkdownLinks(
            destination: { written in
                FileMentions.destination(written).flatMap { file($0.path, line: $0.line, column: $0.column)?.url }
            },
            spans: { words in
                FileMentions.find(in: words).compactMap { mention in
                    guard let file = file(mention.path, line: mention.line, column: mention.column) else { return nil }
                    // The Mac's home said as `~`: the rest is the sender's words.
                    let written = words[mention.range]
                    let at = written.hasPrefix("@") ? "@" : ""
                    let path = written.dropFirst(at.count)
                    let shown: String? = path.hasPrefix(file.home + "/") ? at + "~" + path.dropFirst(file.home.count) : nil
                    return MarkdownLinks.Span(range: mention.range, url: file.url, words: shown)
                }
            })
    }
}

/// A message's words with the files they name as links: what a bubble draws.
struct VigilMessageWords: View {
    let id: String
    let words: String
    let place: MentionPlace?
    let host: VigilChatHost
    /// What a press on a file does: the host's, given the file.
    let open: (VigilMentionedFile) -> Void

    @State private var found: VigilMentions.Found?

    init(id: String, words: String, place: MentionPlace?, host: VigilChatHost, open: @escaping (VigilMentionedFile) -> Void) {
        self.id = id
        self.words = words
        self.place = place
        self.host = host
        self.open = open
        _found = State(initialValue: place.flatMap { VigilMentions.shared.cached(VigilMentions.key(id, words, $0)) })
    }

    var body: some View {
        let key = place.map { VigilMentions.key(id, words, $0) }
        MarkdownView(words)
            .markdownLinks(found.flatMap { found in place.map { VigilMentions.links(found, root: $0.root, folders: host.reveals($0.root)) } })
            .environment(\.openURL, OpenURLAction { url in
                guard let file = VigilMentionedFile(url) else { return .systemAction }
                open(file)
                return .handled
            })
            // A run of text takes one tooltip, not one per link: the words'
            // files in full, under the pointer anywhere on them.
            .help(Self.paths(found))
            // Its words changed (an edit): what was found is asked again.
            .task(id: key) {
                found = key.flatMap { VigilMentions.shared.cached($0) }
                guard let key, let place else { return }
                guard found == nil else { return }
                found = await VigilMentions.shared.look(key, words, place, host: host)
            }
    }

    /// Every path the words name that its Mac found, whole, one a line, sorted.
    private static func paths(_ found: VigilMentions.Found?) -> String {
        guard let found else { return "" }
        let paths = found.values.compactMap(\.path)
        return Array(Set(paths)).sorted().joined(separator: "\n")
    }
}

/// A file a message named, read from its Mac and drawn as vigil reads it:
/// markdown as a page, any other text as code coloured by its kind, at the
/// line the message named.
struct VigilFilePage: View {
    let file: VigilMentionedFile
    /// The file's text from its Mac (`MentionCall.read`).
    let read: @Sendable () async throws -> DocumentText
    /// Shows the file in this Mac's Finder; nil where it is on another Mac
    /// or the device has no Finder. Offered when the file is not text.
    var reveal: (() -> Void)? = nil

    @State private var text: DocumentText?
    @State private var failure: String?
    @Environment(\.colorScheme) private var scheme

    private var ext: String { (file.path as NSString).pathExtension.lowercased() }
    private var markdown: Bool { ["md", "markdown", "mdx", "mdown"].contains(ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(file.shown + (file.line.map { ":\($0)" } ?? ""))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if let text {
                if markdown {
                    ScrollView {
                        MarkdownView(text.text).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VigilCodePage(text: text.text, language: ext, line: file.line, scheme: scheme)
                }
            } else if let failure {
                VStack(alignment: .leading, spacing: 10) {
                    Text(failure).inkText(.detail)
                    if let reveal {
                        Button("Show in Finder", systemImage: "folder", action: reveal)
                    }
                }
                .padding(16)
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: file.id) {
            do {
                text = try await read()
                failure = nil
            } catch {
                failure = "Not read: \(error)"
            }
        }
    }
}

/// Code as a page: its lines numbered, coloured by its kind (swift-utils'
/// `Syntax`, by the file's extension), scrolled to the named line and that
/// line marked.
private struct VigilCodePage: View {
    let lines: [AttributedString]
    let line: Int?

    init(text: String, language: String, line: Int?, scheme: ColorScheme) {
        let ground = Syntax.Appearance(scheme)
        let colored = language.isEmpty || ["txt", "log"].contains(language)
            ? AttributedString(text) : Syntax.highlight(text, language: language, on: ground)
        lines = Self.split(colored)
        self.line = line
    }

    /// One attributed line per line of the text, its newline gone.
    private static func split(_ text: AttributedString) -> [AttributedString] {
        var lines: [AttributedString] = []
        var start = text.startIndex
        var at = text.characters.startIndex
        while at < text.characters.endIndex {
            if text.characters[at] == "\n" {
                lines.append(AttributedString(text[start..<at]))
                start = text.characters.index(after: at)
            }
            at = text.characters.index(after: at)
        }
        lines.append(AttributedString(text[start..<text.endIndex]))
        return lines
    }

    var body: some View {
        let digits = String(lines.count).count
        ScrollViewReader { scroll in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(String(index + 1))
                                .foregroundStyle(.tertiary)
                                .frame(width: CGFloat(digits) * 8 + 4, alignment: .trailing)
                            Text(lines[index]).fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index + 1 == line ? Color.accentColor.opacity(0.14) : .clear)
                        .id(index + 1)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
            .onAppear {
                guard let line, line >= 1, line <= lines.count else { return }
                scroll.scrollTo(line, anchor: .center)
            }
        }
    }
}
