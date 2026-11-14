import Foundation
import GitKit
import GitViews
import MarkdownEditing
import SwiftUI
import VigilWire

/// One `DocumentCall` answered by a pane's Mac (harness/DOCUMENTS.md): over
/// the link from the phone or for another Mac's pane, by this Mac's hub for
/// its own (`Local.here`). What it throws is said as it describes itself.
typealias PaneDocumentCall = @Sendable (DocumentCall) async throws -> Data

/// The pane's documents watched on its Mac (`Open.documentWatch`).
typealias PaneDocumentWatch = @Sendable () -> AsyncStream<DocumentChange>

/// A line typed into the pane's agent and entered, on the person's press.
typealias PaneTell = @Sendable (String) async throws -> Void

/// The documents of one pane, and the one being edited. The Mac holds the
/// files; this holds the text on screen, what the Mac had when it was read
/// (`base`), and the way between them: an edit is written a moment after
/// typing pauses, over the text it was made on and no other, and the file's
/// own changes (the agent's, another editor's) come in place while nothing
/// here is unsaved.
@MainActor @Observable
final class PaneDocumentsModel {
    enum Standing: Equatable {
        case reading
        case saved
        case edited
        case saving
        /// The file changed under an unsaved edit: both texts, the person's choice.
        case conflict(DocumentText)
        case failed(String)
    }

    private let call: PaneDocumentCall
    private let watch: PaneDocumentWatch
    let tell: PaneTell?

    private(set) var list: DocumentList?
    private(set) var failure: String?
    /// The document on screen, by its path.
    private(set) var shown: String?
    private(set) var text = ""
    /// The file as the Mac had it when last read or written.
    private(set) var base: DocumentText?
    private(set) var standing = Standing.reading
    /// Documents the agent was told about, by the file's change it was told of.
    private(set) var told: [String: Double] = [:]
    private(set) var telling = false

    /// The text of a write on its way: the watch reads it back before the
    /// write's own answer arrives.
    private var sending: String?
    private var pending: Task<Void, Never>?
    private var following: Task<Void, Never>?

    init(call: @escaping PaneDocumentCall, watch: @escaping PaneDocumentWatch, tell: PaneTell?) {
        self.call = call
        self.watch = watch
        self.tell = tell
    }

    var document: PaneDocument? { shown.flatMap { path in list?.documents.first { $0.path == path } } }

    /// Typing pauses this long before the edit is written.
    static let pause = Duration.milliseconds(700)

    func start() async {
        await relist()
        if shown == nil {
            if let first = Self.opening(list) { await open(first.path) }
        } else {
            // Shown again after a while unwatched: the file may have moved on.
            await took(.everything)
        }
        following?.cancel()
        following = Task { [weak self, watch] in
            for await change in watch() {
                guard let self else { return }
                await self.took(change)
            }
        }
    }

    func stop() {
        following?.cancel()
        following = nil
        pending?.cancel()
        // An edit not yet written is written on the way out.
        if standing == .edited { Task { await save() } }
    }

    /// The document a pane opens on: the instruction file nearest the
    /// agent's folder (the last it reads), else whatever comes first.
    static func opening(_ list: DocumentList?) -> PaneDocument? {
        let there = (list?.documents ?? []).filter { $0.modified != nil }
        return there.last { $0.kind == .instructions } ?? there.first
    }

    private func relist() async {
        do {
            list = try JSONDecoder().decode(DocumentList.self, from: await call(.list))
            failure = nil
        } catch {
            if list == nil { failure = "\(error)" }
        }
    }

    /// Another document on screen; an edit of the one before is written first.
    func open(_ path: String) async {
        pending?.cancel()
        if standing == .edited { await save() }
        // Unwritten (a conflict, a failure): it stays on screen to be settled.
        guard shown == nil || standing == .saved || standing == .reading || path == shown else { return }
        shown = path
        standing = .reading
        base = nil
        await read()
    }

    private func read() async {
        guard let path = shown else { return }
        do {
            let read = try JSONDecoder().decode(DocumentText.self, from: await call(.read(path)))
            guard path == shown else { return }
            base = read
            text = read.text
            standing = .saved
            if heard[path] == nil { heard[path] = read.text }
        } catch {
            guard path == shown else { return }
            standing = .failed("\(error)")
        }
    }

    /// The editor's text changed: by a key, or by this model setting it.
    func typed(_ new: String) {
        guard new != text else { return }
        text = new
        guard base != nil, standing != .reading else { return }
        if case .conflict = standing { return }
        // A write on its way answers for itself (`save` settles after it).
        if sending == nil { settle() }
    }

