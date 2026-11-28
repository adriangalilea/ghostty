import Foundation
import GitViews
import Ink
import MarkdownText
import SwiftUI
import VigilWire

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// The person's chats with agents, drawn with Ink's chat family: the list
/// of every chat of a host (`VigilChatList`), one chat a page at a time with
/// its composer (`VigilChatView`), the two side by side (`VigilChat`) and a
/// pane's chat as a column beside it (`VigilPaneChat`).
///
/// Nothing here works out what a chat holds. The host that keeps the chats
/// sends its list as rows it computed (`Messages.Row`: the last post, what
/// is unread, what waits for the person, every member named) and each chat
/// a page at a time (`Messages.Page`); `VigilChats` holds what it was sent
/// and the views draw it.

/// What the views ask of the app that holds them.
struct VigilChatHost {
    /// The id of the host whose chats these are, as its posts name it
    /// (`Messages.Post.writtenIn`); nil until it is known.
    var hostID: String?
    /// A page of a chat's posts: the `limit` newest below `before`.
    var page: @Sendable (_ chat: ChatID, _ before: Int?, _ limit: Int) async throws -> Messages.Page
    /// The person's post.
    var post: @Sendable (_ say: Messages.Say) async throws -> Messages.Standing
    /// The person's act on what is there.
    var act: @Sendable (_ what: Messages.Act.What) async throws -> Messages.Acted
    /// The person's answer to a question the host asks about a pane, which
    /// its own surface holds (`Asks.Standing`): what came of it, in its words.
    var answer: @Sendable (_ press: Asks.Press) async throws -> String
    /// Go to a pane of that host.
    var open: @MainActor (_ pane: String) -> Void = { _ in }
    /// Whether a person's hand was on this device after the moment (unix
    /// seconds), or within the minute before: read needs it.
    var handAfter: @MainActor (_ moment: Double) -> Bool = { _ in true }
    /// One ask about the files a post names, of the host `root` they are on
    /// (`Open.mention`): which are files there, and one read.
    var mention: @Sendable (_ call: MentionCall, _ root: String) async throws -> Data
    /// A file a post names, shown where the app shows files, beside `pane`
    /// when the chat was open beside one. Nil: the chat pushes its page
    /// itself (the phone).
    var openFile: (@MainActor (_ file: VigilMentionedFile, _ pane: String?) -> Void)? = nil
    /// Whether the press being handled now is a person's: on the Mac, a
    /// hardware click (no posted event, no accessibility action), which an
    /// answer on a request needs. Read inside the button's action.
    var pressedByPerson: @MainActor () -> Bool = { true }

    /// Whether a folder on the host `root` can be shown here: revealed in
    /// this Mac's Finder, so only this Mac's own.
    func reveals(_ root: String) -> Bool {
        #if os(macOS)
            root == hostID
        #else
            false
        #endif
    }

    /// A named file's text from its host.
    func read(_ file: VigilMentionedFile) -> @Sendable () async throws -> DocumentText {
        let mention = mention
        return { try JSONDecoder().decode(DocumentText.self, from: await mention(.read(file.path), file.root)) }
    }
}

/// One host's chats as the views draw them: its list, the questions it asks
/// about its panes, and a page of each chat a view has open. Fed by whoever
/// follows the host (`take`, `asked`, `unreachable`), which is the app's;
/// the same store on the Mac and on the phone.
@MainActor
final class VigilChats: ObservableObject {
    /// Whether the host's chats can be read at all: apart from a host that
    /// answers and has none.
    enum Reach: Equatable {
        /// Nothing heard yet.
        case waiting
        case reached
        /// Why its chats cannot be read now, in words for the person.
        case unreachable(String)
    }

    @Published private(set) var reach: Reach = .waiting
    /// The list, a chat waiting for the person's yes first, then the most
    /// recently written in.
    @Published private(set) var rows: [Messages.Row] = []
    /// The questions the host asks about its panes, on its own surface.
    @Published private(set) var asks: [Asks.Standing] = []
    /// The page of each chat a view shows now.
    @Published private(set) var pages: [ChatID: Messages.Page] = [:]
    /// Why a shown chat's page could not be read.
    @Published private(set) var failures: [ChatID: String] = [:]
    /// What rows of panes wear, apart from the list: a post or a read
    /// redraws the list, and a pane's row only when its count changed.
    let marks = Marks()
    var host: VigilChatHost
    /// The events of a step, after its rows were taken: what an app notifies from.
    var heard: (@MainActor ([Event]) -> Void)?
    /// The list or the questions changed: what an app counts its badges from.
    var changed: (@MainActor () -> Void)?

