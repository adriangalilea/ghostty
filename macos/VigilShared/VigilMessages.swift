import AuthzProtocol
import Foundation
import GitViews
import Ink
import LocalAuthentication
import MarkdownText
import SwiftUI
import VigilWire

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// The person's threads with agents (harness/README.md "Messages"), drawn
/// with Ink's chat family and nothing of its own: the whole window (every
/// thread of every Mac, `VigilChat`) and one pane's thread as a column
/// beside it (`VigilThreadColumn`). What the threads hold is worked out by
/// `MessageThreads` from each Mac's mailbox; where a message goes, what an
/// act does and where "go to" leads are the host's (`VigilChatHost`).

/// vigil's message, named where AuthzUI's own `Message` is in scope too
/// (`VigilMessageRequest`); the module's name is an enum's too, so it cannot
/// qualify it.
typealias VigilMessage = Message

/// The threads and counts every view reads, worked out once per change of
/// the mailboxes, off the main thread, by the store that follows them (the
/// Mac's `VigilMessageStore`, the phone's): no view computes them. Each view
/// once rebuilt every thread of every Mac at every render, and every record
/// that changed was a render: a read of 220 drained the count one by one.
struct VigilMessageIndex: Equatable, Sendable {
    var threads: [MessageThread] = []
    var list: [VigilListedThread] = []
    var conversations: [MessageThread] { list.map(\.thread) }
    /// Each pane's every thread as one, by "root/pane" (`MessageThreads.panes`).
    var panes: [String: MessageThread] = [:]
    var pending: [String: [String: MessageThreads.Pending]] = [:]
    var awaiting: [String: [String: Set<String>]] = [:]
    var forYou: [MessageThreads.ForYou] = []
    var traffic = MessageThreads.Traffic()

    init() {}
    init(_ mailboxes: [String: [String: Message.Record]], asks: [String: [PaneAsk]], chats: [String: [Chat]] = [:]) {
        threads = MessageThreads.threads(mailboxes)
        var conversations = MessageThreads.conversations(mailboxes)
        // A group with nothing said yet is listed too, and one that waits for
        // the person's yes first of all.
        let listed = Set(conversations.filter { $0.chat != nil }.map { $0.key.root + "/" + $0.key.pane })
        for (root, held) in chats {
            for chat in held where !listed.contains(root + "/" + MessageThread.chatPane(chat.id)) {
                let empty = MessageThread(key: .init(root: root, pane: MessageThread.chatPane(chat.id), conversation: nil), items: [])
                if chat.allowed { conversations.append(empty) } else { conversations.insert(empty, at: 0) }
            }
        }
        traffic = MessageThreads.Traffic(mailboxes, conversations: conversations)
        list = conversations.map(VigilListedThread.init)
        panes = MessageThreads.panes(threads)
        forYou = MessageThreads.forYou(conversations)
        pending = MessageThreads.pending(forYou: forYou)
        var awaiting = MessageThreads.awaitingYou(mailboxes)
        // A pane's hand counts what vigil asks about it too.
        for (root, list) in asks {
            for ask in list {
                for pane in ask.panes { awaiting[root, default: [:]][pane, default: []].insert(ask.id) }
            }
        }
        self.awaiting = awaiting
        for (root, groups) in chats {
            for group in groups where group.request != nil {
                for member in group.members { self.awaiting[root, default: [:]][member.pane, default: []].insert(group.id) }
            }
        }
    }

    /// A pane's every thread as one, keyed by `key` (the conversation it holds).
    func pane(_ key: MessageThread.Key) -> MessageThread? {
        guard var thread = panes["\(key.root)/\(key.pane)"] else { return nil }
        thread.key = key
        return thread
    }
}

/// The mailbox supplies everything in a list row except its live pane names.
/// Opening the list should never build a conversation's bubbles for its preview.
struct VigilListedThread: Equatable, Sendable {
    let thread: MessageThread
    let speakers: [MessageThread.Item]
    let people: [String]
    let from: String?
    let line: String?
    let at: Date?
    let unread: Int
    let waits: Bool
    let delivery: InkChat.Delivery?

    init(_ thread: MessageThread) {
        self.thread = thread
        var seen: Set<String> = [Message.you]
        var speakers: [MessageThread.Item] = []
        var people: [String] = []
        for item in thread.items {
            let sender = VigilChatPeople.key(of: item)
            if seen.insert(sender).inserted {
                speakers.append(item)
                people.append(sender)
            }
        }
        self.speakers = speakers
        self.people = people
        let last = thread.items.last
        from = last.map(VigilChatPeople.key(of:))
        line = last.map { InkChat.line(of: VigilThreadWords.words($0)) }
        at = last.map { Date(timeIntervalSince1970: $0.record.message.sent) }
        unread = thread.unread
        waits = thread.items.contains { !$0.record.message.to.isPerson && $0.latest.state.kind == .awaitingApproval }
        delivery = last.flatMap {
            $0.record.message.from.kind == .person && !$0.record.message.to.isPerson ? VigilThreadWords.delivery($0.latest.state) : nil
        }
    }

    func summary(title: String) -> InkChat.Summary {
        InkChat.Summary(thread.id, title: title, people: people, from: from, line: line, at: at,
                        unread: unread, waits: waits, delivery: delivery)
    }
}

