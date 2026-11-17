import Foundation
import Ink
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

/// A pane as a thread names it.
struct VigilChatPane: Equatable, Sendable {
    /// What its row is called: the one naming rule (`Directory.titles`).
    var title: String
    /// Its Mac's name, when it is not this one.
    var mac: String?

    var said: String { mac.map { "\(title) on \($0)" } ?? title }
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
}

/// Every thread, and the one chosen beside the list.
struct VigilChat: View {
    let threads: [MessageThread]
    let host: VigilChatHost
    @Binding var chosen: String?

    var body: some View {
        let thread = threads.first { $0.id == chosen }
        let people = VigilChatPeople(threads: threads, host: host)
        InkChat(
            title: thread.map { people.title(of: $0.key) },
            detail: thread.map { VigilThreadWords.detail($0, people: people) },
            open: thread != nil
        ) {
            InkConversations(
                threads.map { people.summary($0) }, selection: $chosen, people: people.all, me: Message.you,
                picture: { _ in EmptyView() },
                empty: {
                    Text("No messages yet. An agent's message to another, or to you (`vigil send you`), starts a thread here.")
                        .inkText(.detail)
                })
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

    var body: some View {
        let people = VigilChatPeople(threads: thread.map { [$0] } ?? [], host: host)
        InkChat.Column(title: people.title(of: key), detail: thread.map { VigilThreadWords.detail($0, people: people) }) {
            VigilThreadConversation(key: key, thread: thread, people: people, host: host)
        }
    }
}

/// Who speaks in threads, as Ink names people: the person, each pane's
/// agent or command, each watch and feed.
struct VigilChatPeople {
    let all: [InkChat.Person]
    let host: VigilChatHost
    private let names: [String: String]

    @MainActor init(threads: [MessageThread], host: VigilChatHost) {
        self.host = host
        var people: [String: InkChat.Person] = [Message.you: InkChat.Person(Message.you, name: "You")]
        for thread in threads {
            let own = Self.key(root: thread.key.root, pane: thread.key.pane)
            if people[own] == nil { people[own] = Self.paneAgent(own, host.name(thread.key.root, thread.key.pane), kind: .agent) }
            for item in thread.items {
                let from = item.record.message.from
                let key = Self.key(of: item)
                guard people[key] == nil else { continue }
                switch from.kind {
                case .person: break
                case .agent, .tool:
                    let pane = from.pane.map { host.name(item.senderRoot, $0) } ?? VigilChatPane(title: from.agent ?? "a command")
                    people[key] = Self.paneAgent(key, pane, kind: from.kind)
                case .watch: people[key] = InkChat.Person(key, name: "watch \(from.watch ?? "")", symbol: "binoculars")
                case .feed: people[key] = InkChat.Person(key, name: "feed \(from.watch ?? "")", symbol: "dot.radiowaves.up.forward")
                }
            }
        }
        all = people.values.sorted { $0.id < $1.id }
        names = people.mapValues(\.name)
    }

    private static func paneAgent(_ key: String, _ pane: VigilChatPane, kind: Message.Sender.Kind) -> InkChat.Person {
        InkChat.Person(key, name: pane.said, short: pane.title, symbol: kind == .agent ? "sparkles" : "terminal")
    }

    static func key(root: String, pane: String) -> String { "pane:\(root)/\(pane)" }

    /// The sender's key among the people.
    static func key(of item: MessageThread.Item) -> String {
        let from = item.record.message.from
        switch from.kind {
        case .person: return Message.you
        case .agent, .tool: return from.pane.map { key(root: item.senderRoot, pane: $0) } ?? "\(from.kind.rawValue):\(from.agent ?? "")"
        case .watch, .feed: return "\(from.kind.rawValue):\(from.watch ?? "")"
        }
    }

    @MainActor func title(of key: MessageThread.Key) -> String { host.name(key.root, key.pane).said }

    @MainActor func summary(_ thread: MessageThread) -> InkChat.Summary {
        let messages = VigilThreadWords.messages(thread, people: self)
        let read = InkChat.Summary(thread.id, title: title(of: thread.key), messages: messages, me: Message.you)
        // Unread is the thread's own count (its messages for the pane you have
        // not read), never every message after the first of them.
        return InkChat.Summary(
            read.id, title: read.title, people: read.people, from: read.from, line: read.line, at: read.at,
            unread: thread.unread, waits: read.waits)
    }

    func name(_ key: String) -> String { names[key] ?? key }
}

/// A record as Ink's message, in vigil's words.
enum VigilThreadWords {
    @MainActor static func messages(_ thread: MessageThread, people: VigilChatPeople) -> [InkChat.Message] {
        thread.items.map { message($0, in: thread, people: people) }
    }

    @MainActor static func message(_ item: MessageThread.Item, in thread: MessageThread, people: VigilChatPeople) -> InkChat.Message {
        let record = item.record, message = record.message
        // Where "go to" leads: the other end of the message from this thread's pane.
        let elsewhere = message.from.pane.map { (item.senderRoot, $0) }
            .flatMap { $0 == (thread.key.root, thread.key.pane) ? nil : $0 }
        let place = people.host.name(elsewhere?.0 ?? item.root, elsewhere?.1 ?? message.to.pane).said
        return InkChat.Message(
            record.id, from: VigilChatPeople.key(of: item), at: Date(timeIntervalSince1970: message.sent), words(record),
            answers: message.replyTo ?? message.corrects,
            reactions: InkChat.Reaction.counted(record.reactions.map { .init($0.emoji, by: $0.by) }, me: Message.you, name: people.name),
            delivery: message.to.isPerson ? nil : delivery(record.state), edited: record.edited != nil, place: place)
    }

    /// Its words, or what became of them when the person removed it.
    static func words(_ record: Message.Record) -> String {
        if record.state.kind == .withdrawn { return "*Removed before any agent had it.*" }
        if record.removed != nil {
            return record.state.kind.reachedAgent ? "*Removed here. The agent already has it.*" : "*Removed.*"
        }
        return record.message.body
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
        let waiting = thread.items.last { $0.record.waits }.map { $0.record.state.words }
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

    @State private var draft = ""
    @State private var replying: String?
    @State private var editing: String?
    @State private var failure: String?

    private var items: [MessageThread.Item] { thread?.items ?? [] }

    var body: some View {
        let messages = thread.map { VigilThreadWords.messages($0, people: people) } ?? []
        InkConversation(
            messages, people: people.all, me: Message.you, unread: thread?.firstUnread, acts: acts(messages)
        ) {
            MarkdownView($0.words)
        } empty: {
            Text("Nothing said here yet. What you write goes to this pane's agent as yours.").inkText(.detail)
        }
        .task(id: thread?.items.filter { $0.record.unread }.map(\.id)) { markRead() }
        InkComposer(
            text: $draft, prompt: "Message \(people.title(of: key))",
            replying: replying.flatMap { id in messages.first { $0.id == id } }.map { InkChat.Answered($0, people: people.all) },
            editing: editing != nil, blocked: failure, cancel: { cancel() }
        ) { words in
            send(words)
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
                guard let record = record(message.id), !record.state.kind.final else { return }
                replying = nil
                editing = message.id
                draft = record.message.body
            },
            remove: { message in act(.remove(message.id), on: message.id) },
            copy: { message in VigilChatPasteboard.copy(record(message.id)?.message.body ?? message.words) },
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

    private func record(_ id: String) -> Message.Record? { items.first { $0.id == id }?.record }
    private func root(of id: String) -> String { items.first { $0.id == id }?.root ?? key.root }

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

    /// What the person has in front of them is read: the thread's unread
    /// messages, marked on the Mac that holds each.
    private func markRead() {
        let unread = Dictionary(grouping: items.filter { $0.record.unread }, by: \.root)
        let run = host.act
        for (root, items) in unread {
            let ids = items.map(\.id)
            Task { _ = try? await run(.read(ids), root) }
        }
    }
}

/// The pasteboard of the platform the view runs on.
enum VigilChatPasteboard {
    @MainActor static func copy(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}