    @MainActor
    final class Marks: ObservableObject {
        /// Per pane of the host, the posts the person has not read in its
        /// agent's chats with them alone.
        @Published fileprivate(set) var unread: [String: Int] = [:]
        /// Per pane, what waits on the person there, by id: a chat with a
        /// delivery waiting for their yes, a chat proposed and not answered,
        /// a question about the pane. Ids, so a fold of rows counts each once.
        @Published fileprivate(set) var waiting: [String: Set<String>] = [:]

        var everyWaiting: Set<String> { waiting.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
        /// A row's pane: nil for a row that is no pane of this host.
        func waiting(pane: String?) -> Set<String> { pane.flatMap { waiting[$0] } ?? [] }
        func unread(pane: String?) -> Int { pane.flatMap { unread[$0] } ?? 0 }
    }

    private static let pageSize = 60
    /// How many views show each chat: its page is kept while any does.
    private var shown: [ChatID: Int] = [:]
    /// How many of its newest posts each shown chat's page holds.
    private var depth: [ChatID: Int] = [:]
    private var loading: Set<ChatID> = []
    private var stale: Set<ChatID> = []

    init(host: VigilChatHost) { self.host = host }

    // MARK: What the follower heard

    func take(_ step: Messages.Step) {
        if reach != .reached { reach = .reached }
        switch step {
        case .whole(let whole):
            place(whole)
            // Everything may have changed while nothing was followed.
            for chat in shown.keys { reload(chat) }
        case .events(let events, let changed):
            var byID = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
            for row in changed { byID[row.id] = row }
            place(Array(byID.values))
            var touched: Set<ChatID> = []
            var unplaced = false
            for event in events {
                guard case .messages(let change) = event.change else { continue }
                if let chat = Messages.chat(of: change, post: { self.chat(holding: $0) }) {
                    touched.insert(chat)
                } else if case .note = change {
                    continue
                } else {
                    unplaced = true
                }
            }
            for chat in touched where shown[chat] != nil { reload(chat) }
            // A change of a post no page holds yet: a page being read now
            // may predate it.
            if unplaced { stale.formUnion(loading) }
            heard?(events)
        }
    }

    func asked(_ asks: [Asks.Standing]) {
        guard asks != self.asks else { return }
        self.asks = asks
        remark()
    }

    func unreachable(_ why: String) {
        let next = Reach.unreachable(why)
        if reach != next { reach = next }
    }

    /// The host that answered said its own id (`Local.MessageStep.host`).
    func opened(host id: String?) {
        if let id, host.hostID != id { host.hostID = id }
    }

    var hostID: String? { host.hostID }

    private func place(_ next: [Messages.Row]) {
        let ordered = next
            .filter { $0.summary.chat.consent != .refused }
            .sorted { one, other in
                let asked = (one.summary.chat.asksYou, other.summary.chat.asksYou)
                if asked.0 != asked.1 { return asked.0 }
                return one.summary.activity > other.summary.activity
            }
        if ordered != rows { rows = ordered }
        remark()
    }

    private func remark() {
        var unread: [String: Int] = [:]
        var waiting: [String: Set<String>] = [:]
        for row in rows {
            let chat = row.summary.chat
            let present = row.members.filter { chat.present.contains($0.member) }
            if present.count == 1, let pane = present[0].pane, row.summary.unread > 0 { unread[pane, default: 0] += row.summary.unread }
            if row.summary.awaitingYou > 0 || chat.asksYou {
                for pane in present.compactMap(\.pane) { waiting[pane, default: []].insert(chat.id.raw) }
            }
        }
        for ask in asks {
            for pane in ask.panes { waiting[pane, default: []].insert(ask.id) }
        }
        if unread != marks.unread { marks.unread = unread }
        if waiting != marks.waiting { marks.waiting = waiting }
        changed?()
    }

    /// The posts the person has not read, in every chat.
    var unread: Int { rows.reduce(0) { $0 + $1.summary.unread } }
    /// What waits on the person, each once.
    var waiting: Set<String> {
        Set(rows.filter { $0.summary.awaitingYou > 0 || $0.summary.chat.asksYou }.map(\.id.raw)).union(asks.map(\.id))
    }

