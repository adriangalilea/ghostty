import AppKit
import FoundationModels
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
///             remain and opening resurrects them into one tabbed window
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

    /// One leaf of the workspace, enough to rebuild it: where it was and what
    /// ran in it. A daemon pane resurrects by native reattach; a claude pane
    /// without a daemon resurrects via `wake pane` (resume); stateless tools
    /// re-run their command; a bare shell resurrects as a bare shell.
    struct Pane: Codable {
        let cwd: String
        let command: String?
        /// The command's exact argv from the kernel (KERN_PROCARGS2), never
        /// ps text: resurrection execs it directly, no shell ever parses it,
        /// so a process styling its title with metacharacters can misparse
        /// but never execute.
        var argv: [String]?
        /// VT dump (scrollback + screen) frozen at capture; replayed with
        /// `cat` on resurrection so the content survives, not just the shape.
        var dump: String?
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
    /// their split shape. nil layout = single pane.
    struct Tab: Codable {
        var panes: [Pane]
        var layout: Layout?
    }

    struct Session {
        let name: String
        var label: String
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
                guard notification.object is NSWindow else { return }
                VigilSessionManager.shared.reconcileTabs()
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

    private struct WakeEvent: Decodable {
        let container: String
        let event: String
        let tty: String?
        /// The vigild pane daemon the claude lives in. Ground truth for
        /// ownership: VIGIL_SESSION in the process env is stamped at birth
        /// and goes stale when a tab is dragged into another session.
        let pane: String?
    }

    /// Join key for claudes born without a container env (adopted windows):
    /// the event's tty against every session surface's ttyName.
    private func sessionMatching(tty: String) -> String? {
        guard tty.count > 2, tty != "??" else { return nil }
        for (name, session) in sessions {
            for tree in liveTrees(session) {
                for view in tree where view.surfaceModel?.ttyName?.hasSuffix(tty) == true {
                    return name
                }
            }
        }
        return nil
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
        // launch (offset resets anyway) is the one safe moment to truncate.
        // The ms-wide race with a concurrent hook append is accepted.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: eventsURL.path),
           let size = attrs[.size] as? UInt64, size > 1024 * 1024,
           let handle = try? FileHandle(forReadingFrom: eventsURL) {
            handle.seek(toFileOffset: size - 128 * 1024)
            let tail = handle.readDataToEndOfFile()
            try? handle.close()
            // Cut at a line boundary so the first record parses.
            if let nl = tail.firstIndex(of: 0x0a) {
                try? tail.suffix(from: tail.index(after: nl)).write(to: eventsURL, options: .atomic)
            }
        }

        // Start at end of file: history is not pending attention.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: eventsURL.path),
           let size = attrs[.size] as? UInt64 {
            eventsOffset = size
        }
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

        var changed = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let event = try? JSONDecoder().decode(WakeEvent.self, from: Data(line.utf8)) else { continue }
            // Ownership resolution, strongest first: the pane daemon the
            // claude lives in (survives drag-out; env container goes stale),
            // then the birth container, then the tty (adopted claudes).
            let name: String
            if let pane = event.pane, !pane.isEmpty, let owner = sessionOwning(pane: pane) {
                name = owner
            } else if sessions[event.container] != nil {
                name = event.container
            } else if let tty = event.tty, let matched = sessionMatching(tty: tty) {
                name = matched
            } else {
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
        if changed { onAttentionChange?() }
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
        if value, let controller = anchorController(of: name) {
            refineLabel(name: name, screen: controller.focusedSurface?.cachedScreenContents.get() ?? "")
        }
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
        for tab in session.tabs {
            for pane in tab.panes {
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
        let trees = ms.map(\.surfaceTree).filter { !$0.isEmpty }
        sessions[name]!.tabs = captureTabs(name: name, trees)
        for tree in trees { linkClaudes(name: name, tree: tree) }
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

    /// A pane the claude adapter owns: claude itself, or vigil's own
    /// resume wrapper (a re-captured resurrected pane's foreground is the
    /// `wake pane` node process, not claude).
    static func isClaudePane(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("claude")
            || command.contains("wake.ts")
            || command.contains("wake pane")
    }

    // MARK: Survival class

    /// True when every pane of the tree lives in a daemon: the session
    /// survives the app dying. Any plain pane makes the whole window
    /// capture+resume class; the weakest link is the honest answer.
    static func daemonBacked(_ tree: SplitTree<Ghostty.SurfaceView>) -> Bool {
        var any = false
        for view in tree {
            any = true
            if view.vigilAttachId == nil { return false }
        }
        return any
    }

    /// The session's survival class across all states (asleep judges by
    /// its captured tabs: all attach sentinels = daemons waiting).
    func daemonBacked(session: Session) -> Bool {
        if case .asleep = session.state {
            return !session.tabs.isEmpty && session.tabs.allSatisfy { tab in
                !tab.panes.isEmpty && tab.panes.allSatisfy {
                    $0.command?.hasPrefix(Self.attachSentinel) == true
                }
            }
        }
        let trees = liveTrees(session)
        return !trees.isEmpty && trees.allSatisfy { Self.daemonBacked($0) }
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

    /// Capture every tab of the workspace: panes + split shape per tree,
    /// dump filenames indexed across the whole session so tabs never
    /// collide.
    private func captureTabs(
        name: String, _ trees: [SplitTree<Ghostty.SurfaceView>]
    ) -> [Tab] {
        var tabs: [Tab] = []
        var paneIndex = 0
        for tree in trees {
            let panes = capturePanes(name: name, tree, startIndex: paneIndex)
            paneIndex += panes.count
            tabs.append(Tab(panes: panes, layout: Self.captureLayout(tree)))
        }
        return tabs
    }

    /// What is running where, plus what was on screen, for resurrection. The
    /// foreground process of a pane is its command; a bare shell reads as nil.
    /// Every pane's content (scrollback + screen) is frozen as a VT dump.
    private func capturePanes(
        name: String, _ tree: SplitTree<Ghostty.SurfaceView>, startIndex: Int
    ) -> [Pane] {
        let dir = dumpsDir(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var panes: [Pane] = []
        for (offset, view) in tree.enumerated() {
            let index = startIndex + offset
            let cwd = view.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path

            // Daemon panes: identity IS the attach id; the daemon holds the
            // live state, nothing else needs capturing for resurrection.
            if let attachId = view.vigilAttachId {
                let dumpPath = dir.appendingPathComponent("\(index).vt").path
                let dumped = view.surfaceModel?.vigilDump(to: dumpPath) == true
                panes.append(Pane(
                    cwd: cwd,
                    command: "\(Self.attachSentinel)\(attachId)",
                    dump: dumped ? dumpPath : nil))
                continue
            }

            var command: String?
            var argv: [String]?
            if let pid = view.surfaceModel?.foregroundPID,
               let args = Self.processArgv(pid: pid_t(pid)), let first = args.first {
                let base = URL(fileURLWithPath: first).lastPathComponent
                let shells = ["fish", "bash", "zsh", "sh", "login"]
                if !shells.contains(base), !base.hasPrefix("-") {
                    command = args.joined(separator: " ")
                    argv = args
                }
            }
            var dump: String?
            let dumpPath = dir.appendingPathComponent("\(index).vt").path
            if view.surfaceModel?.vigilDump(to: dumpPath) == true {
                dump = dumpPath
            }
            panes.append(Pane(cwd: cwd, command: command, argv: argv, dump: dump))
        }
        return panes
    }

    /// The real argv of a process straight from the kernel. ps renders argv
    /// as one space-joined string, which destroys argument boundaries and
    /// makes replay a quoting problem; the kernel buffer has the exact
    /// NUL-separated array.
    static func processArgv(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }
        // Layout: argc, exec path, NUL padding, then argc NUL-terminated args.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        var start = index
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args.isEmpty ? nil : args
    }

    /// Adopted claudes were born without identity: recover it forensically via
    /// `wake link` (process on the pane's tty -> its newest transcript) so
    /// resurrection resumes the conversation.
    private func linkClaudes(name: String, tree: SplitTree<Ghostty.SurfaceView>) {
        for view in tree {
            guard let tty = view.surfaceModel?.ttyName else { continue }
            let suffix = URL(fileURLWithPath: tty).lastPathComponent
            runFireAndForget(wakeBin, ["link", name, suffix])
        }
    }

    private var wakeBin: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/wake").path
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
            let rest = Array(trees.dropFirst())
            if !rest.isEmpty {
                // The anchor window presents on the NEXT runloop tick
                // (scheduleInitialPresentation); a tab added to an
                // unpresented window is born invisible. Attach after it
                // is actually up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    for tree in rest {
                        let tab = TerminalController.vigilNewTab(ghostty, parent: controller, tree: tree)
                        self.registerMember(tab, name: name)
                        self.vlog("open: '\(name)' tab attach window=\(tab.window != nil) grouped=\(tab.window?.tabGroup === controller.window?.tabGroup)")
                    }
                }
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
    /// natively (living daemon = living processes); a legacy claude pane
    /// resumes via wake; other commands re-run; shells come back bare.
    private func resurrect(name: String, ghostty: Ghostty.App) {
        let session = sessions[name]!
        var tabs = session.tabs
        if tabs.isEmpty || tabs.allSatisfy({ $0.panes.isEmpty }) {
            tabs = [Tab(panes: [Pane(cwd: session.cwd, command: "claude")], layout: nil)]
        }

        // One claude resume per session for the legacy (non-daemon) path:
        // the wake registry has one uuid.
        var claudeAssigned = false
        func configFor(_ pane: Pane) -> Ghostty.SurfaceConfiguration {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.cwd
            config.environmentVariables["VIGIL_SESSION"] = name

            // Daemon panes resurrect by NATIVE reattach: living daemon
            // means living processes, nothing recreated.
            if let command = pane.command, command.hasPrefix(Self.attachSentinel) {
                config.vigilAttach = String(command.dropFirst(Self.attachSentinel.count))
                return config
            }

            // Recreation path (adopted, pre-daemon panes). Command panes
            // exec their captured argv directly: no shell parses it, and
            // the program repaints its own screen (no dump replay). The
            // claude pane resumes via wake TYPED INTO A SHELL: the
            // adapter needs the login environment (a direct: spawn under
            // the app's launchd env has no user PATH; found live, the
            // wrapper died instantly and the pane came back blank).
            // Every typed string here is vigil's own (dump paths,
            // slugs), never captured process text.
            if let argv = pane.argv, !Self.isClaudePane(pane.command) {
                config.command = "direct:" + argv.joined(separator: " ")
                return config
            }
            var parts: [String] = []
            // Dump replay only for a plain shell (restores its scrollback);
            // a claude pane repaints its own TUI on `wake pane`, so catting
            // its frozen screen just flashes stale content first.
            if Self.isClaudePane(pane.command), !claudeAssigned {
                claudeAssigned = true
                parts.append("wake pane \(name)")
            } else if let dump = pane.dump, FileManager.default.fileExists(atPath: dump) {
                parts.append("cat '\(dump)'")
            }
            if !parts.isEmpty {
                config.initialInput = parts.joined(separator: "; ") + "\n"
            }
            return config
        }

        /// Splits and subsequent tabs wait for their window to actually
        /// present (next runloop tick); building against an unpresented
        /// window drops splits and births invisible tabs.
        vlog("resurrect: '\(name)' tabs=\(tabs.count) panes=\(tabs.map(\.panes.count))")
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
                }
                continue
            } else {
                controller = TerminalController.newWindow(
                    ghostty, withBaseConfig: configFor(panes[firstIndex]))
                firstController = controller
            }
            registerMember(controller, name: name)

            materializeSplits(controller, tab: tab, configFor: configFor)
        }
        sessions[name]!.state = .embedded
        firstController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Rebuild one tab's splits a beat after its window presents (a split
    /// against an unhosted surface is dropped), then re-shape to the
    /// captured ratios.
    private func materializeSplits(
        _ controller: TerminalController,
        tab: Tab,
        configFor: @escaping (Pane) -> Ghostty.SurfaceConfiguration
    ) {
        let panes = tab.panes
        guard panes.count > 1 else { return }
        let layout = tab.layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
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
        if persistent { detach(name: name) } else { kill(name: name) }
        return true
    }

    /// Closing one TAB of a multi-tab session is a structural edit, not a
    /// lifecycle event: the tab leaves the session and becomes its own
    /// buried ephemeral session (120s grace, ⌘⇧T exhumes it into its own
    /// window; expiry kills its pane daemons). Symmetric with drag-out,
    /// which also makes a tab its own session, just an alive one.
    func closeTabStructurally(_ controller: TerminalController) {
        guard let name = sessionName(of: controller) else { return }
        let tree = controller.surfaceTree
        memberships.removeObject(forKey: controller)
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
    /// surviving window must not silently make it mortal). New random id
    /// (identity is never derived), label refined async when persistent.
    private func mintSession(from controllers: [TerminalController], inheriting old: Session) {
        let name = newSessionId()
        let cwd = controllers.first?.focusedSurface?.pwd ?? old.cwd
        var session = Session(name: name, label: name, cwd: cwd, state: .embedded)
        session.persistent = old.persistent
        sessions[name] = session
        for controller in controllers { registerMember(controller, name: name) }
        vlog("mint(drag-out): '\(name)' from '\(old.name)' tabs=\(controllers.count) persistent=\(old.persistent)")
        if session.persistent, let controller = controllers.first {
            refineLabel(name: name, screen: controller.focusedSurface?.cachedScreenContents.get() ?? "")
        }
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

    func rename(name: String, label: String) {
        guard sessions[name] != nil else { return }
        sessions[name]!.label = label
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
        for controller in members(of: name) { memberships.removeObject(forKey: controller) }
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
            label: session?.label ?? name,
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
    func vlog(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/vigil.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
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
        for (name, s) in sessions {
            if case .embedded = s.state, members(of: name).isEmpty {
                vlog("!! IMPOSSIBLE [\(site)]: '\(name)' embedded with no members, persistent=\(s.persistent)")
            }
            if !s.persistent, case .asleep = s.state {
                vlog("!! IMPOSSIBLE [\(site)]: ephemeral '\(name)' is asleep")
            }
        }
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

    /// Ask the on-device model for a nicer label, from what is on screen.
    /// Fire-and-forget: if the model is unavailable or slow the seed label
    /// stands, and a manual rename always wins (checked before applying).
    private func refineLabel(name: String, screen: String) {
        guard #available(macOS 26.0, *) else { return }
        guard SystemLanguageModel.default.availability == .available else { return }
        guard let session = sessions[name] else { return }
        let seedLabel = session.label
        let context = "cwd: \(session.cwd)\ntitle: \(seedLabel)\nscreen:\n\(screen.suffix(1500))"

        Task {
            let lm = LanguageModelSession(instructions: """
                You name terminal workspace sessions. Given the working directory, \
                title and visible screen of a terminal, answer with ONLY a short \
                evocative name for the session, 2 to 4 lowercase words, no \
                punctuation. Name the task being done, not the tools.
                """)
            guard let response = try? await lm.respond(to: context) else { return }
            let label = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !label.isEmpty, label.count <= 48 else { return }
            await MainActor.run {
                // Apply only if nobody renamed it while we were thinking.
                guard let current = self.sessions[name], current.label == seedLabel else { return }
                self.sessions[name]!.label = label
                self.persist()
            }
        }
    }

    // MARK: Persistence (identity + cwd + captured tabs; trees are runtime)

    private struct PersistedSession: Codable {
        let name: String
        let label: String
        let cwd: String
        let tabs: [Tab]?
        /// Pre-tab schema (one flat pane list + layout): decoded as a
        /// single-tab session, never written.
        let panes: [Pane]?
        let layout: Layout?
        let order: Int?
        let pinned: Bool?
        let buriedUntil: Date?
    }

    private func persist() {
        var entries = sessions.values.filter { $0.persistent }.map {
            PersistedSession(name: $0.name, label: $0.label, cwd: $0.cwd, tabs: $0.tabs, panes: nil, layout: nil, order: $0.order, pinned: $0.pinned, buriedUntil: nil)
        }
        entries += graveyard.values.filter { !$0.ephemeral }.map {
            PersistedSession(name: $0.name, label: $0.label, cwd: $0.cwd, tabs: $0.tabs, panes: nil, layout: nil, order: $0.order, pinned: $0.pinned, buriedUntil: graveyardDeadlines[$0.name])
        }
        entries.sort { $0.name < $1.name }
        let data = try! JSONEncoder().encode(entries)
        try? FileManager.default.createDirectory(
            at: persistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try! data.write(to: persistURL)
        syncWindowMarks()
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
            let daemonBacked = persistent && Self.daemonBacked(controller.surfaceTree)

            // Enforce a session's stored pin intent on its live window
            // (covers resurrection/re-embed for free); session-less windows
            // keep their pure window-level pin.
            if let name, let session = sessions[name] {
                applyPin(window, session.pinned)
            }
            let pinned = name.map { sessionPinned($0) } ?? isPinned(controller)

            let mark = VigilWindowMark(
                label: name.flatMap { sessions[$0]?.label },
                persistent: persistent,
                daemonBacked: daemonBacked,
                pinned: pinned,
                onTogglePersist: { [weak self] in
                    // Session scope IS the window: one flip covers every tab.
                    self?.toggleWindowPersist(controller)
                },
                onTogglePin: { [weak self] in
                    if let name { self?.togglePinSession(name) }
                    else { self?.togglePin(controller); self?.persist() }
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

            // Persistent windows wear a thin class-colour border (teal daemon
            // / cyan resume); ephemeral windows get NONE (the default,
            // undramatic state). Persistent is the one that stands out.
            let color: NSColor? = !persistent ? nil
                : (daemonBacked ? .systemTeal : .systemCyan)
            syncBorder(window, color: color)
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
                cwd: entry.cwd,
                state: .asleep,
                tabs: entry.tabs
                    ?? [Tab(panes: entry.panes ?? [], layout: entry.layout)],
                order: entry.order ?? 0)
            // vigil.json only ever holds persistent sessions (persist filters).
            session.persistent = true
            session.pinned = entry.pinned ?? false
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