/// A pane as a thread names it: its agent's name and face in every bubble
/// and every thread's head.
struct VigilChatPane: Equatable, Sendable {
    /// What it is called: its member's name, else its agent's conversation,
    /// else its row's name.
    var title: String
    /// Its face: its pane's or workspace's emoji, else its member's.
    var face: String?
    /// Its member's tint, minted once and kept (`Member.tint`): the same
    /// colour on every surface.
    var tint: String?
    /// Its Mac's name, when it is not this one.
    var mac: String?
    /// The agent program it holds ("claude", "codex"), from its conversation;
    /// nil: none known (a shell, a command).
    var program: String? = nil

    var said: String { mac.map { "\(title) on \($0)" } ?? title }

    /// The one rule every surface names a pane's agent by (CHATS.md, decided
    /// 2026-11-19: one look per agent everywhere): the member the pane holds,
    /// as its Mac's broker stated it (`Members.look`: its name, never a
    /// prompt's first words, and its tint), else the conversation's name
    /// from the pane's glance, else its row's name (`Directory.titles`); its
    /// pane's or workspace's emoji, else its member's face; its Mac when it
    /// is not this one.
    static func of(
        alias: String? = nil, member: (name: String?, face: String?, tint: String?)? = nil, conversation: String?, title: String, face: String?,
        mac: String?, program: String? = nil
    ) -> VigilChatPane {
        let emoji = face.flatMap { $0.isEmpty ? nil : $0 }
        return VigilChatPane(
            title: alias ?? conversation ?? member?.name ?? title, face: emoji ?? member?.face, tint: member?.tint, mac: mac, program: program)
    }
}

/// What a host that cannot do something says.
enum VigilChatError: Error, CustomStringConvertible {
    case notHere
    var description: String { "group chats are written in from a Mac's Messages for now" }
}

/// What the views ask of the app that holds them.
struct VigilChatHost {
    /// This Mac's tether root: a record of another Mac is acted on there.
    var here: String?
    /// This Mac's own name, said as the person's sender.
    var macName: String
    /// A pane of the Mac `root`, as its rows name it.
    var name: @MainActor (_ root: String, _ pane: String) -> VigilChatPane
    /// A message posted to the mailbox of the Mac `root`.
    var post: @Sendable (_ message: Message, _ root: String) async throws -> Void
    /// The person's act on a record of the Mac `root`.
    var act: @Sendable (_ act: Message.Act, _ root: String) async throws -> Message.Acted
    /// Go to the pane `pane` of the Mac `root`.
    var open: @MainActor (_ root: String, _ pane: String) -> Void
    /// Whether a person's hand was on this device after the moment (unix
    /// seconds), or within the minute before: the app's seen rule
    /// (`VigilWorkspaces.personActed(after:)`). Read needs it.
    var handAfter: @MainActor (_ moment: Double) -> Bool
    /// One ask about the files a message names, of the Mac `root` they are
    /// on (`Open.mention`): which are files there, and one read.
    var mention: @Sendable (_ call: MentionCall, _ root: String) async throws -> Data
    /// A file a message names, shown where the host shows files, beside the
    /// pane of the thread it was pressed in (`key`). Nil: the conversation
    /// pushes its page itself (the phone).
    var openFile: (@MainActor (_ file: VigilMentionedFile, _ key: MessageThread.Key) -> Void)? = nil
    /// Whether the press being handled now is a person's: on the Mac, a
    /// hardware click (no posted event, no accessibility action), which an
    /// answer on a request needs, as Authz's own input guard does
    /// (authz.space SECURITY-REVIEW.md). Read inside the button's action.
    var pressedByPerson: @MainActor () -> Bool = { true }
    /// The questions vigil asks the person about the pane a thread is with
    /// (`PaneAsk`), as its Mac holds them now: drawn in the thread above the
    /// composer, answered there on their card.
    var asks: @MainActor (_ key: MessageThread.Key) -> [PaneAsk] = { _ in [] }
    /// A group chat of the Mac `root`, as it keeps it (`Chat`).
    var chat: @MainActor (_ root: String, _ id: String) -> Chat? = { _, _ in nil }
    /// The person's post in a group chat of the Mac `root` (`chat.post`).
    var postInChat: @Sendable (_ chat: String, _ body: String, _ replyTo: String?, _ root: String) async throws -> Void = { _, _, _, _ in
        throw VigilChatError.notHere
    }

    var activity: [MessageThreads.Activity] = []
    var groupPanes: [String: String] = [:]
    var createGroup: (@Sendable (String, [String]) async throws -> Chat)?

    /// Whether a folder on the Mac `root` can be shown here: revealed in
    /// this Mac's Finder, so only this Mac's own.
    func reveals(_ root: String) -> Bool {
        #if os(macOS)
            root == here
        #else
            false
        #endif
    }

    /// A named file's text from its Mac.
    func read(_ file: VigilMentionedFile) -> @Sendable () async throws -> DocumentText {
        let mention = mention
        return { try JSONDecoder().decode(DocumentText.self, from: await mention(.read(file.path), file.root)) }
    }
}

/// The Messages list (CHATS.md, decided 2026-11-19): every conversation
/// once, and a picker at its foot, All or one agent; opened from somewhere
/// specific it lands filtered there. `only` is its host's, so whoever opens
/// it (a pane's hand, envelope or menu on the Mac) says which agent. What
/// the Mac's window, its bar and the phone each list.
struct VigilThreadList: View {
    let list: [VigilListedThread]
    let people: VigilChatPeople
    @Binding var selection: String?
    @Binding var only: String?