    // MARK: A pane's chats

    /// The chats the agent in `pane` is in now, as the list orders them.
    func chats(withPane pane: String) -> [Messages.Row] {
        rows.filter { row in row.members.contains { $0.pane == pane && row.summary.chat.present.contains($0.member) } }
    }

    /// The agent in `pane`, as any chat it is in names it.
    func agent(inPane pane: String) -> Messages.Named? {
        for row in rows {
            if let named = row.members.first(where: { $0.pane == pane }) { return named }
        }
        return nil
    }

    /// The chat a pane's panel opens on: one in `waiting` when it was opened
    /// from what waits there, else its agent's latest chat with the person
    /// alone, else its latest of any.
    func chat(forPane pane: String, waiting: Set<String> = []) -> ChatID? {
        let with = chats(withPane: pane)
        return (with.first { waiting.contains($0.id.raw) }
            ?? with.first { $0.summary.chat.present.filter { $0 != .you }.count == 1 }
            ?? with.first)?.id
    }

    // MARK: Pages

    /// A view shows `chat`: its page is read and kept current until `hide`.
    func show(_ chat: ChatID) {
        shown[chat, default: 0] += 1
        if shown[chat] == 1 { reload(chat) }
    }

    func hide(_ chat: ChatID) {
        guard let count = shown[chat] else { return }
        if count > 1 {
            shown[chat] = count - 1
        } else {
            shown[chat] = nil
            depth[chat] = nil
            pages[chat] = nil
            failures[chat] = nil
        }
    }

    /// The page reaches a screen further back.
    func earlier(_ chat: ChatID) {
        depth[chat] = (depth[chat] ?? Self.pageSize) + Self.pageSize
        reload(chat)
    }

    private func chat(holding post: PostID) -> ChatID? {
        pages.first { $0.value.posts.contains { $0.post.id == post } }?.key
    }

    /// One read of a chat's page at a time; a change that arrives meanwhile
    /// is one more read after it, never one per change.
    private func reload(_ chat: ChatID) {
        guard !loading.contains(chat) else {
            stale.insert(chat)
            return
        }
        loading.insert(chat)
        let want = depth[chat] ?? Self.pageSize
        let read = host.page
        Task {
            do {
                // The host hands 200 posts a read at most.
                var page = try await read(chat, nil, min(want, 200))
                while page.posts.count < want, let before = page.before {
                    let older = try await read(chat, before, min(want - page.posts.count, 200))
                    guard !older.posts.isEmpty else { break }
                    page.posts = older.posts + page.posts
                    page.before = older.before
                    for named in older.members where !page.members.contains(where: { $0.member == named.member }) {
                        page.members.append(named)
                    }
                }
                if shown[chat] != nil {
                    if pages[chat] != page { pages[chat] = page }
                    if failures[chat] != nil { failures[chat] = nil }
                }
            } catch {
                if shown[chat] != nil { failures[chat] = "\(error)" }
            }
            loading.remove(chat)
            if stale.remove(chat) != nil, shown[chat] != nil { reload(chat) }
        }
    }
}

extension Messages.Chat {
    /// Proposed by an agent or a command, waiting for the person's one yes.
    var asksYou: Bool { if case .asked = consent { true } else { false } }
}

extension Messages.Summary {
    /// When it was last written in, or made.
    var activity: Double { last?.at ?? chat.made }
}

/// Who a chat's views draw: the person and every member the host named.
struct VigilChatPeople {
    static let you = MemberID.you.raw

    let all: [InkChat.Person]
    private let named: [String: Messages.Named]

    /// `also`: members a post or a row names that the host listed nowhere
    /// (a writer no longer known): drawn by their id, so every sender is
    /// among the people.
    init(_ members: [Messages.Named], also: [MemberID] = []) {
        var named: [String: Messages.Named] = [:]
        for member in members where named[member.member.raw] == nil { named[member.member.raw] = member }
        var people: [String: InkChat.Person] = [Self.you: InkChat.Person(Self.you, name: "You")]
        for (key, member) in named {
            people[key] = InkChat.Person(
                key, name: member.name, handle: member.handle, symbol: Self.symbol(member.kind), tint: member.tint.flatMap(InkTint.init))
        }
        for member in also where people[member.raw] == nil {
            people[member.raw] = InkChat.Person(member.raw, name: member.raw, symbol: "questionmark")
        }
        all = people.values.sorted { $0.id < $1.id }
        self.named = named
    }

