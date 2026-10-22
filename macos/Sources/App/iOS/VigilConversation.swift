import AuthzUI
import SwiftUI
import VigilActivity
import VigilLink
import VigilWire

/// An agent pane drawn as its conversation (harness/CLAUDE-FEED.md): what
/// was asked, what the agent said, every tool call with its command, diff
/// or output, and what it does now. The Mac reads the agent's files and
/// sends vigil's own rows (`FeedEntry`); this screen only draws them. The
/// terminal is one toggle away and stays the truth of last resort.
///
/// Who owns which fact: the rows are the transcript's (what happened); what
/// happens now is the broker's (`FeedLive`), joined to a tool call by its
/// id. A call with no result is "running" only while the broker says the
/// turn works, "waiting for you" only while a request names it, otherwise
/// "unfinished": the rows never stand in for state.
@MainActor
final class Conversation: ObservableObject {
    let ref: PaneRef
    /// The rows, oldest first; an id already held replaces its row.
    @Published private(set) var entries: [FeedEntry] = []
    /// What the pane does now, from the broker.
    @Published private(set) var live: FeedLive?
    /// Older rows exist on the Mac (paged when the top is reached).
    @Published private(set) var earlier = false
    /// Why nothing arrives now (out of reach, refused, no conversation);
    /// nil while the feed is followed.
    @Published private(set) var waiting: String?
    /// A first snapshot arrived: there is a conversation to draw.
    @Published private(set) var opened = false
    /// An older page is being read.
    @Published private(set) var paging = false
    /// Why the last older page could not be read (a tap tries again).
    @Published private(set) var pageError: String?
    /// Moves with every change at the bottom (a row added or replaced, the
    /// live state), never with a page prepended: what keeps a reader at
    /// the newest row there.
    @Published private(set) var revision = 0
    private var conversation: String?
    private var index: [String: Int] = [:]
    private var task: Task<Void, Never>?

    init(ref: PaneRef) { self.ref = ref }

    /// Drawn from made-up rows (`VigilFixture`): nothing followed.
    init(ref: PaneRef, entries: [FeedEntry], live: FeedLive?, earlier: Bool = false, waiting: String? = nil) {
        self.ref = ref
        self.live = live
        self.earlier = earlier
        self.waiting = waiting
        opened = !entries.isEmpty
        replace(entries)
    }