    @State private var activity = false
    @State private var creating = false

    /// The agent a pane's end names, by Mac and pane.
    static func end(_ key: MessageThread.Key) -> String { "\(key.root)/\(key.pane)" }

    var body: some View {
        let host = people.host
        let ends = Set(list.flatMap { listed -> [String] in
            let thread = listed.thread
            if let id = thread.chat, let group = host.chat(thread.key.root, id) {
                return group.members.map { thread.key.root + "/" + $0.pane }
            }
            return ([thread.key] + [thread.with].compactMap { $0 }).map(Self.end)
        }).sorted()
        let shown = list.filter { row in
            guard let only else { return true }
            let thread = row.thread
            if let id = thread.chat, let group = host.chat(thread.key.root, id) {
                return group.members.contains { thread.key.root + "/" + $0.pane == only }
            }
            return Self.end(thread.key) == only || thread.with.map(Self.end) == only
        }
        let pending = shown.filter { row in row.thread.chat.flatMap { host.chat(row.thread.key.root, $0)?.request } != nil }
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $activity) {
                    Text("Threads").tag(false)
                    Text("Activity").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                if host.createGroup != nil {
                    Button { creating = true } label: { Image(systemName: "person.2.badge.plus") }
                        .accessibilityLabel("New Group").help("New Group")
                }
            }.padding(.inkGap)
            if activity {
                VigilActivityList(rows: host.activity, only: only, people: people)
            } else {
                ForEach(pending, id: \.thread.id) { row in
                    Button { selection = row.thread.id } label: {
                        Label("Review group · " + people.title(of: row.thread), systemImage: "hand.raised")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.inkGap)
                }
                InkConversations(
                    shown.filter { row in !pending.contains { $0.thread.id == row.thread.id } }
                        .map { $0.summary(title: people.title(of: $0.thread)) },
                    selection: $selection, people: people.all, me: Message.you, picture: { people.picture($0) },
                    empty: { if pending.isEmpty { Text("No conversations").inkText(.detail) } })
            }
            if ends.count > 1 {
                InkSelect(
                    "Show", selection: $only,
                    options: [InkSelectOption(String?.none, "All")]
                        + ends.map { end in InkSelectOption(Optional(end), people.title(ofEnd: end)) },
                    prompt: "All")
                .padding(.inkGap)
            }
        }
        .sheet(isPresented: $creating) { VigilNewMessageGroup(host: host) }

    }
}

/// Observation on this device only. The cursor advances when a person sees traffic.
@MainActor final class VigilActivityWatches: ObservableObject {
    static let shared = VigilActivityWatches()
    private let defaults: UserDefaults
    private let key = "vigil.messages.watchedPanes"
    private var state: MessageThreads.Watches
    private var traffic = MessageThreads.Traffic()
    @Published private(set) var dots: Set<String> = []
    @Published private(set) var watched: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MessageThreads.Watches.self, from: $0) } ?? .init()
        watched = Set(state.cursors.keys)
    }

    func update(_ traffic: MessageThreads.Traffic) {
        self.traffic = traffic
        let before = state
        state.receive(traffic)
        publish(since: before)
    }

    func toggle(_ pane: String) {
        let before = state
        state.toggle(pane, in: traffic)
        publish(since: before)
    }

    func seen(_ pane: String, at time: Double, id: String) {
        guard dots.contains(pane) else { return }
        let before = state
        state.see(pane, at: time, id: id)
        publish(since: before)
    }

    func seen(_ thread: MessageThread) {
        guard !dots.isEmpty else { return }
        // A pane can speak in many chats. Only clear the latest posts this thread shows.
        let visible = Set(thread.items.map { $0.root + "/" + ($0.record.message.post ?? $0.id) })
        for pane in dots {
            guard let newest = traffic.latest[pane] else { continue }
            for id in newest.ids.intersection(visible) { seen(pane, at: newest.at, id: id) }
        }
    }

    private func publish(since before: MessageThreads.Watches) {
        if state != before {
            defaults.set(try? JSONEncoder().encode(state), forKey: key)
            let keys = Set(state.cursors.keys)
            if watched != keys { watched = keys }
        }
        let changed = state.dots(in: traffic)
        if changed != dots { dots = changed }
    }
}

struct VigilTrafficDot: View {
    let panes: [String]
    @ObservedObject private var watches = VigilActivityWatches.shared
    var body: some View {
        if !watches.dots.isDisjoint(with: panes) {
            Circle().fill(.secondary).frame(width: 5, height: 5)
                .accessibilityLabel("New watched activity").help("New watched activity")
        }
    }
}

struct VigilWatchPaneActivity: View {
    let pane: String
    @ObservedObject private var watches = VigilActivityWatches.shared
    var body: some View {
        Button { watches.toggle(pane) } label: {
            Label(!watches.watched.contains(pane) ? "Watch activity" : "Stop watching activity", systemImage: "eye")
        }
    }
}

private struct VigilActivityList: View {
    let rows: [MessageThreads.Activity]
    let only: String?
    let people: VigilChatPeople
    #if os(macOS)
    @Environment(\.controlActiveState) private var active
    private var front: Bool { active == .key }
    #else
    @Environment(\.scenePhase) private var phase
    private var front: Bool { phase == .active }
    #endif

