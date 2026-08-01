import AppKit
import SwiftUI

/// vigil: sessions as a first-class native concept.
///
/// A session is a named workspace scoped to a WINDOW: every tab of the window
/// (each tab a SplitTree of surfaces) belongs to one session and survives as
/// one unit. It is in exactly one of four states:
///   embedded  showing in a window; live membership is the controller→session
///             map, ordered by the window's tabGroup (AppKit is the single
///             source of truth for grouping)
///   floating  one tab hosted by the quick terminal (Quake-style peek); the
///             other tabs wait as detached trees
///   detached  alive with no window (this manager strongly owns the tab
///             trees, ptys running)
///   asleep    no live surfaces (app relaunch/reboot); only the captured tabs
///             remain and opening reattaches them (their daemons live on)
///             regrouped into one tabbed window
///
/// Identity is pointer-not-value: `name` is the stable key (a random
/// adjective-noun; feeds VIGIL_SESSION and the wake registry), `label` is the
/// human alias. Tabs and splits are structure INSIDE the session, never
/// identities: a new tab joins its window's session, a dragged-out tab mints
/// a new session (reconcileTabs), and daemons are owned by reachability, not
/// by parsing their id.
///
/// Durable state lives in the wake registry (~/.local/state/wake), maintained
/// event-driven by Claude Code hooks. This manager persists name + label +
/// cwd + captured tabs so asleep sessions are listable and resurrectable.
@MainActor
class VigilSessionManager {
    static let shared = VigilSessionManager()

    enum State {
        case embedded
        /// One tab floats in the quick terminal; `rest` are the session's
        /// other tab trees, waiting detached. `floatedIndex` is where the
        /// floating tree reinserts on reclaim.
        case floating(rest: [SplitTree<Ghostty.SurfaceView>], floatedIndex: Int)
        /// One tree per tab, in tab order.
        case detached([SplitTree<Ghostty.SurfaceView>])
        case asleep
    }

    /// Why a session wants Adrian. `input` (claude Notification: permission or
    /// question) outranks `done` (turn finished); FIFO within a rank. Cleared
    /// on open/next, never on mere glancing.
    enum Attention: Int {
        case none = 0
        case done = 1
        case input = 2
    }