    init(rows: [Messages.Row]) {
        self.init(rows.flatMap(\.members), also: rows.compactMap(\.summary.last?.by))
    }

    init(page: Messages.Page) {
        self.init(page.members, also: page.posts.map(\.post.by) + page.chat.members.map(\.member))
    }

    func name(_ key: String) -> String { key == Self.you ? "You" : named[key]?.name ?? key }
    func name(_ member: MemberID) -> String { name(member.raw) }
    /// The pane a member runs in on the host now.
    func pane(_ member: MemberID) -> String? { named[member.raw]?.pane }

    /// What a chat is called: its own name with its face and how many are
    /// in it, else whoever is in it besides the person.
    func title(_ chat: Messages.Chat) -> String {
        if let name = chat.name {
            let face: String = if case .emoji(let emoji)? = chat.face { emoji } else { "👥" }
            return "\(face) \(name) · \(chat.present.count)"
        }
        let others = chat.present.filter { $0 != .you }.map(name)
        switch others.count {
        case 0: return "Only you"
        case 2: return "\(others[0]) ↔ \(others[1])"
        default: return ListFormatter.localizedString(byJoining: others)
        }
    }

    /// The mark of a member's kind where it wears no face.
    private static func symbol(_ kind: String?) -> String {
        switch kind {
        case "claude": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "watch": "binoculars"
        default: "terminal"
        }
    }

    private static func badge(_ kind: String?) -> Color {
        switch kind {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": Color(red: 0.06, green: 0.64, blue: 0.50)
        case "watch": .indigo
        default: .gray
        }
    }

    /// A member's face: the emoji the host says it wears, with its kind's
    /// badge at its corner (Claude, Codex, a watch, a command), so two
    /// agents wearing one emoji are told apart; else Ink's own (its kind's
    /// mark, the person's initial).
    @ViewBuilder func picture(_ person: InkChat.Person) -> some View {
        if let member = named[person.id], let face = member.face, !face.isEmpty {
            GeometryReader { g in
                let side = min(g.size.width, g.size.height)
                Text(face)
                    .font(.system(size: (side * 0.62).rounded()))
                    .frame(width: g.size.width, height: g.size.height)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: Self.symbol(member.kind))
                            .font(.system(size: (side * 0.22).rounded(), weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: side * 0.42, height: side * 0.42)
                            .background(Self.badge(member.kind), in: Circle())
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            .accessibilityLabel(member.kind ?? "member")
                    }
            }
        }
    }
}

/// Every chat of a host, as its rows say. A host whose chats cannot be read
/// says so and why, apart from one that answers and has none.
struct VigilChatList: View {
    @ObservedObject var chats: VigilChats
    /// The chosen chat's id.
    @Binding var selection: String?

    var body: some View {
        let people = VigilChatPeople(rows: chats.rows)
        VStack(spacing: 0) {
            if case .unreachable(let why) = chats.reach {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Can't reach this host's chats yet", systemImage: "antenna.radiowaves.left.and.right.slash").font(.headline)
                    Text(why).inkText(.detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.inkGap)
            }
            InkConversations(
                chats.rows.map { Self.summary($0, people: people) },
                selection: $selection, people: people.all, me: VigilChatPeople.you, picture: { people.picture($0) },
                empty: {
                    switch chats.reach {
                    case .reached: Text("You have no chats").inkText(.detail)
                    case .waiting: Text("Reaching this host's chats…").inkText(.detail)
                    case .unreachable: EmptyView()
                    }
                })
        }
    }

    static func summary(_ row: Messages.Row, people: VigilChatPeople) -> InkChat.Summary {
        let summary = row.summary, chat = summary.chat
        let standing = chat.asksYou ? "Waiting for your yes" : "Nothing said yet"
        return InkChat.Summary(
            chat.id.raw, title: people.title(chat), people: chat.present.filter { $0 != .you }.prefix(3).map(\.raw),
            from: summary.last?.by.raw, line: summary.last.map { InkChat.line(of: $0.words) } ?? standing,
            at: Date(timeIntervalSince1970: summary.activity), unread: summary.unread,
            waits: summary.awaitingYou > 0 || chat.asksYou)
    }
}