    var body: some View {
        let shown = only.map { pane in rows.filter { $0.panes.contains(pane) } } ?? rows
        List(shown) { row in
            let sender = people.name(VigilChatPeople.key(row.from, root: row.senderRoot))
            let to = row.recipients.map { people.title(ofEnd: $0) }.joined(separator: ", ")
            let group = row.chat.flatMap { people.host.chat(row.root, $0)?.name }
            VStack(alignment: .leading) {
                HStack {
                    Text(sender + " → " + (to.isEmpty ? (group ?? "You") : to)).lineLimit(2)
                    Spacer()
                    Text(Date(timeIntervalSince1970: row.sent), style: .time).font(.caption)
                }
                if let group, !to.isEmpty { Text(group).font(.caption).foregroundStyle(.secondary) }
                Text(InkChat.line(of: row.words)).lineLimit(1).foregroundStyle(.secondary)
            }
            .contextMenu {
                ForEach(row.panes.sorted(), id: \.self) { pane in
                    Menu(people.title(ofEnd: pane)) { VigilWatchPaneActivity(pane: pane) }
                }
            }
            .onAppear { mark(row) }
            .onChange(of: front) { mark(row) }
        }
        .overlay { if shown.isEmpty { Text("No activity").foregroundStyle(.secondary) } }
    }

    private func mark(_ row: MessageThreads.Activity) {
        guard front else { return }
        for end in row.panes where only == nil || only == end {
            VigilActivityWatches.shared.seen(end, at: row.arrived, id: row.id)
        }
    }
}

private struct VigilNewMessageGroup: View {
    let host: VigilChatHost
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var failure: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("New Group").font(.headline)
            TextField("Group name", text: $name)
            List(host.groupPanes.keys.sorted { (host.groupPanes[$0] ?? "", $0) < (host.groupPanes[$1] ?? "", $1) }, id: \.self) { pane in
                Toggle(host.groupPanes[pane] ?? pane, isOn: Binding(
                    get: { selected.contains(pane) },
                    set: { if $0 { selected.insert(pane) } else { selected.remove(pane) } }))
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") {
                    guard host.pressedByPerson(), let create = host.createGroup else {
                        failure = "Press Create directly to make this group."
                        return
                    }
                    creating = true
                    Task {
                        do { _ = try await create(name, selected.sorted()); dismiss() }
                        catch { failure = String(describing: error); creating = false }
                    }
                }.disabled(creating || !Chat.validName(name) || !(2...32).contains(selected.count))
            }
        }.padding().frame(minWidth: 280, minHeight: 320)
    }
}

/// Every thread, and the one chosen beside the list.
struct VigilChat: View {
    let list: [VigilListedThread]
    let host: VigilChatHost
    @Binding var chosen: String?
    /// Whose conversations the list shows: opened from nothing in
    /// particular, all.
    @State private var only: String?

    var body: some View {
        let thread = list.first { $0.thread.id == chosen }?.thread
        let people = VigilChatPeople(list: list, host: host)
        InkChat(
            title: thread.map { people.title(of: $0) },
            detail: thread.map { VigilThreadWords.detail($0, people: people) },
            open: thread != nil
        ) {
            VigilThreadList(list: list, people: people, selection: $chosen, only: $only)
        } conversation: {
            if let thread {
                VigilThreadConversation(key: thread.key, thread: thread, people: people, host: host)
                    .id(thread.id)
            }
        } tools: {
            if let thread {
                Button {
                    host.open(thread.key.root, thread.key.pane)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.inkTool)
                .inkTip("go to its pane")
            }
        }
        .onBack { chosen = nil }
    }
}

/// One pane's thread as a column: the aside beside the pane. A pane with no
/// message yet shows an empty conversation and its composer.
struct VigilThreadColumn: View {
    let key: MessageThread.Key
    let thread: MessageThread?
    let host: VigilChatHost
    /// The message it opens on (`VigilMessageStore.focus`): a pressed hand's.
    var focus: String? = nil

    var body: some View {
        let people = VigilChatPeople(threads: thread.map { [$0] } ?? [], host: host)
        InkChat.Column(title: people.title(of: key), detail: thread.map { VigilThreadWords.detail($0, people: people) }) {
            VigilThreadConversation(key: key, thread: thread, people: people, host: host, focus: focus)
        }
    }
}

/// A sender as a thread draws it, in the shape of the identity model's member
/// (`/tmp/identity/MODEL.md`: one kind for a person, an agent, a subagent, a
/// device, a watch and the system, each with a name, a face, a handle and a
/// kind). Every sender is drawn through it; today it is filled from what the
/// mailbox and the pane's rows know (`VigilChatPane.of`), and the identity
/// build changes only what fills it.
struct VigilChatMember: Equatable {
    enum Kind: Equatable { case person, agent, subagent, device, watch, system, tool }

    /// The key a message names it by among the thread's people.
    var key: String
    var name: String
    /// What its name is shortened to where room is short.
    var short: String?
    /// Its face, an emoji, where it wears one; else its kind's mark.
    var face: String?
    /// What a mention types ("@notice-design-1281"); none known yet.
    var handle: String?
    var kind: Kind
    /// The program behind an agent ("claude", "codex"): its mark where it wears no face.
    var program: String?
    /// How it stands to another member, said after its name ("subagent of @x").
    var relation: String?
    /// Its own colour, minted once and kept (`Member.tint`); nil: Ink's by order.
    var tint: String?

