import AppKit
import Log
import SwiftUI
import VigilHarness
import VigilWire

let conversationLog = Log.log.scope("conversation")

/// An agent pane on the Mac shows its conversation or its terminal, as the
/// phone's pane screen does (`VigilShared/VigilConversation.swift`, the one
/// implementation of both): the terminal by default, the conversation one
/// press away, and the person's choice kept per pane across launches.
/// Which panes run an agent is their facts' word (the glance, while it
/// speaks for the pane's program): a pane whose agent exits shows its
/// terminal again, a shell never gets a conversation.
@MainActor
final class VigilPaneFaces: ObservableObject {
    static let shared = VigilPaneFaces()

    enum Face: String { case conversation, terminal }

    /// What a pane on screen is, as its Mac's facts say.
    struct Agent: Equatable {
        /// Its agent's conversation id (the glance's).
        let conversation: String
        /// Its state as every row shows it (the seen rule applied).
        let shown: AgentState?
    }

    /// Every pane a view of this app shows that runs an agent, by row id
    /// (this Mac's daemon id, `<tether root>/<id>` for another Mac's).
    @Published private(set) var agents: [String: Agent] = [:]
    /// The panes the person turned to their conversation, by row id; every
    /// other agent pane shows its terminal. Kept in the app's defaults:
    /// the choice of a pane outlives a launch, and dies with the pane.
    @Published private(set) var conversationsShown: Set<String>
    private static let conversationsKey = "vigil.paneFaces.conversation"

    /// The conversations followed, one per pane however many views show it
    /// (a mirror in another window shares it), with how many show it.
    private var conversations: [String: (model: Conversation, views: Int)] = [:]
    /// Only the viewport where the person pressed the switch takes focus.
    private weak var focusAfterSwitch: Ghostty.SurfaceView?
    private var observer: NSObjectProtocol?
    private var pending = false

    private init() {
        // A pane of this Mac no workspace or burial lists any more is gone
        // for good (ids are never reused): its choice goes with it. Another
        // Mac's are kept, that Mac's registry is not here to ask.
        let kept = Set(UserDefaults.standard.stringArray(forKey: Self.conversationsKey) ?? [])
        let workspaces = VigilWorkspaces.shared
        let listed = Set(workspaces.workspaces.values.flatMap { $0.tabs.flatMap(\.paneIds) })
            .union(workspaces.graveyard.values.flatMap { $0.tabs.flatMap(\.paneIds) })
        conversationsShown = kept.filter { VigilRemote.split($0) != nil || listed.contains($0) }
        if conversationsShown != kept { UserDefaults.standard.set(Array(conversationsShown).sorted(), forKey: Self.conversationsKey) }
        observer = NotificationCenter.default.addObserver(forName: VigilWorkspaces.stateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VigilPaneFaces.shared.refreshSoon() }
        }
        refresh()
    }

    /// The face `row` shows: nil for a pane that runs no agent.
    func face(of row: String) -> Face? {
        guard agents[row] != nil else { return nil }
        return conversationsShown.contains(row) ? .conversation : .terminal
    }

    func show(_ face: Face, in view: Ghostty.SurfaceView) {
        guard let row = Self.row(of: view) else { return }
        let next = face == .conversation ? conversationsShown.union([row]) : conversationsShown.subtracting([row])
        guard next != conversationsShown else { return }
        focusAfterSwitch = view
        conversationsShown = next
        UserDefaults.standard.set(Array(next).sorted(), forKey: Self.conversationsKey)
        conversationLog.info("face", ["pane": row, "face": face.rawValue])
    }

    func takeFocusAfterSwitch(in view: Ghostty.SurfaceView) -> Bool {
        guard focusAfterSwitch === view else { return false }
        focusAfterSwitch = nil
        return view.window?.isKeyWindow == true
    }

    func focusReply(in view: Ghostty.SurfaceView) {
        guard let row = Self.row(of: view), face(of: row) == .conversation else { return }
        conversations[row]?.model.askReply()
    }

    /// The row id a view of a pane is known by (every aside's, every row's).
    static func row(of view: Ghostty.SurfaceView) -> String? {
        view.vigilAttachId.map { id in view.vigilHost.map { VigilRemote.compositeId($0, id) } ?? id }
    }

    /// Once per turn however many facts moved in it.
    func refreshSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [self] in
            pending = false
            refresh()
        }
    }

    /// The agents among the panes some view shows, read from this Mac's
    /// facts for its own and from the other Macs' directories for theirs.
    func refresh() {
        var next: [String: Agent] = [:]
        let hosts = Dictionary(VigilRemote.shared.hosts.map { ($0.device, $0) }, uniquingKeysWith: { a, _ in a })
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects {
            guard let id = view.vigilAttachId, let row = Self.row(of: view), next[row] == nil else { continue }
            if let device = view.vigilHost {
                guard let facts = hosts[device]?.directory?.panes[id], let conversation = facts.meaning?.conversation else { continue }
                next[row] = Agent(conversation: conversation, shown: facts.shown)
            } else {
                let workspaces = VigilWorkspaces.shared
                guard let conversation = workspaces.paneFacts(id).meaning?.conversation else { continue }
                next[row] = Agent(conversation: conversation, shown: workspaces.paneDisplayState(id))
            }
        }
        if next != agents { agents = next }
    }

    /// The conversation of `row`, followed while some view shows it.
    func take(_ row: String) -> Conversation {
        if let held = conversations[row] {
            conversations[row] = (held.model, held.views + 1)
            return held.model
        }
        let model = Conversation(key: row, pane: VigilRemote.split(row)?.name ?? row, source: VigilPaneConversation.source(row: row))
        model.start()
        conversations[row] = (model, 1)
        conversationLog.info("following", ["pane": row])
        return model
    }

    /// A view of `row`'s conversation went: the last one stops following it.
    func release(_ row: String) {
        guard let held = conversations[row] else { return }
        guard held.views <= 1 else {
            conversations[row] = (held.model, held.views - 1)
            return
        }
        held.model.stop()
        conversations[row] = nil
        conversationLog.info("no longer followed", ["pane": row])
    }
}

