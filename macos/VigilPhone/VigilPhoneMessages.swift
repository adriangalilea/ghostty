import AuthzProtocol
import Combine
import Ink
import SwiftUI
import TetherKit
import UIKit
import VigilLink
import VigilWire

/// Every Mac's mailbox as the person's view on the phone reads it
/// (harness/README.md "Messages"): each paired Mac's followed over tether
/// (`VigilLink.messages`: whole at every opening, then each change, reopened
/// the moment the Mac may be back), as the Mac app's `VigilMessageStore`
/// reads them through its hub. The threads, each pane's count and the names
/// a thread is drawn with come from here; the views are the Mac's own
/// (`VigilChat`, `VigilThreadColumn`, `MessagesMark`).
@MainActor
final class VigilPhoneMessages: ObservableObject {
    static let shared = VigilPhoneMessages()

    /// Each Mac's records by its tether root.
    @Published private(set) var mailboxes: [String: [String: Message.Record]] = [:]
    /// What the tree's rows draw of the mailboxes, apart from them: a
    /// receipt or a reaction moves `mailboxes` and repaints the chat, never
    /// the tree; only a changed count does.
    let marks = Marks()

    @MainActor
    final class Marks: ObservableObject {
        /// Every pane's count (`MessageThreads.pending`), replaced only when it differs.
        @Published fileprivate(set) var pending: [String: [String: MessageThreads.Pending]] = [:]
        /// The messages waiting on the person's yes, by Mac and pane, on both
        /// their panes (`MessageThreads.awaitingYou`), replaced only when it differs.
        @Published fileprivate(set) var awaiting: [String: [String: Set<String>]] = [:]

        func pending(root: String, pane: String) -> MessageThreads.Pending? { pending[root]?[pane] }
        func awaiting(root: String, pane: String) -> Set<String> { awaiting[root]?[pane] ?? [] }
        /// What the person has not read, on every Mac.
        var unread: Int { pending.values.flatMap(\.values).reduce(0) { $0 + $1.unread } }
    }

    private var node: TetherNode?
    /// Each Mac's mailbox follow, by its tether root.
    private var following: [String: Task<Void, Never>] = [:]
    private var receipts: VigilReceipts { VigilPhone.shared.receipts }

    private init() {}

    var threads: [MessageThread] { MessageThreads.threads(mailboxes) }
    /// Every conversation listed once: what the Messages screen lists.
    var conversations: [MessageThread] { MessageThreads.conversations(mailboxes) }

    /// A pane's every thread as one: what its mode shows, holding exactly
    /// what its row mark counts.
    func paneThread(_ key: MessageThread.Key) -> MessageThread? {
        MessageThreads.pane(mailboxes, root: key.root, pane: key.pane, conversation: key.conversation)
    }

    // MARK: Following (VigilPhone says when the node is up and which Macs there are)

    func attach(node: TetherNode) {
        guard self.node == nil else { return }
        self.node = node
    }

    /// The paired Macs now: each one's mailbox followed, a Mac gone taken out.
    func macs(_ roots: Set<String>) {
        for (root, task) in following where !roots.contains(root) {
            task.cancel()
            following[root] = nil
        }
        mailboxes = mailboxes.filter { roots.contains($0.key) }
        for root in roots { follow(root) }
        recount()
    }