    /// The pane's agent or command, named by the pane's rows.
    static func pane(_ key: String, _ pane: VigilChatPane, kind: Kind, program: String?) -> VigilChatMember {
        VigilChatMember(
            key: key, name: pane.said, short: pane.title, face: pane.face, kind: kind, program: program ?? pane.program, tint: pane.tint)
    }

    /// What kind of member it is, as the badge on its face says it (CHATS.md,
    /// decided 2026-11-19: every agent has one look): Claude, Codex, a watch,
    /// a command. Nil for the person and anything with no badge of its own.
    var badge: (symbol: String, color: Color)? {
        switch kind {
        case .agent, .subagent:
            switch program {
            case "claude": ("asterisk", Color(red: 0.85, green: 0.47, blue: 0.34))
            case "codex": ("chevron.left.forwardslash.chevron.right", Color(red: 0.06, green: 0.64, blue: 0.50))
            default: ("terminal", .gray)
            }
        case .watch: ("binoculars", .indigo)
        case .tool: ("terminal", .gray)
        case .person, .system, .device: nil
        }
    }

    /// The member as Ink draws a sender, in its own colour.
    var person: InkChat.Person {
        InkChat.Person(
            key, name: name, short: short, handle: handle, symbol: symbol, tint: tint.flatMap(InkTint.init), relation: relation)
    }

    /// Its mark where it wears no face: a person has none (their initial), an
    /// agent its program's, else the terminal it runs in (never a generic sparkle).
    private var symbol: String? {
        switch kind {
        case .person: nil
        case .watch: "binoculars"
        case .system: "gearshape"
        case .device: "laptopcomputer"
        case .tool: "terminal"
        case .agent, .subagent:
            switch program {
            case "claude": "asterisk"
            case "codex": "chevron.left.forwardslash.chevron.right"
            default: "terminal"
            }
        }
    }
}

/// Who speaks in threads: the person, each pane's agent or command, each
/// watch and feed, as members.
struct VigilChatPeople {
    let all: [InkChat.Person]
    let host: VigilChatHost
    private let members: [String: VigilChatMember]

    @MainActor init(threads: [MessageThread], host: VigilChatHost) {
        self.init(speakers: threads.map { ($0.key, $0.items) }, host: host)
    }

    @MainActor init(list: [VigilListedThread], host: VigilChatHost) {
        self.init(speakers: list.map { ($0.thread.key, $0.speakers) }, host: host)
    }

    @MainActor private init(speakers: [(MessageThread.Key, [MessageThread.Item])], host: VigilChatHost) {
        self.host = host
        var members: [String: VigilChatMember] = [
            Message.you: VigilChatMember(key: Message.you, name: "You", kind: .person)
        ]
        for (thread, items) in speakers {
            let own = Self.key(root: thread.root, pane: thread.pane)
            for item in items {
                let from = item.record.message.from
                let key = Self.key(of: item)
                guard members[key] == nil else { continue }
                switch from.kind {
                case .person: break
                case .agent, .tool:
                    let kind: VigilChatMember.Kind = from.kind == .agent ? .agent : .tool
                    members[key] = .pane(
                        key, from.pane.map { host.name(item.senderRoot, $0) } ?? VigilChatPane.of(conversation: nil, title: from.agent ?? "a command", face: nil, mac: nil),
                        kind: kind, program: from.agent)
                case .watch: members[key] = VigilChatMember(key: key, name: "watch \(from.watch ?? "")", kind: .watch)
                case .feed: members[key] = VigilChatMember(key: key, name: "feed \(from.watch ?? "")", kind: .watch)
                }
            }
            if members[own] == nil {
                members[own] = .pane(own, host.name(thread.root, thread.pane), kind: .agent, program: nil)
            }
        }
        all = members.values.map(\.person).sorted { $0.id < $1.id }
        self.members = members
    }

    /// A sender's face: their pane's workspace emoji where it wears one, with
    /// its kind's badge at its corner (Claude, Codex, a watch, a command), so
    /// two agents of one workspace are told apart; else Ink's own (the
    /// agent's mark, the person's initial). Its colour is the member's tint,
    /// which Ink draws around it.
    @ViewBuilder func picture(_ person: InkChat.Person) -> some View {
        if let member = members[person.id], let face = member.face {
            GeometryReader { g in
                let side = min(g.size.width, g.size.height)
                Text(face)
                    .font(.system(size: (side * 0.62).rounded()))
                    .frame(width: g.size.width, height: g.size.height)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = member.badge {
                            Image(systemName: badge.symbol)
                                .font(.system(size: (side * 0.22).rounded(), weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: side * 0.42, height: side * 0.42)
                                .background(badge.color, in: Circle())
                                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                                .accessibilityLabel(member.program ?? "\(member.kind)")
                        }
                    }
            }
        }
    }

    static func key(root: String, pane: String) -> String { "pane:\(root)/\(pane)" }

    /// The sender's key among the people.
    static func key(of item: MessageThread.Item) -> String {
        key(item.record.message.from, root: item.senderRoot)
    }

