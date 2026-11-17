import AppKit
import AuthzProtocol
import Combine
import SwiftUI
import VigilHarness
import VigilWire

/// Every Mac's mailbox as the person's view reads it (harness/README.md
/// "Messages"): this Mac's and each paired Mac's, each followed through
/// this Mac's hub (`Local.messages`: whole at every opening, then each
/// change, never polled). The threads, each pane's pending count and the
/// names a thread is drawn with are worked out from it here, once, for the
/// window, the asides and the sidebar's row marks.
@MainActor
final class VigilMessageStore: ObservableObject {
    static let shared = VigilMessageStore()

    /// Each Mac's records by its tether root.
    @Published private(set) var mailboxes: [String: [String: Message.Record]] = [:]
    /// This Mac's tether root, said by the hub when this Mac's mailbox opens.
    @Published private(set) var here: String?
    /// Every pane's count for its row mark (`MessageThreads.pending`).
    @Published private(set) var pending: [String: [String: MessageThreads.Pending]] = [:]
    /// What each pane is called, by `root/pane` (`VigilChatPane`), and where
    /// its row is (the workspace row and the pane id a sidebar click takes).
    @Published private(set) var panes: [String: Named] = [:]

    struct Named: Equatable {
        var pane: VigilChatPane
        var workspace: String
        var navigation: String
    }

    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    /// The mailboxes followed, by device (nil key: this Mac's, as "").
    private var following: [String: Task<Void, Never>] = [:]
    private var renaming: DispatchWorkItem?
    private var stateObserver: NSObjectProtocol?