/// Every chat, and the one chosen beside the list.
struct VigilChat: View {
    @ObservedObject var chats: VigilChats
    @Binding var chosen: String?

    var body: some View {
        let row = chats.rows.first { $0.id.raw == chosen }
        let people = VigilChatPeople(rows: chats.rows)
        InkChat(
            title: row.map { people.title($0.summary.chat) },
            detail: row.map { Self.detail($0.summary.chat, people: people) },
            open: row != nil
        ) {
            VigilChatList(chats: chats, selection: $chosen)
        } conversation: {
            if let row {
                VigilChatView(chat: row.id, chats: chats).id(row.id)
            }
        }
        .onBack { chosen = nil }
    }

    /// Who is in it, the person last.
    static func detail(_ chat: Messages.Chat, people: VigilChatPeople) -> String {
        ListFormatter.localizedString(byJoining: chat.present.filter { $0 != .you }.map(people.name) + ["you"])
    }
}

/// A pane's chat as a column beside it. It opens on one chat (its agent's
/// latest with the person, or the one that waits when it was opened from
/// what waits), says which chat that is, and stays on it: a post in another
/// chat never moves the column or what is being written. Another of the
/// agent's chats is the person's to choose. A pane whose agent is in no
/// chat shows a composer, and what is written there starts one.
struct VigilPaneChat: View {
    let pane: String
    @ObservedObject var chats: VigilChats
    /// What the hand that opened it counted (`VigilChats.Marks.waiting`).
    var waiting: Set<String> = []
    /// The chat it was opened for, when it was opened for one.
    var initial: ChatID? = nil
    /// What stands above the column: where its pane is, on the Mac.
    var head: AnyView? = nil

    @State private var bound: ChatID?
    @State private var draft = ""
    @State private var failure: String?