    /// Continuous program state of a pane, distinct from Attention: the
    /// attention FIFO is the edge-triggered queue of "needs Adrian" moments;
    /// this is the always-current answer to "what is this pane's program
    /// doing". Written by the hook adapter as a one-word file per pane
    /// (~/.local/state/wake/state/<pane>.state, mtime = since); any program
    /// may adopt the contract (claude does today). Ranked for the sidebar
    /// tree rollup: a collapsed node shows the max over its descendants.
    enum AgentState: Int, Comparable {
        case idle = 0
        case done = 1
        case working = 2
        case blocked = 3
        static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }
    }

    /// Anything projecting session state (sidebar, overview) re-reads on
    /// this: posted from the persist/attention chokepoints.
    static let stateDidChange = Notification.Name("vigilStateDidChange")

    /// When Adrian last looked at each session (focus ack): a pane's `done`
    /// older than the ack displays as idle (finished-and-seen), herdr's
    /// seen-flip without storing a flag anywhere.
    private(set) var lastAck: [String: Date] = [:]

    /// One leaf of the workspace. Every pane lives in a vigild daemon, so
    /// `command` is its attach sentinel and resurrection is native reattach;
    /// a pane that somehow lost its daemon resurrects as a bare shell in its
    /// cwd (the honest fallback, nothing recreated, nothing replayed).
    struct Pane: Codable {
        let cwd: String
        let command: String?
    }

    /// Recursive shape of one tab's splits. Pane indices refer to Tab.panes,
    /// whose order is the tree's DFS leaf order (SplitTree iteration order).
    indirect enum Layout: Codable {
        case leaf(Int)
        case h(Double, Layout, Layout) // left | right, ratio = left share
        case v(Double, Layout, Layout) // top / bottom

        var firstLeaf: Int {
            switch self {
            case .leaf(let i): return i
            case .h(_, let l, _), .v(_, let l, _): return l.firstLeaf
            }
        }
    }

    /// One tab of the workspace, captured: its panes (DFS leaf order) and
    /// their split shape. nil layout = single pane. The dock is the tab's
    /// right bar (a stack of tool panes, one visible), captured alongside.
    struct Tab: Codable {
        var panes: [Pane]
        var layout: Layout?
        var dock: DockCapture?

        init(panes: [Pane], layout: Layout?, dock: DockCapture? = nil) {
            self.panes = panes
            self.layout = layout
            self.dock = dock
        }
    }

    /// The captured shape of one tab's dock: its tenants (ordinary
    /// daemon-backed panes), which one shows, its width, and whether it is
    /// collapsed. Collapse never kills: the tenants' daemons run on.
    struct DockCapture: Codable {
        var panes: [Pane]
        var active: Int
        var width: Double
        var collapsed: Bool
    }

    struct Session {
        let name: String
        var label: String
        /// The session's face: 1–3 emoji, display-only ornament (never
        /// identity, same rule as the label). nil = none.
        var emoji: String? = nil
        var cwd: String
        var state: State
        var attention: Attention = .none
        var attentionSince: Date?
        /// Captured at detach, one entry per tab in tab order; what
        /// resurrection rebuilds (as tabs of ONE window).
        var tabs: [Tab] = []
        /// Manual overview ordering (drag & drop); lower first.
        var order: Int = 0
        /// Pinned-on-top intent, persisted: applied to the window whenever
        /// the session is embedded (open/re-embed/resurrect), so a pin
        /// survives detach, quit and reboot, and a detached/asleep session
        /// can be pinned before it even has a window.
        var pinned: Bool = false
        /// Survival policy. Ephemeral (false): the daemons are killed on
        /// window close and on quit, and the session is never written to
        /// vigil.json. Persistent (true): survives close/quit/reboot and
        /// wears the class border. ⌘⇧P flips this in place; the daemons keep
        /// running either way, so there is never a restart.
        var persistent: Bool = false
        /// A buried ephemeral session: exhumes intact but is never written
        /// to vigil.json. Runtime-only.
        var ephemeral: Bool = false
        /// Loaded intent: this session had a WINDOW when the app last
        /// recorded it (crash or shutdown), so launch restores it as one.
        /// Detached-in-background sessions load with this false and stay
        /// asleep: startup rebuilds the workspace exactly as it was.
        var foreground: Bool = false
        /// Live for embedded (refreshed on overview open), frozen at the
        /// moment of detach for detached. Runtime-only.
        var thumbnail: NSImage?

        var paneCount: Int { tabs.reduce(0) { $0 + $1.panes.count } }
    }

    private(set) var sessions: [String: Session] = [:]

    /// Live membership: which session each tab-controller belongs to. Weak
    /// keys: a controller that dies simply leaves the map. The tabGroup
    /// orders members; this map only assigns them.
    private let memberships = NSMapTable<TerminalController, NSString>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory)

    /// Live docks, keyed by tab controller (the dock is per TAB: its
    /// tenants are context-bound, lazygit of THIS tab's repo). Weak keys;
    /// the runtime strongly owns the tenant SurfaceViews.
    private let dockMap = NSMapTable<TerminalController, VigilDockRuntime>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory)

    /// Docks of detached/floating sessions: session name → tab index →
    /// runtime, index-aligned with the detached trees array (the same
    /// capture order). Re-embed zips them back onto controllers.
    private var detachedDocks: [String: [Int: VigilDockRuntime]] = [:]

    /// Killed sessions rest here for a grace period before their daemons
    /// actually die. Undo (ghostty's native `undo` action; bind cmd+shift+T
    /// to it) exhumes the session intact: kill was a detach + a deadline,
    /// nothing had died yet. Ghostty's own ExpiringUndoManager drives the
    /// expiry. 120s: long enough for regret, short enough that hidden
    /// daemons never linger (config key candidate if it feels wrong).
    private var graveyard: [String: Session] = [:]
    private var graveyardDeadlines: [String: Date] = [:]
    static let killGrace: TimeInterval = 120

    /// Set once at app launch by VigilStatusItem; needed to spawn windows.
    weak var ghosttyApp: Ghostty.App?

    /// Status item hook: called whenever attention state changes.
    var onAttentionChange: (() -> Void)?

    var pendingCount: Int {
        sessions.values.filter { $0.attention != .none }.count
    }

    private var persistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/vigil.json")
    }

    private init() {
        load()
        sweepPaneDaemons()
        startEventWatcher()
        // The sweep is a garbage collector: collection points are events
        // (burial reaps) plus this slow safety tick for anything that dies
        // outside vigil's sight (undo expiry, crashes).
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    VigilSessionManager.shared.sweepPaneDaemons()
                }
            }
        }
        // Fresh ephemeral windows must wear their ring without waiting for
        // a session state change; and a completed tab drag (out or in) has
        // no dedicated AppKit event, but the moved window becomes key, so
        // membership reconciliation rides the same notification.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                VigilSessionManager.shared.reconcileTabs()
                VigilSessionManager.shared.ackFocus(window: window)
                VigilSessionManager.shared.syncWindowMarks()
            }
        }
        // The quick terminal dismissing (any way: toggle, esc-out, focus
        // loss) is the moment a floating session returns to detached.
        NotificationCenter.default.addObserver(
            forName: .quickTerminalDidChangeVisibility,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                let manager = VigilSessionManager.shared
                guard let quick = notification.object as? QuickTerminalController,
                      !quick.visible,
                      let name = manager.floatingName else { return }
                manager.reclaim(name, from: quick)
            }
        }
    }

    // MARK: Membership (session = the window, tabs are members)

    /// The session this tab-controller belongs to.
    func sessionName(of controller: TerminalController) -> String? {
        memberships.object(forKey: controller) as String?
    }

    /// Assign a live controller to a session. All grouping/order comes from
    /// the controller's window and tabGroup; this only records ownership.
    func registerMember(_ controller: TerminalController, name: String) {
        memberships.setObject(name as NSString, forKey: controller)
    }

    /// The session's live tab-controllers in tab order. Controllers whose
    /// window died are not members (weak map + window filter).
    func members(of name: String) -> [TerminalController] {
        var found: [TerminalController] = []
        for controller in TerminalController.all
        where sessionName(of: controller) == name && controller.window != nil {
            found.append(controller)
        }
        guard found.count > 1,
              let group = found.first?.window?.tabGroup?.windows else { return found }
        return found.sorted { a, b in
            let ia = a.window.flatMap { group.firstIndex(of: $0) } ?? .max
            let ib = b.window.flatMap { group.firstIndex(of: $0) } ?? .max
            return ia < ib
        }
    }

    /// The window to focus for a session: its selected tab if the tabGroup
    /// knows one, else the first member's window.
    func focusWindow(of name: String) -> NSWindow? {
        let ms = members(of: name)
        guard let first = ms.first?.window else { return nil }
        if let selected = first.tabGroup?.selectedWindow,
           ms.contains(where: { $0.window === selected }) {
            return selected
        }
        return first
    }

    /// The controller behind the session's focus window (embedded only).
    func anchorController(of name: String) -> TerminalController? {
        guard let window = focusWindow(of: name) else { return nil }
        return window.windowController as? TerminalController
    }

    /// The session's live tab trees in tab order (embedded: member trees;
    /// floating: the waiting rest + the quick terminal's tree; detached:
    /// the owned trees).
    private func liveTrees(_ session: Session) -> [SplitTree<Ghostty.SurfaceView>] {
        switch session.state {
        case .embedded:
            return members(of: session.name).map(\.surfaceTree).filter { !$0.isEmpty }
        case .floating(let rest, _):
            var trees = rest
            if floatingName == session.name,
               let quick = quickController(create: false),
               !quick.surfaceTree.isEmpty {
                trees.append(quick.surfaceTree)
            }
            return trees
        case .detached(let trees):
            return trees
        case .asleep:
            return []
        }
    }

    // MARK: Attention (fed by claude hooks through the wake events log)

    private var eventsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/events.jsonl")
    }

    private var eventsOffset: UInt64 = 0
    private var eventsTimer: Timer?

    /// The drain offset survives relaunches: attention that fired while the
    /// app was CLOSED (a watcher verdict, a headless claude finishing in its
    /// daemon) is exactly the attention a relaunch must surface. Only ancient
    /// history (pre-truncation) is not pending.
    private var eventsOffsetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/events.offset")
    }

    private struct WakeEvent: Decodable {
        let container: String
        let event: String
        /// The vigild pane daemon the claude lives in. Ground truth for
        /// ownership: VIGIL_SESSION in the process env is stamped at birth
        /// and goes stale when a tab is dragged into another session.
        let pane: String?
    }

    /// The session owning this pane daemon right now (live surfaces or
    /// captured sentinels). Ownership is derived, never parsed from the id.
    private func sessionOwning(pane: String) -> String? {
        sessions.first { ownedPaneIds($0.value).contains(pane) }?.key
    }

    /// Tail the events log the claude hooks append to. A 1s poll is honest
    /// enough for human attention; the log is small and offset-read.
    private func startEventWatcher() {
        // Bound the attention log: it is append-only and offset-tailed, so
        // launch is the one safe moment to truncate (the saved offset is
        // reset below when we do). The ms-wide race with a concurrent hook
        // append is accepted.
        var truncated = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: eventsURL.path),
           let size = attrs[.size] as? UInt64, size > 1024 * 1024,
           let handle = try? FileHandle(forReadingFrom: eventsURL) {
            handle.seek(toFileOffset: size - 128 * 1024)
            let tail = handle.readDataToEndOfFile()
            try? handle.close()
            // Cut at a line boundary so the first record parses.
            if let nl = tail.firstIndex(of: 0x0a) {
                try? tail.suffix(from: tail.index(after: nl)).write(to: eventsURL, options: .atomic)
                truncated = true
            }
        }

        // Resume from the last drained position: attention that fired while
        // the app was closed replays now (presence/ownership filters still
        // apply). After a truncation the saved offset points into the old
        // file; the whole bounded tail replays instead.
        let size = (try? FileManager.default.attributesOfItem(atPath: eventsURL.path))
            .flatMap { $0[.size] as? UInt64 } ?? 0
        let saved = (try? String(contentsOf: eventsOffsetURL, encoding: .utf8))
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        eventsOffset = truncated ? 0 : min(saved ?? size, size)
        drainEvents()
        eventsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    VigilSessionManager.shared.drainEvents()
                }
            }
        }
    }

    private func drainEvents() {
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        if size < eventsOffset { eventsOffset = 0 } // log was pruned/rotated
        guard size > eventsOffset else { return }
        handle.seek(toFileOffset: eventsOffset)
        let data = handle.readDataToEndOfFile()
        eventsOffset = size
        try? "\(size)".write(to: eventsOffsetURL, atomically: true, encoding: .utf8)

        var changed = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let event = try? JSONDecoder().decode(WakeEvent.self, from: Data(line.utf8)) else { continue }
            // Ownership resolution, strongest first: the pane daemon the
            // claude lives in (survives drag-out; env container goes
            // stale), then the birth container.
            let name: String
            if let pane = event.pane, !pane.isEmpty, let owner = sessionOwning(pane: pane) {
                name = owner
            } else if sessions[event.container] != nil {
                name = event.container
            } else {
                continue
            }
            // Presence beats attention: an event for the session you are
            // LOOKING AT is already answered; only unwatched sessions queue.
            if isWatching(name) {
                lastAck[name] = Date() // a done that fired under your eyes is seen
                changed = true
                continue
            }
            let attention: Attention = event.event == "Notification" ? .input : .done
            // Escalate only: an input request is not downgraded by a later Stop.
            if attention.rawValue > sessions[name]!.attention.rawValue {
                sessions[name]!.attention = attention
                sessions[name]!.attentionSince = Date()
                changed = true
            }
        }
        if changed {
            onAttentionChange?()
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }

    /// True when Adrian is looking at this session right now: its window
    /// (or the quick terminal hosting it) is key and the app is active.
    private func isWatching(_ name: String) -> Bool {
        guard NSApp.isActive else { return false }
        if floatingName == name,
           quickController(create: false)?.window?.isKeyWindow == true { return true }
        guard let window = focusWindow(of: name) else { return false }
        return window.isKeyWindow
    }

    /// Focusing a session's window IS the acknowledgement: whatever it
    /// wanted, you are there now. Called on every key-window change.
    func ackFocus(window: NSWindow) {
        guard let controller = window.windowController as? TerminalController,
              let name = sessionName(of: controller),
              let session = sessions[name] else { return }
        lastAck[name] = Date()
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        guard session.attention != .none else { return }
        sessions[name]!.attention = .none
        sessions[name]!.attentionSince = nil
        onAttentionChange?()
    }

    /// The head of the attention FIFO: input beats done, oldest first
    /// within a rank.
    private var mostUrgent: Session? {
        sessions.values
            .filter { $0.attention != .none }
            .sorted {
                if $0.attention.rawValue != $1.attention.rawValue {
                    return $0.attention.rawValue > $1.attention.rawValue
                }
                return ($0.attentionSince ?? .distantPast) < ($1.attentionSince ?? .distantPast)
            }
            .first
    }

    /// The attention FIFO: open the most urgent session.
    func next() {
        guard let session = mostUrgent else { return }
        open(name: session.name)
    }

    // MARK: Floating (the quick terminal hosts one tab of a session)

    /// Name of the session currently hosted by the quick terminal.
    private(set) var floatingName: String?
    /// The quick terminal's own workspace, stashed while a session floats
    /// in it; restored when the session leaves.
    private var stashedQuickTree: SplitTree<Ghostty.SurfaceView>?
    /// True while vigil swaps trees in/out of the quick terminal, so its
    /// tree-change observer must not auto-animate the window in.
    private(set) var quickTreeSwap = false

    private func quickController(create: Bool) -> QuickTerminalController? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        if !create && !delegate.quickControllerInitialized { return nil }
        return delegate.quickController
    }

    /// Drop a session into the quick terminal (Quake-style peek). The key
    /// always does something sensible: something floating -> dismiss it;
    /// else the most urgent pending session; else the session of the window
    /// you are in right now. That last fallback is why the key felt dead:
    /// with nothing pending it used to no-op.
    func nextFloating() {
        if floatingName != nil {
            quickController(create: false)?.animateOut()
            return
        }
        if let session = mostUrgent {
            float(name: session.name)
            return
        }
        guard let controller = TerminalController.preferredParent,
              let name = sessionName(of: controller) else { return }
        float(name: name)
    }

    /// Host a session in the quick terminal. An embedded session surrenders
    /// its window first (a detach, capture included) and floats its SELECTED
    /// tab; the other tabs wait detached. Asleep ones resurrect into a real
    /// window instead (a rebuild belongs in a workspace, not a peek).
    func float(name: String) {
        guard let session = sessions[name] else { return }
        guard let quick = quickController(create: true) else { return }

        let tree: SplitTree<Ghostty.SurfaceView>
        var rest: [SplitTree<Ghostty.SurfaceView>] = []
        var floatedIndex = 0
        switch session.state {
        case .embedded:
            // Which tab floats: the one you were looking at.
            let ms = members(of: name)
            let selected = focusWindow(of: name)
            let selectedIndex = ms.firstIndex { $0.window === selected } ?? 0
            detach(name: name)
            guard case .detached(let trees) = sessions[name]!.state, !trees.isEmpty else { return }
            floatedIndex = min(selectedIndex, trees.count - 1)
            tree = trees[floatedIndex]
            rest = trees
            rest.remove(at: floatedIndex)
        case .floating:
            sessions[name]!.attention = .none
            sessions[name]!.attentionSince = nil
            onAttentionChange?()
            quick.animateIn()
            return
        case .detached(let trees):
            guard !trees.isEmpty else { return }
            tree = trees[0]
            rest = Array(trees.dropFirst())
        case .asleep:
            open(name: name)
            return
        }

        // Whoever floats now leaves first; a native quick terminal
        // workspace is stashed, not destroyed.
        if let current = floatingName {
            reclaim(current, from: quick)
        } else if !quick.surfaceTree.isEmpty {
            stashedQuickTree = quick.surfaceTree
        }

        sessions[name]!.state = .floating(rest: rest, floatedIndex: floatedIndex)
        sessions[name]!.attention = .none
        sessions[name]!.attentionSince = nil
        onAttentionChange?()
        floatingName = name
        quickTreeSwap = true
        quick.surfaceTree = tree
        quickTreeSwap = false
        quick.animateIn()
        if let view = tree.root?.leftmostLeaf() {
            DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
        }
        persist()
    }

    /// The floating session leaves the quick terminal: back to detached
    /// with whatever its tree is NOW (splits made while floating survive),
    /// reinserted among its waiting tabs, and the quick terminal gets its
    /// own stashed workspace back.
    func reclaim(_ name: String, from quick: QuickTerminalController) {
        guard floatingName == name else { return }
        floatingName = nil
        let tree = quick.surfaceTree
        if let session = sessions[name] {
            var trees: [SplitTree<Ghostty.SurfaceView>] = []
            var index = 0
            if case .floating(let rest, let floatedIndex) = session.state {
                trees = rest
                index = floatedIndex
            }
            if !tree.isEmpty {
                trees.insert(tree, at: min(index, trees.count))
            }
            if trees.isEmpty {
                sessions[name]!.state = .asleep
            } else {
                sessions[name]!.tabs = captureTabs(name: name, trees)
                sessions[name]!.state = .detached(trees)
            }
        }
        quickTreeSwap = true
        quick.surfaceTree = stashedQuickTree ?? SplitTree()
        quickTreeSwap = false
        stashedQuickTree = nil
        persist()
    }

    // MARK: Lifecycle

    /// Set a session's survival policy directly. Flag flip, no restart; the
    /// scope is the session, which IS the whole window.
    func setPersistent(name: String, _ value: Bool) {
        guard sessions[name] != nil else { return }
        sessions[name]!.persistent = value
        if value { refineIdentity(name: name) }
        persist()
    }

    /// Stamp a fresh window's config so it is daemon-backed from birth (a
    /// vigild attach id + VIGIL_SESSION). Returns nil when the config already
    /// carries vigil identity (attach id or VIGIL_SESSION: create,
    /// resurrection and tab paths handled it), so this only augments plain
    /// windows (⌘N, the startup window, dock reopen). Pair with
    /// registerEphemeralSession once the controller exists.
    func newWindowConfig(
        base: Ghostty.SurfaceConfiguration?
    ) -> (config: Ghostty.SurfaceConfiguration, name: String, cwd: String)? {
        if base?.vigilAttach != nil { return nil }
        if base?.environmentVariables["VIGIL_SESSION"] != nil { return nil }
        let cwd = base?.workingDirectory
            ?? TerminalController.preferredParent?.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let name = newSessionId()
        var config = base ?? Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = "vigil-\(name)-0"
        return (config, name, cwd)
    }

    /// Register a freshly-created plain window as an ephemeral session.
    func registerEphemeralSession(controller: TerminalController, name: String, cwd: String) {
        var session = Session(name: name, label: name, cwd: cwd, state: .embedded)
        session.tabs = [Tab(panes: [Pane(cwd: cwd, command: "\(Self.attachSentinel)vigil-\(name)-0")], layout: nil)]
        sessions[name] = session
        registerMember(controller, name: name)
        vlog("born(window): '\(name)' cwd=\(cwd)")
        persist()
    }

    /// New Session = a new ephemeral, daemon-backed window. The shell/claude
    /// lives in a vigild daemon, not the window's pty, so ⌘⇧P flips
    /// `persistent` with zero restart: the process never moves.
    func create(cwd: String) {
        guard let ghostty = ghosttyApp else { return }
        let name = newSessionId()
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = "vigil-\(name)-0"
        becomeRegular()
        let controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        var session = Session(name: name, label: name, cwd: cwd, state: .embedded)
        session.tabs = [Tab(panes: [Pane(cwd: cwd, command: "\(Self.attachSentinel)vigil-\(name)-0")], layout: nil)]
        sessions[name] = session // persistent defaults false → ephemeral
        registerMember(controller, name: name)
        vlog("born(create): '\(name)' cwd=\(cwd)")
        persist()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pane commands with this prefix are daemon attach ids, not shell
    /// commands; resurrection sets the surface's native attach config.
    static let attachSentinel = "vigil-attach:"

    /// A new tab JOINS its window's session (session scope = the window):
    /// this stamps the config with the parent session's identity and the
    /// next free pane daemon id. Returns nil for configs that already carry
    /// vigil identity (resurrection) or windows with no session.
    func newTabConfig(
        parent: TerminalController,
        base: Ghostty.SurfaceConfiguration?
    ) -> (config: Ghostty.SurfaceConfiguration, name: String)? {
        if base?.vigilAttach != nil { return nil }
        if base?.environmentVariables["VIGIL_SESSION"] != nil { return nil }
        guard let name = sessionName(of: parent) else { return nil }
        var config = base ?? Ghostty.SurfaceConfiguration()
        if config.workingDirectory == nil {
            config.workingDirectory = parent.focusedSurface?.pwd
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = "vigil-\(name)-\(nextPaneIndex(name: name))"
        return (config, name)
    }

    /// Splits inside a session are daemon-backed: called by the split path
    /// for EVERY split; passes through untouched unless this controller
    /// belongs to a session. cwd inherits from the split's origin pane so
    /// the daemon shell starts where you were.
    func configForNewSplit(
        in controller: BaseTerminalController,
        from oldView: Ghostty.SurfaceView,
        base: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceConfiguration? {
        guard let terminal = controller as? TerminalController,
              let name = sessionName(of: terminal) else { return base }
        var config = base ?? Ghostty.SurfaceConfiguration()
        guard config.vigilAttach == nil else { return config }

        config.vigilAttach = "vigil-\(name)-\(nextPaneIndex(name: name))"
        config.environmentVariables["VIGIL_SESSION"] = name
        if config.workingDirectory == nil {
            config.workingDirectory = oldView.pwd
        }
        return config
    }

    /// Every pane daemon id a session owns: live attach surfaces across all
    /// its tab trees plus captured attach sentinels. Ownership is derived
    /// from reachability, NEVER parsed out of the daemon id (the id embeds
    /// the BIRTH session as a label; drag-out moves ownership without
    /// renaming daemons).
    func ownedPaneIds(_ session: Session) -> Set<String> {
        var ids = Set<String>()
        for tree in liveTrees(session) {
            for view in tree {
                if let id = view.vigilAttachId { ids.insert(id) }
            }
        }
        // Dock tenants are panes too: live runtimes (embedded tabs and
        // detached/floating stashes) and captured sentinels all claim their
        // daemons, or the reachability sweep would murder a collapsed dock.
        for controller in members(of: session.name) {
            for view in dockMap.object(forKey: controller)?.views ?? [] {
                if let id = view.vigilAttachId { ids.insert(id) }
            }
        }
        for runtime in (detachedDocks[session.name] ?? [:]).values {
            for view in runtime.views {
                if let id = view.vigilAttachId { ids.insert(id) }
            }
        }
        for tab in session.tabs {
            for pane in tab.panes + (tab.dock?.panes ?? []) {
                if let cmd = pane.command, cmd.hasPrefix(Self.attachSentinel) {
                    ids.insert(String(cmd.dropFirst(Self.attachSentinel.count)))
                }
            }
        }
        return ids
    }

    /// The next free daemon pane index for a session: max over every owned
    /// pane id, plus one. Collision-free across tabs, resurrections and
    /// upgrades.
    private func nextPaneIndex(name: String) -> Int {
        guard let session = sessions[name] else { return 0 }
        var maxIndex = 0
        for id in ownedPaneIds(session) {
            if let n = id.split(separator: "-").last.flatMap({ Int($0) }) {
                maxIndex = max(maxIndex, n)
            }
        }
        return maxIndex + 1
    }

    /// Detach: every tab tree (ptys running) moves from the window to this
    /// manager. Emptying each member's tree closes its window; our strong
    /// reference keeps every surface alive.
    func detach(name: String) {
        guard let session = sessions[name], case .embedded = session.state else { return }
        let ms = members(of: name)
        guard !ms.isEmpty else { return }
        let focus = focusWindow(of: name)
        let focusController = (focus?.windowController as? TerminalController) ?? ms[0]
        if let pwd = focusController.focusedSurface?.pwd { sessions[name]!.cwd = pwd }
        // Freeze the visual: the overview shows what the workspace looked
        // like at the moment it was released. The selected tab's WHOLE
        // window content: a workspace is its splits, one pane is a lie.
        sessions[name]!.thumbnail = Self.windowSnapshot(focusController)
            ?? (focusController.focusedSurface ?? focusController.surfaceTree.root?.leftmostLeaf())?.asImage
        // Trees and docks captured together, index-aligned (empty-tree
        // members are skipped for both, so the indices agree).
        var trees: [SplitTree<Ghostty.SurfaceView>] = []
        var docks: [Int: VigilDockRuntime] = [:]
        for controller in ms where !controller.surfaceTree.isEmpty {
            if let runtime = dockMap.object(forKey: controller) {
                runtime.unmount()
                docks[trees.count] = runtime
                dockMap.removeObject(forKey: controller)
            }
            trees.append(controller.surfaceTree)
        }
        sessions[name]!.tabs = captureTabs(name: name, trees, docks: docks)
        detachedDocks[name] = docks.isEmpty ? nil : docks
        sessions[name]!.state = .detached(trees)
        // Membership ends BEFORE the trees empty: the window-close cascade
        // must see these controllers as session-less.
        for controller in ms {
            memberships.removeObject(forKey: controller)
            controller.surfaceTree = SplitTree()
        }
        // The frozen visual survives relaunch too: asleep sessions keep their
        // face in the overview.
        if let thumb = sessions[name]!.thumbnail {
            persistThumb(name: name, image: thumb)
        }
        persist()
    }

    /// Captured ratios onto a freshly materialized tree. Structural walk:
    /// wherever the realized node and the layout agree (same split kind),
    /// the captured ratio replaces the 0.5 the split was born with; any
    /// divergence (a split that failed to materialize) passes through.
    static func applyRatios(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        _ layout: Layout
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        guard case .split(let split) = node else { return node }
        let ratio: Double
        let l: Layout
        let r: Layout
        switch layout {
        case .leaf: return node
        case .h(let captured, let left, let right):
            guard split.direction == .horizontal else { return node }
            ratio = captured; l = left; r = right
        case .v(let captured, let left, let right):
            guard split.direction == .vertical else { return node }
            ratio = captured; l = left; r = right
        }
        return .split(.init(
            direction: split.direction,
            ratio: ratio,
            left: applyRatios(split.left, l),
            right: applyRatios(split.right, r)))
    }

    /// The workspace's split shape, pane indices in DFS leaf order (the
    /// same order capturePanes walks).
    static func captureLayout(_ tree: SplitTree<Ghostty.SurfaceView>) -> Layout? {
        guard let root = tree.root else { return nil }
        var counter = 0
        func walk(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> Layout {
            switch node {
            case .leaf:
                defer { counter += 1 }
                return .leaf(counter)
            case .split(let split):
                let l = walk(split.left)
                let r = walk(split.right)
                return split.direction == .horizontal
                    ? .h(split.ratio, l, r)
                    : .v(split.ratio, l, r)
            }
        }
        let layout = walk(root)
        if case .leaf = layout { return nil } // single pane: no shape to keep
        return layout
    }

    /// Per-session state directory: VT dumps + frozen thumbnail.
    private func dumpsDir(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/dumps/\(name)")
    }

    /// Capture every tab of the workspace: panes + split shape per tree.
    /// Daemon panes need only their attach sentinel (the daemon IS the
    /// state); a daemon-less pane records its cwd and comes back as a bare
    /// shell.
    private func captureDock(_ runtime: VigilDockRuntime) -> DockCapture? {
        guard !runtime.views.isEmpty else { return nil }
        let panes = runtime.views.map { view -> Pane in
            Pane(
                cwd: view.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
                command: view.vigilAttachId.map { "\(Self.attachSentinel)\($0)" })
        }
        return DockCapture(
            panes: panes,
            active: min(max(runtime.active, 0), panes.count - 1),
            width: Double(runtime.width),
            collapsed: runtime.collapsed)
    }

    /// docks: live runtimes by tab index (detach passes them). nil = carry
    /// forward whatever the session already holds for that index (a stashed
    /// runtime, else the previous capture), so paths that never see docks
    /// (reclaim from the quick terminal) cannot silently drop them: a
    /// dropped capture is an unreachable daemon, and the sweep kills those.
    private func captureTabs(
        name: String, _ trees: [SplitTree<Ghostty.SurfaceView>],
        docks: [Int: VigilDockRuntime]? = nil
    ) -> [Tab] {
        let previous = sessions[name]?.tabs ?? []
        return trees.enumerated().map { (index, tree) in
            let panes = tree.map { view -> Pane in
                let cwd = view.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
                let command = view.vigilAttachId.map { "\(Self.attachSentinel)\($0)" }
                return Pane(cwd: cwd, command: command)
            }
            let dock: DockCapture?
            if let docks {
                dock = docks[index].flatMap { captureDock($0) }
            } else if let runtime = detachedDocks[name]?[index] {
                dock = captureDock(runtime)
            } else {
                dock = index < previous.count ? previous[index].dock : nil
            }
            return Tab(panes: panes, layout: Self.captureLayout(tree), dock: dock)
        }
    }

    private func runFireAndForget(_ bin: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Refresh live thumbnails for embedded sessions (overview open path).
    /// A successful snapshot is also persisted to thumb.png so the card
    /// always has SOMETHING to show, even if a later snapshot fails (a
    /// miniaturized/occluded window, a window mid-layout after re-embed);
    /// on failure we fall back to the last persisted image rather than
    /// blanking the card to "no preview" (the sparse-thumbnail bug).
    func refreshThumbnails() {
        for (name, session) in sessions {
            guard case .embedded = session.state,
                  let controller = anchorController(of: name) else { continue }
            if let image = Self.windowSnapshot(controller) {
                sessions[name]!.thumbnail = image
                persistThumb(name: name, image: image)
            } else if sessions[name]!.thumbnail == nil {
                sessions[name]!.thumbnail = NSImage(
                    contentsOfFile: dumpsDir(name).appendingPathComponent("thumb.png").path)
            }
        }
    }

    /// Write a thumbnail to the session's thumb.png (survives relaunch).
    private func persistThumb(name: String, image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: dumpsDir(name), withIntermediateDirectories: true)
        try? png.write(to: dumpsDir(name).appendingPathComponent("thumb.png"))
    }

    /// The full window content composited (every split), not a single pane.
    static func windowSnapshot(_ controller: TerminalController) -> NSImage? {
        guard let view = controller.window?.contentView else { return nil }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Open: focus if embedded, re-embed if detached, resurrect if asleep.
    /// Detached and asleep sessions come back as ONE window with all their
    /// tabs regrouped (session scope = the window).
    func open(name: String) {
        guard let session = sessions[name] else { vlog("open: '\(name)' UNKNOWN session (noop)"); return }
        guard let ghostty = ghosttyApp else { vlog("open: '\(name)' no ghosttyApp (noop)"); return }
        vlog("open: '\(name)' state=\(stateTag(session.state))")

        // Opening is the acknowledge: attention clears here and only here.
        sessions[name]!.attention = .none
        sessions[name]!.attentionSince = nil
        lastAck[name] = Date()
        onAttentionChange?()
        becomeRegular()

        switch session.state {
        case .floating:
            quickController(create: false)?.animateIn()

        case .embedded:
            guard let window = focusWindow(of: name) else {
                // Every member window died without us noticing. Treat as asleep.
                sessions[name]!.state = .asleep
                open(name: name)
                return
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

        case .detached(let trees):
            vlog("open: '\(name)' detached tabs=\(trees.count) -> re-embed")
            guard let first = trees.first else {
                sessions[name]!.state = .asleep
                open(name: name)
                return
            }
            let controller = TerminalController.newWindow(ghostty, tree: first, confirmUndo: false)
            registerMember(controller, name: name)
            if let dock = detachedDocks[name]?[0] {
                dockMap.setObject(dock, forKey: controller)
            }
            let rest = Array(trees.dropFirst())
            if !rest.isEmpty {
                // The anchor window presents on the NEXT runloop tick
                // (scheduleInitialPresentation); a tab added to an
                // unpresented window is born invisible. Attach after it
                // is actually up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    for (index, tree) in rest.enumerated() {
                        let tab = TerminalController.vigilNewTab(ghostty, parent: controller, tree: tree)
                        self.registerMember(tab, name: name)
                        if let dock = self.detachedDocks[name]?[index + 1] {
                            self.dockMap.setObject(dock, forKey: tab)
                        }
                        self.vlog("open: '\(name)' tab attach window=\(tab.window != nil) grouped=\(tab.window?.tabGroup === controller.window?.tabGroup)")
                    }
                    self.detachedDocks[name] = nil
                    VigilBars.shared.syncAll()
                }
            } else {
                detachedDocks[name] = nil
            }
            sessions[name]!.state = .embedded
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

        case .asleep:
            resurrect(name: name, ghostty: ghostty)
        }
        persist()
    }

    /// Rebuild the whole workspace from its captured tabs: one window, every
    /// tab regrouped, every pane back in its cwd. Daemon panes reattach
    /// natively (living daemon = living processes, per-pane resume rides
    /// VIGILD_RESUME); a daemon-less pane comes back as a bare shell.
    private func resurrect(name: String, ghostty: Ghostty.App) {
        let session = sessions[name]!
        var tabs = session.tabs
        if tabs.isEmpty || tabs.allSatisfy({ $0.panes.isEmpty }) {
            tabs = [Tab(panes: [Pane(cwd: session.cwd, command: nil)], layout: nil)]
        }

        func configFor(_ pane: Pane) -> Ghostty.SurfaceConfiguration {
            resurrectConfig(name: name, pane: pane)
        }

        /// Splits and subsequent tabs wait for their window to actually
        /// present (next runloop tick); building against an unpresented
        /// window drops splits and births invisible tabs.
        vlog("resurrect: '\(name)' tabs=\(tabs.count) panes=\(tabs.map(\.panes.count))")

        func materializeDock(_ controller: TerminalController, _ capture: DockCapture?) {
            materializeDockCapture(controller, capture, configFor: configFor)
        }

        var firstController: TerminalController?
        var tabDelay: TimeInterval = 0
        for tab in tabs {
            let panes = tab.panes
            guard !panes.isEmpty else { continue }
            let firstIndex = min(tab.layout?.firstLeaf ?? 0, panes.count - 1)

            let controller: TerminalController
            if let parent = firstController?.window {
                // Regrouped: subsequent tabs join the first tab's window,
                // staggered behind its presentation. The config already
                // carries vigil identity, so the newTab path passes it
                // through without minting a session.
                tabDelay += 0.3
                let config = configFor(panes[firstIndex])
                DispatchQueue.main.asyncAfter(deadline: .now() + tabDelay) { [weak self] in
                    guard let self else { return }
                    guard let tabController = TerminalController.newTab(
                        ghostty, from: parent, withBaseConfig: config) else {
                        self.vlog("resurrect: '\(name)' tab creation FAILED")
                        return
                    }
                    self.registerMember(tabController, name: name)
                    self.vlog("resurrect: '\(name)' tab up grouped=\(tabController.window?.tabGroup === parent.tabGroup)")
                    self.materializeSplits(tabController, tab: tab, configFor: configFor)
                    materializeDock(tabController, tab.dock)
                }
                continue
            } else {
                controller = TerminalController.newWindow(
                    ghostty, withBaseConfig: configFor(panes[firstIndex]))
                firstController = controller
            }
            registerMember(controller, name: name)

            materializeSplits(controller, tab: tab, configFor: configFor)
            materializeDock(controller, tab.dock)
        }
        sessions[name]!.state = .embedded
        firstController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A pane's resurrection config: cwd + session identity + the native
    /// attach id when its daemon lives (then the surface is a reattach).
    private func resurrectConfig(name: String, pane: Pane) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pane.cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        if let command = pane.command, command.hasPrefix(Self.attachSentinel) {
            config.vigilAttach = String(command.dropFirst(Self.attachSentinel.count))
        }
        return config
    }

    /// A captured dock comes back as live tenant surfaces: their daemons
    /// survived (spec files, `vigild restore`), so each SurfaceView is a
    /// native reattach exactly like a split pane's.
    private func materializeDockCapture(
        _ controller: TerminalController,
        _ capture: DockCapture?,
        configFor: (Pane) -> Ghostty.SurfaceConfiguration
    ) {
        guard let capture, !capture.panes.isEmpty,
              let app = ghosttyApp?.app else { return }
        let views = capture.panes.map {
            Ghostty.SurfaceView(app, baseConfig: configFor($0))
        }
        let runtime = VigilDockRuntime(
            views: views,
            active: min(capture.active, views.count - 1),
            width: CGFloat(capture.width),
            collapsed: capture.collapsed)
        dockMap.setObject(runtime, forKey: controller)
        VigilBars.shared.sync(controller)
    }

    /// Rebuild one tab's splits a beat after its window presents (a split
    /// against an unhosted surface is dropped), then re-shape to the
    /// captured ratios.
    private func materializeSplits(
        _ controller: TerminalController,
        tab: Tab,
        configFor: @escaping (Pane) -> Ghostty.SurfaceConfiguration,
        delay: TimeInterval = 0.7
    ) {
        let panes = tab.panes
        guard panes.count > 1 else { return }
        let layout = tab.layout
        // The default delay exists for windows that have not PRESENTED yet
        // (splits against an unhosted surface drop); mounting into a live
        // window passes 0 and splits land on the next runloop tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let anchor = controller.surfaceTree.root?.leftmostLeaf() else {
                self?.vlog("resurrect: splits DROPPED (no anchor surface)")
                return
            }
            if let layout {
                // Real shape: split the region first (preorder), then
                // recurse into each side.
                @MainActor
                func materialize(_ node: Layout, anchor: Ghostty.SurfaceView) {
                    let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
                    let l: Layout, r: Layout
                    switch node {
                    case .leaf: return
                    case .h(_, let left, let right):
                        direction = .right
                        l = left; r = right
                    case .v(_, let left, let right):
                        direction = .down
                        l = left; r = right
                    }
                    guard r.firstLeaf < panes.count,
                          let rightView = controller.newSplit(
                              at: anchor,
                              direction: direction,
                              baseConfig: configFor(panes[r.firstLeaf]))
                    else { return }
                    materialize(l, anchor: anchor)
                    materialize(r, anchor: rightView)
                }
                materialize(layout, anchor: anchor)
                // Splits are born 0.5; re-shape to the captured ratios
                // wherever the realized tree matches the layout.
                if let root = controller.surfaceTree.root {
                    controller.surfaceTree = SplitTree(
                        root: Self.applyRatios(root, layout),
                        zoomed: nil)
                }
            } else {
                var at: Ghostty.SurfaceView? = anchor
                for pane in panes.dropFirst() {
                    guard let anchorView = at else { break }
                    at = controller.newSplit(at: anchorView, direction: .right, baseConfig: configFor(pane)) ?? at
                }
            }
        }
    }

    // MARK: Close (vigil owns every close; scope decides the meaning)

    /// Closing a session's WINDOW is its lifecycle event: persistent
    /// detaches (everything keeps running), ephemeral is killed with the
    /// undo grace. Returns true when handled (the close must be swallowed
    /// by the caller).
    func handleWindowClose(controller: TerminalController) -> Bool {
        guard let name = sessionName(of: controller) else {
            vlog("handleWindowClose: controller has NO session -> not handled (window closes plain)")
            return false
        }
        let persistent = sessions[name]!.persistent
        let empty = members(of: name).allSatisfy { $0.surfaceTree.isEmpty }
        vlog("handleWindowClose: '\(name)' persistent=\(persistent) emptyTrees=\(empty)")
        if empty {
            for member in members(of: name) { memberships.removeObject(forKey: member) }
            if persistent { sessions[name]!.state = .asleep }
            else { killDaemons(of: sessions[name]!); sessions[name] = nil }
            persist()
            return false
        }
        if persistent {
            detach(name: name)
        } else {
            // Explicit ⌘W on an ephemeral session: the one gesture that
            // kills it, confirmed like ⌘⇧⌫ (Adrian 2026-08-01), then the
            // usual 120s undo grace.
            confirmKill(name: name) { self.kill(name: name) }
        }
        return true
    }

    /// Confirm-then-kill for surfaces outside the keybind path (sidebar
    /// context menu): same alert, same grace.
    func killWithConfirm(name: String) {
        guard sessions[name] != nil else { return }
        confirmKill(name: name) { self.kill(name: name) }
    }

    /// Closing one TAB of a multi-tab session is a structural edit, not a
    /// lifecycle event: the tab leaves the session and becomes its own
    /// buried ephemeral session (120s grace, ⌘⇧T exhumes it into its own
    /// window; expiry kills its pane daemons). Symmetric with drag-out,
    /// which also makes a tab its own session, just an alive one.
    func closeTabStructurally(_ controller: TerminalController) {
        guard let name = sessionName(of: controller) else { return }
        let tree = controller.surfaceTree
        let dock = dockMap.object(forKey: controller)
        memberships.removeObject(forKey: controller)
        dockMap.removeObject(forKey: controller)
        controller.surfaceTree = SplitTree()
        vlog("closeTab: one tab leaves '\(name)'")
        guard !tree.isEmpty else { persist(); return }

        let surface = tree.root?.leftmostLeaf()
        let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
        let cwd = surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let tabName = newSessionId()
        var session = Session(
            name: tabName,
            label: title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title,
            cwd: cwd,
            state: .detached([tree]))
        session.ephemeral = true
        session.thumbnail = surface?.asImage
        // The tab's dock leaves WITH its tab (the dock is the tab's).
        if let dock {
            dock.unmount()
            detachedDocks[tabName] = [0: dock]
            session.tabs = captureTabs(name: tabName, [tree], docks: [0: dock])
        }
        bury(session)
        persist()
    }

    /// The eye on/off toggle: flip the front window's session between
    /// persistent (survives quit) and ephemeral (dies on close), in place.
    func toggleFrontPersist() {
        guard let controller = TerminalController.preferredParent else { return }
        toggleWindowPersist(controller)
    }

    /// The titlebar eye at window scope: the controller's session IS the
    /// window, one flag flip covers every tab.
    func toggleWindowPersist(_ controller: TerminalController) {
        guard let name = sessionName(of: controller) else { return }
        setPersistent(name: name, !(sessions[name]?.persistent ?? false))
    }

    /// True when the front window belongs to a persistent session.
    var frontWindowPersistent: Bool {
        guard let controller = TerminalController.preferredParent,
              let name = sessionName(of: controller) else { return false }
        return sessions[name]?.persistent == true
    }

    /// True when this window belongs to a persistent session.
    func windowPersistent(_ controller: TerminalController) -> Bool {
        guard let name = sessionName(of: controller) else { return false }
        return sessions[name]?.persistent == true
    }

    /// One-gesture detach for the front window: detaching means
    /// keep-running-in-the-background, which is what persistent is.
    func detachFrontWindow() {
        guard let controller = TerminalController.preferredParent,
              let name = sessionName(of: controller) else { return }
        sessions[name]?.persistent = true
        detach(name: name)
        persist()
    }

    /// Mark the window's session persistent (survives close/quit/reboot). The
    /// window is already daemon-backed, so this only flips the flag.
    func persistFully(controller: TerminalController) {
        guard let name = sessionName(of: controller) else { return }
        setPersistent(name: name, true)
    }

    // MARK: Drag-out / drag-in (membership follows AppKit's tabGroups)

    /// True while vigil itself is mutating memberships/trees, so the
    /// key-window observer must not reconcile half-finished states.
    private var reconcilingTabs = false

    /// Make live membership agree with AppKit's tab grouping. Two moves:
    /// a session spanning several tabGroups SPLITS (each stray group mints
    /// a fresh session inheriting the survival class: drag-out); several
    /// sessions sharing one tabGroup MERGE into the group's first session
    /// (drag-in). Daemons never notice: ownership is reachability, and the
    /// surfaces moved with their tabs.
    func reconcileTabs() {
        guard !reconcilingTabs else { return }
        reconcilingTabs = true
        defer { reconcilingTabs = false }

        // Split: one session, several tabGroups.
        for (name, session) in sessions {
            guard case .embedded = session.state else { continue }
            let ms = members(of: name)
            guard ms.count > 1 else { continue }
            let groups = Dictionary(grouping: ms) { controller -> ObjectIdentifier in
                if let group = controller.window?.tabGroup { return ObjectIdentifier(group) }
                return ObjectIdentifier(controller)
            }
            guard groups.count > 1 else { continue }
            // The largest group keeps the identity (ties: the group holding
            // the first member, i.e. tab order).
            let keep = groups.max {
                ($0.value.count, $0.value.first === ms.first ? 1 : 0)
                    < ($1.value.count, $1.value.first === ms.first ? 1 : 0)
            }!.key
            for (id, strays) in groups where id != keep {
                mintSession(from: strays, inheriting: session)
            }
        }

        // Merge: one tabGroup, several sessions. Group order decides the
        // absorber: the session of the group's first session tab.
        var byGroup: [ObjectIdentifier: [(window: NSWindow, name: String)]] = [:]
        for controller in TerminalController.all {
            guard let window = controller.window,
                  let name = sessionName(of: controller),
                  let group = window.tabGroup else { continue }
            byGroup[ObjectIdentifier(group), default: []].append((window, name))
        }
        for (_, entries) in byGroup {
            let ordered = entries.sorted { a, b in
                guard let group = a.window.tabGroup?.windows else { return false }
                return (group.firstIndex(of: a.window) ?? .max) < (group.firstIndex(of: b.window) ?? .max)
            }
            let names = ordered.map(\.name)
            guard let absorber = names.first else { continue }
            for other in Set(names.dropFirst()) where other != absorber {
                absorb(other, into: absorber)
            }
        }
    }

    /// Drag-out: these tabs left their session's window; they become their
    /// own session, inheriting the survival class (dragging a tab out of a
    /// surviving window must not silently make it mortal). The ID stays a
    /// fresh random handle (identity is NEVER derived — the adrian-N
    /// lesson); lineage lives in the LABEL: "<parent label> 2", "… 3",
    /// renameable and refined async when persistent.
    private func mintSession(from controllers: [TerminalController], inheriting old: Session) {
        let name = newSessionId()
        let cwd = controllers.first?.focusedSurface?.pwd ?? old.cwd
        var ordinal = 2
        let taken = Set(sessions.values.map(\.label))
        while taken.contains("\(old.label) \(ordinal)") { ordinal += 1 }
        var session = Session(name: name, label: "\(old.label) \(ordinal)", cwd: cwd, state: .embedded)
        session.persistent = old.persistent
        session.emoji = old.emoji // visual lineage, renameable like the label
        sessions[name] = session
        for controller in controllers { registerMember(controller, name: name) }
        vlog("mint(drag-out): '\(name)' ('\(session.label)') from '\(old.name)' tabs=\(controllers.count) persistent=\(old.persistent)")
        // No async label refinement here: the lineage label is already
        // meaningful (unlike an id seed), and silently replacing it would
        // erase exactly the breadcrumb the mint just created. Rename wins.
        persist()
    }

    /// Drag-in: a session's tabs joined another session's window; the window
    /// absorbs them. Attention escalates; nothing dies (the daemons'
    /// ownership moved with their surfaces).
    private func absorb(_ other: String, into absorberName: String) {
        guard let absorbed = sessions[other], sessions[absorberName] != nil else { return }
        for controller in members(of: other) {
            registerMember(controller, name: absorberName)
        }
        if absorbed.attention.rawValue > sessions[absorberName]!.attention.rawValue {
            sessions[absorberName]!.attention = absorbed.attention
            sessions[absorberName]!.attentionSince = absorbed.attentionSince
        }
        sessions[absorberName]!.persistent =
            sessions[absorberName]!.persistent || absorbed.persistent
        sessions[other] = nil
        try? FileManager.default.removeItem(at: dumpsDir(other))
        vlog("absorb(drag-in): '\(other)' -> '\(absorberName)'")
        persist()
        onAttentionChange?()
    }

    // MARK: Shapeshift (the sidebar's click semantic)

    /// The window is a VIEWPORT: clicking a session in the bar swaps what
    /// this window displays, it never spawns a window. Live targets keep
    /// their home (focus it); detached/asleep targets mount INTO this
    /// window. The current occupant leaves honestly: persistent detaches
    /// (running, invisible), ephemeral buries (120s undo), a session-less
    /// stray's tree buries too.
    func shapeshift(in controller: TerminalController, to targetName: String) {
        guard let target = sessions[targetName], let ghostty = ghosttyApp else { return }
        switch target.state {
        case .embedded, .floating:
            open(name: targetName)
            return
        case .detached, .asleep:
            break
        }
        guard sessionName(of: controller) != targetName else { return }
        guard controller.window != nil else { open(name: targetName); return }
        vlog("shapeshift: window of '\(sessionName(of: controller) ?? "stray")' -> '\(targetName)'")

        releaseOccupant(of: controller)

        // Mounting IS the acknowledge, same as open.
        sessions[targetName]!.attention = .none
        sessions[targetName]!.attentionSince = nil
        lastAck[targetName] = Date()
        onAttentionChange?()
        mount(targetName, into: controller, ghostty: ghostty)
        // No focus theatre: the user is already IN this window; only pull
        // it forward when it is not key (menu/intent entry points).
        if controller.window?.isKeyWindow != true {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        persist()
    }

    /// The current occupant leaves the window WITHOUT the window closing:
    /// every tab is captured, sibling tab-windows close (trees emptied),
    /// and this controller's tree is left alone for mount to REPLACE
    /// (an emptied tree closes the window; a replaced one never does).
    private func releaseOccupant(of controller: TerminalController) {
        if let current = sessionName(of: controller) {
            let ms = members(of: current)
            let trees = ms.map(\.surfaceTree).filter { !$0.isEmpty }
            sessions[current]!.tabs = mergedCapture(name: current)
            if let pwd = controller.focusedSurface?.pwd { sessions[current]!.cwd = pwd }
            sessions[current]!.thumbnail = Self.windowSnapshot(controller)
            // Dock runtimes release with their views: the captures + the
            // daemons carry them; nothing is stashed.
            for member in ms {
                dockMap.object(forKey: member)?.unmount()
                dockMap.removeObject(forKey: member)
            }
            detachedDocks[current] = nil
            for member in ms { memberships.removeObject(forKey: member) }
            for member in ms where member !== controller { member.surfaceTree = SplitTree() }
            if sessions[current]!.persistent {
                // Straight to ASLEEP: every released pane's daemon holds
                // its exact state and the capture resurrects it; keeping
                // detached trees in memory buys nothing and costs window
                // churn on the way back. (A daemon-less pane dies here,
                // the same honesty as app quit.)
                sessions[current]!.state = .asleep
                if let thumb = sessions[current]!.thumbnail {
                    persistThumb(name: current, image: thumb)
                }
            } else {
                // Looking away is NOT a close (Adrian 2026-08-01): an
                // ephemeral session lives on detached-in-memory (trees
                // held, daemons running), listed in the bar, and dies only
                // on explicit ⌘W / ⌘⇧⌫ / ⌘Q.
                sessions[current]!.state = .detached(trees)
            }
        } else if !controller.surfaceTree.isEmpty {
            // Safety-net stray: mint it a REAL ephemeral session (alive,
            // listed, killable) instead of silently burying its tree.
            let tree = controller.surfaceTree
            let surface = controller.focusedSurface ?? tree.root?.leftmostLeaf()
            let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
            let cwd = surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            var stray = Session(
                name: newSessionId(),
                label: title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title,
                cwd: cwd,
                state: .detached([tree]))
            stray.thumbnail = surface?.asImage
            sessions[stray.name] = stray
        }
    }

    /// Mount a detached/asleep session INTO an existing window as ONE
    /// synchronous tree swap: its first tab REPLACES the window's tree and
    /// every other tab stays COLD (capture + running daemons; the sidebar
    /// lists them and a click mounts them the same way). No window is ever
    /// created or closed here: a shapeshift must be instant, not a
    /// shuffle (Adrian 2026-08-01).
    private func mount(_ name: String, into controller: TerminalController, ghostty: Ghostty.App) {
        guard let session = sessions[name] else { return }
        switch session.state {
        case .detached(let trees):
            // Captures were written by whoever detached; mount the first
            // LIVE tree as-is and release the rest to cold (their daemons
            // hold the state, the captures resurrect them on click).
            guard let first = trees.first else {
                sessions[name]!.state = .asleep
                mount(name, into: controller, ghostty: ghostty)
                return
            }
            registerMember(controller, name: name)
            controller.surfaceTree = first
            if let dock = detachedDocks[name]?[0] {
                dockMap.setObject(dock, forKey: controller)
            }
            for runtime in (detachedDocks[name] ?? [:]).values where runtime !== dockMap.object(forKey: controller) {
                runtime.unmount()
            }
            detachedDocks[name] = nil
            sessions[name]!.state = .embedded

        case .asleep:
            var tabs = session.tabs
            if tabs.isEmpty || tabs.allSatisfy({ $0.panes.isEmpty }) {
                tabs = [Tab(panes: [Pane(cwd: session.cwd, command: nil)], layout: nil)]
                sessions[name]!.tabs = tabs
            }
            guard let app = ghostty.app else { return }
            let configFor: (Pane) -> Ghostty.SurfaceConfiguration = { [unowned self] in
                self.resurrectConfig(name: name, pane: $0)
            }
            registerMember(controller, name: name)
            guard let tab = tabs.first(where: { !$0.panes.isEmpty }) else { return }
            let panes = tab.panes
            let firstIndex = min(tab.layout?.firstLeaf ?? 0, panes.count - 1)
            let view = Ghostty.SurfaceView(app, baseConfig: configFor(panes[firstIndex]))
            controller.surfaceTree = SplitTree(view: view)
            materializeSplits(controller, tab: tab, configFor: configFor, delay: 0)
            materializeDockCapture(controller, tab.dock, configFor: configFor)
            sessions[name]!.state = .embedded

        case .embedded, .floating:
            break
        }
    }

    /// Swap WHICH tab of the CURRENT session this window displays: capture
    /// the mounted tab back (its daemons keep its exact state), release
    /// it, materialize the cold tab in place. The viewport rule, one
    /// level down. `anchor` is any pane id of the cold tab (indices shift
    /// as tabs go live/cold; pane ids never lie).
    func shapeshiftTab(name: String, anchor: String, in controller: TerminalController) {
        guard sessionName(of: controller) == name, sessions[name] != nil else { return }
        let tabs = mergedCapture(name: name)
        sessions[name]!.tabs = tabs
        let live = liveAttachIds(of: name)
        guard !live.contains(anchor),
              let target = tabs.first(where: { tab in
                  (tab.panes + (tab.dock?.panes ?? [])).contains { paneId(of: $0) == anchor }
              }),
              !target.panes.isEmpty,
              let app = ghosttyApp?.app else { return }
        vlog("shapeshiftTab: '\(name)' -> tab anchored at \(anchor)")

        dockMap.object(forKey: controller)?.unmount()
        dockMap.removeObject(forKey: controller)
        let configFor: (Pane) -> Ghostty.SurfaceConfiguration = { [unowned self] in
            self.resurrectConfig(name: name, pane: $0)
        }
        let panes = target.panes
        let firstIndex = min(target.layout?.firstLeaf ?? 0, panes.count - 1)
        let view = Ghostty.SurfaceView(app, baseConfig: configFor(panes[firstIndex]))
        controller.surfaceTree = SplitTree(view: view)
        materializeSplits(controller, tab: target, configFor: configFor, delay: 0)
        materializeDockCapture(controller, target.dock, configFor: configFor)
        persist()
    }

    // MARK: Sidebar navigation (rows resolve through shapeshift)

    /// A tab row, anchored by any of its pane ids (indices shift as tabs
    /// go live/cold; pane ids never lie). Live tab → focus its window;
    /// cold tab of THIS window's session → swap it in; anything else →
    /// shapeshift the session here, then swap the tab if it stayed cold.
    func activateTab(name: String, anchor: String?, in controller: TerminalController?) {
        if let anchor, let view = liveView(attachId: anchor), let window = view.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let controller else { open(name: name); return }
        if sessionName(of: controller) != name {
            shapeshift(in: controller, to: name)
        }
        if let anchor, sessionName(of: controller) == name, liveView(attachId: anchor) == nil {
            shapeshiftTab(name: name, anchor: anchor, in: controller)
        }
    }

    /// A pane row: a live surface gets direct focus; a cold one rides
    /// activateTab (its tab mounts), then takes focus.
    func activatePane(name: String, paneId: String?, in controller: TerminalController?) {
        guard let paneId else {
            activateTab(name: name, anchor: nil, in: controller)
            return
        }
        if let view = liveView(attachId: paneId), let window = view.window {
            window.makeKeyAndOrderFront(nil)
            Ghostty.moveFocus(to: view)
            return
        }
        activateTab(name: name, anchor: paneId, in: controller)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let view = self.liveView(attachId: paneId) else { return }
            Ghostty.moveFocus(to: view)
        }
    }

    // MARK: Cycle / ordering / naming

    /// Modal-less cycling, cmd+backtick with the overview's order: focus
    /// moves through LIVE windows only (embedded sessions by manual order,
    /// stray windows last), wrapping. Opening a detached or asleep session
    /// is a deliberate act (overview, Next, the menu); a focus cycle key
    /// must never resurrect windows as a side effect.
    func cycle() {
        reconcile()
        let sessionWindows = sessions.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .compactMap { session -> NSWindow? in
                guard case .embedded = session.state else { return nil }
                return focusWindow(of: session.name)
            }
        let strays = ephemeralControllers().compactMap(\.window)
        let ring = sessionWindows + strays
        guard !ring.isEmpty else { return }

        var current = -1
        if let key = NSApp.keyWindow {
            current = ring.firstIndex { $0 === key || $0.tabGroup === key.tabGroup } ?? -1
        }
        let target = ring[(current + 1) % ring.count]
        becomeRegular()
        if target.isMiniaturized { target.deminiaturize(nil) }
        target.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Manual overview ordering (drag & drop).
    func setOrder(name: String, order: Int) {
        guard sessions[name] != nil else { return }
        sessions[name]!.order = order
        persist()
    }

    func rename(name: String, label: String, emoji: String?) {
        guard sessions[name] != nil else { return }
        sessions[name]!.label = label
        sessions[name]!.emoji = emoji
        persist()
    }

    /// Windows that slipped past registration (should not exist; safety
    /// net) keep a runtime label keyed by the controller.
    private var ephemeralLabels: [ObjectIdentifier: String] = [:]

    func ephemeralLabel(_ controller: TerminalController) -> String? {
        ephemeralLabels[ObjectIdentifier(controller)]
    }

    func renameEphemeral(_ controller: TerminalController, _ label: String) {
        ephemeralLabels[ObjectIdentifier(controller)] = label
    }

    /// State-honest removal: drop the session entity. embedded: unregister,
    /// the window returns to being a plain window (nothing dies; closing it
    /// later kills normally). detached: dropping the only reference releases
    /// the surfaces. asleep: forget the registry entry. wake's own registry
    /// is never touched.
    func forget(name: String) {
        for controller in members(of: name) {
            memberships.removeObject(forKey: controller)
            dockMap.removeObject(forKey: controller)
        }
        detachedDocks[name] = nil
        sessions[name] = nil
        try? FileManager.default.removeItem(at: dumpsDir(name))
        persist()
        onAttentionChange?()
    }

    // MARK: Kill + graveyard

    /// Kill with a grace period: detach silently (window closes, every
    /// process keeps running), bury the session, and only when the grace
    /// expires do the daemons actually die. Undo within the grace exhumes
    /// everything intact. The caller already confirmed; no prompts here.
    func kill(name: String) {
        guard let s = sessions[name] else { vlog("kill: '\(name)' NOT in sessions (noop)"); return }
        vlog("kill: '\(name)' state=\(stateTag(s.state)) persistent=\(s.persistent) -> graveyard")
        if case .floating = sessions[name]!.state, let quick = quickController(create: false) {
            quick.animateOut()
            reclaim(name, from: quick)
        }
        if case .embedded = sessions[name]!.state {
            detach(name: name)
        }
        var session = sessions[name]!
        // The buried trees keep their daemons alive until expiry or exhume.
        // An ephemeral session's burial is not written to vigil.json.
        session.ephemeral = !session.persistent
        sessions[name] = nil
        session.attention = .none
        bury(session)
        persist()
        onAttentionChange?()
    }

    /// Rest a session in the graveyard: 120s grace, undoable, reaped on
    /// expiry. One burial mechanism for every kind of kill (window kill,
    /// structural tab close).
    private func bury(_ session: Session) {
        let name = session.name
        graveyard[name] = session
        graveyardDeadlines[name] = Date().addingTimeInterval(Self.killGrace)

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.undoManager.registerUndo(
                withTarget: self,
                expiresAfter: .seconds(Int64(Self.killGrace))
            ) { manager in
                manager.exhume(name)
            }
            appDelegate.undoManager.setActionName("Kill Session")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace + 1) { [weak self] in
            self?.reapIfExpired(name)
        }
    }

    /// A killed session resting in its grace period, for the overview:
    /// lingers dimmed with a countdown and a recover act.
    struct Burial {
        let name: String
        let label: String
        let emoji: String?
        let deadline: Date
        let thumbnail: NSImage?
        let ephemeral: Bool
    }

    func burials() -> [Burial] {
        graveyard.values.compactMap { session in
            guard let deadline = graveyardDeadlines[session.name] else { return nil }
            return Burial(
                name: session.name,
                label: session.label,
                emoji: session.emoji,
                deadline: deadline,
                thumbnail: session.thumbnail,
                ephemeral: session.ephemeral)
        }
        .sorted { $0.deadline < $1.deadline }
    }

    /// Kill the session you are IN right now, floating or in a normal
    /// window, with no trip to the overview. The floating quick terminal
    /// takes priority when it is the key window (that is what you are
    /// looking at); otherwise the front terminal's session. Always
    /// confirmed first (a keystroke that kills processes must ask), then
    /// undo grace.
    func killCurrent() {
        if let name = floatingName,
           let quick = quickController(create: false),
           quick.window?.isKeyWindow == true {
            confirmKill(name: name) { self.kill(name: name) }
            return
        }
        guard let controller = TerminalController.preferredParent else {
            if let name = floatingName { confirmKill(name: name) { self.kill(name: name) } }
            return
        }
        if let name = sessionName(of: controller) {
            confirmKill(name: name) { self.kill(name: name) }
        } else {
            let title = controller.focusedSurface?.title.trimmingCharacters(in: .whitespaces)
            confirmKill(
                label: (title?.isEmpty == false ? title! : "this window"),
                info: "The window closes and its processes die."
            ) { self.killEphemeral(controller) }
        }
    }

    /// Confirmation before a kill fired from a keystroke (not the overview,
    /// which has its own). Critical alert, Kill/Cancel; runs the kill only
    /// on confirm. Shown from service mode too, hence the activate.
    private func confirmKill(name: String, _ doKill: @escaping () -> Void) {
        let session = sessions[name]
        confirmKill(
            label: [session?.emoji, session?.label ?? name].compactMap { $0 }.joined(separator: " "),
            info: "Its processes die. Undo within \(Int(Self.killGrace))s.",
            thumbnail: session?.thumbnail,
            doKill)
    }

    private func confirmKill(
        label: String, info: String, thumbnail: NSImage? = nil, _ doKill: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Kill \(label)?"
        alert.informativeText = info
        if let thumbnail { alert.icon = thumbnail }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { doKill() }
    }

    /// Undo of a kill: back from the graveyard as a full session (identity
    /// included, ephemeral or not), everything still running.
    func exhume(_ name: String) {
        guard let session = graveyard.removeValue(forKey: name) else { return }
        graveyardDeadlines[name] = nil
        sessions[name] = session
        persist()
        open(name: name)
    }

    /// A window that slipped past registration (safety net) gets the same
    /// courtesy as a session on kill: buried with the grace, exhumable.
    func killEphemeral(_ controller: TerminalController) {
        let tree = controller.surfaceTree
        guard !tree.isEmpty else {
            killController(controller)
            return
        }
        let surface = controller.focusedSurface ?? tree.root?.leftmostLeaf()
        let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
        let cwd = surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        killController(controller)

        var session = Session(
            name: newSessionId(),
            label: title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title,
            cwd: cwd,
            state: .detached([tree]))
        session.ephemeral = true
        bury(session)
    }

    /// Reap NOW, before the grace expires: the daemons die immediately and
    /// the burial is dropped. For "get this out of my face" from the
    /// overview instead of waiting out the 120s.
    func reapNow(_ name: String) {
        graveyardDeadlines[name] = Date.distantPast
        reapIfExpired(name)
    }

    /// The grace ran out: now the kill actually happens. Dropping the
    /// buried trees releases surfaces (recreation processes die) and every
    /// owned pane daemon is killed.
    private func reapIfExpired(_ name: String) {
        guard let deadline = graveyardDeadlines[name], Date() >= deadline else { return }
        // Resolve the daemon list BEFORE releasing anything, then drop every
        // reference so the surfaces fully free, and only THEN kill the
        // daemons: a daemon killed under a live surface posts child_exited
        // into the teardown (the socket EOF), racing the free.
        let paneIds = graveyard[name].map { ownedPaneIds($0) } ?? []
        graveyard[name] = nil
        graveyardDeadlines[name] = nil
        detachedDocks[name] = nil // tenant surfaces freed BEFORE their daemons die
        try? FileManager.default.removeItem(at: dumpsDir(name))
        killDaemons(paneIds: paneIds)
        persist()
        sweepPaneDaemons()
    }

    /// Kill pane daemons by id (resolved by the caller while its references
    /// were still alive).
    private func killDaemons(paneIds: Set<String>) {
        let vigildBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/vigild").path
        for id in paneIds {
            runFireAndForget(vigildBin, ["kill", id])
        }
    }

    /// Kill every pane daemon a session owns. Ownership is the session's
    /// derived pane-id list, never a name-prefix match (a dragged-in tab's
    /// daemon carries its BIRTH session in its id, not its owner).
    private func killDaemons(of session: Session) {
        killDaemons(paneIds: ownedPaneIds(session))
    }

    /// Garbage-collect pane daemons by reachability: a daemon lives while a
    /// live attach surface holds it (any tree anywhere, undo corpses
    /// included: the surface IS the socket) or a captured sentinel claims it
    /// (sessions, burials). Everything else is unreachable and dies. Young
    /// pidfiles are spared: a daemon mid-birth has no surface yet.
    private func sweepPaneDaemons() {
        // Two-instance safety: another instance of THIS bundle shares the
        // vigild state dir, and its ephemeral daemons are invisible to this
        // one (not in vigil.json), so sweeping while it runs would murder
        // its live sessions. Vanilla upstream ghostty never touches vigild
        // and does not block the GC. Caveat until the fork owns its bundle
        // id everywhere: a fork installed under a DIFFERENT id is invisible
        // to this guard.
        let me = ProcessInfo.processInfo.processIdentifier
        let rivals = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.processIdentifier != me
        }
        guard rivals.isEmpty else {
            vlog("sweep: skipped, another instance of this bundle is running")
            return
        }

        var owned = Set<String>()
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects {
            if let id = view.vigilAttachId { owned.insert(id) }
        }
        for session in sessions.values { owned.formUnion(ownedPaneIds(session)) }
        for session in graveyard.values { owned.formUnion(ownedPaneIds(session)) }

        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/vigild")
        let vigildBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/vigild").path
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        where entry.hasSuffix(".pid") && entry.hasPrefix("vigil-") {
            let stem = String(entry.dropLast(4))
            guard !owned.contains(stem) else { continue }
            let path = stateDir.appendingPathComponent(entry).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let created = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(created) < 300 { continue }
            vlog("sweep: unreachable daemon '\(stem)' -> kill")
            runFireAndForget(vigildBin, ["kill", stem])
        }
    }

    // MARK: Dock (the right bar: per-TAB stack of daemon-backed tool panes)

    /// The live dock of a tab, if it has one.
    func dock(for controller: TerminalController) -> VigilDockRuntime? {
        dockMap.object(forKey: controller)
    }

    /// The titlebar toggle: collapse/expand the tab's dock; first use
    /// creates it with one shell tenant in the tab's cwd. Collapse hides
    /// the surface, the daemon keeps running (the detach mechanism).
    func toggleDock(_ controller: TerminalController) {
        if let runtime = dockMap.object(forKey: controller) {
            runtime.collapsed.toggle()
        } else {
            guard addDockTenant(controller) != nil else { return }
        }
        VigilBars.shared.sync(controller)
        persist()
    }

    /// Spawn a new dock tenant: an ordinary daemon-backed pane (own vigild
    /// daemon, VIGIL_SESSION stamped) rooted in the tab's cwd.
    @discardableResult
    func addDockTenant(_ controller: TerminalController) -> Ghostty.SurfaceView? {
        guard let name = sessionName(of: controller),
              let app = controller.ghostty.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = controller.focusedSurface?.pwd
            ?? sessions[name]?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = "vigil-\(name)-\(nextPaneIndex(name: name))"
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let runtime = dockMap.object(forKey: controller) ?? {
            let r = VigilDockRuntime(views: [], active: 0, width: 340, collapsed: false)
            dockMap.setObject(r, forKey: controller)
            return r
        }()
        runtime.views.append(view)
        runtime.active = runtime.views.count - 1
        runtime.collapsed = false
        VigilBars.shared.sync(controller)
        persist()
        return view
    }

    /// Close one tenant: release the surface, then kill its daemon (in
    /// that order, the deferred-free UAF lesson). An explicit small close
    /// on an explicit small pane: no confirm, no grace.
    func closeDockTenant(_ controller: TerminalController, index: Int) {
        guard let runtime = dockMap.object(forKey: controller),
              runtime.views.indices.contains(index) else { return }
        let view = runtime.views.remove(at: index)
        let paneId = view.vigilAttachId
        view.removeFromSuperview()
        runtime.active = min(runtime.active, max(runtime.views.count - 1, 0))
        if runtime.views.isEmpty { dockMap.removeObject(forKey: controller) }
        VigilBars.shared.sync(controller)
        persist()
        if let paneId {
            DispatchQueue.main.async { [weak self] in
                self?.killDaemons(paneIds: [paneId])
            }
        }
    }

    func setDockActive(_ controller: TerminalController, index: Int) {
        guard let runtime = dockMap.object(forKey: controller),
              runtime.views.indices.contains(index) else { return }
        runtime.active = index
        VigilBars.shared.sync(controller)
    }

    func setDockWidth(_ controller: TerminalController, width: CGFloat) {
        guard let runtime = dockMap.object(forKey: controller) else { return }
        runtime.width = min(max(width, 220), 700)
        VigilBars.shared.sync(controller)
    }

    // MARK: Process truth (the daemons' tree/died files, surfaced)

    private var vigildStateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/vigild")
    }

    /// Compact human label for one tree line's argv; nil for noise (shells,
    /// wrappers, caffeinate). Interpreters are named by their script.
    private static func processLabel(_ argv: String) -> String? {
        let parts = argv.split(separator: " ")
        guard let first = parts.first else { return nil }
        let base = URL(fileURLWithPath: String(first)).lastPathComponent
        if base.hasPrefix("-") { return nil }
        let noise: Set<String> = ["fish", "bash", "zsh", "sh", "login", "caffeinate"]
        if noise.contains(base) { return nil }
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "tsx"]
        if interpreters.contains(base) {
            for part in parts.dropFirst() where !part.hasPrefix("-") && !part.contains("=") {
                let pb = URL(fileURLWithPath: String(part)).lastPathComponent
                if pb.contains(".") { return pb }
            }
        }
        return base
    }

    private func paneFileLines(_ pane: String, _ ext: String) -> [String] {
        let url = vigildStateDir.appendingPathComponent("\(pane).\(ext)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// argv column of a tree/died file, skipping line 1 (the pane's shell).
    private func paneCommands(_ pane: String, _ ext: String) -> [String] {
        paneFileLines(pane, ext).dropFirst().map {
            $0.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? ""
        }
    }

    /// The deepest interesting process of one pane (its "program"): last
    /// tree line with a label, so `fish → claude` reads claude and
    /// `fish → bun dev` reads bun. nil = just a shell.
    func paneProgram(_ pane: String) -> String? {
        var out: String?
        for argv in paneCommands(pane, "tree") {
            if let label = Self.processLabel(argv) { out = label }
        }
        return out
    }

    private var agentStateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/state")
    }

    /// The pane's continuous program state as its adapter last wrote it.
    func paneAgentState(_ pane: String) -> (state: AgentState, since: Date)? {
        let url = agentStateDir.appendingPathComponent("\(pane).state")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let state: AgentState
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "working": state = .working
        case "blocked": state = .blocked
        case "done": state = .done
        case "idle": state = .idle
        default: return nil
        }
        let since = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return (state, since ?? .distantPast)
    }

    /// Display state: `done` decays to idle once the session was focused
    /// after it fired (looking at a finished turn IS seeing it).
    func paneDisplayState(_ pane: String, in session: String) -> AgentState? {
        guard let s = paneAgentState(pane) else { return nil }
        if s.state == .done, let ack = lastAck[session], ack >= s.since { return .idle }
        return s.state
    }

    /// The tree rollup: max state over every pane the session owns.
    func sessionAgentState(_ name: String) -> AgentState? {
        guard let session = sessions[name] else { return nil }
        return ownedPaneIds(session).compactMap { paneDisplayState($0, in: name) }.max()
    }

    /// What a session is RUNNING right now, compact and deduped, straight
    /// from the daemons' live tree files.
    func runningSummary(of name: String) -> [String] {
        guard let session = sessions[name] else { return [] }
        var out: [String] = []
        for pane in ownedPaneIds(session).sorted() {
            for argv in paneCommands(pane, "tree") {
                if let label = Self.processLabel(argv), !out.contains(label) {
                    out.append(label)
                }
            }
        }
        return out
    }

    struct DiedProcess {
        let pane: String
        let command: String
    }

    /// What died with the machine and nobody re-armed: tombstones still on
    /// disk for this session's panes. Claude panes consume their own via
    /// the SessionStart hook, so what remains is exactly what needs a
    /// human decision.
    func diedProcesses(of name: String) -> [DiedProcess] {
        guard let session = sessions[name] else { return [] }
        var out: [DiedProcess] = []
        for pane in ownedPaneIds(session).sorted() {
            for argv in paneCommands(pane, "died") {
                guard Self.processLabel(argv) != nil else { continue }
                guard !argv.hasPrefix("claude"), !argv.contains("/claude") else { continue }
                out.append(DiedProcess(pane: pane, command: argv))
            }
        }
        return out
    }

    /// Short labels for the died row in the overview.
    func diedSummary(of name: String) -> [String] {
        var out: [String] = []
        for died in diedProcesses(of: name) {
            if let label = Self.processLabel(died.command), !out.contains(label) {
                out.append(label)
            }
        }
        return out
    }

    /// True when the pane's shell sits at a prompt (pidfile line 3, the
    /// deep foreground, equals the child shell): safe to type into.
    private func paneIdleAtShell(_ pane: String) -> Bool {
        let lines = paneFileLines(pane, "pid")
        guard lines.count >= 3,
              let child = lines[0].split(separator: " ").last.flatMap({ Int($0) }),
              let fg = Int(lines[2].trimmingCharacters(in: .whitespaces))
        else { return false }
        return child == fg
    }

    func liveView(attachId: String) -> Ghostty.SurfaceView? {
        Ghostty.SurfaceView.vigilAttachSurfaces.allObjects
            .first { $0.vigilAttachId == attachId }
    }

    /// Relaunch what died: the exact captured argv, typed into the pane it
    /// died in — ONLY when that pane's shell is idle at a prompt (never
    /// into a running program), and only from an explicit user click (the
    /// click IS the approval that makes replaying a captured command
    /// acceptable). Busy panes keep their tombstone for a later attempt.
    func relaunchDied(name: String) {
        guard case .embedded = sessions[name]?.state else {
            open(name: name)
            return
        }
        let byPane = Dictionary(grouping: diedProcesses(of: name), by: \.pane)
        for (pane, procs) in byPane {
            guard paneIdleAtShell(pane), let view = liveView(attachId: pane) else {
                vlog("relaunch: pane '\(pane)' busy or unattached, tombstone kept")
                continue
            }
            for died in procs {
                view.surfaceModel?.sendText(died.command + "\r")
                vlog("relaunch: '\(died.command)' -> \(pane)")
            }
            try? FileManager.default.removeItem(
                at: vigildStateDir.appendingPathComponent("\(pane).died"))
        }
    }

    /// Drop a session's tombstones without acting on them.
    func dismissDied(name: String) {
        guard let session = sessions[name] else { return }
        for pane in ownedPaneIds(session) {
            try? FileManager.default.removeItem(
                at: vigildStateDir.appendingPathComponent("\(pane).died"))
        }
    }

    /// Silent, total window kill: emptying the tree closes the window without
    /// ghostty's own close confirmation (same mechanism detach uses), and with
    /// no reference kept the surfaces free and the processes die.
    func killController(_ controller: TerminalController) {
        controller.surfaceTree = SplitTree()
    }

    /// Every terminal window NOT registered to a session: should not exist
    /// (every window is session-backed from birth), kept as a safety net so
    /// the overview shows all of ghostty regardless. On-screen windows only:
    /// ghostty retains closed windows for undo-close, and those corpses must
    /// not haunt the overview.
    func ephemeralControllers() -> [TerminalController] {
        TerminalController.all.filter { controller in
            guard let window = controller.window else { return false }
            guard window.isVisible || window.isMiniaturized else { return false }
            guard !controller.surfaceTree.isEmpty else { return false }
            return sessionName(of: controller) == nil
        }
    }

    // MARK: Sidebar snapshot (the left bar's tree, one immutable read)

    struct SidebarPane: Identifiable, Equatable {
        let id: String            // attach id, or a synthetic id for daemon-less panes
        let paneId: String?       // vigild daemon id when daemon-backed
        let title: String         // display: program (argv truth) or surface title
        let program: String?      // the argv truth alone; nil = just a shell
        let state: AgentState?
        let isDock: Bool
    }

    struct SidebarTab: Identifiable, Equatable {
        let id: String
        let title: String
        let index: Int
        let panes: [SidebarPane]
        /// Any pane id of this tab: the join key row clicks resolve by
        /// (indices shift as tabs go live/cold, pane ids never lie).
        var anchor: String?
        /// Captured-but-unmounted (lazy shapeshift): daemons run, no views.
        var cold: Bool = false
    }

    struct SidebarSessionRow: Identifiable, Equatable {
        let id: String            // the session name (the identity)
        let emoji: String?
        let label: String
        let stateTag: String      // live / floating / detached / asleep
        let attention: Attention
        let agg: AgentState?
        let persistent: Bool
        let isFront: Bool
        let tabs: [SidebarTab]
    }

    /// One immutable projection of everything the left bar shows: every
    /// session (live, detached, asleep) → its tabs → their panes (splits
    /// AND dock tenants), each pane with its program (argv truth from the
    /// daemon's tree file) and its continuous AgentState.
    func sidebarSnapshot() -> [SidebarSessionRow] {
        let front = NSApp.keyWindow?.windowController as? TerminalController
        let frontName = front.flatMap { sessionName(of: $0) }

        func paneRow(view: Ghostty.SurfaceView, session: String, isDock: Bool) -> SidebarPane {
            let paneId = view.vigilAttachId
            let program = paneId.flatMap { paneProgram($0) }
            let title = program
                ?? (view.title.isEmpty ? "shell" : view.title)
            return SidebarPane(
                id: paneId ?? "view-\(ObjectIdentifier(view).hashValue)",
                paneId: paneId,
                title: title,
                program: program,
                state: paneId.flatMap { paneDisplayState($0, in: session) },
                isDock: isDock)
        }

        func capturedPaneRow(_ pane: Pane, session: String, index: Int, tab: Int, isDock: Bool) -> SidebarPane {
            let paneId = self.paneId(of: pane)
            let program = paneId.flatMap { paneProgram($0) }
            let title = program
                ?? URL(fileURLWithPath: pane.cwd).lastPathComponent
            return SidebarPane(
                id: paneId ?? "captured-\(session)-\(tab)-\(index)\(isDock ? "-d" : "")",
                paneId: paneId,
                title: title,
                program: program,
                state: paneId.flatMap { paneDisplayState($0, in: session) },
                isDock: isDock)
        }

        /// A tab's skim label: WHERE it lives (cwd basename), never an echo
        /// of its first pane's program (the pane rows already say that).
        func tabTitle(cwd: String?, fallback: String) -> String {
            guard let cwd, !cwd.isEmpty else { return fallback }
            let base = URL(fileURLWithPath: cwd).lastPathComponent
            return base.isEmpty ? fallback : base
        }

        var rows: [SidebarSessionRow] = []
        let ordered = sessions.values.sorted { ($0.order, $0.label) < ($1.order, $1.label) }
        for session in ordered {
            let name = session.name
            var tabs: [SidebarTab] = []
            switch session.state {
            case .embedded:
                for (index, controller) in members(of: name).enumerated() {
                    guard !controller.surfaceTree.isEmpty else { continue }
                    var panes = controller.surfaceTree.map {
                        paneRow(view: $0, session: name, isDock: false)
                    }
                    if let dock = dockMap.object(forKey: controller) {
                        panes += dock.views.map { paneRow(view: $0, session: name, isDock: true) }
                    }
                    let cwd = controller.focusedSurface?.pwd
                        ?? controller.surfaceTree.root?.leftmostLeaf().pwd
                    tabs.append(SidebarTab(
                        id: "\(name)-t\(index)",
                        title: tabTitle(cwd: cwd, fallback: "tab \(index + 1)"),
                        index: index, panes: panes,
                        anchor: panes.first(where: { $0.paneId != nil })?.paneId))
                }
                // COLD tabs: captured, none of their panes live anywhere
                // (lazy shapeshift keeps them asleep on purpose); their
                // daemons run and their state dots stay truthful.
                let live = liveAttachIds(of: name)
                for (index, tab) in session.tabs.enumerated() {
                    let ids = (tab.panes + (tab.dock?.panes ?? [])).compactMap { paneId(of: $0) }
                    guard !ids.isEmpty, ids.allSatisfy({ !live.contains($0) }) else { continue }
                    var panes = tab.panes.enumerated().map {
                        capturedPaneRow($1, session: name, index: $0, tab: index, isDock: false)
                    }
                    panes += (tab.dock?.panes ?? []).enumerated().map {
                        capturedPaneRow($1, session: name, index: $0, tab: index, isDock: true)
                    }
                    tabs.append(SidebarTab(
                        id: "\(name)-c\(index)",
                        title: tabTitle(cwd: tab.panes.first?.cwd, fallback: "tab \(index + 1)"),
                        index: index,
                        panes: panes,
                        anchor: ids.first,
                        cold: true))
                }
            case .floating, .detached:
                for (index, tree) in liveTrees(session).enumerated() {
                    var panes = tree.map { paneRow(view: $0, session: name, isDock: false) }
                    if let dock = detachedDocks[name]?[index] {
                        panes += dock.views.map { paneRow(view: $0, session: name, isDock: true) }
                    }
                    tabs.append(SidebarTab(
                        id: "\(name)-t\(index)",
                        title: tabTitle(cwd: tree.root?.leftmostLeaf().pwd, fallback: "tab \(index + 1)"),
                        index: index,
                        panes: panes,
                        anchor: panes.first(where: { $0.paneId != nil })?.paneId))
                }
            case .asleep:
                for (index, tab) in session.tabs.enumerated() {
                    var panes = tab.panes.enumerated().map {
                        capturedPaneRow($1, session: name, index: $0, tab: index, isDock: false)
                    }
                    panes += (tab.dock?.panes ?? []).enumerated().map {
                        capturedPaneRow($1, session: name, index: $0, tab: index, isDock: true)
                    }
                    tabs.append(SidebarTab(
                        id: "\(name)-t\(index)",
                        title: tabTitle(cwd: tab.panes.first?.cwd, fallback: "tab \(index + 1)"),
                        index: index,
                        panes: panes,
                        anchor: panes.first(where: { $0.paneId != nil })?.paneId,
                        cold: true))
                }
            }
            let tag: String
            switch session.state {
            case .embedded: tag = "live"
            case .floating: tag = "floating"
            case .detached: tag = "detached"
            case .asleep: tag = "asleep"
            }
            rows.append(SidebarSessionRow(
                id: name,
                emoji: session.emoji,
                label: session.label,
                stateTag: tag,
                attention: session.attention,
                agg: tabs.flatMap(\.panes).compactMap(\.state).max(),
                persistent: session.persistent,
                isFront: name == frontName,
                tabs: tabs))
        }
        return rows
    }

    // MARK: Pin on top

    /// Apply a pin state to a live window (Antinote-style float-on-top +
    /// follow-across-spaces).
    private func applyPin(_ window: NSWindow, _ pin: Bool) {
        window.level = pin ? .floating : .normal
        window.collectionBehavior = pin
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed]
    }

    /// Toggle pin for a session-less window (safety net): pure window level.
    func togglePin(_ controller: TerminalController) {
        guard let window = controller.window else { return }
        applyPin(window, !isPinned(controller))
    }

    func isPinned(_ controller: TerminalController) -> Bool {
        controller.window?.level == .floating
    }

    /// Toggle pin for a SESSION by name, whatever its state. The intent is
    /// stored on the session (persisted) so it survives detach/quit/reboot,
    /// and a detached/asleep session can be pinned before it has a window;
    /// live windows get it applied immediately.
    func togglePinSession(_ name: String) {
        guard sessions[name] != nil else { return }
        sessions[name]!.pinned.toggle()
        let pin = sessions[name]!.pinned
        for member in members(of: name) {
            if let window = member.window { applyPin(window, pin) }
        }
        persist()
    }

    /// The pin state of a session (its stored intent).
    func sessionPinned(_ name: String) -> Bool {
        sessions[name]?.pinned ?? false
    }

    /// Pin/unpin the front window (menu + keybind entry point).
    func togglePinFront() {
        guard let controller = TerminalController.preferredParent else { return }
        if let name = sessionName(of: controller) {
            togglePinSession(name)
        } else {
            togglePin(controller)
        }
        // Refresh the titlebar mark so the float icon reflects the new state
        // now, not on the next focus change.
        syncWindowMarks()
    }

    // MARK: Quit

    /// True while quitting should mean "become a menu bar service" instead of
    /// dying. Flipped by quitForReal (the eye menu's explicit kill).
    private var reallyQuit = false

    /// Cmd+Q with sessions alive: detach every persistent session, kill the
    /// ephemeral ones (their daemons die exactly as a normal quit would have
    /// killed their processes), vanish from the dock. Returns true when the
    /// termination must be cancelled.
    func interceptTermination() -> Bool {
        guard !reallyQuit else { return false }
        reconcile()
        // Freeze foreground truth NOW: the detach cascade below closes the
        // windows, and a termination that proceeds to death (vigil-dev
        // pkill, SIGTERM) must record them as OPEN or the next launch
        // restores nothing (observed 2026-08-01: every dev restart came up
        // windowless). Cleared a tick later so service-mode persists go
        // back to live truth.
        var frozen: [String: Bool] = [:]
        for (name, session) in sessions { frozen[name] = isForeground(session) }
        shutdownForeground = frozen
        defer { DispatchQueue.main.async { self.shutdownForeground = nil } }

        if let name = floatingName, let quick = quickController(create: false) {
            reclaim(name, from: quick)
        }
        // Persistent sessions detach and keep running (service mode);
        // ephemeral ones die with the app. Snapshot names first:
        // detach/remove mutate sessions, which must not happen while
        // iterating it.
        let persistentNames = Array(sessions.filter { $0.value.persistent }.keys)
        let ephemeralNames = Array(sessions.filter { !$0.value.persistent }.keys)
        for name in persistentNames {
            if case .embedded = sessions[name]?.state { detach(name: name) }
        }
        for name in ephemeralNames {
            // Daemons resolved while the trees are still alive.
            if let session = sessions[name] { killDaemons(of: session) }
            for controller in members(of: name) { memberships.removeObject(forKey: controller) }
            sessions[name] = nil
        }
        // Nothing to survive: let the app quit for real.
        guard sessions.values.contains(where: { $0.persistent }) else {
            persist()
            return false
        }
        for window in NSApp.windows where window.isVisible {
            window.close()
        }
        // Policy switch deferred a tick: flipping to accessory in the same
        // runloop pass as the window teardown left the status item deaf
        // (observed 2026-07-17, AppKit event routing quirk).
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
        return true
    }

    func quitForReal() {
        reallyQuit = true
        NSApp.terminate(nil)
    }

    /// System shutdown/restart/logout: the app must DIE (cancelling
    /// termination blocks the shutdown), recording the workspace exactly as
    /// it stands so login rebuilds it: foreground flags frozen while the
    /// windows are still open, ephemeral daemons killed (their specs die
    /// with them, so `vigild restore` does not respawn cruft), persistent
    /// daemons left for the OS to kill (their specs survive; restore
    /// respawns them at login).
    func prepareForSystemShutdown() {
        var frozen: [String: Bool] = [:]
        for (name, session) in sessions { frozen[name] = isForeground(session) }
        shutdownForeground = frozen
        for (name, session) in sessions where !session.persistent {
            killDaemons(of: session)
            for controller in members(of: name) { memberships.removeObject(forKey: controller) }
            sessions[name] = nil
        }
        persist()
    }

    /// Launch restoration: reopen every session that had a window when the
    /// app last died (crash or shutdown), in overview order. Detached and
    /// asleep background sessions stay exactly as they were. Returns true
    /// when anything was restored (the caller then skips the virgin
    /// initial window).
    func restoreForegroundSessions() -> Bool {
        let names = sessions.values
            .filter { session in
                guard session.foreground else { return false }
                if case .asleep = session.state { return true }
                return false
            }
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .map(\.name)
        for name in names {
            sessions[name]!.foreground = false
            vlog("restore(launch): '\(name)' -> window")
            open(name: name)
        }
        return !names.isEmpty
    }

    /// Returning from service mode: any opened window brings back the dock
    /// presence.
    private func becomeRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: Instrumentation

    /// Append-only lifecycle trace at ~/.local/state/wake/vigil.log. Every
    /// session transition is recorded so an impossible state is caught the
    /// moment it appears instead of being guessed at from a screenshot.
    /// Dev builds only: a public (Release) build writes nothing to disk.
    func vlog(_ msg: String) {
        #if DEBUG
        let line = "\(Date()) \(msg)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/vigil.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
        #endif
    }

    private func stateTag(_ s: State) -> String {
        switch s {
        case .embedded: return "embedded"
        case .floating: return "floating"
        case .detached(let trees): return "detached(\(trees.count) tabs)"
        case .asleep: return "asleep"
        }
    }

    /// Scream (loudly, in the log) when a session is in a state that must never
    /// exist, so the impossible state is caught the moment it appears instead
    /// of guessed at. Does not crash: the caller self-heals and the app stays
    /// usable for repeated repro.
    func assertInvariants(_ site: String) {
        #if DEBUG
        for (name, s) in sessions {
            if case .embedded = s.state, members(of: name).isEmpty {
                vlog("!! IMPOSSIBLE [\(site)]: '\(name)' embedded with no members, persistent=\(s.persistent)")
            }
            if !s.persistent, case .asleep = s.state {
                vlog("!! IMPOSSIBLE [\(site)]: ephemeral '\(name)' is asleep")
            }
        }
        #endif
    }

    /// Self-heal: sessions whose member windows silently died (persistent
    /// sleeps on its last capture, ephemeral dies: its window IS its life),
    /// membership vs tabGroup divergence, empty-tree corpse windows.
    func reconcile() {
        reconcileTabs()
        let orphaned = sessions.filter { _, session in
            if case .embedded = session.state { return members(of: session.name).isEmpty }
            return false
        }
        for (name, session) in orphaned {
            vlog("reconcile: '\(name)' embedded with no members, persistent=\(session.persistent) -> \(session.persistent ? "asleep" : "killed")")
            if session.persistent {
                sessions[name]!.state = .asleep
            } else {
                killDaemons(of: session)
                sessions[name] = nil
            }
        }
        for controller in TerminalController.all
        where controller.surfaceTree.isEmpty && controller.window?.isVisible == true {
            NSLog("vigil: closing zombie window (empty surface tree)")
            controller.window?.close()
        }
    }

    // MARK: Naming

    private static let idAdjectives = [
        "amber", "bold", "brave", "bright", "calm", "clever", "cosmic", "crisp",
        "daring", "eager", "gentle", "jolly", "keen", "lively", "lucid", "merry",
        "mighty", "nimble", "noble", "proud", "quiet", "rapid", "royal", "sage",
        "sleek", "snowy", "solar", "spry", "stark", "sunny", "swift", "tidal",
        "vivid", "witty", "zesty",
    ]
    private static let idNouns = [
        "otter", "panda", "falcon", "heron", "lynx", "badger", "cedar", "maple",
        "willow", "river", "harbor", "comet", "ember", "quartz", "canyon",
        "meadow", "glacier", "summit", "delta", "fjord", "grove", "dune", "reef",
        "tundra", "aurora", "nebula", "pulsar", "zephyr", "cobalt", "indigo",
        "onyx", "topaz", "raven", "sparrow", "marten",
    ]

    /// A fresh session id — the identity, the source of truth. A pronounceable
    /// adjective-noun (e.g. `brave-panda`) so we can refer to a session out
    /// loud; NOT derived from the cwd (that named everything in $HOME "adrian-N"
    /// and made real sessions look like cruft). The human label is a separate
    /// alias. The daemon id is `vigil-<id>-<index>`, split on the LAST dash, so
    /// the dash in the id is safe.
    private func newSessionId() -> String {
        func taken(_ s: String) -> Bool {
            sessions[s] != nil || graveyard[s] != nil
                || FileManager.default.fileExists(atPath: dumpsDir(s).path)
        }
        func gen() -> String {
            "\(Self.idAdjectives.randomElement()!)-\(Self.idNouns.randomElement()!)"
        }
        var id = gen()
        var tries = 0
        while taken(id) {
            tries += 1
            id = tries < 40 ? gen() : "\(gen())-\(Int.random(in: 2...999))"
        }
        return id
    }

    /// What the sparkle (and the persist refinement) reasons from: cwd,
    /// current label, what the daemons actually run, the visible screen.
    func identityContext(name: String) -> String {
        guard let session = sessions[name] else { return "" }
        let screen = anchorController(of: name)?.focusedSurface?.cachedScreenContents.get() ?? ""
        let running = runningSummary(of: name).joined(separator: ", ")
        return "cwd: \(session.cwd)\ntitle: \(session.label)\nrunning: \(running)\nscreen:\n\(screen.suffix(1500))"
    }

    /// Emoji already chosen across sessions, deduped: the editor's one-click
    /// reuse strip.
    func recentEmoji() -> [String] {
        var out: [String] = []
        for session in sessions.values {
            guard let emoji = session.emoji else { continue }
            for cluster in emoji.map(String.init) where !out.contains(cluster) {
                out.append(cluster)
            }
        }
        return out
    }

    /// Ask the on-device model for a nicer identity (emoji + label as one
    /// coherent pair), from what the session is doing. Fire-and-forget: if
    /// the model is unavailable or slow the seeds stand, and a manual choice
    /// always wins (label applied only if untouched since the seed, emoji
    /// only if still unset at both ends).
    private func refineIdentity(name: String) {
        guard VigilIdentity.modelAvailable else { return }
        guard let session = sessions[name] else { return }
        let seedLabel = session.label
        let hadEmoji = session.emoji != nil
        let context = identityContext(name: name)

        Task {
            guard let suggestion = await VigilIdentity.suggest(context: context, avoiding: []) else { return }
            await MainActor.run {
                guard let current = self.sessions[name] else { return }
                var changed = false
                if current.label == seedLabel {
                    self.sessions[name]!.label = suggestion.label
                    changed = true
                }
                if !hadEmoji, current.emoji == nil, !suggestion.emoji.isEmpty {
                    self.sessions[name]!.emoji = suggestion.emoji
                    changed = true
                }
                if changed { self.persist() }
            }
        }
    }

    // MARK: Persistence (identity + cwd + captured tabs; trees are runtime)

    private struct PersistedSession: Codable {
        let name: String
        let label: String
        let emoji: String?
        let cwd: String
        let tabs: [Tab]?
        let order: Int?
        let pinned: Bool?
        let buriedUntil: Date?
        /// Had a window at record time; launch restores it as one.
        let foreground: Bool?
    }

    /// Frozen foreground truth for the shutdown persist: the flags must
    /// record the windows as OPEN while the app dies with them showing.
    private var shutdownForeground: [String: Bool]?

    /// Was this session showing (window or quick terminal) at persist time?
    private func isForeground(_ session: Session) -> Bool {
        if let frozen = shutdownForeground { return frozen[session.name] ?? false }
        switch session.state {
        case .embedded, .floating: return true
        case .detached, .asleep: return false
        }
    }

    /// The daemon id a captured pane attaches to, if any.
    func paneId(of pane: Pane) -> String? {
        guard let cmd = pane.command, cmd.hasPrefix(Self.attachSentinel) else { return nil }
        return String(cmd.dropFirst(Self.attachSentinel.count))
    }

    /// Every attach id LIVE in a session's member windows (trees + docks).
    private func liveAttachIds(of name: String) -> Set<String> {
        var ids = Set<String>()
        for member in members(of: name) {
            for view in member.surfaceTree {
                if let id = view.vigilAttachId { ids.insert(id) }
            }
            for view in dockMap.object(forKey: member)?.views ?? [] {
                if let id = view.vigilAttachId { ids.insert(id) }
            }
        }
        return ids
    }

    /// Capture an embedded session WITHOUT losing its COLD tabs: live
    /// member trees capture normally; previous captures none of whose
    /// panes are live anywhere carry forward. Cold tabs are deliberate
    /// (shapeshift mounts lazily, the daemons hold their state); dropping
    /// one from the capture would strand its daemons for the sweep.
    private func mergedCapture(name: String) -> [Tab] {
        guard let session = sessions[name] else { return [] }
        var trees: [SplitTree<Ghostty.SurfaceView>] = []
        var docks: [Int: VigilDockRuntime] = [:]
        for member in members(of: name) where !member.surfaceTree.isEmpty {
            if let runtime = dockMap.object(forKey: member) {
                docks[trees.count] = runtime
            }
            trees.append(member.surfaceTree)
        }
        var tabs = captureTabs(name: name, trees, docks: docks)
        let live = liveAttachIds(of: name)
        for tab in session.tabs {
            let ids = (tab.panes + (tab.dock?.panes ?? [])).compactMap { paneId(of: $0) }
            guard !ids.isEmpty, ids.allSatisfy({ !live.contains($0) }) else { continue }
            tabs.append(tab)
        }
        return tabs
    }

    /// Captures of EMBEDDED sessions go stale between detaches, and a hard
    /// app kill (crash, vigil-dev restart) then resurrects the LAST
    /// DETACH's shape while the launch sweep murders every daemon the
    /// stale capture never claimed (cost real panes 2026-08-01:
    /// sleek-onyx-1/2/3, bold-willow-7). Refresh at the persist
    /// chokepoint: every state change re-captures the live shape, so
    /// vigil.json always resurrects what is actually on screen.
    private func refreshEmbeddedCaptures() {
        for (name, session) in sessions {
            guard case .embedded = session.state else { continue }
            guard !members(of: name).isEmpty else { continue }
            let tabs = mergedCapture(name: name)
            if !tabs.isEmpty { sessions[name]!.tabs = tabs }
        }
    }

    private func persist() {
        refreshEmbeddedCaptures()
        var entries = sessions.values.filter { $0.persistent }.map {
            PersistedSession(name: $0.name, label: $0.label, emoji: $0.emoji, cwd: $0.cwd, tabs: $0.tabs, order: $0.order, pinned: $0.pinned, buriedUntil: nil, foreground: isForeground($0))
        }
        entries += graveyard.values.filter { !$0.ephemeral }.map {
            PersistedSession(name: $0.name, label: $0.label, emoji: $0.emoji, cwd: $0.cwd, tabs: $0.tabs, order: $0.order, pinned: $0.pinned, buriedUntil: graveyardDeadlines[$0.name], foreground: false)
        }
        entries.sort { $0.name < $1.name }
        let data = try! JSONEncoder().encode(entries)
        try? FileManager.default.createDirectory(
            at: persistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try! data.write(to: persistURL)
        syncWindowMarks()
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// Idempotent: every window of a persistent session carries the
    /// vigilance mark (eye + label titlebar pill, colored by survival class)
    /// and a matching content border; every other window carries none. One
    /// sync walks all windows; called from persist(), the chokepoint every
    /// state change already flows through (plus any window becoming key,
    /// for fresh windows).
    private func syncWindowMarks() {
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            // Real terminal windows only (skip corpses without a tree).
            guard window.isVisible || window.isMiniaturized else { continue }
            guard !controller.surfaceTree.isEmpty else { continue }

            let existing = window.titlebarAccessoryViewControllers.enumerated()
                .first { $0.element is VigilTitlebarAccessory }

            let name = sessionName(of: controller)
            let persistent = name.map { sessions[$0]?.persistent == true } ?? false

            // Enforce a session's stored pin intent on its live window
            // (covers resurrection/re-embed for free); session-less windows
            // keep their pure window-level pin.
            if let name, let session = sessions[name] {
                applyPin(window, session.pinned)
            }
            let pinned = name.map { sessionPinned($0) } ?? isPinned(controller)

            let mark = VigilWindowMark(
                label: name.flatMap { sessions[$0]?.label },
                emoji: name.flatMap { sessions[$0]?.emoji },
                persistent: persistent,
                pinned: pinned,
                dockOpen: dockMap.object(forKey: controller).map { !$0.collapsed } ?? false,
                onEditIdentity: name.map { n in { VigilIdentity.editModal(name: n) } },
                onTogglePersist: { [weak self] in
                    // Session scope IS the window: one flip covers every tab.
                    self?.toggleWindowPersist(controller)
                },
                onTogglePin: { [weak self] in
                    if let name { self?.togglePinSession(name) }
                    else { self?.togglePin(controller); self?.persist() }
                },
                onToggleDock: name == nil ? nil : { [weak self] in
                    self?.toggleDock(controller)
                })

            if let hosting = existing?.element.view as? NSHostingView<VigilWindowMark> {
                hosting.rootView = mark
                hosting.setFrameSize(hosting.fittingSize)
            } else {
                let hosting = NSHostingView(rootView: mark)
                // A titlebar accessory does not lay out from SwiftUI intrinsic
                // size on its own; give the hosting view a concrete frame or
                // it collapses to zero width and shows nothing.
                hosting.setFrameSize(hosting.fittingSize)
                let accessory = VigilTitlebarAccessory()
                accessory.view = hosting
                accessory.layoutAttribute = .right
                window.addTitlebarAccessoryViewController(accessory)
            }

            // Persistent windows wear the thin teal border; ephemeral
            // windows get NONE (the default, undramatic state). Persistent
            // is the one that stands out.
            syncBorder(window, color: persistent ? .systemTeal : nil)

            // The side bars ride the same chokepoint: every window that
            // gets its mark gets its bars (idempotent install + state sync).
            VigilBars.shared.sync(controller)
        }
    }

    /// A thin class-colour border around the window, drawn as a click-through
    /// overlay INSIDE the contentView (safe surface, like the glass effect)
    /// with the window's real corner radius so it hugs the rounded shape.
    /// Never touches the private frame view (that broke teardown). A nil
    /// colour removes it (ephemeral windows carry no border).
    private func syncBorder(_ window: NSWindow, color: NSColor?) {
        guard let content = window.contentView else { return }
        let existing = content.subviews.compactMap({ $0 as? VigilBorderOverlay }).first
        guard let color else {
            existing?.removeFromSuperview()
            return
        }
        let overlay = existing ?? {
            let o = VigilBorderOverlay(frame: content.bounds)
            o.autoresizingMask = [.width, .height]
            o.wantsLayer = true
            content.addSubview(o) // topmost; interior transparent, edges only
            return o
        }()
        overlay.frame = content.bounds
        let radius: CGFloat = (window.responds(to: Selector(("_cornerRadius")))
            ? window.value(forKey: "_cornerRadius") as? CGFloat : nil) ?? 10
        overlay.layer?.cornerRadius = radius
        overlay.layer?.cornerCurve = .continuous
        overlay.layer?.borderWidth = 2
        overlay.layer?.borderColor = color.withAlphaComponent(0.6).cgColor
        overlay.layer?.masksToBounds = false
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistURL) else { return }
        guard let entries = try? JSONDecoder().decode([PersistedSession].self, from: data) else { return }
        for entry in entries {
            var session = Session(
                name: entry.name,
                label: entry.label,
                emoji: entry.emoji,
                cwd: entry.cwd,
                state: .asleep,
                tabs: entry.tabs ?? [],
                order: entry.order ?? 0)
            // vigil.json only ever holds persistent sessions (persist filters).
            session.persistent = true
            session.pinned = entry.pinned ?? false
            session.foreground = entry.foreground ?? false
            session.thumbnail = NSImage(
                contentsOfFile: dumpsDir(entry.name).appendingPathComponent("thumb.png").path)
            if let deadline = entry.buriedUntil {
                // Buried across a relaunch: honor the remaining grace (the
                // daemons are still out there), reap immediately if spent.
                graveyard[entry.name] = session
                graveyardDeadlines[entry.name] = deadline
                let wait = max(deadline.timeIntervalSinceNow, 0) + 1
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.reapIfExpired(entry.name)
                }
            } else {
                sessions[entry.name] = session
            }
        }
    }
}

extension TerminalController {
    /// A new tab in an existing window hosting an EXISTING split tree: the
    /// re-embed primitive for multi-tab sessions (newWindow(tree:) is the
    /// window half, this is the tab half).
    static func vigilNewTab(
        _ ghostty: Ghostty.App,
        parent: TerminalController,
        tree: SplitTree<Ghostty.SurfaceView>
    ) -> TerminalController {
        let controller = TerminalController(ghostty, withSurfaceTree: tree)
        controller.isBackgroundOpaque = parent.isBackgroundOpaque
        if let window = controller.window, let parentWindow = parent.window {
            parentWindow.addTabbedWindowSafely(window, ordered: .above)
            controller.showWindow(nil)
        }
        return controller
    }
}
