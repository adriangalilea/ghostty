import AppKit
import AuthzProtocol
import Combine
import Ink
import SwiftUI
import UserNotifications
import VigilHarness
import VigilWire

/// This Mac's chats as the person's views read them: followed through this
/// Mac's hub (`Local.messages`: the list whole at every opening, then each
/// event with the rows it changed, never polled) into the store every view
/// draws from (`VigilChats`). Nothing is worked out here: the list, the
/// counts and every member's name are the host's.
///
/// Another Mac's chats are not followed: nothing carries them between hosts
/// yet, and its hub says so.
@MainActor
final class VigilMessageStore: ObservableObject {
    static let shared = VigilMessageStore()

    let chats: VigilChats
    /// What the sidebar's rows draw of the chats, apart from them.
    var marks: VigilChats.Marks { chats.marks }
    /// This Mac's tether root, said by the hub when the follow opens.
    @Published private(set) var here: String?
    /// What each pane is called, by `root/pane`, and where its row is (the
    /// workspace row and the pane id a sidebar click takes): the sidebar's
    /// own names, for what is not a chat (a watch's pane, "go to").
    @Published private(set) var panes: [String: Named] = [:]

    struct Named: Equatable {
        var title: String
        /// Its Mac's name, when it is not this one.
        var mac: String?
        var workspace: String
        var navigation: String

        var said: String { mac.map { "\(title) on \($0)" } ?? title }
    }

    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private var following: Task<Void, Never>?
    /// The sidebar's rows as its model last built them (`rows(_:)`).
    private var lastRows: [VigilWorkspaces.SidebarWorkspaceRow] = []

    private init() {
        chats = VigilChats(host: VigilChatHost(
            page: { chat, before, limit in try await Self.page(chat, before: before, limit: limit) },
            post: { say in try await Self.post(say) },
            act: { what in try await Self.act(what) },
            press: { ask, open in try await Self.press(ask, open: open) },
            pressHere: { ask, pressed in
                try await Self.call(
                    "ask.press", .object(["id": .string(ask), "allow": .bool(pressed.allow), "authenticated": .bool(pressed.authenticated)]),
                    as: Messages.Acted.self)
            },
            open: { pane in VigilMessageStore.shared.open(pane: pane, in: VigilMessageStore.viewport) },
            // The app's own seen rule: a hand on this Mac after it arrived.
            handAfter: { VigilWorkspaces.personActed(after: Date(timeIntervalSince1970: $0)) },
            mention: { call, root in try await Self.mention(call, root: root) },
            openFile: { file, pane in
                if let pane { VigilFilePanel.show(file, beside: pane) } else { VigilFilePanel.window(file) }
            },
            pressedByPerson: { Self.pressedByPerson() }))
        chats.changed = { [weak self] in self?.recount() }
        chats.heard = { [weak self] events in
            guard let self else { return }
            VigilMessageAlerts.shared.heard(events, rows: self.chats.rows)
        }
    }

    // MARK: Following (VigilRemote says when the hub answers)

    /// The hub answers: this Mac's chats are followed (again, after a hub
    /// that went away).
    func hubAnswers() { follow() }

    /// The follow ended with the hub (VigilRemote's stream ended): it is
    /// followed again when the hub answers. What was held stays drawn.
    func hubGone() {
        following?.cancel()
        following = nil
        brokerWatch?.cancel()
        brokerWatch = nil
        chats.unreachable("This Mac's vigil-agent is not answering.")
    }