    static func key(_ from: Message.Sender, root: String) -> String {
        switch from.kind {
        case .person: return Message.you
        case .agent, .tool: return from.pane.map { key(root: root, pane: $0) } ?? "\(from.kind.rawValue):\(from.agent ?? "")"
        case .watch, .feed: return "\(from.kind.rawValue):\(from.watch ?? "")"
        }
    }

    @MainActor func title(of key: MessageThread.Key) -> String { host.name(key.root, key.pane).said }
    /// A thread's name: its pane's, or both ends' for a conversation between
    /// two agents, listed once.
    @MainActor func title(of thread: MessageThread) -> String {
        // A group says it is one: its face (people when it has none), its
        // name and how many are in it, you among them.
        if let id = thread.chat {
            let chat = host.chat(thread.key.root, id)
            return "\(chat?.face ?? "👥") \(chat?.name ?? "a group") · \((chat?.members.count ?? 0) + 1)"
        }
        return thread.with.map { "\(title(of: thread.key)) ↔ \(title(of: $0))" } ?? title(of: thread.key)
    }
    /// An end of the list's picker (`VigilThreadList.end`, "root/pane") by name.
    @MainActor func title(ofEnd end: String) -> String {
        guard let slash = end.firstIndex(of: "/") else { return end }
        return host.name(String(end[..<slash]), String(end[end.index(after: slash)...])).said
    }

    func name(_ key: String) -> String { members[key]?.name ?? key }
}

/// A record as Ink's message, in vigil's words.
enum VigilThreadWords {
    /// Mailbox changes arrive as snapshots. Most append a row or change one
    /// delivery state. Keep the previous rendering inputs for this conversation.
    @MainActor final class Projection {
        private var items: [MessageThread.Item] = []
        private var rendered: [InkChat.Message] = []
        private var people: [InkChat.Person] = []

        func messages(_ thread: MessageThread?, people current: VigilChatPeople) -> [InkChat.Message] {
            let next = thread?.items ?? []
            let samePeople = people == current.all
            var places: [MessageThread.Key: String] = [:]
            if rendered.count > next.count { rendered.removeLast(rendered.count - next.count) }
            for (index, item) in next.enumerated() {
                let end = VigilThreadWords.otherEnd(of: item, from: thread?.key)
                let place: String
                if let known = places[end] {
                    place = known
                } else {
                    place = current.host.name(end.root, end.pane).said
                    places[end] = place
                }
                if index < rendered.count, items[index] == item, rendered[index].place == place,
                   samePeople || item.record.reactions.isEmpty { continue }
                let row = VigilThreadWords.message(item, place: place, people: current)
                if index < rendered.count { rendered[index] = row } else { rendered.append(row) }
            }
            items = next
            people = current.all
            return rendered
        }
    }

    /// Where “go to” leads from this thread's pane. Conversations in the
    /// same pane share a display name.
    private static func otherEnd(of item: MessageThread.Item, from key: MessageThread.Key?) -> MessageThread.Key {
        let message = item.record.message
        if let pane = message.from.pane, item.senderRoot != key?.root || pane != key?.pane {
            return .init(root: item.senderRoot, pane: pane, conversation: nil)
        }
        return .init(root: item.root, pane: message.to.pane, conversation: nil)
    }

    @MainActor private static func message(_ item: MessageThread.Item, place: String, people: VigilChatPeople) -> InkChat.Message {
        let record = item.record, message = record.message
        // One bubble per message: its corrections are its edits (`MessageThreads`
        // folds them), so it says its newest words, stands as they stand, and
        // its "edited" opens the words before.
        let removed = item.record.removed != nil || record.state.kind == .withdrawn
        return InkChat.Message(
            record.id, from: VigilChatPeople.key(of: item), at: Date(timeIntervalSince1970: message.sent), words(item),
            answers: message.replyTo,
            reactions: InkChat.Reaction.counted(record.reactions.map { .init($0.emoji, by: $0.by) }, me: Message.you, name: people.name),
            delivery: message.to.isPerson ? nil : delivery(item.latest.state), edited: !removed && item.edited,
            earlier: removed ? [] : item.earlier, place: place)
    }

    /// Its words now, or what became of them when the person removed it.
    static func words(_ item: MessageThread.Item) -> String {
        let record = item.record
        if record.state.kind == .withdrawn { return "*Removed before any agent had it.*" }
        if record.removed != nil {
            return item.every.contains { $0.record.state.kind.reachedAgent }
                ? "*Removed here. The agent already has it.*" : "*Removed.*"
        }
        return item.words
    }

    /// How it stands on its way, as Ink marks it; nil where it has no way
    /// to go any more because the person took it back.
    static func delivery(_ state: Message.State) -> InkChat.Delivery? {
        switch state {
        case .accepted: .accepted
        case .awaitingApproval: .awaitsApproval
        case .awaitingAgent: .awaitsAgent
        case .handed: .handed
        case .recorded: .recorded
        case .refused: .refused
        case .expired: .expired
        case .unknown: .unknown
        case .withdrawn, .forYou: nil
        }
    }

    /// The thread's head: who is in it, and why the person's own wait when
    /// they do (delivery switched off for that agent program, no agent in
    /// the pane), in the mailbox's own words.
    @MainActor static func detail(_ thread: MessageThread, people: VigilChatPeople) -> String {
        let waiting = thread.items.flatMap(\.every).last { $0.record.waits }.map { $0.record.state.words }
        let others = Set(thread.items.map { VigilChatPeople.key(of: $0) }).subtracting([Message.you]).map(people.name).sorted()
        let who = ListFormatter.localizedString(byJoining: others + ["you"])
        return waiting.map { "Yours is \($0)" } ?? who
    }
}

