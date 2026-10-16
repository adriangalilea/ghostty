import Foundation
import GhosttyKit
import OSLog
import TetherKit
import VigilActivity
import VigilLink
import VigilWire

/// Receipts, observed by the settings sheet ALONE.
@MainActor
final class VigilReceipts: ObservableObject {
    @Published private(set) var lines: [String] = []
    func append(_ line: String) {
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }
}

/// A pane on a Mac, the navigation value the tree hands to the pane screen.
struct PaneRef: Hashable {
    let host: VigilPhone.Host
    let pane: String
    let title: String

    /// Identity is the Mac and the pane; the title is display.
    static func == (a: PaneRef, b: PaneRef) -> Bool { a.host.id == b.host.id && a.pane == b.pane }
    func hash(into h: inout Hasher) { h.combine(host.id); h.combine(pane) }
}

/// The phone's model: the Macs it reaches (paired devices running vigil,
/// over tether's `vigil/1`, on the node vigil's authz endpoint runs), each
/// Mac's directory (the `dir` stream, the same document the Mac's own
/// remote sidebar reads) rendered as the sidebar's tree, and the attach
/// path (a pane's `proxy` stream, handed to the surface as an fd). Nothing
/// here owns a session: the phone is a viewport, every fact stays on the Mac.
@MainActor
final class VigilPhone: ObservableObject {
    static let shared = VigilPhone()
    private static let logger = Logger(subsystem: "com.adriangalilea.vigil", category: "phone")

    /// A Mac: a paired device running vigil, named by its tether root.
    struct Host: Identifiable, Hashable {
        let id: String
        var name: String
    }

    // The Mac's directory document (vigild dir).
    struct Pane: Decodable {
        let id: String
        var cwd: String
        var title: String?
        var label: String?
        var emoji: String?
        var command: String?
    }
    struct Dock: Decodable { var panes: [Pane] }
    struct Tab: Decodable {
        var panes: [Pane]
        var label: String?
        var emoji: String?
        var dock: Dock?
    }
    struct Session: Decodable {
        let name: String
        var label: String
        var emoji: String?
        var order: Int?
        var tabs: [Tab]?
    }
    struct PaneTruth: Decodable {
        var alive: Bool
        var state: String?
        var tree: [String]?
        /// "rows cols <owner>", the owner's pty grid (a preview renders it scaled).
        var size: String?
        /// FNV-1a (hex) of the daemon's viewport text: the content receipt.
        var screen: String?
        /// The state file's mtime and the `<pane>.seen` mtime, unix seconds.
        var stateRevision: String?
        var since: Double?
        var seen: Double?
        /// What a row shows, the ONE reading every viewport gives the
        /// directory: `working unknown` is the harness's uncertainty, not
        /// work; done/blocked already seen anywhere (seen >= since) is idle.
        var displayState: String? {
            guard let state else { return nil }
            let parts = state.split(separator: " ").map(String.init)
            guard let first = parts.first else { return nil }
            if first == "working", parts.count > 1, parts[1] == "unknown" { return "unknown" }
            if first == "done" || first == "blocked", let seen, let since, seen >= since { return "idle" }
            return first
        }
        var grid: (rows: Int, cols: Int)? {
            // "rows cols <owner hello>": the grid is the first two words.
            let p = (size ?? "").split(separator: " ").prefix(2).compactMap { Int($0) }
            return p.count == 2 && p[0] > 0 && p[1] > 0 ? (p[0], p[1]) : nil
        }
    }
    struct Directory: Decodable {
        var host: String
        var sessions: [Session]
        var panes: [String: PaneTruth]
    }

    /// The paired Macs running vigil, from tether (never typed in).
    @Published private(set) var hosts: [Host] = [] { didSet { rebuildTree() } }
    /// Directories and errors publish; the TREE is derived once per change
    /// (never in a body), and receipts live in their own object so a log
    /// line can never re-render the tree (every receipt re-rendered every
    /// row and taps died mid-update, 2026-08-28).
    private(set) var directories: [String: Directory] = [:] {
        didSet {
            rebuildTree()
            checkScreens()
            let waiting = directoryWaiters
            directoryWaiters = []
            waiting.forEach { $0.resume() }
        }
    }
    private var directoryWaiters: [Waiter] = []