    /// A follow that ends while the hub stands is followed again by itself,
    /// on an event and never on a clock: at once when it had delivered (it
    /// fell behind its backlog, or the broker restarted), else at the next
    /// change of the folder the broker's socket is in. One that never
    /// delivers is never dialed in a loop.
    private func follow() {
        guard following == nil else { return }
        let steps = Self.hub.messageSteps(device: nil)
        following = Task { [weak self] in
            var delivered = false
            for await step in steps {
                guard !Task.isCancelled, let self else { return }
                switch step.step {
                case .open:
                    self.here = step.root
                    self.rename()
                    messagesLog.info("chats followed", ["host": String((step.root ?? "?").prefix(10))])
                case .said:
                    guard let said = step.said else { continue }
                    delivered = true
                    self.chats.take(said)
                case .asks:
                    self.chats.asked(step.asks ?? [])
                case .waiting:
                    self.chats.unreachable(step.reason ?? "its hub gave no reason")
                    messagesLog.info("chats out of reach", ["why": step.reason ?? ""])
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.following = nil
            messagesLog.warn("chats follow ended", ["next": delivered ? "followed again" : "waits for the broker"])
            if delivered { self.follow() } else { self.awaitBroker() }
        }
    }

    /// The broker's folder, watched while the follow waits for a broker.
    private var brokerWatch: DispatchSourceFileSystemObject?
    private func awaitBroker() {
        guard brokerWatch == nil else { return }
        let folder = VigilPaths.agent.path
        let fd = Darwin.open(folder, O_EVTONLY)
        guard fd >= 0 else { return messagesLog.error("broker folder not watched; chats follow again when the hub does", ["path": folder]) }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watch.setEventHandler {
            MainActor.assumeIsolated {
                let store = VigilMessageStore.shared
                store.brokerWatch?.cancel()
                store.brokerWatch = nil
                store.follow()
            }
        }
        watch.setCancelHandler { close(fd) }
        brokerWatch = watch
        watch.resume()
    }

    // MARK: Counts (the menu bar and the Dock)

    /// The posts the person has not read, in every chat: the menu bar's ✉.
    private(set) var unreadCount = 0
    /// What waits on the person's answer, each once: the menu bar's hand,
    /// as every row's `WaitingMark`.
    private(set) var waitingCount = 0
    /// What needs the person in Messages: the Dock's one number.
    var forYouCount: Int { unreadCount + waitingCount }
    /// `unreadCount` or `waitingCount` changed.
    static let forYouDidChange = Notification.Name("vigilMessagesForYouDidChange")

    private func recount() {
        let unread = chats.unread, waiting = chats.waiting.count
        guard unread != unreadCount || waiting != waitingCount else { return }
        unreadCount = unread
        waitingCount = waiting
        NotificationCenter.default.post(name: Self.forYouDidChange, object: nil)
    }

    // MARK: Names (from the sidebar's own rows)

    /// The sidebar's rows, each time its model built new ones
    /// (`VigilSidebarModel.refresh`): names come from them, never from a
    /// snapshot of their own.
    func rows(_ rows: [VigilWorkspaces.SidebarWorkspaceRow]) {
        guard rows != lastRows else { return }
        lastRows = rows
        rename()
    }

    private func rename() {
        guard let here else { return }
        var next: [String: Named] = [:]
        for row in lastRows {
            let remote = VigilRemote.split(row.id)?.0
            for pane in row.tabs.flatMap(\.panes) {
                let key: String, navigation: String
                if let remote {
                    guard let (_, name) = VigilRemote.split(pane.id) else { continue }
                    (key, navigation) = ("\(remote)/\(name)", pane.id)
                } else {
                    guard let paneId = pane.paneId else { continue }
                    (key, navigation) = ("\(here)/\(paneId)", paneId)
                }
                next[key] = Named(
                    title: pane.messageAlias ?? pane.member?.alias ?? pane.conversationName ?? pane.member?.name ?? pane.title,
                    mac: remote == nil ? nil : row.host?.name, workspace: row.id, navigation: navigation)
            }
        }
        if next != panes { panes = next }
    }

    // MARK: What the views ask of this Mac

    /// Whether the event being handled is a person's click: a mouse button
    /// event no process posted (a hardware click carries poster 0, as Authz's
    /// `InputGuard` measured), dispatched within the last second. An
    /// accessibility press dispatches no event, so what AppKit holds then is
    /// an older one, or none, and it is refused, logged.
    @MainActor static func pressedByPerson() -> Bool {
        guard let event = NSApp.currentEvent else {
            messagesLog.warn("press refused: no event (an accessibility action)")
            return false
        }
        let clicks: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp]
        let poster = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        let age = ProcessInfo.processInfo.systemUptime - event.timestamp
        guard clicks.contains(event.type), poster == 0, age < 1 else {
            messagesLog.warn("press refused: not a person's click", ["event": "\(event.type.rawValue)", "poster": poster, "age": age])
            return false
        }
        return true
    }

    private struct Failed: Error, CustomStringConvertible { let description: String }

    /// One call to this Mac's broker, which takes the app as the person's
    /// (its trusted peer, so nothing asks): what it answered, or what it
    /// refused, said.
    private nonisolated static func call<Answer: Decodable>(_ method: String, _ payload: JSONValue, as: Answer.Type) async throws -> Answer {
        try await Task.detached {
            let response = try HarnessWire.call(RPCRequest(method, payload))
            guard response.ok else { throw Failed(description: response.refusal) }
            return try response.value.decode(Answer.self)
        }.value
    }

    private nonisolated static func page(_ chat: ChatID, before: Int?, limit: Int) async throws -> Messages.Page {
        var payload: [String: JSONValue] = ["chat": .string(chat.raw), "limit": .number(Double(limit))]
        if let before { payload["before"] = .number(Double(before)) }
        return try await call("chat.read", .object(payload), as: Messages.Page.self)
    }

    private nonisolated static func post(_ say: Messages.Say) async throws -> Messages.Standing {
        let standing = try await call("chat.post", try .from(say), as: Messages.Standing.self)
        messagesLog.info("posted", ["post": String(standing.post.id.raw.prefix(8)), "chat": String(standing.post.chat.raw.prefix(8))])
        return standing
    }

    private nonisolated static func act(_ what: Messages.Act.What) async throws -> Messages.Acted {
        let acted = try await call("chat.act", try .from(Messages.Act(what)), as: Messages.Acted.self)
        if case .read = what {} else { messagesLog.info("acted", ["said": acted.said]) }
        return acted
    }

    private nonisolated static func press(_ ask: String, open: Bool) async throws -> Messages.Acted {
        try await call("ask.press", .object(["id": .string(ask), "open": .bool(open)]), as: Messages.Acted.self)
    }

    /// An ask about the files a post names, of the host they are on: this
    /// Mac's hub for its own. Another host's are not asked: its chats are
    /// not here either.
    nonisolated static func mention(_ call: MentionCall, root: String) async throws -> Data {
        let own = await MainActor.run { shared.chats.hostID }
        guard root == own else { throw Failed(description: "that file is on another host, which is not asked from here yet") }
        return try await Task.detached {
            do { return try hub.here(.mention(call)) } catch {
                messagesLog.warn("mention not answered", ["ask": call.kind.rawValue, "err": "\(error)"])
                throw Failed(description: "\(error)")
            }
        }.value
    }

    /// The window a chat's act lands in: the key one, else the last main
    /// one, else any shown.
    static var viewport: TerminalController? {
        (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.lastMain
            ?? TerminalController.all.first { $0.window?.isVisible == true }
    }

    /// Go to a pane of this Mac, by its workspace.
    func open(pane: String, in controller: TerminalController?) {
        guard let workspace = VigilWorkspaces.shared.owner(ofPane: pane) else {
            return messagesLog.warn("go to: no workspace holds that pane now", ["pane": pane])
        }
        VigilWorkspaces.shared.activatePane(name: workspace, paneId: pane, in: controller)
        controller?.window?.makeKeyAndOrderFront(nil)
        messagesLog.info("went to a pane", ["pane": pane])
    }

    /// Go to a pane of the Mac `root`: this Mac's by its workspace, another
    /// Mac's as its sidebar row would (a mirror of its tab).
    func open(root: String, pane: String, in controller: TerminalController?) {
        if root == here { return open(pane: pane, in: controller) }
        guard let named = panes["\(root)/\(pane)"] else {
            return messagesLog.warn("go to: that Mac's directory lists no such pane", ["pane": pane])
        }
        VigilWorkspaces.shared.activatePane(name: named.workspace, paneId: named.navigation, in: controller)
        controller?.window?.makeKeyAndOrderFront(nil)
        messagesLog.info("went to a pane", ["pane": pane, "here": false])
    }
}

/// Messages is a section of the main window: the left bar's Messages lists
/// every chat (`VigilSidebarChats`). A chat with one agent opens in the
/// window's right bar beside that agent's pane, which takes the viewport;
/// any other chat opens in the Messages window, which is also a chat popped
/// out of the right bar.
@MainActor
enum VigilMessagesPanel {
    private static var shown: NSWindow?
    /// The chat the window shows, held for the window's life.
    private static let chosen = Chosen()

    final class Chosen: ObservableObject {
        @Published var id: String?
    }

    /// Messages in the window in front, on `chat` when one is named: the
    /// menu bar's Messages…, a post's notification. With no terminal window
    /// to hold it, the chat pops out.
    static func section(chat: String?) {
        NSApp.activate()
        guard let controller = VigilMessageStore.viewport else {
            messagesLog.info("messages: no terminal window; popped out", ["chat": chat ?? ""])
            return window(chat: chat)
        }
        VigilBars.shared.showMessages(chat: chat, in: controller)
    }

    /// A chat chosen in `controller`'s bar. With one agent, whose pane is on
    /// this Mac: the pane goes in the window (as a press on its row does)
    /// and the chat in the right bar beside it. Any other: the Messages
    /// window.
    static func open(chat id: String, in controller: TerminalController) {
        let store = VigilMessageStore.shared
        guard let row = store.chats.rows.first(where: { $0.id.raw == id }) else {
            return messagesLog.warn("messages: that chat is gone", ["chat": id])
        }
        let chat = row.summary.chat
        let others = row.members.filter { chat.present.contains($0.member) }
        guard others.count == 1, let pane = others[0].pane else { return window(chat: id) }
        store.open(pane: pane, in: controller)
        // A mount builds its tree in this turn: the aside is asked once the
        // pane is there.
        DispatchQueue.main.async {
            if !aside(pane: pane, chat: row.id, in: controller) { window(chat: id) }
        }
    }

    /// The pane's chat in `controller`'s right bar, when the pane is on
    /// screen there; false when it is not.
    @discardableResult
    private static func aside(pane: String, chat: ChatID?, waiting: Set<String> = [], in controller: TerminalController) -> Bool {
        let store = VigilMessageStore.shared
        guard VigilBars.shared.panesOnScreen(in: controller).contains(pane) else {
            messagesLog.warn("messages: its pane is not on screen here", ["pane": pane])
            return false
        }
        VigilBars.shared.showAside(
            VigilBars.Aside(
                pane: pane, kind: .messages, title: store.chats.agent(inPane: pane)?.name ?? "Messages",
                view: AnyView(VigilMessagesAside(
                    pane: pane, chat: chat, waiting: waiting, sidebar: VigilBars.shared.sidebarModel(of: controller))),
                popOut: { window(chat: (chat ?? store.chats.chat(forPane: pane))?.raw) }))
        messagesLog.info("messages opened", ["pane": pane, "where": "right bar"])
        return true
    }

    /// A chat popped out into a window of its own, on `chat`.
    static func window(chat: String?) {
        if let chat { chosen.id = chat }
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

    /// A pane row's waiting hand, its envelope or its menu's Messages: the
    /// pane in the window and its agent's chat beside it. `waiting`: what a
    /// pressed hand counts; the column opens on the chat that waits, at the
    /// first post that does. `paneId`: a pane of this Mac; another Mac's
    /// pane has no chat here.
    static func show(paneId: String?, id: String, waiting: Set<String> = [], in controller: TerminalController?) {
        guard let paneId else {
            return messagesLog.warn("messages: another Mac's chats are not reached from here yet", ["pane": id])
        }
        guard let controller else { return messagesLog.warn("messages: no window to show them in", ["pane": id]) }
        VigilMessageStore.shared.open(pane: paneId, in: controller)
        DispatchQueue.main.async { aside(pane: paneId, chat: nil, waiting: waiting, in: controller) }
        messagesLog.info("messages opened from a pane", ["pane": id, "waiting": waiting.count])
    }
}

/// A macOS notification for each post addressed to the person while Vigil
/// is not the front app: a post in a chat of theirs with one agent, or one
/// that mentions them anywhere. Only for one posted while this app runs
/// (what was said before is history, not news), never for the person's own.
/// Pressed, it opens that chat; read anywhere, it is taken away.
@MainActor
final class VigilMessageAlerts {
    static let shared = VigilMessageAlerts()
    /// The chat a notification opens, in its user info.
    static let chatKey = "vigil.message.chat"

    /// The posts notified and still delivered, by chat, with their position.
    private var delivered: [ChatID: [(position: Int, post: PostID)]] = [:]

    func heard(_ events: [Event], rows: [Messages.Row]) {
        for event in events {
            guard case .messages(let change) = event.change else { continue }
            switch change {
            case .posted(let post):
                guard post.by != .you, !NSApp.isActive, let row = rows.first(where: { $0.id == post.chat }) else { continue }
                let chat = row.summary.chat
                guard chat.present.contains(.you), chat.present.count == 2 || post.mentions.contains(.you) else { continue }
                notify(post, in: row)
            case .read(let mark):
                let read = (delivered[mark.chat] ?? []).filter { $0.position <= mark.through }
                guard !read.isEmpty else { continue }
                delivered[mark.chat]?.removeAll { $0.position <= mark.through }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: read.map { Self.identifier($0.post) })
            default: continue
            }
        }
    }

    private static func identifier(_ post: PostID) -> String { "vigil.post.\(post.raw)" }

    private func notify(_ post: Messages.Post, in row: Messages.Row) {
        let writer = row.members.first { $0.member == post.by }
        let content = UNMutableNotificationContent()
        content.title = [writer?.face, writer?.name ?? "A member"].compactMap { $0 }.joined(separator: " ")
        if let name = row.summary.chat.name { content.subtitle = name }
        content.body = post.words
        // Loud only as its urgency says: an urgent post to the person rings;
        // every other one is listed quietly.
        let rings = post.urgency == .urgent || post.urgency == .stop
        content.sound = rings ? .default : nil
        content.interruptionLevel = rings ? .timeSensitive : .passive
        content.threadIdentifier = post.chat.raw
        content.userInfo = [Self.chatKey: post.chat.raw]
        let request = UNNotificationRequest(identifier: Self.identifier(post.id), content: content, trigger: nil)
        if let position = post.position { delivered[post.chat, default: []].append((position, post.id)) }
        let center = UNUserNotificationCenter.current()
        let id = post.id.raw
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else {
                return messagesLog.warn("post not notified", ["id": id, "why": error.map { "\($0)" } ?? "notifications are not allowed"])
            }
            center.add(request) { error in
                if let error { messagesLog.warn("post not notified", ["id": id, "why": "\(error)"]) }
                else { messagesLog.info("post notified", ["id": id]) }
            }
        }
    }

    /// A press on one of ours: its chat, in the window in front's Messages.
    /// False for any other notification.
    nonisolated static func open(_ response: UNNotificationResponse) -> Bool {
        guard let chat = response.notification.request.content.userInfo[chatKey] as? String else { return false }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                NSApp.activate()
                VigilMessagesPanel.section(chat: chat)
            }
        }
        return true
    }

    nonisolated static func ours(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo[chatKey] != nil
    }
}