/// A thread's messages and the composer under them: the draft, what is
/// answered and what is edited are held here; every act goes to the Mac
/// whose mailbox holds the record.
struct VigilThreadConversation: View {
    let key: MessageThread.Key
    let thread: MessageThread?
    let people: VigilChatPeople
    let host: VigilChatHost
    /// The message it opens on, scrolled to and marked while it waits on the
    /// person (InkConversation's `focus`); nil, its newest.
    var focus: String? = nil

    @State private var projection = VigilThreadWords.Projection()
    @State private var draft = ""
    @State private var replying: String?
    @State private var editing: String?
    @State private var failure: String?
    /// The ids a read is on its way for: asked once.
    @State private var marking: Set<String> = []
    /// A file a message names, pushed as its page where the host has no
    /// place of its own for files.
    @State private var opened: VigilMentionedFile?
    #if os(macOS)
        @Environment(\.controlActiveState) private var active
        /// In front: its window is the key one.
        private var front: Bool { active == .key }
    #else
        @Environment(\.scenePhase) private var phase
        private var front: Bool { phase == .active }
    #endif

    private var items: [MessageThread.Item] { thread?.items ?? [] }
    /// The newest message a standing yes let through: where its revoke is.
    private var newestByStandingYes: String? { items.last { $0.record.byStandingYes }?.id }

