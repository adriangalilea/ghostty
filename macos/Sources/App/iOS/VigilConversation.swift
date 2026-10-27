import AuthzUI
import GitViews
import Log
import MarkdownText
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
    /// How many of the newest rows are drawn: a page (`Feed.page`, the
    /// Mac's own: a snapshot is its first page, an earlier page the next),
    /// every row laid out to anchor the view at its bottom. Rows held beyond
    /// those drawn (a Mac older than the paged snapshot sends 200) are
    /// revealed as the top comes into view, before asking the Mac.
    @Published private(set) var drawn = Feed.page
    static let page = Feed.page
    /// The rows drawn, oldest first.
    var visible: ArraySlice<FeedEntry> { entries.suffix(drawn) }
    /// Rows older than those drawn exist, here or on the Mac.
    var more: Bool { entries.count > drawn || earlier }
    private var conversation: String?
    private var index: [String: Int] = [:]
    private var task: Task<Void, Never>?

    init(ref: PaneRef) { self.ref = ref }

    /// Drawn from made-up rows (`VigilFixture`): nothing followed.
    init(ref: PaneRef, entries: [FeedEntry], live: FeedLive?, earlier: Bool = false, waiting: String? = nil, offer: Offer? = nil,
         reply: Reply? = nil, queued: [FeedQueued] = []) {
        self.ref = ref
        self.reply = reply
        self.queued = queued
        self.live = live
        self.earlier = earlier
        self.waiting = waiting
        self.offer = live?.request.flatMap { request in offer.map { (request.id, $0) } }
        opened = !entries.isEmpty
        replace(entries)
    }

    // MARK: The request standing

    /// How the standing request is answered from here, read from its authz
    /// home (the feed names it by id only): its yes and no, its questions'
    /// options, or the terminal.
    enum Offer: Equatable {
        /// Still being read from its home.
        case reading
        case consent(allow: String, allowLabel: String, deny: String, denyLabel: String)
        /// Questions whose every answer is one of their options.
        case choices([Ask])
        /// Nothing this screen can answer: the terminal can.
        case terminal
    }

    /// One question of a questionnaire, as its options answer it.
    struct Ask: Equatable {
        let id: String
        let title: String
        let multiple: Bool
        let choices: [Choice]
    }

    /// The standing request's id and how it is answered here.
    @Published private(set) var offer: (request: String, offer: Offer)?
    /// An answer on its way to the request's home.
    @Published private(set) var answering = false
    /// Why the last answer was not taken.
    @Published private(set) var answerError: String?

    /// The live state named a request (or none): read it from its home.
    private func readOffer() {
        guard let id = live?.request?.id else {
            offer = nil
            answerError = nil
            return
        }
        guard offer?.request != id else { return }
        offer = (id, .reading)
        answerError = nil
        Task {
            let request = await VigilAuthz.shared.request(device: ref.host.id, id: id)
            guard live?.request?.id == id else { return }
            let next = request.map(Self.offer) ?? .terminal
            offer = (id, next)
            VigilPhone.shared.receipts.info("feed", "request read", ["pane": ref.pane, "request": String(id.prefix(8)), "offer": "\(next)"])
        }
    }

    private static func offer(_ request: AskRequest) -> Offer {
        if case .buttons(let quick) = Answering(request) {
            return .consent(allow: quick.allow, allowLabel: quick.allowLabel, deny: quick.deny, denyLabel: quick.denyLabel)
        }
        let asks = request.questions.map { Ask(id: $0.id, title: $0.title, multiple: $0.kind == .multipleChoice, choices: $0.choices) }
        if request.kind == .question, !asks.isEmpty,
           request.questions.allSatisfy({ ($0.kind == .singleChoice || $0.kind == .multipleChoice) && !$0.choices.isEmpty }) {
            return .choices(asks)
        }
        return .terminal
    }

    /// Answers the standing request through authz, as its card would.
    func answer(_ decision: Decision) {
        guard let request = offer?.request, !answering else { return }
        answering = true
        answerError = nil
        Task {
            let why = await VigilAuthz.shared.answer(device: ref.host.id, request: request, decision)
            answering = false
            answerError = why
        }
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
                    receive(message)
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

    /// One message of the pane's feed, as the Mac sent it: the feed's
    /// follow calls it, and so does a fixture replaying a feed's timing.
    func receive(_ message: FeedMessage) {
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
            queued = snapshot.queued ?? []
            readOffer()
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
            if let reply, reply.failed == nil, changed.contains(where: { Self.carries($0, reply.text) }) { self.reply = nil }
            revision += 1
        case .live(let now):
            live = now
            readOffer()
            revision += 1
        case .queued(let now):
            queued = now
            if let reply, reply.failed == nil, now.contains(where: { Self.same($0.text, reply.text) }) { self.reply = nil }
            revision += 1
        }
    }

    private func replace(_ rows: [FeedEntry]) {
        entries = rows
        index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        drawn = Self.page
        revision += 1
    }

    /// The page above the rows drawn: from those held, else from the Mac.
    func loadEarlier() {
        if entries.count > drawn {
            drawn = min(entries.count, drawn + Self.page)
            return
        }
        Task { _ = await pageEarlier() }
    }

    /// One page from the Mac before the oldest row held; false when none came.
    private func pageEarlier() async -> Bool {
        guard earlier, !paging, let first = entries.first, let conversation else { return false }
        paging = true
        pageError = nil
        defer { paging = false }
        do {
            let page = try await VigilPhone.shared.feedEarlier(ref, FeedEarlier(conversation: conversation, before: first.id))
            // Another conversation arrived meanwhile: this page is not its.
            guard self.conversation == conversation else { return false }
            let fresh = page.entries.filter { index[$0.id] == nil }
            entries = fresh + entries
            index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
            drawn += fresh.count
            earlier = page.earlier
            VigilPhone.shared.receipts.info("feed", "earlier page", ["pane": ref.pane, "entries": fresh.count, "more": page.earlier])
            return !fresh.isEmpty
        } catch {
            pageError = VigilLink.reason(error)
            VigilPhone.shared.receipts.warn("feed", "earlier page not read", ["pane": ref.pane, "err": error])
            return false
        }
    }

    /// A row to bring on screen (an edit opened from the changes), once drawn.
    @Published private(set) var focus: String?
    /// Why the last row asked for could not be shown.
    @Published private(set) var focusMissing: String?

    /// Draws everything from `id`'s row down, paging back to it if it is
    /// older than what is held, then names it in `focus`.
    func show(_ id: String) {
        focusMissing = nil
        Task {
            var pages = 0
            while index[id] == nil, earlier, pages < Self.focusPages {
                guard await pageEarlier() else { break }
                pages += 1
            }
            guard let at = index[id] else {
                focusMissing = "That edit is not in what the Mac reads of this conversation."
                return
            }
            drawn = max(drawn, entries.count - at)
            focus = id
        }
    }

    /// Pages a jump reads back at most (30 rows each).
    static let focusPages = 100

    func focused() { focus = nil }
    func missingSeen() { focusMissing = nil }

    /// Where a tool call with no result stands, by the broker's word.
    enum Pending { case waiting, running, unfinished }

    // MARK: A reply

    /// A reply on its way: typed into the pane, not yet a prompt in the
    /// feed (it is sent once the feed shows it), or why it was not sent.
    struct Reply: Equatable {
        let text: String
        var failed: String?
    }
    @Published private(set) var reply: Reply?

    /// What was sent while it worked and it has not taken yet: its own
    /// queue, as its transcript says (`FeedMessage.queued`).
    @Published private(set) var queued: [FeedQueued] = []

    /// Why a reply cannot be typed now (nil: it can, any time the prompt is
    /// its input box: while it works, the agent queues it itself). A dialog
    /// standing in the terminal would take the words as its answer.
    var replyRefusal: String? {
        // The placeholder of the reply box: one short line.
        guard let live else { return nil }
        switch live.state {
        case .blocked where live.flavor == .ask: return nil
        case .blocked: return "Answer its request first"
        case .done, .idle, .working, .interrupting, .unknown: return nil
        }
    }

    /// The placeholder: what a reply does now.
    var replyHint: String {
        if let replyRefusal { return replyRefusal }
        switch live?.state {
        case .working?, .interrupting?: return "Queue a message"
        default: return "Reply"
        }
    }

    /// Words handed to the reply box from elsewhere (a quote from the
    /// changes view): the box appends them to what is typed, then clears this.
    @Published var quote: String?

    /// Where pressing a key stands: its answer from the Mac, or why not.
    @Published private(set) var keyNote: String?
    @Published private(set) var pressing: PaneKey?

    /// Presses one of the agent's keys in its pane (`PaneKey`): the Mac
    /// checks each step against the transcript and says what happened.
    func press(_ key: PaneKey) {
        guard pressing == nil else { return }
        pressing = key
        keyNote = nil
        Task {
            defer { pressing = nil }
            do {
                keyNote = try await VigilPhone.shared.press(key, in: ref)
            } catch {
                keyNote = VigilLink.reason(error)
                VigilPhone.shared.receipts.warn("feed", "key not pressed", ["pane": ref.pane, "key": key.rawValue, "err": error])
            }
        }
    }

    /// Types `text` into the pane; a refusal or failure is said in `reply`.
    func send(_ text: String) {
        guard replyRefusal == nil, reply == nil || reply?.failed != nil else { return }
        guard Open.validText(text) else {
            reply = Reply(text: text, failed: "Too long or not text: 4000 bytes of printable text at most.")
            return
        }
        reply = Reply(text: text)
        Task {
            do {
                // Shown as sent when the feed carries it as a prompt
                // (`apply`), which may be before this returns.
                try await VigilPhone.shared.send(text, to: ref)
            } catch {
                guard reply?.text == text else { return }
                reply?.failed = VigilLink.reason(error)
                VigilPhone.shared.receipts.warn("feed", "reply not sent", ["pane": ref.pane, "err": error])
            }
        }
    }

    /// What the person sent in the conversation as far as the feed reads it,
    /// the newest first, each once: the reply box's history.
    var sent: [String] {
        var seen: Set<String> = []
        let typed = entries.reversed().compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry.body, prompt.origin == .typed || prompt.origin == .queued else { return nil }
            return prompt.text.text
        }
        return (queued.reversed().map(\.text) + typed)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
    }

    private static func carries(_ entry: FeedEntry, _ text: String) -> Bool {
        guard case .prompt(let prompt) = entry.body else { return false }
        return same(prompt.text.text, text) || prompt.text.text.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The standing request names no row held here (a dialog with no
    /// tool, or its call not read yet): it is answered under the rows.
    var requestUnplaced: Bool {
        guard let request = live?.request else { return false }
        return request.toolUse.map { index[$0] == nil } ?? true
    }

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
    /// Its Mac's directory: the state the header shows (the seen rule).
    @ObservedObject private var phone = VigilPhone.shared
    /// Shows the pane's terminal instead (the toggle's other side).
    let showTerminal: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var position = ScrollPosition(idType: String.self)
    @State private var atBottom = true
    /// Where each row is and what the list shows, checked after every
    /// layout: rows held and none on screen is a blank list, said in the log.
    @State private var witness = ListWitness()

    /// The bottom row's id: the live state, always last.
    private static let bottom = "live"

    @ObservedObject private var keyboard = KeyboardState.shared

    var body: some View {
        Group {
            if conversation.opened {
                screen
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
        .environment(\.showTerminal, showTerminal)
    }

    /// The terminal's own ground in dark (the app's appearance), the
    /// system's in light: switching to the terminal never changes it.
    private var ground: Color { scheme == .dark ? Color(VigilTheme.background) : Color(.systemBackground) }

    /// A row's frame moved: kept, and the list checked.
    private func framed(_ id: String, _ frame: CGRect) {
        witness.rows[id] = frame
        witness.check(pane: conversation.ref.pane, ids: conversation.visible.map(\.id) + [Self.bottom])
    }

    /// The rows over the reply box, one column moved up by the keyboard as a
    /// fact (`KeyboardState`, the terminal's own pattern): no SwiftUI
    /// keyboard avoidance and nothing floating over the box (an iOS keyboard
    /// toolbar is a glass layer of its own that covered the box and took the
    /// send button's taps). The column keeps its own size.
    private var screen: some View {
        VStack(spacing: 0) {
            rows
            Composer(conversation: conversation, keyboardUp: keyboard.inset > 0)
        }
        // Down: the box ends above the home indicator, its ground reaching
        // under it. Up: it ends where the keyboard begins.
        .padding(.bottom, keyboard.aboveSafeArea)
        .ignoresSafeArea(.keyboard)
    }

    private var rows: some View {
        ScrollView {
            // Not lazy: the feed comes a page at a time (`Feed.page`, older
            // pages asked as the top comes into view), so every row is built
            // with its real height. A LazyVStack's estimates disagreed with
            // the scroll offset on a first open and drew a stretch of
            // nothing, blank until reopened (2026-10-27: scrolled to 4980 of
            // a 5763 pt list, no row there).
            VStack(alignment: .leading, spacing: 12) {
                if conversation.more { EarlierRow(conversation: conversation) }
                ForEach(conversation.visible) { entry in
                    EntryRow(entry: entry, conversation: conversation)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { framed(entry.id, $0) }
                }
                if conversation.requestUnplaced {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("It asks you something", systemImage: AgentState.blocked.symbol)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(AgentState.blocked.tint)
                        AnswerBar(conversation: conversation)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                // What you sent while it worked: in its queue until taken.
                if !conversation.queued.isEmpty { QueuedRows(conversation: conversation) }
                if let reply = conversation.reply, reply.failed == nil {
                    PromptRow(prompt: .init(text: Clip(text: reply.text)), stage: .sending)
                }
                if let tasks = conversation.live?.background, tasks.contains(where: \.state.running) {
                    BackgroundSection(tasks: tasks)
                }
                // What it writes now, off its screen: the reply row it becomes
                // once the transcript has it.
                if let writing = conversation.live?.writing {
                    VStack(alignment: .leading, spacing: 4) {
                        MarkdownView(writing).markdownStyle(MarkdownStyle(textStyle: .callout))
                            .opacity(0.6)
                        Label("Writing…", systemImage: "ellipsis")
                            .font(.caption2).foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    .transition(.opacity)
                }
                LiveRow(live: conversation.live, shown: phone.directories[conversation.ref.host.id]?.panes[conversation.ref.pane]?.shown)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { framed(Self.bottom, $0) }
                    .id(Self.bottom)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // A reader at the newest row stays there as rows arrive and the
        // keyboard takes room; one who scrolled up keeps their place. Held
        // by layout, never by a scroll command: the rows are lazy, their
        // heights estimates until drawn, and any scroll to the newest row in
        // the first moment (animated or not) left the list over rows never
        // built, blank until reopened (2026-10-27, the phone's receipts: a
        // live update 80 ms after the snapshot, the content's height still
        // moving 2396 → 7363 → 5763).
        .defaultScrollAnchor(atBottom ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 48
        } action: { _, now in
            atBottom = now
        }
        .onScrollGeometryChange(for: ListWitness.Scroll.self) { geometry in
            .init(room: geometry.containerSize, content: geometry.contentSize.height, top: geometry.visibleRect.minY)
        } action: { _, now in
            witness.scroll = now
            witness.check(pane: conversation.ref.pane, ids: conversation.visible.map(\.id) + [Self.bottom])
        }
        .overlay(alignment: .bottom) {
            if let missing = conversation.focusMissing {
                Label(missing, systemImage: "questionmark.circle")
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 8)
                    .onTapGesture { conversation.missingSeen() }
            }
        }
        // An edit opened from the changes: its call, mid-screen.
        .task(id: conversation.focus) {
            guard let focus = conversation.focus else { return }
            await Task.yield()
            position.scrollTo(id: focus, anchor: .center)
            conversation.focused()
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

/// What the conversation's list shows, checked after every layout that
/// moves it: rows held and none of them on screen is a blank list, said in
/// the log with the numbers that locate it, and said again when rows show.
/// The first drawing of each open is said once (rows, rows on screen). Not
/// observed: writing a frame here never redraws anything.
@MainActor final class ListWitness {
    struct Scroll: Equatable {
        var room: CGSize = .zero
        var content: CGFloat = 0
        var top: CGFloat = 0
    }

    /// Each row's frame in the scroll view's visible space (`.scrollView`).
    var rows: [String: CGRect] = [:]
    var scroll = Scroll()
    private var blank = false
    private var drawn = false
    private var checking = false

    /// After the layout pass in progress, once however many asked.
    func check(pane: String, ids: [String]) {
        guard !checking else { return }
        checking = true
        DispatchQueue.main.async { [self] in
            checking = false
            guard scroll.room.height > 0, !ids.isEmpty else { return }
            let screen = CGRect(origin: .zero, size: scroll.room)
            let shown = ids.filter { rows[$0]?.intersects(screen) == true }.count
            let receipts = VigilPhone.shared.receipts
            let numbers: Fields = [
                "pane": pane, "rows": ids.count, "onScreen": shown, "content": Int(scroll.content),
                "top": Int(scroll.top), "room": Int(scroll.room.height),
            ]
            if shown == 0 {
                guard !blank else { return }
                blank = true
                let nearest = ids.compactMap { rows[$0] }.min { abs($0.midY) < abs($1.midY) }
                receipts.error("conversation", "the list shows no row", numbers.merging(
                    ["nearestRowAt": nearest.map { Int($0.minY) } ?? -1, "framed": ids.filter { rows[$0] != nil }.count]) { $1 })
                return
            }
            if blank {
                blank = false
                receipts.info("conversation", "the list shows rows again", numbers)
            }
            if !drawn {
                drawn = true
                receipts.info("conversation", "list drawn", numbers)
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
                // When it is on screen, never merely built: in a stack that
                // is not lazy, onAppear fires at once and would ask every page.
                ProgressView().onScrollVisibilityChange { shown in if shown { conversation.loadEarlier() } }
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
            PromptRow(prompt: prompt, at: entry.at)
        case .reply(let clip):
            MarkdownView(clip.text).markdownStyle(MarkdownStyle(textStyle: .callout))
        case .thinking(let clip):
            if !clip.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Folded(title: "Thinking", systemImage: "ellipsis.bubble") {
                    Text(clip.text).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .tool(let call):
            let pending = conversation.pending(call, turn: entry.turn)
            // A question answered by buttons here shows its options once: as them.
            let buttons = if pending == .waiting, case .choices? = conversation.offer?.offer { true } else { false }
            // A launch returns at once; the row follows the work it started.
            let task = call.task.flatMap { id in conversation.live?.background?.first { $0.id == id } }
            ToolRow(call: call, pending: pending, task: task, options: !buttons) {
                if pending == .waiting { AnswerBar(conversation: conversation) }
                // A command running in the foreground: Ctrl+B, as at its terminal.
                if pending == .running, case .shell(_, _, false) = call.call {
                    HStack {
                        if let note = conversation.keyNote, conversation.pressing == nil {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            conversation.press(.background)
                        } label: {
                            if conversation.pressing == .background {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Run in background", systemImage: "arrow.down.right.square")
                            }
                        }
                        .buttonStyle(.ink)
                        .disabled(conversation.pressing != nil)
                    }
                }
            }
        case .event(let event):
            EventRow(event: event, at: entry.at)
        case .opaque:
            Label("Not shown here: \(entry.native)", systemImage: "questionmark.square.dashed")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// What waits in the agent's queue, each as your message not yet taken
/// (dashed, quieter), and one button that sends them all now as one
/// message. The Mac checks every step against the transcript and says what
/// happened under it.
private struct QueuedRows: View {
    @ObservedObject var conversation: Conversation

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(conversation.queued.enumerated()), id: \.offset) { _, queued in
                PromptRow(prompt: .init(text: Clip(text: queued.text), origin: .queued), at: queued.at, stage: .queued)
            }
            HStack(spacing: 10) {
                if let note = conversation.keyNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    conversation.press(.sendNow)
                } label: {
                    if conversation.pressing == .sendNow {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(conversation.queued.count == 1 ? "Send now" : "Send all now", systemImage: "paperplane")
                    }
                }
                .buttonStyle(.ink)
                .disabled(conversation.pressing != nil)
            }
        }
    }
}

/// What you (or something on your behalf) said: on the right, a shade off
/// the ground, as a message app draws your side, with when it was sent.
private struct PromptRow: View {
    let prompt: FeedEntry.Prompt
    var at: Double?
    /// Where it stands: in the conversation, waiting in the agent's queue,
    /// or typed into the pane and not yet seen anywhere.
    var stage: Stage = .sent
    @State private var whole = false

    enum Stage { case sent, queued, sending }

    private var origin: String? {
        switch prompt.origin {
        // A queued message once taken is simply sent; one waiting says so
        // in its caption.
        case .typed, .other, .queued: nil
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
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                switch stage {
                case .sent: shape.fill(.primary.opacity(0.09))
                case .queued, .sending:
                    shape.strokeBorder(.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .opacity(stage == .sent ? 1 : 0.7)
            .overlay(alignment: .bottomTrailing) {
                Text(caption).font(.caption2).foregroundStyle(.secondary).monospacedDigit().offset(y: 16)
            }
        }
        .padding(.bottom, 16)
    }

    /// Where it stands and when: "11:33", "Queued · 11:33", "Sending…".
    private var caption: String {
        let time = at.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) }
        switch stage {
        case .sent: return time ?? ""
        case .queued: return ["Queued, not taken yet", time].compactMap { $0 }.joined(separator: " · ")
        case .sending: return "Sending…"
        }
    }
}

/// The reply box: what you type goes to the pane as one message, while the
/// turn is yours; otherwise it says why not.
private struct Composer: View {
    @ObservedObject var conversation: Conversation
    /// The keyboard is up (`KeyboardState`): the box sits on it, and its
    /// own row of ↑ ↓ and hide shows above the text.
    let keyboardUp: Bool
    @State private var text = ""
    @FocusState private var focused: Bool
    /// Where ↑ and ↓ stand in what was sent (nil: the box holds the draft).
    @State private var recalled: Int?
    @State private var draft = ""

    /// ↑ an older message, ↓ a newer one, past the newest back to the draft.
    private func recall(_ step: Int) {
        let sent = conversation.sent
        let next = (recalled ?? -1) + step
        if recalled == nil { draft = text }
        if next < 0 {
            recalled = nil
            text = draft
        } else if next < sent.count {
            recalled = next
            text = sent[next]
        }
    }

    private var history: some View {
        Menu {
            ForEach(Array(conversation.sent.prefix(20).enumerated()), id: \.offset) { index, message in
                Button {
                    if recalled == nil { draft = text }
                    recalled = index
                    text = message
                    focused = true
                } label: {
                    Text(message.split(separator: "\n").first.map(String.init) ?? message)
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 20))
        }
        .disabled(conversation.sent.isEmpty)
        .accessibilityLabel("Sent messages")
    }

    var body: some View {
        let refusal = conversation.replyRefusal
        let sending = conversation.reply.map { $0.failed == nil } ?? false
        VStack(alignment: .leading, spacing: 6) {
            if let failed = conversation.reply?.failed {
                Label("Not sent: \(failed)", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Hue.care)
            }
            // Typing: what was sent, one step at a time, and the keyboard
            // put away. A row of the box itself, never a layer over it.
            if keyboardUp && focused {
                HStack(spacing: 18) {
                    Button { recall(1) } label: { Image(systemName: "chevron.up") }
                        .disabled((recalled ?? -1) + 1 >= conversation.sent.count)
                        .accessibilityLabel("Older sent message")
                    Button { recall(-1) } label: { Image(systemName: "chevron.down") }
                        .disabled(recalled == nil)
                        .accessibilityLabel("Newer sent message")
                    if let recalled {
                        Text("Sent \(recalled + 1) of \(conversation.sent.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { focused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide the keyboard")
                }
                .font(.system(size: 17, weight: .medium))
                .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                history.padding(.bottom, 9)
                TextField(conversation.replyHint, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(refusal != nil)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    conversation.send(text)
                    if conversation.reply?.failed == nil {
                        text = ""
                        recalled = nil
                        draft = ""
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .tint(Hue.yes)
                .disabled(refusal != nil || sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // Down, the box's ground reaches under the home indicator; up, it
        // ends on the keyboard.
        .background(.bar, ignoresSafeAreaEdges: keyboardUp ? [] : .bottom)
        // A failed reply comes back here to be sent again.
        .onChange(of: conversation.reply?.failed) { _, failed in
            if failed != nil, text.isEmpty, let back = conversation.reply?.text { text = back }
        }
        // A quote from the changes view lands in the box, after what was typed.
        .onReceive(conversation.$quote) { quote in
            guard let quote else { return }
            text = text.isEmpty ? quote + "\n\n" : text + "\n\n" + quote + "\n\n"
            conversation.quote = nil
            focused = true
        }
        // An activity's Reply: the box takes the keyboard.
        .onReceive(VigilPhone.shared.$typeInto) { ref in
            guard ref == conversation.ref else { return }
            VigilPhone.shared.typeInto = nil
            focused = true
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

private struct ToolRow<Answers: View>: View {
    let call: ToolCall
    let pending: Conversation.Pending?
    /// The background task this call started, as the pane lists it now.
    let task: AgentTask?
    /// A question's options drawn as written (not when its buttons are).
    let options: Bool
    /// The way to answer the request standing on this call, if one does.
    @ViewBuilder let answers: () -> Answers

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
                if call.task != nil, call.result?.status == .ok {
                    TaskMark(task: task).frame(minHeight: 20)
                } else {
                    StatusMark(result: call.result, pending: pending).frame(minHeight: 20)
                }
            }
            ToolBody(call: call, options: options)
            answers()
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
        case .agent(_, let type, _): BackgroundLine.glyph(type == "fork" ? .fork : .agent)
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

/// Where the work a launch started stands: the call returned at once, the
/// work runs on (`FeedLive.background`). A task the pane no longer lists
/// (ended long ago, or before vigil listened) says only that it started.
private struct TaskMark: View {
    let task: AgentTask?

    var body: some View {
        Group {
            switch task?.state {
            case .running?:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Running")
                }
                .foregroundStyle(.secondary)
            case .completed?: Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Done")
            case .failed?: Label(task?.exitCode.map { "Failed (exit \($0))" } ?? "Failed", systemImage: "xmark").foregroundStyle(Hue.care)
            case .killed?, .stopped?: Label("Stopped", systemImage: "stop").foregroundStyle(.secondary)
            case .ended?: Text("Ended").foregroundStyle(.secondary)
            case nil: Text("Started").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.weight(.medium))
        .labelStyle(.titleAndIcon)
    }
}

/// What a call does, drawn for its kind.
private struct ToolBody: View {
    let call: ToolCall
    let options: Bool

    var body: some View {
        switch call.call {
        case .shell(let command, _, _):
            Expandable(lines: 6) { lines in
                Well {
                    SyntaxText(command, format: .shell, font: .system(.footnote, design: .monospaced))
                        .lineLimit(lines)
                }
            }
        case .patch(let path, let hunks, _, _):
            PatchView(path: path, hunks: hunks)
        case .read, .search, .fetch, .webSearch:
            EmptyView()
        case .question(let questions):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    QuestionView(question: question, answer: call.result?.answers?[question.question], options: options)
                }
            }
        case .plan(let plan):
            Expandable(lines: 10) { lines in
                MarkdownView(plan.text).markdownStyle(
                    lines.map { MarkdownStyle(textStyle: .footnote).preview(lines: $0) } ?? MarkdownStyle(textStyle: .footnote))
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

/// A tool call's change, drawn by swift-utils' `DiffView` (the one diff
/// everywhere: this card, the changes view, a markdown fence): its hunks as
/// unified text, its path for the language, folded to its first lines.
private struct PatchView: View {
    let path: String
    let hunks: [ToolCall.Hunk]

    private var unified: String {
        hunks.map { hunk in
            (["@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"] + hunk.lines).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// A card shows what the edit changed: the unchanged lines Claude keeps
    /// around it (whole paragraphs, in prose) fold behind a tap.
    var body: some View {
        GitViews.DiffView(unified: unified, path: path)
            .diffContext(lines: 0)
            .diffMaxLines(14)
    }
}

/// A question as it was asked: its options, the one answered marked.
private struct QuestionView: View {
    let question: ToolCall.Question
    let answer: String?
    let options: Bool

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
            if options { VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options, id: \.self) { option in
                    let chosen = picked.contains(option)
                    Label(option, systemImage: chosen ? "checkmark.circle.fill" : (question.multiple ? "square" : "circle"))
                        .font(.footnote)
                        .foregroundStyle(chosen ? .primary : .secondary)
                }
            } }
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

// MARK: Answers

extension EnvironmentValues {
    /// Shows the pane's terminal instead of its conversation.
    @Entry var showTerminal: @MainActor () -> Void = {}
}

/// How the standing request is answered from this screen, through authz by
/// its id (as the Lock Screen and the HUD answer it): its no and its yes,
/// its questions' options, or the terminal. Never a key typed into a dialog.
private struct AnswerBar: View {
    @ObservedObject var conversation: Conversation
    @Environment(\.showTerminal) private var showTerminal
    /// A questionnaire's picks so far, by question id.
    @State private var picks: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch conversation.offer?.offer {
            case .reading?, nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the request…").font(.footnote).foregroundStyle(.secondary)
                }
            case .consent(let allow, let allowLabel, let deny, let denyLabel)?:
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(denyLabel) { conversation.answer(.action(deny, feedback: nil)) }.buttonStyle(.ink)
                    Button(allowLabel) { conversation.answer(.action(allow, feedback: nil)) }.buttonStyle(.inkProminent)
                }
                .tint(Hue.yes)
            case .choices(let asks)?:
                choices(asks)
            case .terminal?:
                HStack {
                    Spacer(minLength: 0)
                    Button { showTerminal() } label: { Label("Answer in the terminal", systemImage: "terminal") }
                        .buttonStyle(.ink)
                }
            }
            if conversation.answering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Answering…").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let why = conversation.answerError {
                Label("Not answered: \(why)", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Hue.care)
            }
        }
        .disabled(conversation.answering)
    }

    /// A lone one-of-n question answers on its tap (Authz's card rule);
    /// anything more is picked, then sent.
    @ViewBuilder private func choices(_ asks: [Conversation.Ask]) -> some View {
        let lone = asks.count == 1 && !asks[0].multiple
        ForEach(asks, id: \.id) { ask in
            VStack(alignment: .leading, spacing: 6) {
                if asks.count > 1 { Text(ask.title).font(.footnote.weight(.semibold)) }
                ForEach(ask.choices) { choice in
                    let picked = picks[ask.id, default: []].contains(choice.id)
                    Button {
                        if lone { return send([ask.id: [choice.id]]) }
                        var now = ask.multiple ? picks[ask.id, default: []] : []
                        if picked { now.removeAll { $0 == choice.id } } else { now.append(choice.id) }
                        picks[ask.id] = now
                    } label: {
                        HStack(spacing: 8) {
                            if !lone {
                                Image(systemName: picked ? "checkmark.circle.fill" : (ask.multiple ? "square" : "circle"))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.label)
                                if let description = choice.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Authz's answer chip: a label of any height on its wash.
                    .buttonStyle(AnswerButtonStyle(tint: nil, focused: picked))
                }
            }
        }
        if !lone {
            HStack {
                Spacer(minLength: 0)
                Button("Send") { send(picks) }
                    .buttonStyle(.inkProminent)
                    .tint(Hue.yes)
                    .disabled(asks.contains { picks[$0.id, default: []].isEmpty })
            }
        }
    }

    private func send(_ answers: [String: [String]]) {
        conversation.answer(.answers(answers.mapValues { .choices($0, other: nil) }))
    }
}

// MARK: Events

private struct EventRow: View {
    let event: FeedEntry.Event
    var at: Double?

    /// "11:33": when it happened, a clock on the person's day.
    private var time: String? { at.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } }

    var body: some View {
        switch event {
        case .compacted(let trigger, let before, let after):
            Divided(text: ["Context compacted", trigger, Self.tokens(before, after)].compactMap { $0 }.joined(separator: " · "))
        case .summary(let clip):
            Folded(title: "What it kept after compacting", systemImage: "archivebox") {
                MarkdownView(clip.text).markdownStyle(.footnote)
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
            Divided(text: ["Turn took \(Duration.milliseconds(milliseconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))",
                           time.map { "ended \($0)" }].compactMap { $0 }.joined(separator: " · "))
        case .taskEnded(let task):
            // A background task's end, as the agent heard it: its line,
            // never its markup.
            BackgroundLine(task: task, now: .now)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

// MARK: Background work

/// What the agent runs beside its conversation, above its live state, as
/// its own footer lists it: each running task with its kind, its title and
/// how long it has run; the ones that ended lately folded into one line.
/// Shown while something runs (a finished turn can be waiting on it).
private struct BackgroundSection: View {
    let tasks: [AgentTask]

    var body: some View {
        let running = tasks.filter(\.state.running)
        let ended = tasks.filter { !$0.state.running }
        VStack(alignment: .leading, spacing: 7) {
            Text("Background").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(running) { task in BackgroundLine(task: task, now: clock.date) }
                }
            }
            if !ended.isEmpty {
                Folded(title: Self.summary(ended), systemImage: "checkmark.circle") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ended) { task in BackgroundLine(task: task, now: .now) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "3 ended · 1 failed": how many, and how many failed (an end nobody
    /// described is not a failure).
    static func summary(_ ended: [AgentTask]) -> String {
        let failed = ended.count { $0.state == .failed }
        return "\(ended.count) ended" + (failed > 0 ? " · \(failed) failed" : "")
    }
}

/// One background task in a line: its kind's glyph, its title, then how it
/// stands (its time running, or how it ended) and its tokens when known.
private struct BackgroundLine: View {
    let task: AgentTask
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: Self.glyph(task.kind))
                .font(.caption)
                .foregroundStyle(task.state.running ? AnyShapeStyle(AgentState.working.tint) : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .accessibilityLabel(Self.kind(task.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.footnote).lineLimit(1).truncationMode(.middle)
                // What it does now, in Claude's own words ("Waiting on …").
                if let label = task.label {
                    Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Text(status).font(.caption.monospacedDigit())
                .foregroundStyle(task.state == .failed ? AnyShapeStyle(Hue.care) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    private var status: String {
        let run = Self.elapsed((task.ended ?? now.timeIntervalSince1970) - task.started)
        let tokens = task.tokens.map { " · ↓ \(Self.tokens($0))" } ?? ""
        switch task.state {
        case .running: return run + tokens
        case .completed: return "done in \(run)" + tokens
        case .failed: return "failed" + (task.exitCode.map { " (exit \($0))" } ?? "") + tokens
        case .killed: return "stopped"
        case .stopped: return "stopped with its agent"
        case .ended: return "ended after \(run)"
        }
    }

    /// "20m 5s", "1h 3m": the time as Claude's own panel says it.
    static func elapsed(_ seconds: Double) -> String {
        Duration.seconds(max(0, Int(seconds))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    /// "594.1k", "1.2M".
    static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1_000_000)
            : count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    static func glyph(_ kind: AgentTask.Kind) -> String {
        switch kind {
        case .agent: "person.2"
        case .fork: "arrow.triangle.branch"
        case .shell: "terminal"
        case .monitor: "waveform.path.ecg"
        case .other: "circle.dashed"
        }
    }

    static func kind(_ kind: AgentTask.Kind) -> String {
        switch kind {
        case .agent: "Background agent"
        case .fork: "Fork"
        case .shell: "Background shell"
        case .monitor: "Monitor"
        case .other: "Background task"
        }
    }
}

// MARK: The live state

/// What the pane does now, last: its state in its color and words, how
/// full its context is.
private struct LiveRow: View {
    let live: FeedLive?
    /// The pane's state as every row shows it (its Mac's directory, the
    /// seen rule applied: a finished turn you have seen reads idle), so the
    /// header and this row never say two things about one pane.
    let shown: AgentState?

    var body: some View {
        if let live {
            let seen = shown == .idle && (live.state == .done || live.state == .blocked && live.flavor == .ask)
            let state = seen ? AgentState.idle : live.state
            let flavor = seen ? nil : live.flavor
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state.tint)
                        .symbolEffect(.pulse, isActive: state == .working)
                    Text(state.words(flavor)).font(.footnote.weight(.medium))
                    Spacer(minLength: 6)
                    if let context = live.context { ContextMeter(percent: context) }
                }
                if let status = live.status { StatusLine(status: status) }
            }
            .padding(.top, 4)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

/// What the agent's own status line says: the model and its effort, the
/// account it burns, and that account's windows with the time left until
/// each resets (care from 80%, where the window is nearly spent).
private struct StatusLine: View {
    let status: FeedStatus

    var body: some View {
        let words = [status.model, status.effort].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !words.isEmpty { Text(words) }
                if let account = status.account {
                    if !words.isEmpty { Text("·") }
                    Text(account).fontWeight(.medium)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if !status.limits.isEmpty {
                TimelineView(.periodic(from: .now, by: 60)) { clock in
                    HStack(spacing: 14) {
                        ForEach(status.limits, id: \.name) { limit in
                            LimitMeter(limit: limit, now: clock.date)
                        }
                    }
                }
            }
        }
    }
}

private struct LimitMeter: View {
    let limit: FeedStatus.Limit
    let now: Date

    var body: some View {
        let fill = Double(min(max(limit.used, 0), 100)) / 100
        let left = limit.resets.map { Self.left(until: Date(timeIntervalSince1970: $0), from: now) }
        HStack(spacing: 5) {
            Text(limit.name).foregroundStyle(.secondary)
            Capsule().fill(.primary.opacity(0.12))
                .frame(width: 36, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(limit.used >= 80 ? AnyShapeStyle(Hue.care) : AnyShapeStyle(.secondary))
                        .frame(width: 36 * fill, height: 4)
                }
            Text("\(limit.used)%").monospacedDigit().foregroundStyle(.secondary)
            if let left { Text("↻\(left)").monospacedDigit().foregroundStyle(.tertiary) }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.name) window \(limit.used)% used" + (left.map { ", resets in \($0)" } ?? ""))
    }

    /// "2d6h", "1h3m", "12m": the two largest units left.
    static func left(until reset: Date, from now: Date) -> String {
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        let (days, hours, mins) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(mins)m" }
        return "\(mins)m"
    }
}

/// How full the agent's context window is: a bar and its percent, care
/// from 70 (where it compacts or stops soon), as the activity draws it.
struct ContextMeter: View {
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