    var body: some View {
        let with = chats.chats(withPane: pane)
        let people = VigilChatPeople(rows: chats.rows)
        let row = bound.flatMap { id in chats.rows.first { $0.id == id } }
        let agent = chats.agent(inPane: pane)?.name
        InkChat.Column(
            title: row.map { people.title($0.summary.chat) } ?? agent ?? "This pane",
            detail: bound.map { "Chat \($0.raw.prefix(8))" + (with.count > 1 ? " · one of \(with.count) with this agent" : "") }
        ) {
            if let head { head }
            if let bound {
                VigilChatView(chat: bound, chats: chats, pane: pane, onWaiting: waiting.contains(bound.raw)).id(bound)
            } else {
                InkConversation([], people: people.all, me: VigilChatPeople.you, empty: {
                    switch chats.reach {
                    case .reached: Text("No chat with this pane's agent yet. What you write starts one.").inkText(.detail)
                    case .waiting: Text("Reaching this host's chats…").inkText(.detail)
                    case .unreachable(let why): Text("Can't reach this host's chats yet: \(why)").inkText(.detail)
                    }
                })
                InkComposer(text: $draft, prompt: "Message \(agent ?? "this pane's agent")", blocked: failure, cancel: { failure = nil }) { start($0) }
            }
        } tools: {
            if with.count > 1 {
                Menu {
                    ForEach(with) { other in
                        Button {
                            bound = other.id
                        } label: {
                            Label(people.title(other.summary.chat), systemImage: other.id == bound ? "checkmark" : "bubble.left")
                        }
                    }
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .inkTip("this agent's other chats")
            }
        }
        // Chosen once, when the pane's chats are first known: what arrives
        // later in another chat changes the list and the row marks only.
        .onChange(of: with.map(\.id), initial: true) {
            if bound == nil { bound = initial ?? chats.chat(forPane: pane, waiting: waiting) }
        }
    }

    /// The first words to an agent in no chat: its host puts them in a chat
    /// of the two, and the column stays on that one.
    private func start(_ words: String) {
        if let why = Messages.Post.problem(words) {
            failure = why
            return
        }
        let post = chats.host.post, pane = pane
        draft = ""
        failure = nil
        Task {
            do { bound = try await post(Messages.Say(to: [pane], words: words)).post.chat } catch {
                draft = words
                failure = "Not sent: \(error)"
            }
        }
    }
}

/// One chat: a page of its posts and the composer under them. The composer
/// writes in this chat and no other (`chat`, fixed for the view's life), so
/// what is being written is never sent somewhere else because another chat
/// became the newest. Each post wears how it stands on its way to each
/// agent, and a delivery waiting for the person's yes is answered on its
/// post.
struct VigilChatView: View {
    let chat: ChatID
    @ObservedObject var chats: VigilChats
    /// The pane it stands beside, when it does: where a file it names opens.
    var pane: String? = nil
    /// Opened from what waits: it opens on the first post that does.
    var onWaiting = false

    @State private var draft = ""
    @State private var replying: String?
    @State private var editing: String?
    @State private var failure: String?
    /// What each answer given here came to, in the host's words, by what
    /// was answered (a delivery, the chat, a pane's question).
    @State private var answered: [String: String] = [:]
    /// The position a read is on its way for: asked once.
    @State private var marking = 0
    @State private var opened: VigilMentionedFile?
    #if os(macOS)
        @Environment(\.controlActiveState) private var active
        private var front: Bool { active == .key }
    #else
        @Environment(\.scenePhase) private var phase
        private var front: Bool { phase == .active }
    #endif

    private var host: VigilChatHost { chats.host }
    private var page: Messages.Page? { chats.pages[chat] }

    var body: some View {
        let page = page
        let posts = page?.posts ?? []
        let people = page.map(VigilChatPeople.init(page:)) ?? VigilChatPeople([])
        let messages = posts.map { Self.message($0, people: people) }
        let byID = Dictionary(posts.map { ($0.post.id.raw, $0) }) { first, _ in first }
        // Its revoke stands under the newest post a standing yes let through.
        let revocable = posts.last { $0.standing != nil }?.post.id
        let read = page?.read ?? 0
        let unread = posts.first { ($0.post.position ?? 0) > read && $0.post.by != .you }?.post.id.raw
        let focus = onWaiting ? posts.first { $0.requests != nil }?.post.id.raw : nil
        if page?.before != nil {
            Button("Earlier posts") { chats.earlier(chat) }.buttonStyle(.ink).padding(.vertical, 4)
        }
        InkConversation(messages, people: people.all, me: VigilChatPeople.you, unread: unread, focus: focus, acts: acts(byID, people)) { message in
            let standing = byID[message.id]
            let notes = standing.map { Self.notes($0, people: people) } ?? []
            let requests = (standing?.requests ?? [:]).sorted { $0.key.raw < $1.key.raw }
            let said = standing.map { one in one.deliveries.compactMap { answered[Self.key(one.post.id, $0.to)] } } ?? []
            let revokes = standing?.post.id == revocable
            let under = !notes.isEmpty || !requests.isEmpty || !said.isEmpty || revokes
            VStack(alignment: .leading, spacing: 6) {
                VigilMessageWords(
                    id: message.id, words: message.words,
                    place: standing.flatMap { $0.post.mentionPlace(pane: people.pane($0.post.by)) }, host: host, open: open)
                    // Something stands under the words: the foot (its time)
                    // takes a row of its own under it, never over its buttons.
                    .transformEnvironment(\.inkTailRoom) { if under { $0 = nil } }
                if let standing {
                    ForEach(requests, id: \.key) { entry in
                        let member = entry.key
                        let key = Self.key(standing.post.id, member)
                        VigilAsk(
                            standing: entry.value, heading: "To \(people.name(member)): waiting for you",
                            since: standing.deliveries.first { $0.to == member }?.since, answered: answered[key],
                            answer: { press in
                                try await acted(
                                    .answer(post: standing.post.id, to: member, press.answer, shown: press.shown, authenticated: press.ownerAuthenticated),
                                    on: key)
                            }, pressedByPerson: host.pressedByPerson)
                    }
                    if requests.isEmpty {
                        ForEach(said, id: \.self) { Text($0).inkText(.detail) }
                    }
                    ForEach(notes, id: \.self) { Text($0).inkText(.detail) }
                    if revokes, let yes = standing.standing?.min(by: { $0.key.raw < $1.key.raw }) {
                        VigilStandingYes(until: yes.value) {
                            revoke(.revoke(post: standing.post.id, to: yes.key), on: Self.key(standing.post.id, yes.key))
                        }
                    }
                }
            }
        } picture: {
            people.picture($0)
        } change: { before, after in
            DiffView(old: before, new: after).diffLineNumbers(.hidden)
        } empty: {
            if let why = chats.failures[chat] {
                Text("This chat could not be read: \(why)").inkText(.detail)
            } else if page == nil {
                Text("Reading this chat…").inkText(.detail)
            } else {
                Text("Nothing said here yet.").inkText(.detail)
            }
        }
        .onAppear { chats.show(chat) }
        .onDisappear { chats.hide(chat) }
        // Read is asked when a post arrives, when the window comes to the
        // front, and when a hand moves over the chat: each an event, and
        // the hand itself is the host's seen rule.
        .onChange(of: posts.last?.post.id, initial: true) { markRead() }
        .onChange(of: front) { markRead() }
        #if os(macOS)
        .onHover { if $0 { markRead() } }
        #endif
        // A chat an agent proposed, waiting for the person's one yes.
        if let page, let request = page.request {
            VigilAsk(
                standing: request, heading: "Waiting for you", answered: answered[chat.raw],
                answer: { press in
                    try await acted(.answerChat(chat, press.answer, shown: press.shown, authenticated: press.ownerAuthenticated), on: chat.raw)
                }, pressedByPerson: host.pressedByPerson
            )
            .padding(8)
        }
        // What the host asks about the pane of the one agent this chat is with.
        ForEach(asks(page, people)) { ask in
            let run = host.answer
            VigilAsk(standing: ask, answer: { press in try await run(press) }, pressedByPerson: host.pressedByPerson)
                .padding(8)
        }
        InkComposer(
            text: $draft, prompt: "Message \(page.map { people.title($0.chat) } ?? "this chat")",
            replying: replying.flatMap { id in messages.first { $0.id == id } }.map { InkChat.Answered($0, people: people.all) },
            editing: editing != nil, blocked: failure, cancel: { cancel() }
        ) { words in
            send(words)
        }
        #if os(iOS)
            .navigationDestination(item: $opened) { file in
                VigilFilePage(file: file, read: host.read(file))
                    .navigationTitle(file.name)
                    .toolbarTitleDisplayMode(.inline)
            }
        #endif
    }

    private static func key(_ post: PostID, _ member: MemberID) -> String { "\(post.raw)/\(member.raw)" }

    // MARK: A post as Ink draws it

    private static func message(_ standing: Messages.Standing, people: VigilChatPeople) -> InkChat.Message {
        let post = standing.post
        let removed = post.removed != nil
        return InkChat.Message(
            post.id.raw, from: post.by.raw, at: Date(timeIntervalSince1970: post.at), words(standing),
            answers: post.replyTo?.raw,
            reactions: InkChat.Reaction.counted(
                (standing.reactions ?? []).map { .init($0.emoji, by: $0.by.raw) }, me: VigilChatPeople.you, name: people.name),
            delivery: removed ? nil : delivery(standing.deliveries), edited: !removed && !post.edits.isEmpty,
            earlier: removed ? [] : post.edits.map { $0.content.map(\.words).joined(separator: "\n\n") })
    }

    /// Its words now, or what became of them once it was removed.
    private static func words(_ standing: Messages.Standing) -> String {
        guard standing.post.removed != nil else { return standing.post.words }
        let reached = standing.deliveries.contains { $0.stage.mayHaveReachedAgent && $0.ending?.outcome != .withdrawn }
        return reached ? "*Removed here. An agent already has it.*" : "*Removed.*"
    }

    /// How a post stands on its way, as one mark: the least far of its
    /// deliveries, so a post waiting anywhere says it waits.
    private static func delivery(_ deliveries: [Messages.Delivery]) -> InkChat.Delivery? {
        let marks: [InkChat.Delivery] = deliveries.compactMap { delivery in
            if let ending = delivery.ending {
                switch ending.outcome {
                case .entered: return .recorded
                case .refused: return .refused
                case .expired: return .expired
                case .unknown: return .unknown
                case .withdrawn: return nil
                }
            }
            switch delivery.stage {
            case .waitingForPerson: return .awaitsApproval
            case .waitingForAgent: return .awaitsAgent
            case .handed: return .handed
            }
        }
        let order: [InkChat.Delivery] = [.awaitsApproval, .awaitsAgent, .refused, .expired, .unknown, .handed, .recorded]
        return order.first(where: marks.contains)
    }

    /// Why each delivery stands where it does, when its host said: to whom,
    /// then the host's words.
    private static func notes(_ standing: Messages.Standing, people: VigilChatPeople) -> [String] {
        standing.deliveries.flatMap { delivery -> [String] in
            let said = [delivery.ending?.said ?? delivery.said].compactMap { $0 } + (standing.consider?[delivery.to] ?? [])
            return said.map { "\(people.name(delivery.to)): \($0)" }
        }
    }

    private func asks(_ page: Messages.Page?, _ people: VigilChatPeople) -> [Asks.Standing] {
        guard let page else { return [] }
        let others = page.chat.present.filter { $0 != .you }
        guard others.count == 1, let pane = people.pane(others[0]) else { return [] }
        return chats.asks.filter { $0.panes.contains(pane) }
    }

    // MARK: Acts

    /// A file a post names, pressed: the app's place for files, else a page
    /// pushed here. A folder is revealed in Finder (only this Mac's are links).
    private func open(_ file: VigilMentionedFile) {
        #if os(macOS)
            if file.folder {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                return
            }
        #endif
        if let openFile = host.openFile {
            openFile(file, pane)
        } else {
            opened = file
        }
    }

    private func acts(_ byID: [String: Messages.Standing], _ people: VigilChatPeople) -> InkChat.Acts {
        InkChat.Acts(
            reply: { message in
                editing = nil
                replying = message.id
            },
            react: { message, emoji in
                let given = message.reactions.contains { $0.emoji == emoji && $0.mine }
                act(.react(PostID(message.id), emoji: emoji, on: !given))
            },
            edit: { message in
                // The person corrects their own, while it stands.
                guard let post = byID[message.id]?.post, post.by == .you, post.removed == nil else { return }
                replying = nil
                editing = message.id
                draft = post.words
            },
            remove: { message in act(.remove(PostID(message.id))) },
            copy: { message in VigilPasteboard.copy(byID[message.id]?.post.words ?? message.words) },
            open: { message in
                guard let pane = byID[message.id].flatMap({ people.pane($0.post.by) }) else { return }
                host.open(pane)
            })
    }

    private func cancel() {
        replying = nil
        editing = nil
        draft = ""
        failure = nil
    }

    private func send(_ words: String) {
        if let why = Messages.Post.problem(words) {
            failure = why
            return
        }
        if let editing {
            cancel()
            act(.edit(PostID(editing), words: words))
            return
        }
        let say = Messages.Say(chat: chat, words: words, replyTo: replying.map(PostID.init))
        let post = host.post
        cancel()
        Task {
            do { _ = try await post(say) } catch {
                // Never lost: what was not sent is back in the composer.
                if draft.isEmpty { draft = words }
                failure = "Not sent: \(error)"
            }
        }
    }

    private func act(_ what: Messages.Act.What) {
        let run = host.act
        Task {
            do { _ = try await run(what) } catch { failure = "\(error)" }
        }
    }

    /// The person's answer on what waits for them here (`VigilAsk` checked
    /// it was theirs): what came of it, kept to be said where it was pressed.
    private func acted(_ what: Messages.Act.What, on key: String) async throws -> String {
        let said = try await host.act(what).said
        answered[key] = said
        return said
    }

    /// The person ends a lasting answer: what came of it is said where it
    /// was pressed. Checked in the press's own turn: a program driving the
    /// app ends nothing.
    private func revoke(_ what: Messages.Act.What, on key: String) {
        guard host.pressedByPerson() else {
            answered[key] = "Not ended: only a click of yours ends it here."
            return
        }
        let run = host.act
        Task {
            do { answered[key] = try await run(what).said } catch { answered[key] = "Not ended: \(error)" }
        }
    }

    /// What a person had in front of them is read: while the chat is in
    /// front and a hand on this device followed its first unread post (the
    /// app's seen rule), the person's read mark moves to the newest post
    /// shown. The view merely existing reads nothing.
    private func markRead() {
        guard front, let page, let newest = page.posts.last?.post.position, newest > page.read, newest > marking,
              let first = page.posts.first(where: { ($0.post.position ?? 0) > page.read && $0.post.by != .you }),
              host.handAfter(first.post.at)
        else { return }
        marking = newest
        let run = host.act, chat = chat
        Task {
            do { _ = try await run(.read(chat, through: newest)) } catch { marking = 0 }
        }
    }
}

/// The pasteboard of the platform the view runs on.
enum VigilPasteboard {
    @MainActor static func copy(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}