    var body: some View {
        let messages = projection.messages(thread, people: people)
        // Each row finds its record by id once, never by a walk of the thread.
        let byID = Dictionary(items.map { ($0.id, $0) }) { first, _ in first }
        let revokable = newestByStandingYes
        InkConversation(
            messages, people: people.all, me: Message.you, unread: thread?.firstUnread, focus: focus, acts: acts(messages)
        ) { message in
            let item = byID[message.id]
            // A request sits on the message it is about (CHATS.md, decided
            // 2026-11-19), with what came of an answer given here.
            let asks = item.map { $0.record.awaitsYou || answered[$0.id] != nil } ?? false
            let revokes = !asks && item?.id == revokable
            VStack(alignment: .leading, spacing: 6) {
                VigilMessageWords(id: message.id, words: message.words, place: item?.mentionPlace, host: host, open: open)
                    // Something stands under the words: the foot (its time) takes
                    // a row of its own under it, never over its buttons.
                    .transformEnvironment(\.inkTailRoom) { if asks || revokes { $0 = nil } }
                if let item, asks {
                    VigilMessageRequest(item: item, answered: answered[item.id]) { answer($0, on: item.id) }
                } else if let item, revokes {
                    VigilStandingYes(item: item) { answer($0, on: item.id) }
                }
            }
        } picture: {
            people.picture($0)
        } change: { before, after in
            DiffView(old: before, new: after).diffLineNumbers(.hidden)
        } empty: {
            Text("Nothing said here yet. What you write goes to this pane's agent as yours.").inkText(.detail)
        }
        // Read is asked when what is unread changes, when the window comes to
        // the front, and when a hand moves over the thread: each an event,
        // and the hand itself is the host's seen rule.
        .onChange(of: thread?.unreadIDs, initial: true) { markRead() }
        .onChange(of: thread?.items.last?.id, initial: true) {
            if front, let thread { VigilActivityWatches.shared.seen(thread) }
        }
        .onChange(of: front) {
            if front, let thread { VigilActivityWatches.shared.seen(thread) }
            markRead()
        }
        #if os(macOS)
        .onHover { if $0 { markRead() } }
        #endif
        // A group an agent made waits for the person's one yes, here.
        if let id = MessageThread(key: key, items: []).chat, let chat = host.chat(key.root, id), !chat.allowed {
            VigilChatRequest(chat: chat, answered: answered[chat.id]) { answer($0, on: chat.id) }
        }
        // What vigil asks about this pane, answered here on its card.
        ForEach(host.asks(key)) { ask in
            VigilPaneAskRequest(ask: ask, answered: answered[ask.id]) { answer($0, on: ask.id) }
        }
        InkComposer(
            text: $draft, prompt: "Message \(thread.map { people.title(of: $0) } ?? people.title(of: key))",
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

    /// A file a message names, pressed: the host's place for files, else a
    /// page pushed here. A folder is revealed in Finder (only this Mac's are links).
    private func open(_ file: VigilMentionedFile) {
        #if os(macOS)
            if file.folder {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                return
            }
        #endif
        if let openFile = host.openFile {
            openFile(file, key)
        } else {
            opened = file
        }
    }

    private func acts(_ messages: [InkChat.Message]) -> InkChat.Acts {
        InkChat.Acts(
            reply: { message in
                editing = nil
                replying = message.id
            },
            react: { message, emoji in
                let given = message.reactions.contains { $0.emoji == emoji && $0.mine }
                act(.react(message.id, emoji, on: !given), on: message.id)
            },
            edit: { message in
                // The mailbox's own rule: a recorded one is corrected. An edit
                // is always of the message itself, whatever corrected it before.
                guard let item = item(message.id), item.record.editable else { return }
                replying = nil
                editing = message.id
                draft = item.words
            },
            // The message and every correction of it: none of its words stays
            // on its way once the person removed it.
            remove: { message in
                for one in item(message.id)?.every ?? [] where one.record.removed == nil {
                    act(.remove(one.id), on: one.id)
                }
            },
            copy: { message in VigilPasteboard.copy(item(message.id)?.words ?? message.words) },
            open: { message in
                guard let item = items.first(where: { $0.id == message.id }) else { return }
                let message = item.record.message
                if let pane = message.from.pane, (item.senderRoot, pane) != (key.root, key.pane) {
                    host.open(item.senderRoot, pane)
                } else {
                    host.open(item.root, message.to.pane)
                }
            })
    }

    private func item(_ id: String) -> MessageThread.Item? { items.first { $0.id == id } }
    private func root(of id: String) -> String {
        items.flatMap(\.every).first { $0.id == id }?.root ?? key.root
    }

    private func cancel() {
        replying = nil
        editing = nil
        draft = ""
        failure = nil
    }

    private func send(_ words: String) {
        if let editing {
            act(.edit(editing, body: words), on: editing)
            cancel()
            return
        }
        // In a group: one post, which its Mac gives every agent in it.
        if let chat = MessageThread(key: key, items: []).chat {
            let postInChat = host.postInChat, root = key.root, replyTo = replying
            cancel()
            Task {
                do { try await postInChat(chat, words, replyTo, root) } catch { failure = "Not sent: \(error)" }
            }
            return
        }
        let message = Message(
            from: .init(kind: .person, mac: host.macName),
            to: .init(pane: key.pane, conversation: key.conversation, root: key.root == host.here ? nil : key.root),
            body: words, sent: Date().timeIntervalSince1970, replyTo: replying)
        if let why = message.invalid() {
            failure = why
            return
        }
        let post = host.post, root = key.root
        cancel()
        Task {
            do { try await post(message, root) } catch { failure = "Not sent: \(error)" }
        }
    }

    private func act(_ act: Message.Act, on id: String) {
        let run = host.act, root = root(of: id)
        Task {
            do { _ = try await run(act, root) } catch { failure = "\(error)" }
        }
    }

    /// What the answer given here on each message came to, in the Mac's own
    /// words (`Message.Acted.said`): shown on the message, never discarded.
    @State private var answered: [String: String] = [:]

    /// The person's answer on a message waiting for their yes, or their
    /// revoke of the standing yes that let one through.
    private func answer(_ act: Message.Act, on id: String) {
        // Checked in the press's own turn, where its event is the one being
        // handled: a program driving the app answers nothing.
        guard host.pressedByPerson() else {
            answered[id] = "Not answered: only a click of yours answers it here."
            return
        }
        let run = host.act, root = root(of: id)
        Task {
            do {
                // A yes that needs the owner: owner authentication on this
                // device, before it is sent.
                if act.authenticated == true {
                    let context = LAContext()
                    _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "allow a stop")
                }
                let acted = try await run(act, root)
                answered[id] = acted.said
            } catch {
                answered[id] = "Not answered: " + ((error as? LAError)?.localizedDescription ?? "\(error)")
            }
        }
    }

    /// What a person had in front of them is read: while the thread is in
    /// front, its pane's unread messages that a hand on this device followed
    /// (`toMarkRead`, the host's seen rule), marked on the Mac that holds
    /// each. The view merely existing reads nothing.
    private func markRead() {
        guard front, let thread else { return }
        let due = thread.toMarkRead(handAfter: host.handAfter).filter { !marking.contains($0.id) }
        guard !due.isEmpty else { return }
        marking.formUnion(due.map(\.id))
        let run = host.act
        for (root, items) in Dictionary(grouping: due, by: \.root) {
            let ids = items.map(\.id)
            Task {
                do { _ = try await run(.read(ids), root) } catch { marking.subtract(ids) }
            }
        }
    }
}

/// A question vigil asks about the thread's pane (`PaneAsk`: a close, a line
/// typed or a key pressed into it from elsewhere), drawn where the person
/// is: what it would do, the exact line when there is one, how long it
/// waits, then its answers on its card. Refuse answers it through Authz;
/// its yes needs the owner, so Allow in Authz… opens its card in Authz on
/// this Mac (on the phone, it is allowed on its card in Authz).
struct VigilPaneAskRequest: View {
    let ask: PaneAsk
    let answered: String?
    let act: (Message.Act) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                (Text("\(ask.asker) asks · ") + Text(Date(timeIntervalSince1970: ask.since), format: .relative(presentation: .named)))
                    .inkText(.detail)
            }
            Text(ask.title).font(.headline)
            Text(ask.gist + ". " + ask.says).inkText(.detail)
            if let shell = ask.shell {
                Text(shell).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            if ask.authzOnly == true {
                // Asked by another app than vigil's broker (`vigil drive`):
                // its card in Authz is where it is answered.
                Text("Answer it on its card in Authz.").inkText(.detail)
            } else {
                HStack(spacing: 8) {
                    Button("Refuse") { act(.askRefuse(ask.id)) }.buttonStyle(.ink)
                    #if os(macOS)
                        Button("Allow in Authz…") { act(.askOpen(ask.id)) }.buttonStyle(.ink)
                    #else
                        Text("It is allowed on its card in Authz, once this device is unlocked.").inkText(.detail)
                    #endif
                }
                .focusable(false)
            }
            if let answered { Text(answered).inkText(.detail) }
        }
        .padding(8)
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