/// A conversation's source on the Mac: this Mac's hub answers for its own
/// panes (`here`, the local `feed`) and for another Mac's over tether, the
/// way Documents and Changes reach a pane.
enum VigilPaneConversation {
    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)

    private struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    static func source(row: String) -> ConversationSource {
        let remote = VigilRemote.split(row)
        let id = remote?.name ?? row
        let device = remote?.device
        /// A call to the pane's Mac, off the main thread (the hub's calls block).
        @Sendable func call(_ open: Open) async throws -> Data {
            try await Task.detached {
                do {
                    if let device { return try hub.call(device: device, open) }
                    return try hub.here(open)
                } catch {
                    throw Failed(description: "\(error)")
                }
            }.value
        }
        return ConversationSource(
            follow: { Self.follow(device: device, pane: id) },
            earlier: { request in try JSONDecoder().decode(FeedPage.self, from: await call(.feedEarlier(id, request))) },
            press: { key in
                // Lossy on purpose: a bad byte reads as U+FFFD, the rest still reads.
                // swiftlint:disable:next optional_data_string_conversion
                String(decoding: try await call(.key(id, key)), as: UTF8.self)
            },
            say: { text in
                let said = try JSONDecoder().decode(Said.self, from: await call(.say(id, text: text)))
                conversationLog.info("reply sent", ["pane": row, "bytes": text.utf8.count, "how": said.words])
                return said.words
            },
            // This Mac's pane: its prompt's ask answered in place through its
            // broker, which holds it on the app's surface. Another Mac's is
            // answered at its terminal until that path crosses the wire.
            authz: device == nil ? ConversationAuthz(
                read: { request in await Self.read(request) },
                answer: { press in try await VigilMessageStore.answer(press) },
                pressedByPerson: { VigilMessageStore.pressedByPerson() }) : nil,
            log: ConversationLog(
                info: { Log.log.scope($0).info($1, $2) },
                warn: { Log.log.scope($0).warn($1, $2) },
                error: { Log.log.scope($0).error($1, $2) }),
            reason: { "\($0)" },
            here: "this Mac")
    }

    /// A pane prompt's ask on the app's surface, as this Mac's broker holds
    /// it (`asks.follow`, held by `VigilMessageStore`): the feed may name the
    /// request a moment before the ask arrives, so it is awaited for up to
    /// two seconds (nil: asked at the pane alone, answered, or gone).
    @MainActor private static func read(_ request: String) async -> Asks.Standing? {
        let chats = VigilMessageStore.shared.chats
        if let held = chats.asks.first(where: { $0.id == request }) { return held }
        let arrives = chats.$asks.compactMap { $0.first { $0.id == request } }.first().values
        return await withTaskGroup(of: Asks.Standing?.self) { group in
            group.addTask { @MainActor in
                for await standing in arrives { return standing }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { conversationLog.info("request has no ask here", ["request": String(request.prefix(8))]) }
            return first
        }
    }

    /// The pane's feed through the hub, dialed again when the hub's stream
    /// ends (the hub restarted), from the last cursor it was handed so the
    /// conversation resumes where it stands. Another Mac's is the hub's to
    /// keep following; this redial is for the local connection alone. A
    /// waiting reason is said once until it changes.
    private static func follow(device: String?, pane: String) -> AsyncStream<ConversationStep> {
        AsyncStream { continuation in
            let task = Task.detached {
                var cursor: FeedCursor?
                var said: String?
                var pause = Duration.milliseconds(250)
                while !Task.isCancelled {
                    for await step in hub.feedSteps(device: device, pane: pane, from: cursor) {
                        if let message = step.message {
                            switch message {
                            case .snapshot(let snapshot): cursor = snapshot.cursor
                            case .entries(_, let at): cursor = at
                            case .live, .queued: break
                            }
                            said = nil
                            pause = .milliseconds(250)
                            continuation.yield(.message(message))
                        } else if let why = step.waiting, why != said {
                            said = why
                            continuation.yield(.waiting(why))
                        }
                    }
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(for: pause)
                    pause = min(pause * 2, .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// What a pane's view draws over its terminal for an agent pane: the
/// conversation, or the toggle to it. Placed by the surface's own
/// wrapper (one line there), on every view of a pane, mirrors included.
struct VigilPaneFace: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    /// The terminal's background, the conversation's ground.
    let ground: Color
    let face: VigilPaneFaces.Face?
    let shown: AgentState?

    var body: some View {
        // The viewport proposes its size to either face. A conversation's
        // content must never enlarge the terminal underneath it.
        Color.clear.allowsHitTesting(false)
            .overlay { drawn }
            .clipped()
            .onAppear { VigilPaneFaces.shared.refreshSoon() }
    }

    @ViewBuilder private var drawn: some View {
        if let row = VigilPaneFaces.row(of: surfaceView), let face {
            switch face {
            case .conversation:
                VigilPaneConversationView(row: row, surfaceView: surfaceView, shown: shown, ground: ground)
            case .terminal:
                VStack {
                    HStack {
                        Spacer()
                        Button { VigilPaneFaces.shared.show(.conversation, in: surfaceView) } label: {
                            Label("Conversation", systemImage: "text.bubble")
                        }
                        .font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .help("Show this pane's conversation instead of its terminal")
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .focusable(false)
                // Below the size button when it shows.
                .padding(.top, surfaceView.vigilSizeLost ? 40 : 6)
                .padding(.horizontal, 6)
            }
        }
    }
}

/// The conversation over a pane's terminal, which keeps running under it:
/// the shared screen, the terminal's ground, a button back to the terminal.
/// The keyboard follows what is seen: a pane that takes focus while its
/// conversation shows hands it to the reply box, so no key reaches a
/// terminal nobody sees.
private struct VigilPaneConversationView: View {
    let row: String
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let shown: AgentState?
    let ground: Color
    /// Taken while this view is on screen, released when it goes.
    @State private var conversation: Conversation?

    var body: some View {
        ZStack {
            ground
            if let conversation {
                ConversationView(conversation: conversation, shown: shown, ground: ground) {
                    VigilPaneFaces.shared.show(.terminal, in: surfaceView)
                }
            }
        }
        .environment(\.colorScheme, Self.scheme(of: ground))
        .overlay(alignment: .topTrailing) {
            Button { VigilPaneFaces.shared.show(.terminal, in: surfaceView) } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .font(.caption)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
            .help("Show this pane's terminal instead of its conversation")
        }
        .onAppear {
            let taken = VigilPaneFaces.shared.take(row)
            conversation = taken
            if VigilPaneFaces.shared.takeFocusAfterSwitch(in: surfaceView) ||
                surfaceView.window?.firstResponder === surfaceView {
                surfaceView.window?.makeFirstResponder(nil)
                taken.askReply()
            }
        }
        .onDisappear {
            VigilPaneFaces.shared.release(row)
            conversation = nil
        }
    }

    /// Text drawn for the ground under it: light text on a dark terminal.
    private static func scheme(of ground: Color) -> ColorScheme {
        guard let rgb = NSColor(ground).usingColorSpace(.sRGB) else { return .dark }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5 ? .dark : .light
    }
}
