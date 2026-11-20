import AppKit
import Log
import SwiftUI
import VigilWire

let conversationLog = Log.log.scope("conversation")

/// An agent pane on the Mac shows its conversation or its terminal, as the
/// phone's pane screen does (`VigilShared/VigilConversation.swift`, the one
/// implementation of both): the conversation by default, the terminal one
/// press away, and the person's choice kept per pane while the app runs.
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
    /// The person's choice, by row id; none: the conversation.
    @Published private(set) var chosen: [String: Face] = [:]

    /// The conversations followed, one per pane however many views show it
    /// (a mirror in another window shares it), with how many show it.
    private var conversations: [String: (model: Conversation, views: Int)] = [:]
    private var observer: NSObjectProtocol?
    private var pending = false

    private init() {
        observer = NotificationCenter.default.addObserver(forName: VigilWorkspaces.stateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VigilPaneFaces.shared.refreshSoon() }
        }
        refresh()
    }

    /// The face `row` shows: nil for a pane that runs no agent.
    func face(of row: String) -> Face? {
        guard agents[row] != nil else { return nil }
        return chosen[row] ?? .conversation
    }

    func show(_ face: Face, of row: String) {
        guard chosen[row] != face else { return }
        chosen[row] = face
        conversationLog.info("face", ["pane": row, "face": face.rawValue])
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
            // The Mac app is no authz endpoint: a standing request is
            // answered at the terminal, one press away.
            authz: nil,
            log: ConversationLog(
                info: { Log.log.scope($0).info($1, $2) },
                warn: { Log.log.scope($0).warn($1, $2) },
                error: { Log.log.scope($0).error($1, $2) }),
            reason: { "\($0)" },
            here: "this Mac")
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
/// conversation, or the toggle back to it. Placed by the surface's own
/// wrapper (one line there), on every view of a pane, mirrors included.
struct VigilPaneFace: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    /// The terminal's background, the conversation's ground.
    let ground: Color
    @ObservedObject private var faces = VigilPaneFaces.shared

    var body: some View {
        ZStack {
            // A view just mounted may show an agent no fact change named yet.
            Color.clear.allowsHitTesting(false).onAppear { faces.refreshSoon() }
            drawn
        }
    }

    @ViewBuilder private var drawn: some View {
        if let row = VigilPaneFaces.row(of: surfaceView), let face = faces.face(of: row) {
            switch face {
            case .conversation:
                VigilPaneConversationView(row: row, surfaceView: surfaceView, shown: faces.agents[row]?.shown, ground: ground)
            case .terminal:
                VStack {
                    HStack {
                        Spacer()
                        Button { faces.show(.conversation, of: row) } label: {
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
                    VigilPaneFaces.shared.show(.terminal, of: row)
                }
                .onAppear { if surfaceView.focused { conversation.askReply() } }
                .onChange(of: surfaceView.focusInstant) { if surfaceView.focused { conversation.askReply() } }
            }
        }
        .environment(\.colorScheme, Self.scheme(of: ground))
        .overlay(alignment: .topTrailing) {
            Button { VigilPaneFaces.shared.show(.terminal, of: row) } label: {
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
        .onAppear { conversation = VigilPaneFaces.shared.take(row) }
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
