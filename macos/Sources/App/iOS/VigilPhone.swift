import Foundation
import GhosttyKit
import Log
import TetherKit
import VigilActivity
import VigilLink
import VigilWire

/// One receipt as the in-app list shows it: the event's time, scope,
/// level, message and fields rendered `key=value`.
struct Receipt: Identifiable {
    enum Level { case info, warn, error }
    let id: Int
    let time: Date
    let scope: String
    let level: Level
    let message: String
    let fields: String

    var line: String {
        let mark = level == .error ? "!! " : level == .warn ? "! " : ""
        let stamp = time.formatted(date: .omitted, time: .standard)
        return "\(stamp) \(mark)[\(scope)] \(message)" + (fields.isEmpty ? "" : " \(fields)")
    }
}

/// Every receipt of this app, observed by the settings sheet ALONE. A
/// receipt is a `Log` event (scope, message, fields): the unified log,
/// stderr (`devicectl … launch --console` over the cable) and the app's
/// record (`Library/Logs/vigil-phone.jsonl`, `Record`, shipped to the Macs
/// where `authz trace` reads it), and the same values make the list's row.
@MainActor
final class VigilReceipts: ObservableObject {
    @Published private(set) var all: [Receipt] = []
    private var count = 0

    func info(_ scope: String, _ message: String, _ fields: Fields = [:]) {
        Log.log.scope(scope).info(message, fields)
        show(scope, .info, message, fields)
    }
    func warn(_ scope: String, _ message: String, _ fields: Fields = [:]) {
        Log.log.scope(scope).warn(message, fields)
        show(scope, .warn, message, fields)
    }
    func error(_ scope: String, _ message: String, _ fields: Fields = [:]) {
        Log.log.scope(scope).error(message, fields)
        show(scope, .error, message, fields)
    }