    /// Tether keeps the follow open and opens it again when the Mac may be
    /// back; out of reach, what it held is shown as it was. Only the node
    /// closing ends it: the Mac is followed afresh at the next word of the
    /// paired Macs.
    private func follow(_ root: String) {
        guard following[root] == nil, let node else { return }
        let steps = VigilLink.messages(node, device: root)
        following[root] = Task { [weak self] in
            for await step in steps {
                guard let self, !Task.isCancelled else { return }
                switch step.step {
                case .open: self.receipts.info("messages", "mailbox followed", ["mac": self.macName(root)])
                case .changes:
                    guard let changes = step.changes else { continue }
                    self.mailboxes[root] = changes.applied(to: self.mailboxes[root] ?? [:])
                    // An older Mac tells none: a whole with no asks says it holds none.
                    if let told = changes.asks { self.asks[root] = told } else if changes.whole { self.asks[root] = [] }
                    self.recount()
                case .waiting:
                    self.receipts.warn("messages", "mailbox out of reach", ["mac": self.macName(root), "why": step.reason ?? ""])
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.receipts.warn("messages", "mailbox follow ended", ["mac": self.macName(root)])
            self.following[root] = nil
        }
    }

    /// The questions each Mac asks about its panes now (`PaneAsk`), by root.
    @Published private(set) var asks: [String: [PaneAsk]] = [:]

    private func recount() {
        let next = MessageThreads.pending(mailboxes)
        if next != marks.pending { marks.pending = next }
        // A pane's hand counts what vigil asks about it too.
        var awaiting = MessageThreads.awaitingYou(mailboxes)
        for (root, list) in asks {
            for ask in list {
                for pane in ask.panes { awaiting[root, default: [:]][pane, default: []].insert(ask.id) }
            }
        }
        if awaiting != marks.awaiting { marks.awaiting = awaiting }
    }

    private func macName(_ root: String) -> String {
        VigilPhone.shared.hosts.first { $0.id == root }?.name ?? "a Mac"
    }

    // MARK: The host the views ask

    /// The phone is no Mac: every pane is another Mac's, named with it, and
    /// every message and act goes to that Mac over tether.
    var host: VigilChatHost {
        VigilChatHost(
            here: nil, macName: UIDevice.current.name,
            name: { root, pane in Self.pane(root: root, pane: pane) },
            post: { message, root in try await Self.post(message, root: root) },
            act: { act, root in try await Self.act(act, root: root) },
            open: { root, pane in Self.open(root: root, pane: pane) },
            // On the phone the thread on screen in an active scene (the
            // view's own `front`) is in the person's hand: the screen locks
            // when nobody holds it.
            handAfter: { _ in true },
            mention: { call, root in try await Self.mention(call, root: root) },
            asks: { key in VigilPhoneMessages.shared.asks[key.root]?.filter { $0.panes.contains(key.pane) } ?? [] })
    }

    /// An ask about the files a message names, of the Mac they are on.
    private static func mention(_ call: MentionCall, root: String) async throws -> Data {
        do {
            return try await VigilLink.call(linked(), device: root, .mention(call))
        } catch {
            shared.receipts.warn("messages", "mention not answered", ["mac": String(root.prefix(10)), "ask": call.kind.rawValue, "err": VigilLink.reason(error)])
            throw Failed(description: VigilLink.reason(error))
        }
    }

    private struct Failed: Error, CustomStringConvertible { let description: String }

    private static func linked() throws -> TetherNode {
        guard let node = shared.node else { throw WireError.refused("vigil is not connected to tether yet") }
        return node
    }

    /// The person's message, to the mailbox of the pane's Mac: its hub takes
    /// it as the person's on this phone's admission (harness/README.md
    /// "Messages"). What that Mac refused is said.
    private static func post(_ message: Message, root: String) async throws {
        let output: Data
        do { output = try await VigilLink.call(linked(), device: root, .message(message)) } catch {
            throw Failed(description: VigilLink.reason(error))
        }
        let standing = try JSONDecoder().decode(Message.Standing.self, from: output)
        shared.receipts.info("messages", "posted", ["id": message.id, "pane": message.to.pane, "state": standing.state.kind.rawValue])
        if case .refused(let why) = standing.state { throw Failed(description: "refused: \(why)") }
    }

    private static func act(_ act: Message.Act, root: String) async throws -> Message.Acted {
        // A question about a pane, refused on its card through this phone's
        // endpoint (its yes is given on the card in Authz): those are
        // Authz's alone. A message's answer goes to its Mac, which decides
        // it (harness/README.md "Messages"), Authz reachable or not.
        if act.kind == .askRefuse || act.kind == .askOpen, let id = act.id {
            guard act.kind == .askRefuse else { throw Failed(description: "it is allowed on its card in Authz") }
            if let why = await VigilAuthz.shared.answer(device: root, request: id, .action("deny", feedback: nil)) {
                throw Failed(description: why)
            }
            return Message.Acted(records: [], said: "Refused in Authz.")
        }
        let output: Data
        do { output = try await VigilLink.call(linked(), device: root, .messageAct(act)) } catch {
            throw Failed(description: VigilLink.reason(error))
        }
        let acted = try JSONDecoder().decode(Message.Acted.self, from: output)
        if act.kind != .read { shared.receipts.info("messages", "acted", ["act": act.kind.rawValue, "id": act.id ?? "", "said": acted.said]) }
        return acted
    }

    /// A pane of the Mac `root` as its row names it, with its Mac: what a
    /// thread and a watch call it.
    static func pane(root: String, pane: String) -> VigilChatPane {
        let phone = VigilPhone.shared
        let mac = phone.hosts.first { $0.id == root }?.name ?? "a Mac"
        let face = phone.directories[root]?.place(of: pane)?.workspace.emoji
        guard let node = phone.node(for: PaneRef(host: .init(id: root, name: mac), pane: pane, title: "")) else {
            return VigilChatPane.of(conversation: nil, title: pane, face: face, mac: mac)
        }
        // The member its glance carries: its name and tint, one look everywhere.
        let member = node.glance?.member.map { (name: $0.name, face: String?.none, tint: $0.tint) }
        return VigilChatPane.of(member: member, conversation: node.glance?.title, title: node.title, face: face, mac: mac)
    }

    /// Go to a pane from a message or a watch: the pane screen, over whatever shows.
    static func open(root: String, pane: String, from scope: String = "messages") {
        let phone = VigilPhone.shared
        let mac = phone.hosts.first { $0.id == root }?.name ?? ""
        if let node = phone.node(for: PaneRef(host: .init(id: root, name: mac), pane: pane, title: "")), let ref = node.pane {
            phone.opening = ref
        } else {
            phone.openPane(pane)
        }
        phone.receipts.info(scope, "went to a pane", ["pane": pane])
    }
}

/// Every thread of every Mac: the Messages tab.
struct PhoneMessagesScreen: View {
    @ObservedObject private var store = VigilPhoneMessages.shared
    @State private var chosen: String?

    var body: some View {
        VigilChat(threads: store.conversations, host: store.host, chosen: $chosen)
            .navigationTitle("Messages")
            .toolbarTitleDisplayMode(.inline)
    }
}

/// One pane's every thread, the pane screen's Messages mode.
struct PaneMessages: View {
    let key: MessageThread.Key
    @ObservedObject private var store = VigilPhoneMessages.shared

    var body: some View {
        // What its row mark counts, so reading it here clears the mark. The
        // pane screen's bar names the pane, so the column draws no head.
        let thread = store.paneThread(key)
        let people = VigilChatPeople(threads: thread.map { [$0] } ?? [], host: store.host)
        InkChat.Column {
            VigilThreadConversation(key: key, thread: thread, people: people, host: store.host)
        }
    }
}

/// A row's envelope: its pane's messages, or a folded row's panes'.
struct PhoneMessagesMark: View {
    let refs: [PaneRef]
    let sizes: PaneMarkSizes
    @ObservedObject private var marks = VigilPhoneMessages.shared.marks

    var body: some View {
        // What waits on your yes first, each message once across the folded
        // panes; then what you have not read.
        WaitingMark(
            messages: refs.reduce(into: Set<String>()) { $0.formUnion(marks.awaiting(root: $1.host.id, pane: $1.pane)) }, sizes: sizes)
        MessagesMark(pending: refs.compactMap { marks.pending(root: $0.host.id, pane: $0.pane) }, sizes: sizes)
    }
}