    /// The text written over the file, while the file still holds `base`.
    func save() async {
        guard let base, let path = shown, sending == nil, text != base.text else { return }
        if case .conflict = standing { return }
        let sent = text
        sending = sent
        standing = .saving
        defer { sending = nil }
        do {
            let written = try JSONDecoder().decode(
                DocumentWritten.self, from: await call(.write(path, text: sent, over: base.hash)))
            guard path == shown else { return }
            if let hash = written.hash {
                self.base = DocumentText(path: path, text: sent, hash: hash, modified: written.modified ?? base.modified)
                // The watch says the file changed, and the list is read then.
                settle()
            } else if let theirs = written.theirs {
                meet(theirs)
            }
        } catch {
            guard path == shown else { return }
            standing = .failed("\(error)")
        }
    }

    /// After `base` moved: saved, or still ahead of it and written again.
    private func settle() {
        guard let base else { return }
        pending?.cancel()
        if text == base.text {
            standing = .saved
        } else {
            standing = .edited
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.pause)
                guard !Task.isCancelled else { return }
                await self?.save()
            }
        }
    }

    /// The file as it is on the Mac now, met by what is on screen.
    private func meet(_ theirs: DocumentText) {
        guard let base, theirs.hash != base.hash else { return }
        if theirs.text == text || theirs.text == sending {
            // This side's own write, read back.
            if theirs.text == text {
                self.base = theirs
                standing = .saved
            }
        } else if text == base.text {
            // Nothing unsaved here: the file's change comes in place. With
            // no edit of this side's waiting to be told, it is nothing to
            // tell either: someone else's change (the agent's own, mostly).
            if heard[theirs.path] == base.text { heard[theirs.path] = theirs.text }
            self.base = theirs
            text = theirs.text
            standing = .saved
        } else {
            pending?.cancel()
            standing = .conflict(theirs)
        }
    }

    private func took(_ change: DocumentChange) async {
        await relist()
        guard let path = shown, change.touches(path), standing != .reading else { return }
        // This side's own write, as the list now dates the file: nothing to read.
        if let base, sending == nil, document?.modified == base.modified { return }
        guard let read = try? JSONDecoder().decode(DocumentText.self, from: await call(.read(path))), path == shown else { return }
        if case .conflict = standing {
            standing = .conflict(read)
            return
        }
        meet(read)
    }

    /// A conflict settled: this side's text goes over the file's.
    func keepMine() async {
        guard case .conflict(let theirs) = standing else { return }
        base = theirs
        standing = .edited
        await save()
    }

    /// A conflict settled: the file's text replaces this side's.
    func takeTheirs() {
        guard case .conflict(let theirs) = standing else { return }
        base = theirs
        text = theirs.text
        standing = .saved
    }

    func retry() async {
        guard case .failed = standing else { return }
        if base == nil {
            standing = .reading
            await read()
        } else {
            standing = .edited
            await save()
        }
    }

    /// The agent told to read the shown document again.
    func tellAgent() async {
        guard let tell, let document, let list, !telling else { return }
        telling = true
        defer { telling = false }
        if standing == .edited { await save() }
        let name = Self.tilde(document.named ?? document.path, home: list.home)
        let now = text
        do {
            try await tell(Self.telling(name, from: heard[document.path], to: now))
            told[document.path] = self.document?.modified ?? document.modified ?? 0
            heard[document.path] = now
        } catch {
            standing = .failed("The agent was not told: \(error)")
        }
    }

    /// Each document's text as the agent is taken to have it: as it was
    /// when first read here, then as it was last told. What Tell sends is
    /// what changed since.
    private var heard: [String: String] = [:]

    /// What Tell types into the pane: the lines that changed, by the
    /// file's line numbers now, so the agent has the edit itself and reads
    /// nothing again. A long line is cut to where it changed (an
    /// instruction file's paragraphs are single lines of thousands of
    /// characters); past `tellLimit` the rest is left to the file.
    static func telling(_ name: String, from old: String?, to new: String) -> String {
        let reread = "I edited \(name). Read it again before you go on."
        guard let old, old != new else { return reread }
        let hunks = Git.FileDiff(old: old, new: new, path: name, context: 0).hunks
        guard !hunks.isEmpty else { return reread }
        var out = ["I edited \(name). What changed, by its line numbers now:"]
        var cut = false
        var shortened = false
        for hunk in hunks {
            // A long line with none it replaced is told by its beginning alone.
            shortened = shortened || hunk.lines.contains { $0.kind != .context && $0.text.utf16.count > lineLimit }
                && hunk.lines.filter { $0.kind == .removed }.count != hunk.lines.filter { $0.kind == .added }.count
            let removed = hunk.lines.filter { $0.kind == .removed }
            let added = hunk.lines.filter { $0.kind == .added }
            var lines = [hunk.newCount == 0 ? "@@ removed before line \(hunk.newStart + 1)" : "@@ line \(hunk.newStart)"]
            for (index, line) in removed.enumerated() {
                lines.append("-" + clip(line.text, against: index < added.count ? added[index].text : nil))
            }
            for (index, line) in added.enumerated() {
                lines.append("+" + clip(line.text, against: index < removed.count ? removed[index].text : nil))
            }
            guard (out + lines).joined(separator: "\n").utf8.count <= tellLimit else {
                cut = true
                break
            }
            out += lines
        }
        guard out.count > 1 else { return reread }
        out.append(
            cut ? "There is more than fits here: read the file again for the rest."
                : shortened ? "A line cut short here (…) is whole in the file; nothing else in it changed."
                : "That is the whole edit: nothing else in the file changed.")
        return out.joined(separator: "\n")
    }

    static let tellLimit = 6000
    private static let lineLimit = 400
    private static let around = 120

    /// A line as it is told: whole when short; else the stretch where it
    /// differs from the line it replaced (or replaces), with some of what
    /// stands around it, or its beginning when it stands alone.
    static func clip(_ line: String, against other: String?) -> String {
        let units = Array(line.utf16)
        guard units.count > lineLimit else { return line }
        func text(_ range: Range<Int>) -> String { String(utf16CodeUnits: Array(units[range]), count: range.count) }
        guard let other else { return text(0..<lineLimit) + "… (\(units.count) characters)" }
        let theirs = Array(other.utf16)
        var head = 0
        while head < units.count, head < theirs.count, units[head] == theirs[head] { head += 1 }
        var tail = 0
        while tail < units.count - head, tail < theirs.count - head, units[units.count - 1 - tail] == theirs[theirs.count - 1 - tail] { tail += 1 }
        let from = max(0, head - around)
        let to = min(units.count, max(from, units.count - tail) + around)
        guard to - from <= tellLimit / 2 else { return text(from..<from + lineLimit) + "… (\(units.count) characters)" }
        return (from > 0 ? "…" : "") + text(from..<to) + (to < units.count ? "…" : "")
    }

    /// The agent already heard of the file as it is now.
    var wasTold: Bool {
        guard let document, let modified = document.modified, let at = told[document.path] else { return false }
        return at >= modified
    }

    static func tilde(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// A pane's documents (harness/DOCUMENTS.md): the files its agent works
/// from, each read and edited as the page it reads as (swift-utils'
/// `MarkdownEditor`), written back to its Mac as typed and following the
/// file as it changes there. Drawn by the Mac's documents window and bar and
/// the phone's pane screen alike.
struct VigilDocuments: View {
    /// The pane's files are this Mac's: a page's images are read from the
    /// document's folder.
    let local: Bool
    @State private var model: PaneDocumentsModel
    @State private var page = MarkdownEditor.Page()
    @State private var contents = false
    @Environment(\.markdownEditorTypography) private var typography
    @Environment(\.colorScheme) private var scheme

    init(call: @escaping PaneDocumentCall, watch: @escaping PaneDocumentWatch, tell: PaneTell?, local: Bool) {
        self.local = local
        _model = State(initialValue: PaneDocumentsModel(call: call, watch: watch, tell: tell))
    }

    /// The width from which the documents and the page's contents stand
    /// beside the page; below it they are a menu and a sheet.
    private static let wide: CGFloat = 860

    var body: some View {
        GeometryReader { room in
            let wide = room.size.width >= Self.wide
            Group {
                if let failure = model.failure {
                    GitStateView(.failed(Unread(description: failure), retry: { Task { await model.start() } }))
                } else if let list = model.list {
                    if let unread = list.unread {
                        GitStateView(.empty(title: "No documents", message: unread, symbol: "doc.text"))
                    } else if list.documents.isEmpty {
                        GitStateView(.empty(title: "No documents", message: "Its agent's record names no file it works from yet.",
                                            symbol: "doc.text"))
                    } else {
                        HStack(spacing: 0) {
                            if wide {
                                side(list).frame(width: 248)
                                Rectangle().fill(colour(typography.palette.hairline)).frame(width: 1)
                            }
                            VStack(spacing: 0) {
                                bar(list, wide: wide)
                                Rectangle().fill(colour(typography.palette.hairline)).frame(height: 1)
                                sheet(list)
                            }
                        }
                    }
                } else {
                    GitStateView(.loading("Reading the documents"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colour(typography.palette.ground))
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    /// The page's contents where the view is too narrow to keep them beside
    /// it: a popover on the Mac, a sheet on the phone.
    private var contentsButton: some View {
        Button { contents = true } label: { Image(systemName: "list.bullet.indent") }
            .buttonStyle(.plain)
            .help("Contents")
            .disabled(page.outline.isEmpty)
            .popover(isPresented: $contents) {
                MarkdownEditor.Contents(page)
                    .presentationDetents([.medium, .large])
                    .frame(minWidth: 300, minHeight: 360)
                    // A heading pressed: it goes, the page is there.
                    .onChange(of: page.current) { contents = false }
            }
    }

    private struct Unread: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: The page

    @ViewBuilder private func sheet(_ list: DocumentList) -> some View {
        switch model.standing {
        case .conflict(let theirs):
            conflict(theirs, list)
        case .reading where model.base == nil:
            GitStateView(.loading("Reading"))
        case .failed(let why) where model.base == nil:
            GitStateView(.failed(Unread(description: why), retry: { Task { await model.retry() } }))
        default:
            if let path = model.shown {
                MarkdownEditor.View(
                    text: Binding(get: { model.text }, set: { model.typed($0) }),
                    folder: local ? URL(fileURLWithPath: path).deletingLastPathComponent() : nil, page: page)
                    // Another document is another text: its own undo, caret and scroll.
                    .id(path)
            }
        }
    }

    /// The file changed under an unsaved edit: the two texts as a diff, the
    /// file's against this side's, and which one stays.
    private func conflict(_ theirs: DocumentText, _ list: DocumentList) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("This file changed on the Mac while you were editing it.")
                    .font(.callout.weight(.semibold))
                Text("Below, the file as it is now against your text: red is only in the file, green only in yours. Nothing was written.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { Task { await model.keepMine() } } label: { Label("Write Mine Over It", systemImage: "square.and.arrow.down") }
                    Button { model.takeTheirs() } label: { Label("Take the File's", systemImage: "arrow.uturn.backward") }
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
            }
            .padding(16)
            DiffPage(old: theirs.text, new: model.text, path: PaneDocumentsModel.tilde(theirs.path, home: list.home))
        }
    }

    // MARK: The bar over the page

    private func bar(_ list: DocumentList, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if !wide { picker(list) }
                if wide, let document = model.document {
                    Text(Self.title(document)).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(Self.folder(document, home: list.home)).font(.caption).foregroundStyle(colour(typography.palette.quiet))
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
                standing
                if !wide { contentsButton }
                if model.tell != nil, let document = model.document, document.changedSinceLoaded || model.wasTold {
                    Button { Task { await model.tellAgent() } } label: {
                        // Narrow, the caption under the bar names who is told.
                        Label(model.wasTold ? "Told" : wide ? "Tell \(Self.agent(list))" : "Tell", systemImage: model.wasTold ? "checkmark" : "paperplane")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.wasTold || model.telling)
                    .help("Types one line into its pane: it edited nothing itself, so it is asked to read this file again")
                }
            }
            if let document = model.document {
                Text(Self.sees(document, list))
                    .font(.caption)
                    .foregroundStyle(colour(document.changedSinceLoaded || document.taken != nil ? typography.palette.accent : typography.palette.quiet))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(colour(typography.palette.words))
        // ⌘S writes now what a pause would write.
        .background {
            Button("") { Task { await model.save() } }.keyboardShortcut("s", modifiers: .command).opacity(0)
        }
    }

    @ViewBuilder private var standing: some View {
        let quiet = colour(typography.palette.quiet)
        switch model.standing {
        case .reading: ProgressView().controlSize(.small)
        case .saved: Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(quiet)
        case .edited: Label("Edited", systemImage: "pencil").font(.caption).foregroundStyle(quiet)
        case .saving: Label("Saving", systemImage: "arrow.up").font(.caption).foregroundStyle(quiet)
        case .conflict: Label("Changed on the Mac", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .failed(let why):
            Button { Task { await model.retry() } } label: {
                Label("Not saved: \(why)", systemImage: "exclamationmark.triangle").font(.caption).lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Press to try again")
        }
    }

    // MARK: Which document

    private static let kinds: [(PaneDocument.Kind, String)] = [
        (.instructions, "Instructions"), (.nested, "Read on the way"), (.plan, "Plan"), (.skill, "Skills"),
    ]

    private static func symbol(_ kind: PaneDocument.Kind) -> String {
        switch kind {
        case .instructions: "text.book.closed"
        case .nested: "arrow.turn.down.right"
        case .plan: "list.bullet.clipboard"
        case .skill: "wand.and.stars"
        }
    }

    /// The menu a narrow view picks its document from.
    private func picker(_ list: DocumentList) -> some View {
        Menu {
            ForEach(Self.kinds, id: \.0) { kind, title in
                let documents = list.documents.filter { $0.kind == kind }
                if !documents.isEmpty {
                    Section(title) {
                        ForEach(documents) { document in
                            Button { Task { await model.open(document.path) } } label: {
                                Label("\(Self.title(document)) · \(Self.folder(document, home: list.home))", systemImage: Self.symbol(kind))
                            }
                            .disabled(document.modified == nil)
                        }
                    }
                }
            }
            .labelStyle(.titleAndIcon)
        } label: {
            HStack(spacing: 5) {
                Text(model.document.map(Self.title) ?? "Documents").font(.callout.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(colour(typography.palette.titles))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// The column a wide view keeps beside the page: every document, then
    /// the shown one's contents.
    private func side(_ list: DocumentList) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.kinds, id: \.0) { kind, title in
                        let documents = list.documents.filter { $0.kind == kind }
                        if !documents.isEmpty {
                            Text(title.uppercased())
                                .font(.caption2.weight(.semibold)).kerning(0.6)
                                .foregroundStyle(colour(typography.palette.quiet))
                                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                            ForEach(documents) { document in row(document, list) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(colour(typography.palette.hairline)).frame(height: 1)
            MarkdownEditor.Contents(page)
        }
    }

    private func row(_ document: PaneDocument, _ list: DocumentList) -> some View {
        let current = document.path == model.shown
        let palette = typography.palette
        return Button { Task { await model.open(document.path) } } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1).fill(colour(palette.accent)).frame(width: 2).opacity(current ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(Self.title(document)).font(.callout).lineLimit(1)
                            .foregroundStyle(colour(current ? palette.titles : palette.words))
                        if document.changedSinceLoaded {
                            Circle().fill(colour(palette.accent)).frame(width: 5, height: 5)
                                .help("Changed since \(Self.agent(list)) read it")
                        }
                    }
                    Text(document.modified == nil ? "gone from the Mac" : Self.folder(document, home: list.home))
                        .font(.caption2).foregroundStyle(colour(palette.quiet)).lineLimit(1).truncationMode(.head)
                }
                .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 5)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(document.modified == nil)
        .opacity(document.modified == nil ? 0.5 : 1)
    }

    // MARK: Words

    private static func agent(_ list: DocumentList) -> String {
        switch list.agent {
        case "claude": "Claude"
        case "codex": "Codex"
        default: "the agent"
        }
    }

    /// A skill by its name, any other by its file's.
    private static func title(_ document: PaneDocument) -> String {
        document.kind == .skill ? document.name ?? "skill" : ((document.named ?? document.path) as NSString).lastPathComponent
    }

    private static func folder(_ document: PaneDocument, home: String) -> String {
        PaneDocumentsModel.tilde(((document.named ?? document.path) as NSString).deletingLastPathComponent, home: home)
    }

    private static func clock(_ at: Double) -> String {
        let date = Date(timeIntervalSince1970: at)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) }

    /// When the agent sees an edit of this document, and whether it works
    /// from an older text of it now.
    static func sees(_ document: PaneDocument, _ list: DocumentList) -> String {
        let agent = agent(list)
        if let taken = document.taken {
            let limit = list.limit.map { " (its instruction files stop at \(size($0)) in all)" } ?? ""
            return taken == 0
                ? "\(agent) does not reach this file\(limit)."
                : "\(agent) takes the first \(size(taken)) of this file's \(size(document.bytes ?? taken))\(limit)."
        }
        let read = document.loaded.map { " at \(clock($0))" } ?? ""
        switch document.kind {
        case .instructions, .nested:
            guard document.loaded != nil else { return "\(agent) reads this when a conversation starts." }
            return document.changedSinceLoaded
                ? "Changed since \(agent) read it\(read). It reads it again when the conversation is resumed or compacted."
                : "\(agent) works from this text, read\(read). It reads it again when the conversation is resumed or compacted."
        case .plan:
            return document.changedSinceLoaded
                ? "Changed since \(agent) last had it\(read). It sees an edit when it next opens the plan."
                : "\(agent) sees an edit when it next opens the plan."
        case .skill:
            return document.changedSinceLoaded
                ? "Changed since \(agent) read it\(read). It reads a skill again each time the skill is invoked."
                : "\(agent) reads a skill again each time the skill is invoked."
        }
    }

    private func colour(_ pair: MarkdownEditor.Palette.Pair) -> Color {
        let hex = scheme == .dark ? pair.night : pair.day
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