    /// In the list only: an event another component records itself.
    func show(_ scope: String, _ level: Receipt.Level, _ message: String, _ fields: Fields) {
        count += 1
        let rendered = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.text($0.value))" }
        all.append(Receipt(id: count, time: Date(), scope: scope, level: level, message: message,
                           fields: rendered.joined(separator: " ")))
        if all.count > 400 { all.removeFirst(all.count - 400) }
    }

    private static func text(_ value: any Sendable) -> String {
        switch value {
        case let error as any Error: VigilLink.reason(error)
        case let date as Date: date.formatted(date: .omitted, time: .standard)
        case let duration as Duration: duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        case let list as [String]: list.joined(separator: ",")
        default: "\(value)"
        }
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
/// here owns a workspace: the phone is a viewport, every fact stays on the Mac.
@MainActor
final class VigilPhone: ObservableObject {
    static let shared = VigilPhone()

    /// A Mac: a paired device running vigil, named by its tether root.
    struct Host: Identifiable, Hashable {
        let id: String
        var name: String
    }

    /// The paired Macs running vigil, from tether (never typed in).
    @Published private(set) var hosts: [Host] = [] { didSet { rebuildTree() } }
    /// Directories and errors publish; the TREE is derived once per change
    /// (never in a body), and receipts live in their own object so a log
    /// line can never re-render the tree (a receipt re-rendering every row
    /// kills taps mid-update).
    private(set) var directories: [String: Directory] = [:] {
        didSet {
            // A screen hash alone (a working pane repaints several times a
            // second) changes no row: the tree is rebuilt only for what rows draw.
            if Self.rows(oldValue) != Self.rows(directories) { rebuildTree() }
            checkScreens()
            let waiting = directoryWaiters
            directoryWaiters = []
            waiting.forEach { $0.resume() }
        }
    }
    private var directoryWaiters: [Waiter] = []

    /// Returns when the next directory arrives, or after `seconds` (a link
    /// to a pane born a moment ago waits for the document that lists it).
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

    /// The content receipt (the Mac's `checkScreen`, same rule): every
    /// live surface hashes its viewport like the daemon does; a difference
    /// while the daemon's hash held still across two directory reads is a
    /// desync: logged, then re-synced with a dump.
    /// Every Mac's directory as its rows draw it: without content receipts.
    private static func rows(_ directories: [String: Directory]) -> [String: Directory] {
        directories.mapValues(\.unscreened)
    }

    private func checkScreens() {
        for (pane, view) in surfaces {
            guard let truth = directories.values.first(where: { $0.panes[pane] != nil })?.panes[pane],
                  let daemon = truth.screen, !daemon.isEmpty else { continue }
            let mine = view.screenHash
            let stable = daemon == view.screenSeen
            view.screenSeen = daemon
            if mine == daemon {
                view.screenStrikes = 0
                if !view.screenProven { view.screenProven = true; receipts.info("screen", "in sync", ["pane": pane, "hash": mine]) }
                continue
            }
            guard stable else { continue }
            view.screenStrikes += 1
            if view.screenStrikes == 2 {
                view.screenResyncs += 1
                if view.screenResyncs <= 2 {
                    receipts.error("screen", "mismatch; re-syncing", [
                        "pane": pane, "daemon": daemon, "view": mine, "resync": view.screenResyncs,
                    ])
                    view.refreshFromDaemon()
                } else if view.screenResyncs == 3 {
                    receipts.error("screen", "mismatch persists after 2 re-syncs; silenced", ["pane": pane])
                }
                view.screenStrikes = -3
            }
        }
    }
    /// A Mac this phone is not following right now: since when, why, and
    /// how many attempts failed. What is on screen for it is that old, and
    /// its row says so.
    struct Down: Equatable {
        var since: Date
        var reason: String
        var attempts: Int
    }
    private(set) var down: [String: Down] = [:] { didSet { rebuildTree() } }
    @Published private(set) var nodes: [Node] = []
    /// Nothing happens in this app without a receipt here.
    let receipts = VigilReceipts()
    /// vigil's tether node (the one its authz endpoint runs), once up.
    private var node: TetherNode?
    /// What this phone changes on a Mac (a pane seen, followed, where its
    /// activity is reached), kept until that Mac can be reached (`VigilActs`).
    private(set) var acts: VigilActs?
    /// Why vigil has no tether node (it could not start one): the home
    /// screen says so instead of an empty list.
    @Published private(set) var unlinked: String?
    /// Each Mac's directory stream, open, being dialed or pausing to dial again.
    private var watches: [String: Task<Void, Never>] = [:]
    /// Each Mac's `follows` stream: what this phone follows there, as it changes.
    private var followWatches: [String: Task<Void, Never>] = [:]

    private init() {
        Ghostty.SurfaceView.report = { [weak self] message, fields in
            Task { @MainActor in self?.receipts.info("surface", message, fields) }
        }
    }

    // MARK: Macs (paired devices serving vigil/1)

    /// vigil's node is up (VigilAuthz started it): the Macs are the paired
    /// devices serving vigil (tether's offers), read again whenever
    /// tether says who is paired or what a device serves changed.
    func attach(node: TetherNode) {
        guard self.node == nil else { return }
        self.node = node
        unlinked = nil
        let receipts = receipts
        acts = VigilActs(
            node: node,
            file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tether/vigil-acts.json")
        ) { what, facts in
            Task { @MainActor in receipts.info("act", what, facts) }
        }
        receipts.info("tether", "node up", ["root": String(node.root().prefix(10))])
        VigilAgents.begin()
        readPeers()
        Task { [weak self] in
            for await event in node.events {
                switch event {
                case .paired, .revoked, .offersChanged: self?.readPeers()
                // Events were missed: any of them may have changed the Macs.
                case .lagged:
                    self?.receipts.warn("tether", "events missed; reading the Macs again", ["event": "\(event)"])
                    self?.readPeers()
                // How this phone reaches anything: its network, its relay,
                // each connection's start, end and path, each Mac met. The
                // night the phone left home Wi-Fi and reached nothing for
                // hours, none of this was on the phone.
                // In the in-app list only: tether's own record has each.
                case .network, .relay, .localNetwork, .connected, .disconnected, .path, .met:
                    self?.receipts.show("tether", .info, "event", ["event": "\(event)"])
                default: break
                }
            }
        }
    }

    private func readPeers() {
        guard let node else { return }
        let next: [Host]
        do { next = try VigilLink.macs(node).map { Host(id: $0.root, name: $0.name) } } catch {
            // Who the Macs are could not be read: the list stays as it was
            // and says why, never an empty "no Macs".
            return receipts.error("macs", "paired devices not readable", ["err": error])
        }
        if next != hosts {
            hosts = next
            receipts.info("macs", "paired macs changed", ["macs": next.map(\.name)])
            let ids = Set(next.map(\.id))
            directories = directories.filter { ids.contains($0.key) }
            down = down.filter { ids.contains($0.key) }
            for (id, task) in watches where !ids.contains(id) {
                task.cancel()
                watches[id] = nil
            }
            for (id, task) in followWatches where !ids.contains(id) {
                task.cancel()
                followWatches[id] = nil
            }
        }
        for host in hosts { watch(host) }
        // Each Mac learns where this phone's agents activity is reached and
        // what is followed there.
        VigilAgents.macs(Dictionary(uniqueKeysWithValues: hosts.map { host in
            (host.id, followed.compactMap { key -> String? in
                guard key.hasPrefix(host.id + "/") else { return nil }
                let pane = String(key.dropFirst(host.id.count + 1))
                return Open.validPane(pane) ? pane : nil
            })
        }))
    }

    /// vigil could not start its tether node: nothing reaches a Mac.
    func unlinked(_ why: String) {
        unlinked = why
        receipts.error("tether", "no node", ["why": why])
    }

    /// vigil's node, or why there is none yet.
    private func linked() throws -> TetherNode {
        guard let node else { throw WireError.refused("vigil is not connected to tether yet") }
        return node
    }

    // MARK: Directory (followed per Mac: every change as it happens)

    /// Follows a Mac's directory (`VigilLink.directory`: kept alive by
    /// tether, reopened the moment the Mac may be back or the app returns
    /// to the screen); each document is the Mac's whole directory.
    private func watch(_ host: Host) {
        if followWatches[host.id] == nil, let node {
            let follows = VigilLink.follows(node, device: host.id)
            followWatches[host.id] = Task { [weak self] in
                for await panes in follows {
                    VigilAgents.followed(panes, on: host.id)
                    self?.followed(panes, on: host.id)
                }
                guard !Task.isCancelled else { return }
                self?.followWatches[host.id] = nil
            }
        }
        guard watches[host.id] == nil, let node else { return }
        let steps = VigilLink.directory(node, device: host.id)
        watches[host.id] = Task { [weak self] in
            for await step in steps {
                guard let self else { return }
                switch step.step {
                case .open:
                    if let was = self.down[host.id] {
                        self.receipts.info("dir", "following again", [
                            "mac": host.name, "attempts": was.attempts, "down_since": was.since,
                        ])
                    } else {
                        self.receipts.info("dir", "following", ["mac": host.name])
                    }
                    self.down[host.id] = nil
                    VigilAgents.learnNoteKey(of: host.id, node: node)
                case .directory, .changes:
                    // The panes that moved apply onto the directory held (a
                    // follower always gets a whole document first).
                    guard let dir = step.directory
                        ?? step.changes.flatMap({ changes in self.directories[host.id].map { $0.applying(changes) } })
                    else { continue }
                    if self.directories[host.id] == nil {
                        self.receipts.info("dir", "first directory", [
                            "mac": host.name, "host": dir.host, "workspaces": dir.workspaces.count, "panes": dir.panes.count,
                        ])
                    }
                    self.down[host.id] = nil
                    // A glance that did not travel or did not read: said
                    // once per reason; its row is the terminal meanwhile.
                    for (pane, facts) in dir.panes
                    where facts.glanceError != nil && facts.glanceError != self.directories[host.id]?.panes[pane]?.glanceError {
                        self.receipts.warn("dir", "glance not read; its row shows the terminal", [
                            "mac": host.name, "pane": pane, "err": facts.glanceError ?? "",
                        ])
                    }
                    self.directories[host.id] = dir
                case .waiting:
                    // Every attempt is a receipt: a repeat is evidence (how
                    // long, how often), never noise to fold away.
                    let why = step.reason ?? "out of reach"
                    var now = self.down[host.id] ?? Down(since: Date(), reason: why, attempts: 0)
                    now.attempts += 1
                    now.reason = why
                    self.down[host.id] = now
                    self.receipts.warn("dir", "attempt failed", [
                        "mac": host.name, "attempt": now.attempts, "why": why, "down_since": now.since,
                    ])
                }
            }
            // Only the node closing ends a follow: said, and the Mac followed
            // afresh the next time its peers are read.
            guard !Task.isCancelled, let self else { return }
            self.receipts.warn("dir", "follow ended", ["mac": host.name])
            self.watches[host.id] = nil
        }
    }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The home tree: Macs → workspaces → tabs → panes, one collapsible
    /// tree with the sidebar's rollup semantics (a collapsed node wears
    /// its descendants' state cluster: distinct active states, blocked
    /// first, capped at 4; idle only when idle is all there is).
    struct Node: Identifiable, Equatable {
        enum Kind: Equatable { case host, workspace, tab, pane }
        let id: String
        let kind: Kind
        let title: String
        var subtitle: String? = nil
        var emoji: String? = nil
        /// A pane's own state as shown; nodes above carry the cluster.
        var state: AgentState? = nil
        /// Why a pane waits, when it waits.
        var flavor: BlockFlavor? = nil
        var alive: Bool = true
        /// An agent (Claude, Codex) runs in the pane: it has a conversation
        /// to draw, and its screen opens on it.
        var agent: Bool = false
        /// What its agent means right now (its Mac's `PaneGlance`, believed
        /// only while that agent is the pane's program): its row draws it
        /// instead of a live terminal. nil: a shell, a command, a Mac whose
        /// broker publishes none; its row is the terminal, as ever.
        var glance: PaneGlance? = nil
        /// A pane's state in the words every surface uses.
        var words: String { alive ? (state ?? .idle).words(flavor) : "Not running" }
        var pane: PaneRef? = nil
        /// The owner's grid, for the row's live preview.
        var rows: Int = 0
        var cols: Int = 0
        var sizeOwner: String = ""
        /// A pane's place in words that tell it apart from every other pane
        /// on its Mac (`Directory.path`, the one rule): what a row outside the
        /// tree (Following, Switch to, the pane screen) calls it.
        var path: String? = nil
        /// A pane's priority when it is not normal (high rings through
        /// Focus, low never rings), as the Mac's sidebar marks it.
        var priority: Registry.Priority? = nil
        /// A pane open on another Mac right now.
        var onAnotherMac: Bool = false
        /// The pane following this row follows (pane rows only: a follow is
        /// a pane, whatever runs in it).
        var followPane: String? = nil
        /// The pane a new tab or split made from this row stands beside (a
        /// workspace's: its last tab's first pane, so a new tab goes last;
        /// a tab's: its first pane; a pane's: itself). nil for a dock
        /// tenant, which anchors neither, and for a Mac.
        var anchor: String? = nil
        var children: [Node] = []

        /// The Mac's tether root (every id below a Mac starts with it).
        var root: String { String(id.prefix { $0 != "/" }) }
        /// This row's follow id: `<Mac root>/<pane>`.
        var followKey: String? { followPane.map { "\(root)/\($0)" } }
        /// This node and every node under it.
        var all: [Node] { [self] + children.flatMap(\.all) }

        /// The dots this node shows when collapsed (`AgentState.cluster`,
        /// the Mac sidebar's rule), its own state for a pane.
        var cluster: [AgentState] {
            AgentState.cluster(leaves.filter(\.alive).map { $0.state ?? .idle })
        }
        /// Every pane node under this one.
        var leaves: [Node] {
            if kind == .pane { return [self] }
            return children.flatMap { $0.leaves }
        }
    }

    /// Collapse state, persisted: node ids the user folded.
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "vigil.collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "vigil.collapsed") }
    }

    func tree() -> [Node] { nodes }

    /// A made-up tree, for review only (`VigilFixture`): nothing is
    /// followed or dialed for it.
    func fixture(_ tree: [Node]) { nodes = tree }

    // MARK: Following: a pane on the Lock Screen

    /// Follows, by key (`<Mac root>/<pane>`, `Node.followKey`).
    @Published private(set) var followed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "vigil.followed") ?? []) {
        didSet { UserDefaults.standard.set(Array(followed), forKey: "vigil.followed") }
    }

    /// Every followed pane in the tree as it stands, in tree order: the
    /// home's Following list and the ownership of their questions.
    var followedNodes: [Node] {
        nodes.flatMap(\.all).filter { $0.followKey.map(followed.contains) == true }
    }

    /// How long vigil owns a followed pane (authz's limit, `Engine.ownLimit`):
    /// renewed on every foreground and whenever a followed pane comes
    /// alive; vigil unopened for longer hands its questions back to Authz.
    static let ownSpan: TimeInterval = 8 * 3600

    /// Follows a pane (or stops): it is owned with its Mac's authz, so its
    /// questions come to this app and Authz for iPhone stays quiet for it,
    /// and it rides the top of its Mac's agents activity whatever its state
    /// (`VigilAgents`); stopping lets go of both.
    func follow(_ node: Node, _ on: Bool) {
        guard let key = node.followKey, let pane = node.followPane else { return }
        if on { followed.insert(key) } else { followed.remove(key) }
        receipts.info("follow", on ? "followed" : "no longer followed", ["pane": pane, "title": node.title])
        if on {
            own(node, panes: livePanes(node), until: Date().addingTimeInterval(Self.ownSpan))
        } else {
            let kept = Set(followedNodes.flatMap(livePanes))
            own(node, panes: livePanes(node).filter { !kept.contains($0) }, until: Date())
        }
        VigilAgents.follow(pane: pane, on: node.root, on)
    }

    /// What a Mac's board says is followed there (its record: a follow made
    /// from the Mac's own sidebar arrives this way): the Mac's keys here
    /// become exactly those, newly followed panes owned, dropped ones let go.
    func followed(_ panes: [String], on mac: String) {
        let keys = Set(panes.map { "\(mac)/\($0)" })
        let mine = followed.filter { $0.hasPrefix(mac + "/") }
        guard keys != mine else { return }
        let dropped = nodes.flatMap(\.all).filter { $0.followKey.map { mine.contains($0) && !keys.contains($0) } == true }
        followed = followed.subtracting(mine).union(keys)
        receipts.info("follow", "board's record taken", ["mac": String(mac.prefix(10)), "followed": keys.count])
        let kept = Set(followedNodes.flatMap(livePanes))
        for node in dropped { own(node, panes: livePanes(node).filter { !kept.contains($0) }, until: Date()) }
        renewOwnership()
    }

    /// Every follow's panes, owned again for a full span.
    func renewOwnership() {
        let until = Date().addingTimeInterval(Self.ownSpan)
        for node in followedNodes { own(node, panes: livePanes(node), until: until) }
    }

    /// The panes of the follows, as last owned: a pane that joins one is
    /// owned when it appears.
    private var ownedPanes: Set<String> = []

    private func livePanes(_ node: Node) -> [String] { node.leaves.compactMap(\.pane?.pane) }

    private func own(_ node: Node, panes: [String], until: Date) {
        let runtime = VigilAuthz.shared.runtime
        guard let home = runtime.macs.first(where: { $0.id == node.root }).flatMap({ mac -> String? in
            if case .answering(let homeID, _) = mac.state { homeID } else { nil }
        }) else {
            return receipts.warn("follow", "its mac does not let vigil answer yet; questions stay with authz", ["title": node.title])
        }
        for pane in panes {
            if until > Date() { ownedPanes.insert(pane) } else { ownedPanes.remove(pane) }
            Task { await runtime.own(context: pane, home: home, until: until) }
        }
    }

    /// The tree moved: a follow that gained a pane owns it (the agents
    /// activity is its Mac's to draw).
    private func followTree() {
        let until = Date().addingTimeInterval(Self.ownSpan)
        for node in followedNodes {
            let panes = livePanes(node)
            if !Set(panes).isSubset(of: ownedPanes) { own(node, panes: panes, until: until) }
        }
    }

    /// A closed tab, pane or workspace resting on its Mac (vigil.json lists
    /// it with its deadline and where it stood): Undo puts it back there,
    /// End lets it die now, both sent to that Mac.
    struct Burial: Identifiable, Equatable {
        var id: String { host.id + "/" + name }
        let host: Host
        let name: String
        let label: String
        let emoji: String?
        /// Where it goes back ("finances › tab 3"); nil for a workspace.
        let from: String?
        let until: Date
    }
    @Published private(set) var burials: [Burial] = []

    private func deriveBurials() -> [Burial] {
        let now = Date()
        return hosts.flatMap { host -> [Burial] in
            let listed = directories[host.id]?.workspaces ?? []
            return listed.compactMap { workspace in
                guard let until = workspace.buriedUntil, until > now else { return nil }
                let from = workspace.buriedFrom.map { origin in
                    "\(listed.first { $0.name == origin.workspace }?.label ?? origin.workspace) › tab \(origin.tab + 1)"
                }
                return Burial(host: host, name: workspace.name, label: workspace.label, emoji: workspace.emoji, from: from, until: until)
            }
        }
        .sorted { $0.until < $1.until }
    }

    /// Undo (`exhume`) or End (`reap`) on the burial's Mac; what happened
    /// is a receipt, and a refusal is said on the row's section.
    func settle(_ burial: Burial, undo: Bool) {
        let operation = undo ? "exhume" : "reap"
        Task {
            do {
                let request = WorkspaceCommand.Request.burial(burial.name, operation)
                let data = try await VigilLink.call(linked(), device: burial.host.id, .session(try request.line))
                let outcome = try JSONDecoder().decode(WorkspaceCommand.Outcome.self, from: data)
                let fields: Fields = ["op": operation, "mac": burial.host.name, "workspace": burial.name]
                if outcome.ok {
                    receipts.info("burial", "committed", fields)
                } else {
                    receipts.warn("burial", "refused", fields.merging(["why": outcome.message]) { a, _ in a })
                }
                burialError = outcome.ok ? nil : outcome.message
            } catch {
                receipts.error("burial", "failed", ["op": operation, "mac": burial.host.name, "workspace": burial.name, "err": error])
                burialError = VigilLink.reason(error)
            }
        }
    }
    @Published private(set) var burialError: String?

    // MARK: Creating: a workspace, a tab or a pane, on its Mac

    /// What to create. A workspace is the receiving Mac's (`create`: its
    /// folder, its program, its label); a tab or a split is the anchor's
    /// workspace's, in the anchor's folder (`new_tab`, `split`). `command`
    /// is the new pane's program (nil: a shell), shown before it is sent.
    enum Birth: Equatable {
        case workspace(cwd: String, command: String?, label: String?)
        case tab(beside: String, command: String?)
        case split(beside: String, direction: String, command: String?)

        var command: String? {
            switch self {
            case .workspace(_, let command, _), .tab(_, let command), .split(_, _, let command): command
            }
        }

        /// What it is, in the words a receipt and the progress line use.
        var noun: String {
            switch self {
            case .workspace: "workspace"
            case .tab: "tab"
            case .split: "pane"
            }
        }
    }

    /// Why a creation did not happen, in the words the screen shows.
    enum CreateError: Error, CustomStringConvertible {
        /// The home said no (its own words).
        case refused(String)
        /// The anchor is in no workspace its Mac lists, or that Mac's vigil
        /// publishes no revision to edit against.
        case unplaced(String)
        /// The home committed it; its directory has not listed the pane yet.
        case unlisted(mac: String)
        /// It may or may not have happened (the call failed on the way).
        case unknown(String, id: UUID)

        var description: String {
            switch self {
            case .refused(let why): why
            case .unplaced(let why): why
            case .unlisted(let mac): "Created on \(mac), but it isn't listed yet. It appears in the list once it is."
            case .unknown(let why, let id): "\(why). It may have been created: check the list before trying again (command \(id.uuidString.prefix(8)))."
            }
        }
    }

    /// The creation in flight (one at a time: the home compares revisions,
    /// and a second edit against the same one would be refused anyway).
    @Published private(set) var creating: Birth?

    /// Creates `birth` on `host` and returns the new pane once its Mac's
    /// directory lists it (the screen then opens it, keyboard up). Never
    /// retried: an identical command could only be its own receipt, and a
    /// new one could make a second workspace.
    func create(_ birth: Birth, on host: Host) async throws -> PaneRef {
        precondition(creating == nil, "one creation at a time")
        let request: WorkspaceCommand.Request
        switch birth {
        case .workspace(let cwd, let command, let label):
            request = .create(cwd: cwd, command: command, label: label)
        case .tab(let anchor, let command), .split(let anchor, _, let command):
            guard let place = directories[host.id]?.place(of: anchor) else {
                throw CreateError.unplaced("That pane is no longer in a workspace on \(host.name).")
            }
            guard let revision = place.workspace.layoutRevision else {
                throw CreateError.unplaced("vigil on \(host.name) is too old to add tabs or panes from here. Update it there.")
            }
            let direction: String? = if case .split(_, let d, _) = birth { d } else { nil }
            request = .birth(in: place.workspace.name, revision: revision, anchor: anchor, split: direction, command: command)
        }
        if let why = request.refusal { throw CreateError.refused(why) }
        creating = birth
        defer { creating = nil }
        let fields: Fields = ["id": request.id.uuidString, "what": birth.noun, "mac": host.name,
                              "command": birth.command ?? "shell", "anchor": request.anchor]
        receipts.info("create", "sent", fields)
        // Not connected is nothing sent: said as a refusal, never "may have".
        let node: TetherNode
        do { node = try linked() } catch { throw CreateError.refused(VigilLink.reason(error)) }
        let outcome: WorkspaceCommand.Outcome
        do {
            let data = try await VigilLink.call(node, device: host.id, .session(try request.line))
            outcome = try JSONDecoder().decode(WorkspaceCommand.Outcome.self, from: data)
        } catch {
            receipts.error("create", "outcome unknown", fields.merging(["err": error]) { a, _ in a })
            throw CreateError.unknown(VigilLink.reason(error), id: request.id)
        }
        guard outcome.ok, let pane = outcome.pane else {
            receipts.warn("create", "refused", fields.merging(["code": outcome.code, "why": outcome.message]) { a, _ in a })
            throw CreateError.refused(outcome.message)
        }
        receipts.info("create", "committed", fields.merging(["pane": pane, "workspace": outcome.session ?? request.session]) { a, _ in a })
        guard let ref = await listed(pane, within: 10) else {
            receipts.warn("create", "not listed in time", ["pane": pane, "mac": host.name])
            throw CreateError.unlisted(mac: host.name)
        }
        return ref
    }

    /// The folders `host` works in, most recently active first: every
    /// folder its live panes started in, by the latest state change of a
    /// pane there. What a new workspace is most likely to want.
    func recentFolders(on host: Host) -> [String] {
        guard let dir = directories[host.id] else { return [] }
        var latest: [String: Double] = [:]
        for workspace in dir.live {
            for pane in (workspace.tabs ?? []).flatMap(\.members) {
                latest[pane.cwd] = max(latest[pane.cwd] ?? 0, dir.panes[pane.id]?.since ?? 0)
            }
        }
        return latest.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The programs `host`'s panes were born to run (`Pane.command`), most
    /// used first: offered beside a shell when creating.
    func knownCommands(on host: Host) -> [String] {
        guard let dir = directories[host.id] else { return [] }
        let counts = dir.live.flatMap { ($0.tabs ?? []).flatMap(\.members) }.compactMap(\.command)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// Whether `host` can take a creation now (its directory followed).
    func reachable(_ host: Host) -> Bool { directories[host.id] != nil && down[host.id] == nil }

    /// The Mac a new workspace goes to without asking: the only one that
    /// can take it. With several, which one is yours to choose.
    var onlyReachable: Host? {
        let reachable = hosts.filter(reachable)
        return reachable.count == 1 ? reachable[0] : nil
    }

    /// Creates `birth` on `host` from a gesture: `landed` gets the new pane
    /// (the caller opens it), a failure is said once (`failure`), whichever
    /// screen asked.
    func begin(_ birth: Birth, on host: Host, landed: @escaping @MainActor (PaneRef) -> Void) {
        guard creating == nil else {
            failure = .init(title: "Not created", message: "Still creating the last one. Wait for it to open.")
            return
        }
        Task {
            do { landed(try await create(birth, on: host)) } catch {
                failure = .init(title: "Not created", message: "\(error)")
            }
        }
    }

    /// Why the last edit (a creation, a close) did not happen, until it
    /// is read: the new-workspace sheet says it while it is up, the root's
    /// alert anywhere else.
    struct Failure: Equatable {
        let title: String
        let message: String
    }
    @Published var failure: Failure?

    // MARK: Closing: a pane or a tab, on its Mac

    /// A close waiting for your yes: something runs there (`Facts.busy`,
    /// the Mac's one close rule), and closing kills it.
    struct Closing: Identifiable {
        let id = UUID()
        let host: Host
        let anchor: String
        let tab: Bool
        let busy: [String]
        let done: @MainActor () -> Void
    }
    @Published var closing: Closing?

    /// Closes the pane `anchor` (or its whole tab) on its Mac, which buries
    /// it: it waits in Recently closed, undoable, like a close made there.
    /// Asked first only when something runs in it; `done` once its Mac
    /// committed it.
    func bury(_ anchor: String, tab: Bool, on host: Host, done: @escaping @MainActor () -> Void = {}) {
        guard let dir = directories[host.id], let place = dir.place(of: anchor) else {
            failure = .init(title: "Not closed", message: "That pane is no longer in a workspace on \(host.name).")
            return
        }
        let busy = (tab ? place.tab.paneIds : [anchor]).compactMap { dir.panes[$0]?.busy }
        let closing = Closing(host: host, anchor: anchor, tab: tab, busy: busy, done: done)
        if busy.isEmpty { confirm(closing) } else { self.closing = closing }
    }

    /// Sends a close (asked, or nothing to ask).
    func confirm(_ closing: Closing) {
        let host = closing.host
        guard let place = directories[host.id]?.place(of: closing.anchor), let revision = place.workspace.layoutRevision else {
            failure = .init(title: "Not closed", message: "That pane is no longer in a workspace on \(host.name).")
            return
        }
        let request = WorkspaceCommand.Request(session: place.workspace.name, revision: revision,
                                               operation: closing.tab ? "close_tab" : "close_pane", anchor: closing.anchor)
        let fields: Fields = ["id": request.id.uuidString, "op": request.operation, "mac": host.name, "anchor": closing.anchor]
        receipts.info("close", "sent", fields)
        Task {
            do {
                let data = try await VigilLink.call(linked(), device: host.id, .session(try request.line))
                let outcome = try JSONDecoder().decode(WorkspaceCommand.Outcome.self, from: data)
                guard outcome.ok else {
                    receipts.warn("close", "refused", fields.merging(["code": outcome.code, "why": outcome.message]) { a, _ in a })
                    failure = .init(title: "Not closed", message: outcome.message)
                    return
                }
                receipts.info("close", "committed", fields)
                closing.done()
            } catch {
                receipts.error("close", "outcome unknown", fields.merging(["err": error]) { a, _ in a })
                failure = .init(title: "Not closed",
                                message: "\(VigilLink.reason(error)). It may have closed: check the list before trying again.")
            }
        }
    }

    /// The new-workspace sheet, when it is up: on which Mac and in which
    /// folder it starts (the pane you were in, else the Mac you last used).
    struct Compose: Identifiable {
        let id = UUID()
        var host: Host?
        var folder: String?
    }
    @Published var composing: Compose?

    /// Whether closing `pane` closes its whole tab, dock and all: it is the
    /// tab's only pane (the home's rule for `close_pane`).
    func closesTab(_ pane: String, on host: Host) -> Bool {
        directories[host.id]?.place(of: pane)?.tab.panes.map(\.id) == [pane]
    }

    /// The folder a pane started in, as its Mac lists it.
    func folder(of pane: String, on host: Host) -> String? { directories[host.id]?.place(of: pane)?.pane.cwd }

    /// The Mac a tree row belongs to.
    func host(of node: Node) -> Host? {
        let root = node.kind == .host ? String(node.id.dropFirst("host:".count)) : node.root
        return hosts.first { $0.id == root }
    }

    private func rebuildTree() {
        let closed = deriveBurials()
        if closed != burials { burials = closed }
        let fresh = deriveTree()
        guard fresh != nodes else { return }
        nodes = fresh
        indexTree()
        followTree()
        let leaves = fresh.flatMap(\.leaves)
        let gridded = leaves.filter { $0.pane != nil && $0.rows > 0 }.count
        let folded = collapsed.count
        // How each pane row draws, so "why is this row a terminal" is a read
        // of this line: its agent's glance, or the terminal (no glance: a
        // shell, a command, a broker that publishes none, one that did not
        // read; `glance_unread` names those).
        let glanced = leaves.filter { $0.glance != nil }
        let unread = leaves.filter { $0.glance == nil && $0.agent }.compactMap { leaf -> String? in
            guard let pane = leaf.followPane, let host = host(of: leaf) else { return nil }
            return directories[host.id]?.panes[pane]?.glanceError.map { _ in pane }
        }
        receipts.info("tree", "rebuilt", [
            "panes": leaves.count, "previewable": gridded, "folded": folded,
            "glance_rows": glanced.count, "terminal_rows": leaves.count - glanced.count,
            "agents_without_glance": leaves.filter { $0.glance == nil && $0.agent }.map { $0.followPane ?? $0.id },
            "glance_unread": unread,
        ])
    }

    private func deriveTree() -> [Node] {
        hosts.map { host in
            let dir = directories[host.id]
            // Out of reach with a directory on screen: that directory is as
            // old as the outage, and the row says from when.
            let subtitle: String? = down[host.id].map { d in
                let attempt = "attempt \(d.attempts)"
                return dir == nil ? "\(d.reason) · \(attempt)" : "as of \(Self.clock(d.since)) · \(d.reason) · \(attempt)"
            } ?? (dir == nil ? "connecting…" : nil)
            var node = Node(id: "host:\(host.id)", kind: .host,
                            title: dir?.host ?? host.name,
                            subtitle: subtitle)
            guard let dir else { return node }
            node.children = dir.ordered.map { s in
                let tabs = s.tabs ?? []
                let sid = "\(host.id)/\(s.name)"
                var sess = Node(id: sid, kind: .workspace, title: s.label, emoji: s.emoji,
                                anchor: tabs.last?.panes.first?.id)
                let docked = Set(tabs.flatMap { $0.dock?.panes.map(\.id) ?? [] })
                func paneNode(_ p: Registry.Pane) -> Node {
                    let truth = dir.panes[p.id]
                    // The one rule every surface names a pane by (VigilWire's `title`).
                    let title = dir.title(of: p)
                    let alive = truth?.alive ?? false
                    let path = dir.path(of: p.id) ?? title
                    return Node(id: "\(sid)/\(p.id)", kind: .pane, title: title, emoji: p.emoji,
                                state: truth?.shown,
                                flavor: truth?.shown == .blocked ? truth?.token?.flavor : nil,
                                alive: alive,
                                agent: alive && Program.runsAgent(truth?.tree ?? []),
                                glance: alive ? truth?.meaning : nil,
                                pane: alive ? PaneRef(host: host, pane: p.id, title: path) : nil,
                                rows: truth?.grid?.rows ?? 0, cols: truth?.grid?.cols ?? 0,
                                sizeOwner: truth?.owner ?? "",
                                path: path,
                                priority: p.priority == .normal ? nil : p.priority,
                                onAnotherMac: truth?.lookers.contains(.mac) ?? false,
                                followPane: p.id,
                                anchor: docked.contains(p.id) ? nil : p.id)
                }
                for (ti, t) in tabs.enumerated() {
                    let all = t.members
                    let showTab = tabs.count > 1 || t.label != nil || t.emoji != nil
                    if showTab {
                        var tab = Node(id: "\(sid)/t\(ti)", kind: .tab, title: dir.title(ofTab: ti, in: s), emoji: t.emoji,
                                       anchor: t.panes.first?.id)
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

    // MARK: URLs (vigil://pane/<id>)

    /// `vigil://pane/<id>` (a request's Go there, from Authz): the pane is
    /// found by its daemon id on whichever Mac lists it (ids embed a random
    /// session name, unique across Macs). Directories stream, so a pane
    /// born a moment ago arrives with its Mac's next document: up to five
    /// seconds of them are awaited.
    func resolve(url: URL) async -> PaneRef? {
        guard url.scheme == "vigil", url.host == "pane" else {
            receipts.warn("url", "not a pane link", ["url": url.absoluteString]); return nil
        }
        let id = url.lastPathComponent
        guard Open.validPane(id) else { receipts.warn("url", "names no pane", ["url": url.absoluteString]); return nil }
        guard let ref = await listed(id, within: 5) else {
            receipts.warn("url", "no mac lists the pane", ["pane": id])
            return nil
        }
        receipts.info("url", "pane found", ["pane": id, "mac": ref.host.name])
        return ref
    }

    /// The live pane `id` once a Mac's directory lists it, awaiting the
    /// documents that arrive within `seconds` (a pane born a moment ago
    /// arrives with its Mac's next one).
    private func listed(_ id: String, within seconds: TimeInterval) async -> PaneRef? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let ref = nodes.flatMap(\.leaves).compactMap(\.pane).first(where: { $0.pane == id }) { return ref }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            await nextDirectory(within: left)
        }
    }

    /// A pane to show now (a tapped question): the root view navigates to
    /// it and clears it.
    @Published var opening: PaneRef?

    /// A pane to open with the terminal's keyboard up (an activity's
    /// Reply): the pane screen takes it once it shows that pane.
    @Published var typeInto: PaneRef?

    /// `keyboard`: with the terminal's own keyboard up (an activity's Reply).
    func openPane(_ id: String, keyboard: Bool = false) {
        Task {
            guard let url = URL(string: "vigil://pane/\(id)"), let ref = await resolve(url: url) else { return }
            if keyboard { typeInto = ref }
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
        Task.detached { [weak self] in
            let how = await VigilLink.bridge(stream, read: ours, write: ours)
            close(ours)
            await self?.receipts.info("stream", "ended", ["mac": host.name, "pane": pane, "how": "\(how)"])
        }
        receipts.info("stream", preview ? "preview attached" : "attached", ["mac": host.name, "pane": pane, "fd": fds[0]])
        return fds[0]
    }

    // MARK: Conversation: an agent pane's feed and its replies

    /// A pane's conversation feed (`VigilLink.feed`), followed until the
    /// caller stops iterating; why it could not be followed, as a step.
    func feed(_ ref: PaneRef) -> AsyncStream<VigilLink.FeedStep> {
        guard let node else {
            return AsyncStream { $0.yield(.waiting("vigil is not connected to tether yet")); $0.finish() }
        }
        receipts.info("feed", "following", ["mac": ref.host.name, "pane": ref.pane])
        return VigilLink.feed(node, device: ref.host.id, pane: ref.pane)
    }

    /// The page before `before`, the oldest entry the conversation holds.
    func feedEarlier(_ ref: PaneRef, _ request: FeedEarlier) async throws -> FeedPage {
        try await VigilLink.feedEarlier(linked(), device: ref.host.id, pane: ref.pane, request)
    }

    /// Types `text` into the pane as one message (`send`: one paste, one
    /// Enter), as a reply typed at its keyboard would be.
    func send(_ text: String, to ref: PaneRef) async throws {
        _ = try await VigilLink.call(linked(), device: ref.host.id, .send(ref.pane, text: text))
        receipts.info("feed", "reply sent", ["mac": ref.host.name, "pane": ref.pane, "bytes": text.utf8.count])
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
        if rowFrames[ref.pane] == nil {
            receipts.info("tree", "row reported", ["pane": ref.pane, "top": Int(frame.minY), "bottom": Int(frame.maxY)])
        }
        rowFrames[ref.pane] = frame
        allocatePreviews()
    }

    func treeSize(_ size: CGSize) {
        treeViewport = size
        receipts.info("tree", "viewport", ["width": Int(size.width), "height": Int(size.height)])
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
        receipts.info("tree", "previews", [
            "panes": Array(wanted), "rows": rowFrames.count,
            "width": Int(treeViewport.width), "height": Int(treeViewport.height),
        ])
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
                receipts.info("surface", "cap reached; not shown", ["pane": ref.pane, "cap": Self.surfaceCap])
                return nil
            }
            receipts.info("surface", "cap reached; evicted for the screen", ["pane": victim, "for": ref.pane])
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
            self.receipts.warn("surface", "stream died; dropped, the screen re-dials", ["pane": ref.pane])
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
        receipts.info("surface", "ended", ["pane": pane, "live": surfaces.count])
    }

    /// The pane screen is showing `ref` (nil = the tree). Occlusion
    /// follows: only the presented surface renders while a screen is up;
    /// with the tree up, every row's surface renders.
    func present(_ ref: PaneRef?) {
        guard presenting != ref else { return }
        presenting = ref
        receipts.info("pane", "present", ["pane": ref?.pane ?? "tree"])
        for (pane, view) in surfaces {
            view.visible = ref == nil || pane == ref?.pane
        }
        if let ref { markSeen(ref) }
        reportShown()
        // Back on the tree: rows re-report their frames within a frame
        // (the stack's pop lays the list out after this); a surface no
        // visible row wants by then ends. Deferred, never at the pop
        // itself, so a return never re-dials what the rows still show.
        if ref == nil { sweepUnwanted(after: 0.5) }
    }

    /// The screen showing `ref` went away. Only that screen's presentation
    /// ends: a screen replacing it (a pane just created, opened over this
    /// one) may already present its own, and a late disappearance must
    /// not take it back to the tree (whose sweep would end its surface).
    func dismissed(_ ref: PaneRef) {
        guard presenting == ref else {
            receipts.info("pane", "dismissed after another took the screen", ["pane": ref.pane])
            return
        }
        present(nil)
    }

    /// The app is in front (its scene active): what it presents is in front
    /// of you.
    private var active = false
    func scene(active: Bool) {
        guard self.active != active else { return }
        self.active = active
        receipts.info("scene", active ? "active" : "not active")
        reportShown()
    }

    /// What its Mac's authz was last told this phone shows: (home, pane).
    private var shownAt: (home: String, pane: String)?

    /// The pane presented while the app is in front is in front of you:
    /// its Mac's authz is told (`Presence.showing`), so its questions are
    /// answered at the pane here, nothing pops up elsewhere and no phone
    /// rings for them; leaving it (the tree, another pane, the app) says so.
    private func reportShown() {
        let runtime = VigilAuthz.shared.runtime
        let now: (home: String, pane: String)? = presenting.flatMap { ref in
            guard active, let home = runtime.macs.first(where: { $0.id == ref.host.id }).flatMap({ mac -> String? in
                if case .answering(let homeID, _) = mac.state { homeID } else { nil }
            }) else { return nil }
            return (home, ref.pane)
        }
        guard now?.home != shownAt?.home || now?.pane != shownAt?.pane else { return }
        let before = shownAt
        shownAt = now
        Task {
            if let before, before.home != now?.home { await runtime.shows(context: nil, home: before.home) }
            if let now { await runtime.shows(context: now.pane, home: now.home) }
        }
        receipts.info("authz", "shows", ["pane": now?.pane ?? "nothing"])
    }

    /// A pane shown full screen here was seen: the fact belongs to ITS Mac
    /// (`vigild seen`, PROTOCOL.md), written only on a seen-flip (an
    /// outcome not yet seen), the directory updated optimistically so the
    /// row decays with the glance and the Mac's next document confirms it.
    private func markSeen(_ ref: PaneRef) {
        guard let truth = directories[ref.host.id]?.panes[ref.pane], let revision = truth.unseenRevision else { return }
        directories[ref.host.id]?.panes[ref.pane]?.seen = truth.since
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let acts else { throw WireError.refused("vigil is not connected to tether yet") }
                switch try await acts.send(device: ref.host.id, .seen(ref.pane, revision: revision)) {
                case .delivered:
                    receipts.info("seen", "marked", ["pane": ref.pane, "mac": ref.host.name])
                case .kept(let why):
                    // Kept: the Mac takes it when it is back (a newer state
                    // there by then refuses it, as it should).
                    receipts.info("seen", "marked when the mac is back", ["pane": ref.pane, "mac": ref.host.name, "why": why])
                case .dropped(let why):
                    throw WireError.refused(why)
                }
            } catch {
                if directories[ref.host.id]?.panes[ref.pane]?.stateRevision == revision {
                    directories[ref.host.id]?.panes[ref.pane]?.seen = truth.seen
                }
                receipts.error("seen", "not marked", ["pane": ref.pane, "mac": ref.host.name, "err": error])
            }
        }
    }

    // MARK: Index (derived with the tree, never walked in a body)

    private(set) var paneNodes: [PaneRef: Node] = [:]

    func node(for ref: PaneRef) -> Node? { paneNodes[ref] }

    /// Every live pane on a Mac, in the tree's order (each named by its
    /// `path`).
    func livePanes(on host: Host) -> [Node] {
        nodes.first { $0.id == "host:\(host.id)" }?.leaves.filter { $0.pane != nil } ?? []
    }

    private func indexTree() {
        var panes: [PaneRef: Node] = [:]
        for leaf in nodes.flatMap(\.leaves) {
            guard let ref = leaf.pane else { continue }
            panes[ref] = leaf
        }
        paneNodes = panes
    }
}