    private init() {
        stateObserver = NotificationCenter.default.addObserver(forName: VigilWorkspaces.stateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VigilMessageStore.shared.renameSoon() }
        }
    }

    var threads: [MessageThread] { MessageThreads.threads(mailboxes) }
    var pendingTotal: Int { pending.values.flatMap(\.values).reduce(0) { $0 + $1.unread + $1.waiting } }

    /// The count a pane row wears: `paneId` for this Mac's, the composite
    /// row id (`device/pane`) for another's.
    func pending(paneId: String?, id: String) -> MessageThreads.Pending? {
        if let paneId { return here.flatMap { pending[$0]?[paneId] } }
        guard let (device, pane) = VigilRemote.split(id) else { return nil }
        return pending[device]?[pane]
    }

    /// A thread's key for a pane row: its Mac, the pane, the conversation it holds.
    func key(paneId: String?, id: String, conversation: String?) -> MessageThread.Key? {
        if let paneId { return here.map { MessageThread.Key(root: $0, pane: paneId, conversation: conversation) } }
        guard let (device, pane) = VigilRemote.split(id) else { return nil }
        return MessageThread.Key(root: device, pane: pane, conversation: conversation)
    }

    // MARK: Following (VigilRemote says when the hub answers and which Macs there are)

    /// The hub answers: this Mac's mailbox is followed (again, after a hub
    /// that went away).
    func hubAnswers() { follow(device: nil) }

    /// The paired Macs now: each one's mailbox followed, a Mac gone taken out.
    func macs(_ devices: Set<String>) {
        for (key, task) in following where !key.isEmpty && !devices.contains(key) {
            task.cancel()
            following[key] = nil
            mailboxes[key] = nil
        }
        for device in devices { follow(device: device) }
        recount()
    }

    /// Every follow ended with the hub (VigilRemote's stream ended).
    func hubGone() {
        for task in following.values { task.cancel() }
        following.removeAll()
    }

    private func follow(device: String?) {
        let key = device ?? ""
        guard following[key] == nil else { return }
        let steps = Self.hub.messageSteps(device: device)
        following[key] = Task { [weak self] in
            var root = device
            for await step in steps {
                switch step.step {
                case .open:
                    root = step.root
                    if device == nil {
                        self?.here = step.root
                        self?.rename()
                    }
                    messagesLog.info("mailbox followed", ["device": String((step.root ?? "?").prefix(10)), "here": device == nil])
                case .changes:
                    guard let root, let changes = step.changes else { continue }
                    self?.apply(root, changes)
                // Out of reach: what it held is shown as it was.
                case .waiting: messagesLog.info("mailbox out of reach", ["device": String(key.prefix(10)), "why": step.reason ?? ""])
                }
            }
            // The hub's socket ended: followed again when the hub answers.
            guard let self, !Task.isCancelled else { return }
            self.following[key] = nil
        }
    }

    private func apply(_ root: String, _ changes: Message.Changes) {
        mailboxes[root] = changes.applied(to: mailboxes[root] ?? [:])
        recount()
    }

    private func recount() {
        let next = MessageThreads.pending(mailboxes)
        if next != pending { pending = next }
    }

    // MARK: Names (from the sidebar's own rows: the one naming rule)

    private func renameSoon() {
        guard renaming == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.renaming = nil
                self?.rename()
            }
        }
        renaming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func rename() {
        guard let here else { return }
        var next: [String: Named] = [:]
        for row in VigilWorkspaces.shared.sidebarSnapshot() {
            for pane in row.tabs.flatMap(\.panes) {
                guard let paneId = pane.paneId else { continue }
                next["\(here)/\(paneId)"] = Named(pane: VigilChatPane(title: pane.title), workspace: row.id, navigation: paneId)
            }
        }
        for row in VigilRemote.shared.sidebarRows() {
            guard let (device, _) = VigilRemote.split(row.id) else { continue }
            for pane in row.tabs.flatMap(\.panes) {
                guard let (_, name) = VigilRemote.split(pane.id) else { continue }
                next["\(device)/\(name)"] = Named(
                    pane: VigilChatPane(title: pane.title, mac: row.host?.name), workspace: row.id, navigation: pane.id)
            }
        }
        if next != panes { panes = next }
    }

    // MARK: The host the views ask

    var host: VigilChatHost {
        let here = here, panes = panes
        return VigilChatHost(
            here: here, macName: Host.current().localizedName ?? "this Mac",
            name: { root, pane in
                panes["\(root)/\(pane)"]?.pane
                    ?? VigilChatPane(title: pane, mac: root == here ? nil : VigilRemote.shared.hosts.first { $0.device == root }?.name ?? "another Mac")
            },
            post: { message, root in try await Self.post(message, root: root, here: here) },
            act: { act, root in try await Self.act(act, root: root, here: here) },
            open: { root, pane in VigilMessageStore.shared.open(root: root, pane: pane) })
    }

    private struct Failed: Error, CustomStringConvertible { let description: String }

    /// The person's message, to the mailbox of the pane's Mac: this Mac's
    /// broker (the app is its trusted peer, so nothing asks), another Mac's
    /// through the hub. What that Mac refused is said.
    private nonisolated static func post(_ message: Message, root: String, here: String?) async throws {
        let standing: Message.Standing = try await Task.detached {
            if root == here {
                let response = try HarnessWire.call(RPCRequest("message.post", .from(message)))
                guard let standing = try? response.value.decode(Message.Standing.self) else { throw Failed(description: response.refusal) }
                return standing
            }
            return try JSONDecoder().decode(Message.Standing.self, from: hub.call(device: root, .message(message)))
        }.value
        messagesLog.info("posted", ["id": message.id, "pane": message.to.pane, "state": standing.state.kind.rawValue])
        if case .refused(let why) = standing.state { throw Failed(description: "refused: \(why)") }
    }

    private nonisolated static func act(_ act: Message.Act, root: String, here: String?) async throws -> Message.Acted {
        let acted: Message.Acted = try await Task.detached {
            if root == here {
                let response = try HarnessWire.call(RPCRequest("message.act", .from(act)))
                guard response.ok else { throw Failed(description: response.refusal) }
                return try response.value.decode(Message.Acted.self)
            }
            return try hub.act(device: root, act)
        }.value
        if act.kind != .read { messagesLog.info("acted", ["act": act.kind.rawValue, "id": act.id ?? "", "said": acted.said]) }
        return acted
    }

    /// Go to a pane from a message: this Mac's by its workspace, another
    /// Mac's as its sidebar row would (a mirror of its tab).
    func open(root: String, pane: String) {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.lastMain
            ?? TerminalController.all.first { $0.window?.isVisible == true }
        if root == here {
            guard let workspace = VigilWorkspaces.shared.owner(ofPane: pane) else {
                return messagesLog.warn("go to: no workspace holds that pane now", ["pane": pane])
            }
            VigilWorkspaces.shared.activatePane(name: workspace, paneId: pane, in: controller)
        } else {
            guard let named = panes["\(root)/\(pane)"] else {
                return messagesLog.warn("go to: that Mac's directory lists no such pane", ["pane": pane])
            }
            VigilWorkspaces.shared.activatePane(name: named.workspace, paneId: named.navigation, in: controller)
        }
        controller?.window?.makeKeyAndOrderFront(nil)
        messagesLog.info("went to a pane", ["pane": pane, "here": root == here])
    }
}