    /// The content receipt (the Mac's `checkScreen`, same rule): every
    /// live surface hashes its viewport like the daemon does; a difference
    /// while the daemon's hash held still across two directory reads is a
    /// desync: logged, then re-synced with a dump.
    private func checkScreens() {
        for (pane, view) in surfaces {
            guard let truth = directories.values.first(where: { $0.panes[pane] != nil })?.panes[pane],
                  let daemon = truth.screen, !daemon.isEmpty else { continue }
            let mine = view.screenHash
            let stable = daemon == view.screenSeen
            view.screenSeen = daemon
            if mine == daemon {
                view.screenStrikes = 0
                if !view.screenProven { view.screenProven = true; log("screen: \(pane) in sync (\(mine))") }
                continue
            }
            guard stable else { continue }
            view.screenStrikes += 1
            if view.screenStrikes == 2 {
                view.screenResyncs += 1
                if view.screenResyncs <= 2 {
                    log("!! screen mismatch: \(pane) daemon \(daemon) view \(mine); re-syncing (\(view.screenResyncs)/2)")
                    view.refreshFromDaemon()
                } else if view.screenResyncs == 3 {
                    log("!! screen mismatch: \(pane) persists after 2 re-syncs; silenced")
                }
                view.screenStrikes = -3
            }
        }
    }
    private(set) var errors: [String: String] = [:] { didSet { rebuildTree() } }
    @Published private(set) var nodes: [Node] = []
    let receipts = VigilReceipts()
    var trace: [String] { receipts.lines }
    /// vigil's tether node (the one its authz endpoint runs), once up.
    private var node: TetherNode?
    /// Why vigil has no tether node (it could not start one): the home
    /// screen says so instead of an empty list.
    @Published private(set) var unlinked: String?
    /// Each Mac's directory stream, open, being dialed or pausing to dial again.
    private var watches: [String: Task<Void, Never>] = [:]

    private init() {
        Ghostty.SurfaceView.trace = { [weak self] line in Task { @MainActor in self?.log(line) } }
    }