private struct VigilMessagesWindow: View {
    @ObservedObject var chosen: VigilMessagesPanel.Chosen

    var body: some View {
        VigilChat(chats: VigilMessageStore.shared.chats, chosen: $chosen.id)
    }
}

private struct VigilMessagesAside: View {
    let pane: String
    let chat: ChatID?
    let waiting: Set<String>
    /// The bar of the window it stands in: its head goes there.
    let sidebar: VigilSidebarModel?

    var body: some View {
        VigilPaneChat(
            pane: pane, chats: VigilMessageStore.shared.chats, waiting: waiting, initial: chat,
            head: sidebar.map { AnyView(VigilChatPlace(pane: pane, sidebar: $0)) })
    }
}

/// A pane's chat's head: where its pane is, each step a press away (its
/// workspace, its tab where the tree shows one, the pane). A press shows
/// that row in the window's bar and goes there as a press on the row does.
private struct VigilChatPlace: View {
    let pane: String
    @ObservedObject var sidebar: VigilSidebarModel

    var body: some View {
        HStack(spacing: 4) {
            if let place = sidebar.place(ofPane: pane) {
                step(place.row.label, face: place.row.emoji, symbol: "square.grid.2x2", tip: "Go to the workspace \(place.row.label)") {
                    sidebar.go(to: .workspace, of: place)
                }
                if place.tabShown {
                    Image(systemName: "chevron.compact.right").inkForeground(.faint)
                    step(place.tab.title, face: place.tab.emoji, symbol: "rectangle.on.rectangle", tip: "Go to the tab \(place.tab.title)") {
                        sidebar.go(to: .tab, of: place)
                    }
                }
                Image(systemName: "chevron.compact.right").inkForeground(.faint)
                step(place.pane.title, face: place.pane.emoji, symbol: "terminal", tip: "Go to the pane \(place.pane.title)") {
                    sidebar.go(to: .pane, of: place)
                }
            } else {
                Text("Its pane is in no workspace now").inkText(.caption)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
    }

    private func step(_ title: String, face: String? = nil, symbol: String, tip: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 3) {
                if let face, !face.isEmpty { Text(face) } else { Image(systemName: symbol).inkForeground(.muted) }
                Text(title).inkText(.caption, trim: []).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .inkTip(tip)
    }
}

/// The left bar's Messages: every chat of this Mac, as the chat list draws
/// it. Choosing one opens it in this window (`VigilSidebarModel.choose`).
struct VigilSidebarChats: View {
    @ObservedObject var model: VigilSidebarModel

    var body: some View {
        VigilChatList(
            chats: VigilMessageStore.shared.chats,
            selection: Binding(get: { model.chat }, set: { model.choose(chat: $0) }))
    }
}