/// The Messages window (every thread) and a pane's thread in the right bar,
/// shown where Documents and Changes are (`VigilDocumentsPanel.show`'s rule).
@MainActor
enum VigilMessagesPanel {
    private static var shown: NSWindow?
    /// The thread the window shows, held for the window's life.
    private static let chosen = Chosen()

    final class Chosen: ObservableObject {
        @Published var id: String?
    }

    /// The window, on `thread` when one is named.
    static func window(thread: String?) {
        if let thread { chosen.id = thread }
        if let shown {
            shown.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: VigilMessagesWindow(chosen: chosen).frame(minWidth: 360, minHeight: 360)))
        window.title = "Messages"
        window.setContentSize(NSSize(width: 980, height: 720))
        window.isReleasedWhenClosed = false
        window.center()
        shown = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { shown = nil }
        }
        window.makeKeyAndOrderFront(nil)
        messagesLog.info("messages opened", ["where": "window"])
    }

    /// A pane's thread beside it when it is on screen in `controller`'s
    /// window, else the window on that thread. `pane`: a local pane id, or
    /// `<tether root>/id` for another Mac's (the sidebar's row id).
    static func show(paneId: String?, id: String, title: String, conversation: String?, in controller: TerminalController?) {
        let store = VigilMessageStore.shared
        guard let key = store.key(paneId: paneId, id: id, conversation: conversation) else {
            return messagesLog.warn("messages: this Mac's mailbox has not answered yet", ["pane": id])
        }
        let pane = paneId ?? id
        guard let controller, VigilBars.shared.panesOnScreen(in: controller).contains(pane) else {
            window(thread: thread(of: key)?.id)
            return
        }
        VigilBars.shared.showAside(
            VigilBars.Aside(
                pane: pane, kind: .messages, title: title,
                view: AnyView(VigilMessagesAside(key: key)),
                popOut: { window(thread: thread(of: key)?.id) }))
        messagesLog.info("messages opened", ["pane": pane, "where": "right bar"])
    }

    /// The pane's thread: the conversation it holds, else the pane's newest.
    static func thread(of key: MessageThread.Key) -> MessageThread? {
        let threads = VigilMessageStore.shared.threads
        return threads.first { $0.key == key } ?? threads.first { $0.key.root == key.root && $0.key.pane == key.pane }
    }
}

private struct VigilMessagesWindow: View {
    @ObservedObject var chosen: VigilMessagesPanel.Chosen
    @ObservedObject private var store = VigilMessageStore.shared

    var body: some View {
        VigilChat(threads: store.threads, host: store.host, chosen: $chosen.id)
    }
}

private struct VigilMessagesAside: View {
    let key: MessageThread.Key
    @ObservedObject private var store = VigilMessageStore.shared

    var body: some View {
        VigilThreadColumn(key: key, thread: store.threads.first { $0.key == key }, host: store.host)
    }
}