    /// Every receipt goes three ways: the in-app list, os_log (Console /
    /// `log stream`), and stderr (`devicectl … launch --console` over the
    /// cable). Nothing happens in this app without a line here.
    func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        Self.logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data("vigil: \(line)\n".utf8))
        receipts.append("\(stamp) \(line)")
    }

    // MARK: Macs (paired devices serving vigil/1)

    /// vigil's node is up (VigilAuthz started it): the Macs are the paired
    /// devices serving sessions (tether's offers), read again whenever
    /// tether says who is paired or what a device serves changed.
    func attach(node: TetherNode) {
        guard self.node == nil else { return }
        self.node = node
        unlinked = nil
        log("tether: node up (root \(node.root().prefix(10)))")
        VigilFollow.adopt(followed: followed)
        readPeers()
        Task { [weak self] in
            for await event in node.events {
                switch event {
                case .paired, .revoked, .offersChanged: self?.readPeers()
                default: break
                }
            }
        }
    }

    private func readPeers() {
        guard let node else { return }
        let next = VigilLink.macs(node).map { Host(id: $0.root, name: $0.name) }
        if next != hosts {
            hosts = next
            log("macs: \(next.map(\.name))")
            let ids = Set(next.map(\.id))
            directories = directories.filter { ids.contains($0.key) }
            errors = errors.filter { ids.contains($0.key) }
        }
        for host in hosts { watch(host) }
    }

    /// Back on screen: every Mac whose stream is down is dialed now, not
    /// at the end of its pause.
    func wake() {
        for (id, task) in watches where errors[id] != nil {
            task.cancel()
            watches[id] = nil
        }
        readPeers()
        renewClaims()
    }

    /// vigil could not start its tether node: nothing reaches a Mac.
    func unlinked(_ why: String) {
        unlinked = why
        log("tether: no node (\(why))")
    }

    /// vigil's node, or why there is none yet.
    private func linked() throws -> TetherNode {
        guard let node else { throw WireError.refused("vigil is not connected to tether yet") }
        return node
    }

    // MARK: Directory (a stream per Mac: every change as it happens)

    /// Opens a Mac's directory stream unless one is open: each NDJSON line
    /// is the Mac's whole directory. A stream that ends is dialed again
    /// after a pause that doubles to half a minute (a Mac asleep, out of
    /// reach), and at once when the app comes back on screen.
    private func watch(_ host: Host) {
        guard watches[host.id] == nil else { return }
        watches[host.id] = Task { [weak self] in
            var pause: UInt64 = 1
            while !Task.isCancelled, let self, self.hosts.contains(host) {
                do {
                    let stream = try await VigilLink.stream(self.linked(), device: host.id, .dir)
                    self.errors[host.id] = nil
                    pause = 1
                    var buffer = Data()
                    while let chunk = try await stream.recv() {
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = buffer[buffer.startIndex..<newline]
                            buffer = Data(buffer[buffer.index(after: newline)...])
                            guard !line.isEmpty else { continue }
                            let dir = try JSONDecoder().decode(Directory.self, from: line)
                            if self.directories[host.id] == nil {
                                self.log("dir: \(host.name) = \(dir.host), \(dir.sessions.count) sessions, \(dir.panes.count) panes")
                            }
                            self.directories[host.id] = dir
                        }
                    }
                    self.log("dir: \(host.name) stream ended")
                } catch {
                    self.errors[host.id] = VigilLink.reason(error)
                    self.log("dir: \(host.name): \(error)")
                }
                try? await Task.sleep(for: .seconds(pause))
                pause = min(pause * 2, 30)
            }
            // A Mac no longer paired ends its watch; a cancelled one was
            // already replaced by `wake`.
            if !Task.isCancelled { self?.watches[host.id] = nil }
        }
    }

    /// Returns when the next directory arrives, or after `seconds`.
    private func nextDirectory(within seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = Waiter(continuation)
            directoryWaiters.append(waiter)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.directoryWaiters.removeAll { $0 === waiter }
                waiter.resume()
            }
        }
    }

    /// A continuation resumed once, by whichever comes first.
    private final class Waiter {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// The home tree: hosts → sessions → tabs → panes, one collapsible
    /// tree with the sidebar's rollup semantics (a collapsed node wears
    /// its descendants' state cluster: distinct active states, blocked
    /// first, capped at 4; idle only when idle is all there is).
    struct Node: Identifiable, Equatable {
        enum Kind: Equatable { case host, session, tab, pane }
        let id: String
        let kind: Kind
        let title: String
        var subtitle: String? = nil
        var emoji: String? = nil
        /// A pane's own state; nodes above carry the cluster.
        var state: String? = nil
        var alive: Bool = true
        var pane: PaneRef? = nil
        /// The owner's grid, for the row's live preview.
        var rows: Int = 0
        var cols: Int = 0
        var sizeOwner: String = ""
        /// What following this row follows (nil for a Mac).
        var scope: Follow.Scope? = nil
        var children: [Node] = []

        /// The Mac's tether root (every id below a Mac starts with it).
        var root: String { String(id.prefix { $0 != "/" }) }
        /// This row's follow id: `<Mac root>/<scope key>`, the activity's key.
        var followKey: String? { scope.map { "\(root)/\($0.key)" } }
        /// This node and every node under it.
        var all: [Node] { [self] + children.flatMap(\.all) }

        /// The cluster this node shows when collapsed (its own state for a
        /// pane), the sidebar's rule.
        var cluster: [String] {
            if kind == .pane { return alive ? [state ?? "idle"] : [] }
            let all = children.flatMap { $0.leafStates }
            let active = all.filter { $0 != "idle" }
                .sorted { Self.rank($0) > Self.rank($1) }
            var seen = Set<String>()
            let distinct = active.filter { seen.insert($0).inserted }
            if !distinct.isEmpty { return Array(distinct.prefix(4)) }
            return all.isEmpty ? [] : ["idle"]
        }
        var leafStates: [String] {
            if kind == .pane { return alive ? [state ?? "idle"] : [] }
            return children.flatMap { $0.leafStates }
        }
        /// Every pane node under this one.
        var leaves: [Node] {
            if kind == .pane { return [self] }
            return children.flatMap { $0.leaves }
        }
        static func rank(_ s: String) -> Int {
            switch s { case "blocked": return 3; case "working": return 2; case "done": return 1; default: return 0 }
        }
    }

    /// Collapse state, persisted: node ids the user folded.
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "vigil.collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "vigil.collapsed") }
    }

    func tree() -> [Node] { nodes }

    // MARK: Following: a session, tab or pane on the Lock Screen

    /// Follows, by key (`<Mac root>/<scope key>`, `Node.followKey`).
    @Published private(set) var followed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "vigil.followed") ?? []) {
        didSet { UserDefaults.standard.set(Array(followed), forKey: "vigil.followed") }
    }

    /// Every followed row in the tree as it stands.
    private var followedNodes: [Node] {
        nodes.flatMap(\.all).filter { $0.followKey.map(followed.contains) == true }
    }

    /// How long a claim lives (authz's limit): renewed on every foreground
    /// and whenever a followed scope gains a pane; vigil unopened for
    /// longer hands its questions back to Authz.
    static let claimSpan: TimeInterval = 8 * 3600

    /// Follows a session, tab or pane (or stops): its panes are claimed
    /// with their Mac's authz, so their questions come to this app and
    /// Authz for iPhone stays quiet for them, and it rides the Lock Screen
    /// as a Live Activity; stopping releases both (a pane another follow
    /// still covers stays claimed).
    func follow(_ node: Node, _ on: Bool) {
        guard let key = node.followKey, let scope = node.scope else { return }
        if on { followed.insert(key) } else { followed.remove(key) }
        log("follow: \(node.title) \(on ? "followed" : "no longer followed")")
        if on {
            claim(node, panes: livePanes(node), until: Date().addingTimeInterval(Self.claimSpan))
            guard let mac = hosts.first(where: { $0.id == node.root }),
                  let session = nodes.flatMap(\.children).first(where: { $0.scope?.session == scope.session && $0.kind == .session })
            else { return }
            let lead = lead(node)
            VigilFollow.start(SessionActivity(mac: mac.name, device: mac.id, scope: scope, label: session.title, emoji: session.emoji,
                                              detail: node.kind == .session ? nil : node.title),
                              state: lead.state, since: lead.since)
        } else {
            let kept = Set(followedNodes.flatMap(livePanes))
            claim(node, panes: livePanes(node).filter { !kept.contains($0) }, until: Date())
            VigilFollow.end(key)
        }
    }

    /// Every follow's panes, claimed again for a full span.
    func renewClaims() {
        let until = Date().addingTimeInterval(Self.claimSpan)
        for node in followedNodes { claim(node, panes: livePanes(node), until: until) }
    }

    /// The panes of the follows, as last claimed: a pane that joins one is
    /// claimed when it appears.
    private var claimedPanes: Set<String> = []

    private func livePanes(_ node: Node) -> [String] { node.leaves.compactMap(\.pane?.pane) }

    private func claim(_ node: Node, panes: [String], until: Date) {
        let runtime = VigilAuthz.shared.runtime
        guard let home = runtime.macs.first(where: { $0.id == node.root }).flatMap({ mac -> String? in
            if case .answering(let homeID, _) = mac.state { homeID } else { nil }
        }) else {
            return log("follow: \(node.title): its Mac does not let vigil answer yet; its questions stay with Authz")
        }
        for pane in panes {
            if until > Date() { claimedPanes.insert(pane) } else { claimedPanes.remove(pane) }
            Task { await runtime.claim(context: pane, home: home, until: until) }
        }
    }

    /// The leading state of a row's panes and since when, read from its
    /// Mac's directory the way the Mac reads it (`SessionState.lead`).
    private func lead(_ node: Node) -> (state: SessionState, since: Double) {
        let panes = directories[node.root]?.panes ?? [:]
        let lead = SessionState.lead(node.leaves.compactMap(\.scope?.pane).map { (panes[$0]?.state, panes[$0]?.since, panes[$0]?.seen) })
        return (lead.state, lead.since ?? Date().timeIntervalSince1970)
    }

    /// The tree moved: a follow that gained a pane claims it, and every
    /// follow's activity shows the state now (vigil is open; the Mac's
    /// pushes carry it while it is not).
    private func followTree() {
        let until = Date().addingTimeInterval(Self.claimSpan)
        for node in followedNodes {
            let panes = livePanes(node)
            if !Set(panes).isSubset(of: claimedPanes) { claim(node, panes: panes, until: until) }
            if let key = node.followKey {
                let lead = lead(node)
                VigilFollow.update(key, state: lead.state, since: lead.since)
            }
        }
    }

    private func rebuildTree() {
        let fresh = deriveTree()
        guard fresh != nodes else { return }
        nodes = fresh
        indexTree()
        followTree()
        let leaves = fresh.flatMap(\.leaves)
        let gridded = leaves.filter { $0.pane != nil && $0.rows > 0 }.count
        let folded = collapsed.count
        log("tree: \(leaves.count) pane rows, \(gridded) with a grid (previewable), \(folded) nodes folded")
    }

    private func deriveTree() -> [Node] {
        hosts.map { host in
            let dir = directories[host.id]
            var node = Node(id: "host:\(host.id)", kind: .host,
                            title: dir?.host ?? host.name,
                            subtitle: errors[host.id] ?? (dir == nil ? "connecting…" : nil))
            guard let dir else { return node }
            let sessions = dir.sessions.sorted { ($0.order ?? 0, $0.label) < ($1.order ?? 0, $1.label) }
            node.children = sessions.map { s in
                let tabs = s.tabs ?? []
                let sid = "\(host.id)/\(s.name)"
                var sess = Node(id: sid, kind: .session, title: s.label, emoji: s.emoji,
                                scope: Follow.Scope(session: s.name, kind: .session))
                func paneNode(_ p: Pane) -> Node {
                    let truth = dir.panes[p.id]
                    let program = Self.program(truth?.tree)
                    let title = p.label ?? program
                        ?? p.command.map { String($0.split(separator: " ").first ?? "").split(separator: "/").last.map(String.init) ?? $0 }
                        ?? p.title ?? URL(fileURLWithPath: p.cwd).lastPathComponent
                    let alive = truth?.alive ?? false
                    return Node(id: "\(sid)/\(p.id)", kind: .pane, title: title, emoji: p.emoji,
                                state: truth?.displayState,
                                alive: alive,
                                pane: alive ? PaneRef(host: host, pane: p.id, title: title) : nil,
                                rows: truth?.grid?.rows ?? 0, cols: truth?.grid?.cols ?? 0,
                                sizeOwner: (truth?.size ?? "").split(separator: " ", maxSplits: 2).dropFirst(2).joined(separator: " "),
                                scope: Follow.Scope(session: s.name, kind: .pane, pane: p.id))
                }
                for (ti, t) in tabs.enumerated() {
                    let all = t.panes + (t.dock?.panes ?? [])
                    let showTab = tabs.count > 1 || t.label != nil || t.emoji != nil
                    if showTab {
                        let name = t.label ?? URL(fileURLWithPath: t.panes.first?.cwd ?? "").lastPathComponent
                        var tab = Node(id: "\(sid)/t\(ti)", kind: .tab, title: name.isEmpty ? "tab \(ti + 1)" : name, emoji: t.emoji,
                                       scope: all.first.map { Follow.Scope(session: s.name, kind: .tab, pane: $0.id) })
                        tab.children = all.map(paneNode)
                        sess.children.append(tab)
                    } else {
                        sess.children.append(contentsOf: all.map(paneNode))
                    }
                }
                return sess
            }
            return node
        }
    }

    private static let shells: Set<String> = ["fish", "bash", "zsh", "sh", "login", "caffeinate"]
    nonisolated private static func program(_ tree: [String]?) -> String? {
        var out: String?
        for line in tree ?? [] {
            let argv = line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? ""
            let first = argv.split(separator: " ").first.map(String.init) ?? ""
            let base = String(first.split(separator: "/").last ?? "")
            if base.isEmpty || base.hasPrefix("-") || base.hasSuffix(":") || shells.contains(base) { continue }
            if ["node", "python", "python3", "ruby", "bun", "deno", "tsx"].contains(base) {
                let script = argv.split(separator: " ").dropFirst()
                    .first { !$0.hasPrefix("-") && !$0.contains("=") && $0.contains(".") }
                out = script.map { String($0.split(separator: "/").last ?? $0) } ?? base
            } else {
                out = base
            }
        }
        return out
    }

    // MARK: URLs (vigil://pane/<id>)

    /// `vigil://pane/<id>` (a request's Go there, from Authz): the pane is
    /// found by its daemon id on whichever Mac lists it (ids embed a random
    /// session name, unique across Macs). Directories stream, so a pane
    /// born a moment ago arrives with its Mac's next document: up to five
    /// seconds of them are awaited.
    func resolve(url: URL) async -> PaneRef? {
        guard url.scheme == "vigil" else { return nil }
        // vigil://session/<mac>/<session> (a followed session's Live
        // Activity): the pane asking for you, else its first.
        if url.host == "session" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, let session = nodes.flatMap(\.children).first(where: { $0.id == "\(parts[0])/\(parts[1])" }) else {
                log("url: \(url) names no session listed here"); return nil
            }
            let leaves = session.leaves.compactMap { leaf in leaf.pane.map { (leaf, $0) } }
            return (leaves.first { $0.0.state == "blocked" } ?? leaves.first)?.1
        }
        guard url.host == "pane" || url.host == "reply" else {
            log("url: \(url) is not vigil://pane/<id>, vigil://reply/<id> or vigil://session/<mac>/<session>"); return nil
        }
        let id = url.lastPathComponent
        guard Open.validPane(id) else { log("url: \(url) names no pane"); return nil }
        let deadline = Date().addingTimeInterval(5)
        while true {
            if let ref = nodes.flatMap(\.leaves).compactMap(\.pane).first(where: { $0.pane == id }) {
                log("url: vigil://pane/\(id) -> \(ref.host.name)")
                return ref
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            await nextDirectory(within: left)
        }
        log("url: no Mac lists pane \(id)")
        return nil
    }

    /// A pane to show now (a tapped question): the root view navigates to
    /// it and clears it.
    @Published var opening: PaneRef?

    func openPane(_ id: String) {
        Task {
            guard let url = URL(string: "vigil://pane/\(id)"), let ref = await resolve(url: url) else { return }
            opening = ref
        }
    }

    // MARK: Attach

    /// A live stream to one pane (`proxy`), as an fd for the Attach backend:
    /// one end of a socketpair, the other bridged to the tether stream.
    func attach(_ host: Host, pane: String, preview: Bool = false) async throws -> Int32 {
        let stream = try await VigilLink.stream(linked(), device: host.id, .proxy(pane))
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            try? await stream.finish()
            throw WireError.refused("socketpair: \(String(cString: strerror(errno)))")
        }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let ours = fds[1]
        Task.detached {
            await VigilLink.bridge(stream, read: ours, write: ours)
            close(ours)
        }
        log("\(preview ? "preview" : "attach"): \(host.name) \(pane) fd \(fds[0])")
        return fds[0]
    }

    // MARK: Surfaces: the model owns every live stream

    /// One surface per pane, owned HERE (never by a view's @State): a
    /// surface is a stream to a daemon, an identity the screens borrow.
    /// A row's preview and the pane screen show the SAME surface; hosting
    /// (which container holds the UIView right now) is the representable's
    /// business (`SurfaceHost`), lifetime is this table's.
    private(set) var surfaces: [String: Ghostty.SurfaceView] = [:]
    /// The pane the screen shows, ONE fact: rows read it to know their
    /// view is borrowed, the occlusion policy reads it to idle the rest.
    @Published private(set) var presenting: PaneRef?

    // MARK: Previews follow the viewport
    //
    // The tree realizes a whole host at once (a host is one nested VStack
    // in the LazyVStack), so "realized" says nothing about "visible". Rows
    // report their frame in the tree's space, the tree reports its size,
    // and the cap's slots go to the rows actually in view, nearest the
    // centre first. Frames are written into non-observed storage per
    // scroll frame; only a CHANGE of the previewed set publishes.

    /// Every realized preview row's frame in the tree's coordinate space.
    private var rowFrames: [String: CGRect] = [:]
    private var treeViewport: CGSize = .zero
    /// The panes whose rows show a live preview right now.
    @Published private(set) var previewed = Set<String>()

    func rowFrame(_ ref: PaneRef, _ frame: CGRect) {
        if rowFrames[ref.pane] == nil { log("row: \(ref.pane) at y \(Int(frame.minY))..\(Int(frame.maxY))") }
        rowFrames[ref.pane] = frame
        allocatePreviews()
    }

    func treeSize(_ size: CGSize) {
        treeViewport = size
        log("tree: viewport \(Int(size.width))x\(Int(size.height))")
        allocatePreviews()
    }

    /// A preview row left the tree (scrolled out of the realized range,
    /// or the tree itself is hidden under a pushed screen). The surface
    /// stays while the screen shows it; `present(nil)` sweeps on return.
    func rowDisappeared(_ ref: PaneRef) {
        rowFrames[ref.pane] = nil
        allocatePreviews()
    }

    private func allocatePreviews() {
        let viewport = CGRect(origin: .zero, size: treeViewport)
        let wanted = rowFrames
            .filter { $0.value.intersects(viewport) }
            .sorted { abs($0.value.midY - viewport.midY) < abs($1.value.midY - viewport.midY) }
            .prefix(Self.surfaceCap)
            .map(\.key)
        let set = Set(wanted)
        guard set != previewed else { return }
        previewed = set
        log("previews: \(wanted.joined(separator: " ")) (\(rowFrames.count) rows reported, viewport \(Int(treeViewport.width))x\(Int(treeViewport.height)))")
        if presenting == nil { sweepUnwanted() }
    }

    /// Ends every surface no previewed row holds, ONE turn later: rows
    /// report frames one at a time within a layout pass, and a sweep at
    /// each report would end a preview the next report wants back. Under
    /// a pushed screen nothing ends (the presented surface is borrowed);
    /// the return schedules its own, later sweep.
    private var sweepScheduled = false
    private func sweepUnwanted(after delay: TimeInterval = 0) {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.sweepScheduled = false
            guard self.presenting == nil else { return }
            for pane in self.surfaces.keys where !self.previewed.contains(pane) { self.endSurface(pane) }
        }
    }

    /// Every live surface is a full Metal renderer and a stream: seven
    /// focused full-grid renderers ran the phone hot, so six at most, the
    /// screen's included. A dial in flight holds its slot, or every row of a fresh tree
    /// passes the check at zero and dials at once.
    static let surfaceCap = 6
    private var dialing = Set<String>()

    /// The surface for a pane, dialing one if none exists. `nil` when the
    /// cap is reached (rows show a placeholder; the screen always gets
    /// one: it evicts an idle row's surface).
    func surface(for ref: PaneRef, app: ghostty_app_t, screen: Bool) async throws -> Ghostty.SurfaceView? {
        if let existing = surfaces[ref.pane], existing.surface != nil { return existing }
        guard !dialing.contains(ref.pane) else { return nil }
        if surfaces.count + dialing.count >= Self.surfaceCap {
            guard screen, let victim = surfaces.keys.first(where: { $0 != ref.pane && $0 != presenting?.pane }) else {
                log("surface: cap \(Self.surfaceCap) reached, \(ref.pane) not shown")
                return nil
            }
            log("surface: cap reached, evicting \(victim) for the screen")
            endSurface(victim)
        }
        dialing.insert(ref.pane)
        defer { dialing.remove(ref.pane) }
        let fd = try await attach(ref.host, pane: ref.pane, preview: !screen)
        var config = Ghostty.SurfaceConfiguration()
        config.vigilAttach = ref.pane
        config.vigilFd = fd
        config.vigilMirror = true
        // The phone never owns the pty by focus: only an own-size screen
        // claims, explicitly (a fit viewport mirrors the owner's grid).
        config.vigilExplicitClaim = true
        // A phone reads at 8pt (the Mac's 13 minus five loupe taps).
        config.fontSize = 8
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        view.onStreamEnd = { [weak self, weak view] in
            guard let self, let view, self.surfaces[ref.pane] === view else { return }
            self.log("surface: \(ref.pane) stream died, dropping it; the screen re-dials")
            self.endSurface(ref.pane)
            self.streamGeneration += 1
        }
        surfaces[ref.pane] = view
        return view
    }

    /// Bumped when a live stream dies (the tether connection dropped on a
    /// network change): every screen holding a dead surface re-dials.
    @Published private(set) var streamGeneration = 0

    func endSurface(_ pane: String) {
        guard let view = surfaces.removeValue(forKey: pane) else { return }
        view.detach()
        log("surface: \(pane) ended (\(surfaces.count) live)")
    }

    /// The pane screen is showing `ref` (nil = the tree). Occlusion
    /// follows: only the presented surface renders while a screen is up;
    /// with the tree up, every row's surface renders.
    func present(_ ref: PaneRef?) {
        guard presenting != ref else { return }
        presenting = ref
        log("present: \(ref?.pane ?? "tree")")
        for (pane, view) in surfaces {
            view.visible = ref == nil || pane == ref?.pane
        }
        if let ref { markSeen(ref) }
        // Back on the tree: rows re-report their frames within a frame
        // (the stack's pop lays the list out after this); a surface no
        // visible row wants by then ends. Deferred, never at the pop
        // itself, so a return never re-dials what the rows still show.
        if ref == nil { sweepUnwanted(after: 0.5) }
    }

    /// A pane shown full screen here was seen: the fact belongs to ITS Mac
    /// (`vigild seen`, PROTOCOL.md), written only on a seen-flip (unseen
    /// done/blocked), the directory updated optimistically so the row
    /// decays with the glance and the Mac's next document confirms it.
    private func markSeen(_ ref: PaneRef) {
        guard let truth = directories[ref.host.id]?.panes[ref.pane],
              let revision = truth.stateRevision, revision.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let first = truth.state?.split(separator: " ").first,
              first == "done" || first == "blocked",
              (truth.seen ?? 0) < (truth.since ?? 0) else { return }
        directories[ref.host.id]?.panes[ref.pane]?.seen = truth.since
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await VigilLink.call(linked(), device: ref.host.id, .seen(ref.pane, revision: revision))
                log("seen: \(ref.pane) marked on \(ref.host.name)")
            } catch {
                if directories[ref.host.id]?.panes[ref.pane]?.stateRevision == revision {
                    directories[ref.host.id]?.panes[ref.pane]?.seen = truth.seen
                }
                log("seen: \(ref.pane) on \(ref.host.name) FAILED: \(error)")
            }
        }
    }

    // MARK: Reply (a line typed into a pane, from a followed activity)

    /// The pane a reply is being written to (the reply sheet shows while set).
    @Published var replying: PaneRef?

    /// Types `text` into the pane and submits it, as its Mac's hub does for
    /// a person at the keyboard; true once the Mac took it.
    func reply(_ ref: PaneRef, _ text: String) async -> Bool {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard Open.validReply(line) else { log("reply: nothing to send"); return false }
        do {
            _ = try await VigilLink.call(linked(), device: ref.host.id, .reply(ref.pane, text: line))
            log("reply: \(line.count) characters to \(ref.pane) on \(ref.host.name)")
            return true
        } catch {
            log("reply: \(ref.pane) on \(ref.host.name) FAILED: \(VigilLink.reason(error))")
            return false
        }
    }

    // MARK: Index (derived with the tree, never walked in a body)

    private(set) var paneNodes: [PaneRef: Node] = [:]
    private(set) var sessionTitles: [PaneRef: String] = [:]

    func node(for ref: PaneRef) -> Node? { paneNodes[ref] }
    func sessionTitle(for ref: PaneRef) -> String { sessionTitles[ref] ?? "" }
    struct LivePane: Identifiable {
        let ref: PaneRef
        let session: String
        var id: PaneRef { ref }
    }
    /// Every live pane on a Mac, labelled by its session.
    func livePanes(on host: Host) -> [LivePane] {
        paneNodes.keys.filter { $0.host.id == host.id }
            .sorted { ($0.pane) < ($1.pane) }
            .map { LivePane(ref: $0, session: sessionTitles[$0] ?? "") }
    }

    private func indexTree() {
        var panes: [PaneRef: Node] = [:]
        var titles: [PaneRef: String] = [:]
        for host in nodes {
            for session in host.children {
                for leaf in session.leaves {
                    guard let ref = leaf.pane else { continue }
                    panes[ref] = leaf
                    titles[ref] = session.title
                }
            }
        }
        paneNodes = panes
        sessionTitles = titles
    }
}
