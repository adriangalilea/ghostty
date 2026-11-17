import AppKit
import AuthzProtocol
import Combine
import SwiftUI
import UserNotifications
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
    @Published private(set) var here: String? {
        didSet { if marks.here != here { marks.here = here } }
    }
    /// What the sidebar's rows draw of the mailboxes, apart from them: a
    /// history note, a receipt or a read moves `mailboxes` and repaints the
    /// window, never the sidebar; only a changed count does (the sidebar's
    /// revision rule, CLAUDE.md "Descriptor lifetime and file observations").
    let marks = Marks()

    @MainActor
    final class Marks: ObservableObject {
        /// Every pane's count (`MessageThreads.pending`), replaced only when it differs.
        @Published fileprivate(set) var pending: [String: [String: MessageThreads.Pending]] = [:]
        @Published fileprivate(set) var here: String?

        /// The count a pane row wears: `paneId` for this Mac's, the composite
        /// row id (`device/pane`) for another's.
        func pending(paneId: String?, id: String) -> MessageThreads.Pending? {
            if let paneId { return here.flatMap { pending[$0]?[paneId] } }
            guard let (device, pane) = VigilRemote.split(id) else { return nil }
            return pending[device]?[pane]
        }
    }
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
    var pendingTotal: Int { marks.pending.values.flatMap(\.values).reduce(0) { $0 + $1.unread + $1.waiting } }

    /// A pane's every thread as one: what its aside shows, holding exactly
    /// what its row mark counts.
    func paneThread(_ key: MessageThread.Key) -> MessageThread? {
        MessageThreads.pane(mailboxes, root: key.root, pane: key.pane, conversation: key.conversation)
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

    /// Every follow ended with the hub (VigilRemote's stream ended): each is
    /// followed again when the hub answers.
    func hubGone() {
        for task in following.values { task.cancel() }
        following.removeAll()
        mailboxWatch?.cancel()
        mailboxWatch = nil
    }

    /// A follow that ends while the hub stands is followed again by itself,
    /// on an event and never on a clock: at once when it had delivered (it
    /// fell behind its backlog, or a path dropped), else at the next change
    /// of this Mac's mailbox folder (the broker writes every message there)
    /// for this Mac's, and at the next word of the paired Macs for
    /// another's (whose follow tether itself keeps open). One that never
    /// delivers is never dialed in a loop.
    private func follow(device: String?) {
        let key = device ?? ""
        guard following[key] == nil else { return }
        let steps = Self.hub.messageSteps(device: device)
        following[key] = Task { [weak self] in
            var root = device
            var delivered = false
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
                    delivered = true
                    self?.apply(root, changes)
                // Out of reach: what it held is shown as it was.
                case .waiting: messagesLog.info("mailbox out of reach", ["device": String(key.prefix(10)), "why": step.reason ?? ""])
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.following[key] = nil
            messagesLog.warn("mailbox follow ended", ["device": String(key.prefix(10)), "next": delivered ? "followed again" : "waits for a change"])
            if delivered {
                self.follow(device: device)
            } else if device == nil {
                self.awaitMailbox()
            }
        }
    }

    /// This Mac's mailbox folder, watched while its follow waits.
    private var mailboxWatch: DispatchSourceFileSystemObject?
    private func awaitMailbox() {
        guard mailboxWatch == nil else { return }
        let folder = VigilPaths.agent.appendingPathComponent("mailbox").path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(folder, O_EVTONLY)
        guard fd >= 0 else { return messagesLog.error("mailbox folder not watched; this Mac's messages follow again when the hub does", ["path": folder]) }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watch.setEventHandler {
            MainActor.assumeIsolated {
                let store = VigilMessageStore.shared
                store.mailboxWatch?.cancel()
                store.mailboxWatch = nil
                store.follow(device: nil)
            }
        }
        watch.setCancelHandler { close(fd) }
        mailboxWatch = watch
        watch.resume()
    }

    private func apply(_ root: String, _ changes: Message.Changes) {
        mailboxes[root] = changes.applied(to: mailboxes[root] ?? [:])
        recount()
    }

    private func recount() {
        let next = MessageThreads.pending(mailboxes)
        if next != marks.pending { marks.pending = next }
        let due = MessageThreads.forYou(threads)
        VigilMessageAlerts.shared.due(due, names: host)
        if due.count != forYouCount {
            forYouCount = due.count
            NotificationCenter.default.post(name: Self.forYouDidChange, object: nil)
        }
    }

    /// The messages agents addressed to the person that they have not read
    /// (`MessageThreads.forYou`): what the Dock's badge and the menu bar count.
    private(set) var forYouCount = 0
    /// `forYouCount` changed.
    static let forYouDidChange = Notification.Name("vigilMessagesForYouDidChange")

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
                next["\(here)/\(paneId)"] = Named(
                    pane: VigilChatPane.of(conversation: pane.conversationName, title: pane.title, face: row.emoji, mac: nil),
                    workspace: row.id, navigation: paneId)
            }
        }
        for row in VigilRemote.shared.sidebarRows() {
            guard let (device, _) = VigilRemote.split(row.id) else { continue }
            for pane in row.tabs.flatMap(\.panes) {
                guard let (_, name) = VigilRemote.split(pane.id) else { continue }
                next["\(device)/\(name)"] = Named(
                    pane: VigilChatPane.of(conversation: pane.conversationName, title: pane.title, face: row.emoji, mac: row.host?.name),
                    workspace: row.id, navigation: pane.id)
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
                    ?? VigilChatPane.of(
                        conversation: nil, title: pane, face: nil,
                        mac: root == here ? nil : VigilRemote.shared.hosts.first { $0.device == root }?.name ?? "another Mac")
            },
            post: { message, root in try await Self.post(message, root: root, here: here) },
            act: { act, root in try await Self.act(act, root: root, here: here) },
            open: { root, pane in VigilMessageStore.shared.open(root: root, pane: pane) },
            // The app's own seen rule: a hand on this Mac after it arrived.
            handAfter: { VigilWorkspaces.personActed(after: Date(timeIntervalSince1970: $0)) },
            mention: { call, root in try await Self.mention(call, root: root, here: here) },
            openFile: { file, key in
                VigilFilePanel.show(file, beside: key.root == here ? key.pane : "\(key.root)/\(key.pane)")
            })
    }

    /// An ask about the files a message names, of the Mac they are on: this
    /// Mac's hub for its own (`Local.here`), another Mac's through it.
    nonisolated static func mention(_ call: MentionCall, root: String, here: String?) async throws -> Data {
        try await Task.detached {
            do {
                return root == here ? try hub.here(.mention(call)) : try hub.call(device: root, .mention(call))
            } catch {
                messagesLog.warn("mention not answered", ["mac": String(root.prefix(10)), "ask": call.kind.rawValue, "err": "\(error)"])
                throw Failed(description: "\(error)")
            }
        }.value
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

/// A macOS notification for each message an agent addresses to the person
/// while Vigil is not the front app: one per message, only for one that
/// arrived after this app started (a mailbox opened at launch is history,
/// not news), never for the person's own. Pressed, it opens that message's
/// thread; read anywhere, it is taken away. What is due is the threads' own
/// rule (`MessageThreads.forYou`), handed in by the store at every change.
@MainActor
final class VigilMessageAlerts {
    static let shared = VigilMessageAlerts()
    /// The thread a notification opens, in its user info.
    static let threadKey = "vigil.message.thread"

    private let started = Date().timeIntervalSince1970
    /// Every message already weighed: each is notified once at most.
    private var weighed: Set<String> = []
    /// The messages due at the last change: one no longer due was read.
    private var due: Set<String> = []

    func due(_ now: [MessageThreads.ForYou], names: VigilChatHost) {
        let ids = Set(now.map(\.item.id))
        let read = due.subtracting(ids)
        if !read.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: read.map(Self.identifier))
        }
        due = ids
        let front = NSApp.isActive
        for one in now where weighed.insert(one.item.id).inserted {
            guard one.item.record.arrived >= started, !front else { continue }
            post(one, names: names)
        }
    }

    private static func identifier(_ message: String) -> String { "vigil.message.\(message)" }

    private func post(_ one: MessageThreads.ForYou, names: VigilChatHost) {
        let message = one.item.record.message
        let pane = names.name(one.item.senderRoot, message.from.pane ?? message.to.pane)
        let content = UNMutableNotificationContent()
        content.title = [pane.face, pane.said].compactMap { $0 }.joined(separator: " ")
        content.body = one.item.words
        content.sound = .default
        content.threadIdentifier = one.thread
        content.userInfo = [Self.threadKey: one.thread]
        let request = UNNotificationRequest(identifier: Self.identifier(one.item.id), content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        let id = one.item.id
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else {
                return messagesLog.warn("message not notified", ["id": id, "why": error.map { "\($0)" } ?? "notifications are not allowed"])
            }
            center.add(request) { error in
                if let error { messagesLog.warn("message not notified", ["id": id, "why": "\(error)"]) }
                else { messagesLog.info("message notified", ["id": id]) }
            }
        }
    }

    /// A press on one of ours: its thread, in the Messages window, in front.
    /// False for any other notification.
    nonisolated static func open(_ response: UNNotificationResponse) -> Bool {
        guard let thread = response.notification.request.content.userInfo[threadKey] as? String else { return false }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                NSApp.activate()
                VigilMessagesPanel.window(thread: thread)
            }
        }
        return true
    }

    nonisolated static func ours(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo[threadKey] != nil
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
        // The pane's every thread: what its row mark counts, so opening it
        // is what clears the mark.
        VigilThreadColumn(key: key, thread: store.paneThread(key), host: store.host)
    }
}