    /// Follows the pane's feed until `stop`.
    func start() {
        guard task == nil else { return }
        let steps = VigilPhone.shared.feed(ref)
        task = Task { [weak self] in
            for await step in steps {
                guard let self else { return }
                switch step {
                case .message(let message):
                    waiting = nil
                    apply(message)
                case .waiting(let why):
                    waiting = why
                    VigilPhone.shared.receipts.warn("feed", "waiting", ["pane": ref.pane, "why": why])
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ message: FeedMessage) {
        switch message {
        case .snapshot(let snapshot):
            guard snapshot.schema == Feed.schema else {
                waiting = "This conversation is in a newer form than vigil on this iPhone reads. Update vigil here."
                VigilPhone.shared.receipts.warn("feed", "unknown schema", ["pane": ref.pane, "schema": snapshot.schema])
                return
            }
            conversation = snapshot.conversation
            earlier = snapshot.earlier
            live = snapshot.live
            pageError = nil
            replace(snapshot.entries)
            opened = true
            VigilPhone.shared.receipts.info("feed", "snapshot", [
                "pane": ref.pane, "agent": snapshot.agent, "entries": snapshot.entries.count, "earlier": snapshot.earlier,
            ])
        case .entries(let changed, _):
            for entry in changed {
                if let at = index[entry.id] {
                    entries[at] = entry
                } else {
                    index[entry.id] = entries.count
                    entries.append(entry)
                }
            }
            revision += 1
        case .live(let now):
            live = now
            revision += 1
        }
    }

    private func replace(_ rows: [FeedEntry]) {
        entries = rows
        index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        revision += 1
    }

    /// The page before the oldest row held, put above it.
    func loadEarlier() {
        guard earlier, !paging, let first = entries.first, let conversation else { return }
        paging = true
        pageError = nil
        Task {
            defer { paging = false }
            do {
                let page = try await VigilPhone.shared.feedEarlier(ref, FeedEarlier(conversation: conversation, before: first.id))
                // Another conversation arrived meanwhile: this page is not its.
                guard self.conversation == conversation else { return }
                let fresh = page.entries.filter { index[$0.id] == nil }
                entries = fresh + entries
                index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
                earlier = page.earlier
                VigilPhone.shared.receipts.info("feed", "earlier page", ["pane": ref.pane, "entries": fresh.count, "more": page.earlier])
            } catch {
                pageError = VigilLink.reason(error)
                VigilPhone.shared.receipts.warn("feed", "earlier page not read", ["pane": ref.pane, "err": error])
            }
        }
    }

    /// Where a tool call with no result stands, by the broker's word.
    enum Pending { case waiting, running, unfinished }

    func pending(_ call: ToolCall, turn: String?) -> Pending? {
        guard call.result == nil else { return nil }
        if live?.request?.toolUse == call.id { return .waiting }
        if let state = live?.state, state == .working || state == .interrupting, turn == entries.last?.turn { return .running }
        return .unfinished
    }
}

// MARK: - The screen

struct ConversationView: View {
    @ObservedObject var conversation: Conversation
    /// Shows the pane's terminal instead (the toggle's other side).
    let showTerminal: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var position = ScrollPosition(idType: String.self)
    @State private var atBottom = true

    /// The bottom row's id: the live state, always last.
    private static let bottom = "live"

    var body: some View {
        Group {
            if conversation.opened {
                rows
            } else if let why = conversation.waiting {
                ContentUnavailableView {
                    Label("No conversation", systemImage: "text.bubble")
                } description: {
                    Text(why)
                } actions: {
                    Button("Show the terminal", action: showTerminal).buttonStyle(.ink)
                }
            } else {
                ProgressView("Reading the conversation…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ground.ignoresSafeArea())
    }

    /// The terminal's own ground in dark (the app's appearance), the
    /// system's in light: switching to the terminal never changes it.
    private var ground: Color { scheme == .dark ? Color(VigilTheme.background) : Color(.systemBackground) }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if conversation.earlier { EarlierRow(conversation: conversation) }
                ForEach(conversation.entries) { entry in
                    EntryRow(entry: entry, conversation: conversation)
                }
                LiveRow(live: conversation.live).id(Self.bottom)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 48
        } action: { _, now in
            atBottom = now
        }
        // A reader at the newest row stays there as rows arrive; one who
        // scrolled up keeps their place.
        .onChange(of: conversation.revision) { _, _ in
            guard atBottom else { return }
            withAnimation(.snappy) { position.scrollTo(id: Self.bottom, anchor: .bottom) }
        }
        .overlay(alignment: .top) {
            if let why = conversation.waiting {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(Hue.care)
                    Text("Not updating: \(why)").font(.footnote).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Terminal", action: showTerminal).buttonStyle(.ink)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }
        }
    }
}

/// The top of what is held: older rows load as it comes into view.
private struct EarlierRow: View {
    @ObservedObject var conversation: Conversation
    var body: some View {
        HStack {
            Spacer()
            if let error = conversation.pageError {
                Button { conversation.loadEarlier() } label: {
                    Label("Earlier messages not read: \(error). Try again", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                ProgressView().onAppear { conversation.loadEarlier() }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Rows

private struct EntryRow: View {
    let entry: FeedEntry
    @ObservedObject var conversation: Conversation

    var body: some View {
        switch entry.body {
        case .prompt(let prompt):
            PromptRow(prompt: prompt)
        case .reply(let clip):
            Markdown(text: clip.text).font(.callout)
        case .thinking(let clip):
            if !clip.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Folded(title: "Thinking", systemImage: "ellipsis.bubble") {
                    Text(clip.text).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .tool(let call):
            ToolRow(call: call, pending: conversation.pending(call, turn: entry.turn))
        case .event(let event):
            EventRow(event: event)
        case .opaque:
            Label("Not shown here: \(entry.native)", systemImage: "questionmark.square.dashed")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// What you (or something on your behalf) said: on the right, a shade off
/// the ground, as a message app draws your side.
private struct PromptRow: View {
    let prompt: FeedEntry.Prompt
    @State private var whole = false

    private var origin: String? {
        switch prompt.origin {
        case .typed, .other: nil
        case .queued: "Queued"
        case .task: "From a task"
        case .system: "From the system"
        }
    }

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 4) {
                if let origin {
                    Text(origin).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(prompt.text.text)
                    .font(.callout)
                    .lineLimit(whole ? nil : 12)
                    .textSelection(.enabled)
                    .onTapGesture { whole.toggle() }
                if prompt.images > 0 || prompt.text.dropped > 0 {
                    Text([prompt.images > 0 ? "\(prompt.images) image\(prompt.images == 1 ? "" : "s") not shown" : nil,
                          prompt.text.dropped > 0 ? "\(prompt.text.dropped) characters more" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// A row with a header and a body that opens on a tap, closed by default.
private struct Folded<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Label(title, systemImage: systemImage)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content() }
        }
    }
}

// MARK: Tool calls

private struct ToolRow: View {
    let call: ToolCall
    let pending: Conversation.Pending?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: glyph).font(.footnote).foregroundStyle(.secondary).frame(width: 18, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                StatusMark(result: call.result, pending: pending).frame(minHeight: 20)
            }
            ToolBody(call: call)
            if let output = call.result?.output, !output.text.isEmpty, !call.isRead {
                Folded(title: "Output · \(output.text.lineCount) line\(output.text.lineCount == 1 ? "" : "s")", systemImage: "text.alignleft") {
                    Well {
                        VStack(alignment: .leading, spacing: 4) {
                            if output.dropped > 0 {
                                Text("\(output.dropped) characters before").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(output.text).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var glyph: String {
        switch call.call {
        case .shell: "terminal"
        case .patch(_, _, _, let created): created ? "doc.badge.plus" : "pencil"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .fetch: "globe"
        case .webSearch: "magnifyingglass.circle"
        case .question: "questionmark.bubble"
        case .plan: "list.bullet.clipboard"
        case .todos: "checklist"
        case .agent: "person.2"
        case .generic: "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch call.call {
        case .shell(_, let description, _): description ?? call.name
        case .patch(let path, _, _, _): Paths.name(path)
        case .read(let path, _, _): Paths.name(path)
        case .search(let pattern, _): pattern
        case .fetch(let url): url
        case .webSearch(let query): query
        case .question(let questions): questions.count == 1 ? "A question" : "\(questions.count) questions"
        case .plan: "Plan"
        case .todos: "To do"
        case .agent(let description, _, _): description
        case .generic: call.name
        }
    }

    private var subtitle: String? {
        switch call.call {
        case .shell(_, let description, let background):
            [description == nil ? nil : call.name, background ? "in the background" : nil].compactMap { $0 }.joined(separator: " · ").nonEmpty
        case .patch(let path, let hunks, _, let created):
            [created ? "New file" : nil, Paths.folder(path), hunks.counts].compactMap { $0 }.joined(separator: " · ").nonEmpty
        case .read(let path, let offset, let limit):
            [Paths.folder(path), Paths.range(offset, limit)].compactMap { $0 }.joined(separator: " · ").nonEmpty
        case .search(_, let path): ["Search", path.map(Paths.short)].compactMap { $0 }.joined(separator: " in ")
        case .fetch: "Fetch"
        case .webSearch: "Web search"
        case .agent(_, let type, let background):
            [type ?? call.name, background ? "in the background" : nil].compactMap { $0 }.joined(separator: " · ")
        case .question, .plan, .todos, .generic: nil
        }
    }
}

extension ToolCall {
    /// A read: its contents never travel, so no output is drawn.
    fileprivate var isRead: Bool { if case .read = call { true } else { false } }
}

extension String {
    fileprivate var lineCount: Int { split(separator: "\n", omittingEmptySubsequences: false).count }
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

extension [ToolCall.Hunk] {
    /// "+12 −3": lines added and removed, over every hunk.
    fileprivate var counts: String? {
        let lines = flatMap(\.lines)
        let added = lines.filter { $0.hasPrefix("+") }.count, removed = lines.filter { $0.hasPrefix("-") }.count
        return added + removed == 0 ? nil : "+\(added) −\(removed)"
    }
}

/// A path as a row names it: its file, its folder from home.
enum Paths {
    static func short(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.hasPrefix("/Users/"), parts.count > 3 { return "~/" + parts.dropFirst(3).joined(separator: "/") }
        return path
    }
    static func name(_ path: String) -> String { String(path.split(separator: "/").last ?? Substring(path)) }
    static func folder(_ path: String) -> String? {
        let short = short(path)
        guard let slash = short.lastIndex(of: "/") else { return nil }
        return String(short[..<slash])
    }
    static func range(_ offset: Int?, _ limit: Int?) -> String? {
        switch (offset, limit) {
        case (let start?, let count?): "lines \(start)–\(start + count - 1)"
        case (let start?, nil): "from line \(start)"
        case (nil, let count?): "first \(count) lines"
        case (nil, nil): nil
        }
    }
}

/// How a call ended, or where it stands without an end: plain words, a
/// state's color only where it marks one.
private struct StatusMark: View {
    let result: ToolCall.Result?
    let pending: Conversation.Pending?

    var body: some View {
        Group {
            switch (result?.status, pending) {
            case (.ok?, _): Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Done")
            case (.failed?, _): Label("Failed", systemImage: "xmark").foregroundStyle(Hue.care)
            case (.rejected?, _): Label("Refused", systemImage: "hand.raised").foregroundStyle(.secondary)
            case (.interrupted?, _): Label("Interrupted", systemImage: "stop").foregroundStyle(.secondary)
            case (nil, .waiting?): Label("Waiting for you", systemImage: AgentState.blocked.symbol).foregroundStyle(AgentState.blocked.tint)
            case (nil, .running?):
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Running")
                }
                .foregroundStyle(.secondary)
            case (nil, .unfinished?), (nil, nil): Text("Unfinished").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.weight(.medium))
        .labelStyle(.titleAndIcon)
    }
}

/// What a call does, drawn for its kind.
private struct ToolBody: View {
    let call: ToolCall

    var body: some View {
        switch call.call {
        case .shell(let command, _, _):
            Expandable(lines: 6) { lines in
                Well {
                    SyntaxText(command, format: .shell, font: .system(.footnote, design: .monospaced))
                        .lineLimit(lines)
                }
            }
        case .patch(_, let hunks, let exact, _):
            DiffView(hunks: hunks, exact: exact)
        case .read, .search, .fetch, .webSearch:
            EmptyView()
        case .question(let questions):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    QuestionView(question: question, answer: call.result?.answers?[question.question])
                }
            }
        case .plan(let plan):
            Expandable(lines: 10) { lines in
                Markdown(text: plan.text).font(.footnote).lineLimit(lines)
            }
        case .todos(let todos):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                    TodoLine(todo: todo)
                }
            }
        case .agent:
            EmptyView()
        case .generic(let fields):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    Text("\(Text(field.name).foregroundStyle(.secondary))  \(field.value)")
                        .font(.caption.monospaced())
                        .lineLimit(3)
                }
            }
        }
    }
}

/// Text cut at `lines` until tapped open (a long command, a plan).
private struct Expandable<Content: View>: View {
    let lines: Int
    @ViewBuilder let content: (Int?) -> Content
    @State private var whole = false
    var body: some View {
        content(whole ? nil : lines)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { whole.toggle() } }
    }
}

/// Terminal text as the pane shows it: in a well a shade off the row.
private struct Well<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A change as its lines: added green, removed red, context quiet; the
/// first lines, the rest a tap away.
private struct DiffView: View {
    let hunks: [ToolCall.Hunk]
    let exact: Bool
    @State private var whole = false
    private static let shown = 14

    private var lines: [String] {
        hunks.flatMap { hunk in
            (exact ? ["@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"] : []) + hunk.lines
        }
    }

    var body: some View {
        let all = lines
        let cut = whole ? all : Array(all.prefix(Self.shown))
        Well {
            VStack(alignment: .leading, spacing: 4) {
                // Lines as written, never wrapped: a wrapped line reads as two.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(SyntaxLines.diff(cut.joined(separator: "\n")))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize()
                }
                if all.count > Self.shown {
                    Button(whole ? "Show less" : "Show \(all.count - Self.shown) more lines") {
                        withAnimation(.snappy(duration: 0.2)) { whole.toggle() }
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A question as it was asked: its options, the one answered marked.
private struct QuestionView: View {
    let question: ToolCall.Question
    let answer: String?

    /// The answer as the agent recorded it: an option's words, several
    /// joined by commas, or words of the person's own.
    private var picked: [String] {
        guard let answer else { return [] }
        if question.options.contains(answer) { return [answer] }
        return answer.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
                Text(header.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(question.question).font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options, id: \.self) { option in
                    let chosen = picked.contains(option)
                    Label(option, systemImage: chosen ? "checkmark.circle.fill" : (question.multiple ? "square" : "circle"))
                        .font(.footnote)
                        .foregroundStyle(chosen ? .primary : .secondary)
                }
            }
            if let answer, !picked.allSatisfy(question.options.contains) {
                Label(answer, systemImage: "text.bubble").font(.footnote)
            }
        }
    }
}

private struct TodoLine: View {
    let todo: ToolCall.Todo
    var body: some View {
        let done = todo.status == "completed"
        let doing = todo.status == "in_progress"
        Label {
            Text(todo.text).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : doing ? "circle.lefthalf.filled" : "circle")
                .foregroundStyle(doing ? AgentState.working.tint : .secondary)
        }
        .font(.footnote)
    }
}

// MARK: Events

private struct EventRow: View {
    let event: FeedEntry.Event

    var body: some View {
        switch event {
        case .compacted(let trigger, let before, let after):
            Divided(text: ["Context compacted", trigger, Self.tokens(before, after)].compactMap { $0 }.joined(separator: " · "))
        case .summary(let clip):
            Folded(title: "What it kept after compacting", systemImage: "archivebox") {
                Markdown(text: clip.text).font(.footnote).foregroundStyle(.secondary)
            }
        case .interrupted:
            Label("Interrupted", systemImage: "stop.circle").font(.footnote).foregroundStyle(.secondary)
        case .command(let name, let arguments):
            HStack {
                Spacer(minLength: 44)
                Text([name.hasPrefix("/") ? name : "/" + name, arguments].compactMap { $0 }.joined(separator: " "))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
        case .notice(let clip):
            Text(clip.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
        case .failure(let clip):
            Label { Text(clip.text) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.footnote)
                .foregroundStyle(Hue.care)
        case .turnEnded(let milliseconds):
            Divided(text: "Turn took \(Duration.milliseconds(milliseconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))")
        }
    }

    private static func tokens(_ before: Int?, _ after: Int?) -> String? {
        guard let before, let after else { return nil }
        func k(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
        return "\(k(before)) → \(k(after)) tokens"
    }
}

/// A quiet line across the conversation: something that happened between
/// its messages.
private struct Divided: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
            Text(text).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
        }
    }
}

// MARK: The live state

/// What the pane does now, last: its state in its color and words, how
/// full its context is.
private struct LiveRow: View {
    let live: FeedLive?

    var body: some View {
        if let live {
            HStack(spacing: 8) {
                Image(systemName: live.state.symbol)
                    .foregroundStyle(live.state.tint)
                    .symbolEffect(.pulse, isActive: live.state == .working)
                Text(live.state.words(live.flavor)).font(.footnote.weight(.medium))
                Spacer(minLength: 6)
                if let context = live.context { ContextMeter(percent: context) }
            }
            .padding(.top, 4)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

/// How full the agent's context window is: a bar and its percent, care
/// from 70 (where it compacts or stops soon), as the activity draws it.
private struct ContextMeter: View {
    let percent: Int
    var body: some View {
        let fill = Double(min(max(percent, 0), 100)) / 100
        HStack(spacing: 6) {
            Capsule().fill(.primary.opacity(0.12))
                .frame(width: 56, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(percent >= 70 ? AnyShapeStyle(Hue.care) : AnyShapeStyle(.secondary)).frame(width: 56 * fill, height: 4)
                }
            Text("\(percent)%").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent)% full")
    }
}

// MARK: - Markdown

/// An agent's markdown, drawn by blocks: paragraphs with their inline
/// marks (bold, code, links), headings, fenced code in a well, tables as
/// written in a monospaced well, list items with their bullet.
struct Markdown: View {
    let text: String

    enum Block {
        case paragraph(String)
        case heading(String)
        case code(String)
        case table(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let words):
                    Text(Self.inline(words)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .heading(let words):
                    Text(Self.inline(words)).fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code), .table(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code).font(.caption.monospaced()).textSelection(.enabled).fixedSize()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var table: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))) }
            paragraph = []
            table = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                table.append(trimmed)
            } else if let heading = Self.heading(trimmed) {
                flush()
                blocks.append(.heading(heading))
            } else {
                if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))); table = [] }
                paragraph.append(Self.bullet(line))
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return String(line.dropFirst(hashes + 1))
    }

    /// "- item" and "* item" as "• item", their indent kept.
    private static func bullet(_ line: String) -> String {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") else { return line }
        return indent + "• " + rest.dropFirst(2)
    }
}
