import AppKit
import SwiftUI
import GhosttyKit

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
/// a new session (reconcileTabs).
///
/// OWNERSHIP IS THE REGISTRY. `Session.tabs` lists every pane a session
/// owns, live or cold, in tab order, and it is always current: every
/// structural event (a split born or closed, a tab joining or leaving, a
/// move, a close) edits it synchronously at the moment it happens. Live
/// trees are projections of it, never a source; vigil.json is its mirror.
/// A pane is in exactly one place: a session, a burial, or dead. Nothing
/// is inferred at persist time and nothing heals, because there is no
/// second store to disagree with.
///
/// Every session survives: window close, ⌘Q and reboot keep its daemons
/// running. The only death is an explicit kill, always through the
/// graveyard (120s undo), and a reap kills daemons deterministically and
/// verifies they died. Daemon lifetime never depends on ARC.
///
/// Durable state lives in the wake registry (~/.local/state/wake), maintained
/// event-driven by agent adapters.
@MainActor
class VigilSessionManager {
    static let shared = VigilSessionManager()

    /// One tab's live runtime while it has no window: its split tree (views
    /// alive, daemons attached) and its dock, if any. Held by the session's
    /// state, released as one value.
    struct TabRuntime {
        var tree: SplitTree<Ghostty.SurfaceView>
        var dock: VigilDockRuntime?
    }

    enum State {
        case embedded
        /// One tab floats in the quick terminal; `rest` are the session's
        /// other tabs, waiting detached; `floatedDock` is the floated
        /// tab's dock (alive, unshown while floating); `floatedIndex` is
        /// where the floating tab reinserts on reclaim.
        case floating(rest: [TabRuntime], floatedDock: VigilDockRuntime?, floatedIndex: Int)
        /// One runtime per live tab, in tab order.
        case detached([TabRuntime])
        case asleep
    }

    /// Why a session wants Adrian. `input` (adapter permission or question)
    /// outranks `done` (turn finished); FIFO within a rank. Cleared
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
    /// may adopt the contract (Claude and Codex do today). Ranked for the sidebar
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
    /// Posted from the focus chokepoint (BaseTerminalController.
    /// syncFocusToSurfaceTree): the sidebar re-derives its active chain
    /// the moment keystroke destiny moves, instead of waiting for a tick.
    static let focusDidChange = Notification.Name("vigilFocusDidChange")

    /// When each PANE was last under the eyes (its view visible in the key
    /// window), keyed by pane daemon id: blocked/done older than the pane's
    /// ack display as idle (seen), herdr's seen-flip without a stored flag.
    /// Pane-keyed because seen is a property of the CONSOLE, not the
    /// session: the session-keyed ledger acked asks living in unmounted
    /// tabs of the watched session sight-unseen (dot decayed, no attention,
    /// no follow - an invisible console you could never have answered).
    /// PERSISTED (acks.json): seen must survive an app restart, or every
    /// already-answered pane re-lights and demands a visit. Race-free by
    /// construction: seen = ack >= the state file's mtime, so a state that
    /// changed while the app was down carries a newer mtime and correctly
    /// reads unseen - time arbitrates, no flag can go stale.
    private(set) var lastAck: [String: Date] = [:]

    private var acksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/acks.json")
    }

    private func loadAcks() {
        guard let data = try? Data(contentsOf: acksURL),
              let saved = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        // Only a pane with a state file can decay; acks for dead panes
        // are cruft, pruned here so the ledger never grows unbounded.
        lastAck = saved.filter { pane, _ in
            FileManager.default.fileExists(
                atPath: agentStateDir.appendingPathComponent("\(pane).state").path)
        }
    }

    private func saveAcks() {
        guard let data = try? JSONEncoder().encode(lastAck) else { return }
        try? data.write(to: acksURL)
    }

    /// Custom identities for PANES and TABS (label + emoji, display-only
    /// aliases, the id≠label rule one level down). Keyed by pane daemon id
    /// (tabs by "tab:" + their anchor pane id). A name lives ON THE THING
    /// IT NAMES, in the registry, and nowhere else: it is written, moved,
    /// buried and dropped by exactly the code that owns the pane, so it can
    /// never be collected out from under a live one and a drag carries it
    /// for free.
    struct CustomIdentity: Codable, Equatable {
        var label: String?
        var emoji: String?
    }

    func customIdentity(_ key: String) -> CustomIdentity? {
        let wantsTab = key.hasPrefix("tab:")
        let target = wantsTab ? String(key.dropFirst(4)) : key
        for session in sessions.values.map({ $0 }) + graveyard.values.map({ $0 }) {
            for tab in session.tabs {
                if wantsTab {
                    guard tabPaneIds(tab).first == target else { continue }
                    guard tab.label != nil || tab.emoji != nil else { return nil }
                    return CustomIdentity(label: tab.label, emoji: tab.emoji)
                }
                for pane in tab.panes + (tab.dock?.panes ?? []) where pane.id == target {
                    guard pane.label != nil || pane.emoji != nil else { return nil }
                    return CustomIdentity(label: pane.label, emoji: pane.emoji)
                }
            }
        }
        return nil
    }

    func setCustomIdentity(key: String, label: String?, emoji: String?) {
        let wantsTab = key.hasPrefix("tab:")
        let target = wantsTab ? String(key.dropFirst(4)) : key
        var landed = false
        for (name, session) in sessions {
            var tabs = session.tabs
            var hit = false
            for index in tabs.indices {
                // CONTAINS, not "is first": the anchor is the tab's stable
                // handle, but requiring first position made a rename
                // silently do nothing (Adrian, naming a tab '*-utils').
                if wantsTab, tabPaneIds(tabs[index]).contains(target) {
                    tabs[index].label = label
                    tabs[index].emoji = emoji
                    hit = true
                } else if !wantsTab {
                    for pindex in tabs[index].panes.indices
                    where tabs[index].panes[pindex].id == target {
                        tabs[index].panes[pindex].label = label
                        tabs[index].panes[pindex].emoji = emoji
                        hit = true
                    }
                    if var dock = tabs[index].dock {
                        for dindex in dock.panes.indices where dock.panes[dindex].id == target {
                            dock.panes[dindex].label = label
                            dock.panes[dindex].emoji = emoji
                            hit = true
                        }
                        tabs[index].dock = dock
                    }
                }
            }
            // Evaluate fully, THEN assign: an expression reading `sessions`
            // inside a `sessions[...]` write is an exclusivity trap.
            if hit {
                sessions[name]?.tabs = tabs
                landed = true
            }
        }
        // A name the user typed must never vanish quietly.
        if !landed {
            vlog("!! rename: nothing owns '\(key)' - the name was NOT stored")
        }
        persist()
        // A tab renamed anywhere (sidebar row, tab bar, ⌘-rename) repaints
        // every surface that shows it: one name, no drift.
        if wantsTab {
            for controller in TerminalController.all { syncTabTitle(controller) }
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// One leaf of the workspace. `id` is its vigild daemon id, THE identity
    /// (`vigil-<birth session>-<index>`, minted monotonic, never recycled);
    /// resurrection is a native reattach to that daemon, and a daemon that
    /// died comes back as a fresh shell in `cwd` (honest, nothing replayed).
    struct Pane: Codable {
        let id: String
        var cwd: String
        /// The pane's last known terminal title, refreshed while it is
        /// live. A name that lives only in a live terminal is a side
        /// effect that vanishes when the pane goes cold; stored here it
        /// survives detach, quit, reboot and resurrection.
        var title: String?
        /// The name and face YOU gave this pane: owned by one writer, moves
        /// with the pane on a drag.
        var label: String?
        var emoji: String?

        init(id: String, cwd: String, title: String? = nil,
             label: String? = nil, emoji: String? = nil) {
            self.id = id
            self.cwd = cwd
            self.title = title
            self.label = label
            self.emoji = emoji
        }
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
        /// The tab's own name and face, anchored to the tab, not to a
        /// side map: the sidebar row, the native tab bar and the rename
        /// prompt all read this one value.
        var label: String?
        var emoji: String?

        init(panes: [Pane], layout: Layout?, dock: DockCapture? = nil,
             label: String? = nil, emoji: String? = nil) {
            self.panes = panes
            self.layout = layout
            self.dock = dock
            self.label = label
            self.emoji = emoji
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
        /// THE REGISTRY: every pane this session owns, live or cold, one
        /// entry per tab in tab order, always current (edited at every
        /// structural event, never inferred). Resurrection rebuilds it as
        /// tabs of ONE window.
        var tabs: [Tab] = []
        /// Manual overview ordering (drag & drop); lower first.
        var order: Int = 0
        /// Pinned-on-top intent, persisted: applied to the window whenever
        /// the session is embedded (open/re-embed/resurrect), so a pin
        /// survives detach, quit and reboot, and a detached/asleep session
        /// can be pinned before it even has a window.
        var pinned: Bool = false
        /// The session tree sidebar of this session's window: shown or
        /// hidden, persisted; nil = the app-wide default (the last toggle
        /// anywhere). Per window, never global: toggling one window must
        /// not repaint another.
        var sidebar: Bool? = nil
        /// Loaded intent: this session had a WINDOW when the app last
        /// recorded it (crash or shutdown), so launch restores it as one.
        /// Detached-in-background sessions load with this false and stay
        /// asleep: startup rebuilds the workspace exactly as it was.
        var foreground: Bool = false
        /// Live for embedded (refreshed on overview open), frozen at the
        /// moment of detach for detached. Runtime-only.
        var thumbnail: NSImage?
        /// Next pane daemon index to mint, monotonic and persisted: a pane
        /// index is IDENTITY and is never recycled. Deriving "next" from
        /// currently-owned ids alone reused the index of a tab that had
        /// just left (bury, drag-out) while its daemon still ran - the new
        /// surface attached to the departed tab's socket and replayed it
        /// (⌘T resurrecting a ⌘W-closed tab).
        var paneSeq: Int = 0

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
    /// the runtime strongly owns the tenant SurfaceViews. A windowless
    /// tab's dock rides its `TabRuntime`.
    private let dockMap = NSMapTable<TerminalController, VigilDockRuntime>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory)

    /// Killed sessions rest here for a grace period before their daemons
    /// actually die. Undo (ghostty's native `undo` action; bind cmd+shift+T
    /// to it) exhumes the session intact: kill was a detach + a deadline,
    /// nothing had died yet. Ghostty's own ExpiringUndoManager drives the
    /// expiry. 120s: long enough for regret, short enough that hidden
    /// daemons never linger (config key candidate if it feels wrong).
    /// EVERY close rests here - a session, a tab, a split pane, a dock
    /// tenant - one death path, one undo.
    private var graveyard: [String: Session] = [:]
    private var graveyardDeadlines: [String: Date] = [:]
    static let killGrace: TimeInterval = 120

    /// Most recently active sessions, newest first: the successor order
    /// when the session you are in dies (the tab-close semantic: the
    /// viewport goes to the last one you were in, never closes while any
    /// session remains). Runtime-only; manual order is the fallback.
    private var recent: [String] = []

    /// Nesting depth of vigil's OWN tree swaps (mount, release, kill,
    /// move). `treeDidChange` is the chokepoint for ghostty-driven
    /// structure changes (splits born and closed, undo, process exits)
    /// and must not read a wholesale swap as a mass close.
    private var treeSwaps = 0

    func withTreeSwap(_ body: () -> Void) {
        treeSwaps += 1
        defer { treeSwaps -= 1 }
        body()
    }

    /// Vigil's own wholesale tree swap: under the swap flag AND with the
    /// controller's ghostty undo stack dropped. The undo manager is
    /// app-wide and a controller's "New Split"/"Close Terminal"/"Move
    /// Split" undos outlive any swap: ⌘Z after a shapeshift would assign
    /// the OLD occupant's tree to the window outside any swap, reading as
    /// a mass close of the new occupant plus a theft of the old one.
    private func swapTree(_ controller: TerminalController, _ tree: SplitTree<Ghostty.SurfaceView>) {
        controller.undoManager?.removeAllActions(withTarget: controller)
        withTreeSwap { controller.surfaceTree = tree }
    }

    /// Set once at app launch by VigilStatusItem; needed to spawn windows.
    weak var ghosttyApp: Ghostty.App?

    /// SIGTERM handler (see init): a signal must never leave a service-mode
    /// survivor behind a dev restart.
    private var sigtermSource: DispatchSourceSignal?

    /// Status item hook: called whenever attention state changes.
    var onAttentionChange: (() -> Void)?

    var pendingCount: Int {
        sessions.values.filter { $0.attention != .none }.count
    }

    private var persistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/vigil.json")
    }

    /// The last good workspace, kept beside the live one. Loaded only when
    /// the live file is missing or unreadable, so a truncated or corrupt
    /// write costs one persist, never the workspace.
    private var persistBackupURL: URL {
        persistURL.appendingPathExtension("bak")
    }

    /// Held for the process lifetime; the kernel releases it on ANY death.
    private static var instanceLockFD: Int32 = -1

    /// TWO vigil instances sharing the state dir is corruption waiting
    /// (both restore the same daemons, both persist vigil.json). The
    /// script-side kill-then-launch cannot be trusted alone: macOS
    /// relaunched the app on its own after a `pkill -9` straggler shot
    /// (2026-08-04, two instances born the same second). First instance
    /// wins the flock; a duplicate activates the holder and exits before
    /// touching anything.
    private func acquireInstanceLock() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // O_CLOEXEC or every spawned vigild inherits the fd and HOLDS THE
        // FLOCK after the app dies (locked out of our own lock by a
        // daemon, 2026-08-04 - the attach-socket FD_CLOEXEC lesson again;
        // flock rides the file description, which fork shares and only
        // exec+CLOEXEC severs). Path is app.flock because the original
        // app.lock is still held by daemons born before this fix.
        let fd = Darwin.open(dir.appendingPathComponent("app.flock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return } // no lock support beats a bricked app
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            var buf = [CChar](repeating: 0, count: 32)
            let n = pread(fd, &buf, 31, 0)
            close(fd)
            let holder = n > 0 ? String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            FileHandle.standardError.write(
                Data("vigil: instance lock held by pid \(holder); this duplicate exits\n".utf8))
            if let pid = Int32(holder), let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
            }
            exit(0)
        }
        ftruncate(fd, 0)
        "\(getpid())\n".withCString { _ = pwrite(fd, $0, strlen($0), 0) }
        Self.instanceLockFD = fd
    }

    private init() {
        acquireInstanceLock()
        load()
        loadAcks()
        collectOrphans()
        // A logout/restart/shutdown is starting. THE signal, and the only
        // reliable one: the AppleEvent probe in applicationShouldTerminate
        // (kAEShutDown/kAERestart) does not arrive on macOS 26, so every
        // restart ran the ⌘Q intercept instead, which CANCELS termination
        // into service mode — the app refused to quit, macOS waited on it,
        // and the machine looked wedged until Adrian cut the power (twice,
        // 2026-08-08, both with a shutdown_stall report). Freeze the
        // workspace here, while the windows still show, and from now on
        // termination can never be cancelled.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let manager = VigilSessionManager.shared
                manager.systemPoweringOff = true
                manager.prepareForSystemShutdown()
            }
        }
        startEventWatcher()
        startStateDirWatcher()
        // SIGTERM means DIE (vigil-dev restarts, system tooling). Without
        // this, AppKit routed it into the ⌘Q intercept, which CANCELS
        // termination into menu-bar service mode while sessions exist:
        // three invisible survivors once stacked up behind pkill + open -n
        // (2026-08-01). Freeze foreground truth, persist, really terminate.
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler {
            MainActor.assumeIsolated {
                VigilSessionManager.shared.quitForReal()
            }
        }
        sigtermSource?.resume()
        // A completed tab drag (out or in) has no dedicated AppKit event,
        // but the moved window becomes key, so membership reconciliation
        // rides the key-window notification.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard notification.object is NSWindow else { return }
                VigilSessionManager.shared.reconcileTabs()
                VigilSessionManager.shared.ackVisiblePanes()
                VigilSessionManager.shared.syncWindowMarks()
            }
        }
        // Focus moves WITHIN the key window (split clicks, follow landing
        // on the asking pane) ride the focus chokepoint: presence acks the
        // pane the moment it is actually on screen.
        NotificationCenter.default.addObserver(
            forName: Self.focusDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                VigilSessionManager.shared.ackVisiblePanes()
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
    /// the controller's window and tabGroup. The controller's tree joins
    /// the REGISTRY here when the registry does not know it yet: a fresh
    /// ⌘T or window, or a tab that arrived from another session (drag-in,
    /// a move's settle) - its panes are claimed from wherever they lived,
    /// as one new tab. A tree the registry already lists (a mount, a
    /// regroup) changes nothing. Membership follows the tree, so callers
    /// assign the tree FIRST.
    func registerMember(_ controller: TerminalController, name: String, after parent: TerminalController? = nil) {
        memberships.setObject(name as NSString, forKey: controller)
        guard sessions[name] != nil else { return }
        let dock = dockMap.object(forKey: controller)
        let ids = controller.surfaceTree.compactMap(\.vigilAttachId)
            + (dock?.views.compactMap(\.vigilAttachId) ?? [])
        guard let first = ids.first, !ownedPaneIds(sessions[name]!).contains(first) else { return }
        var carried: [Pane] = []
        var label: String?
        var emoji: String?
        for id in ids {
            guard let taken = takePane(id) else { continue }
            carried.append(taken.pane)
            label = label ?? taken.tabLabel
            emoji = emoji ?? taken.tabEmoji
            chown(id, to: name)
        }
        let (panes, layout) = capture(controller.surfaceTree, carrying: carried)
        let tab = Tab(
            panes: panes, layout: layout,
            dock: dock.flatMap { captureDock($0, carrying: carried) },
            label: label, emoji: emoji)
        // A ⌘T lands right after its parent tab (where AppKit places the
        // native tab), never at the end: registry order IS the tab order.
        let parentIds = Set(parent?.surfaceTree.compactMap(\.vigilAttachId) ?? [])
        if !parentIds.isEmpty,
           let index = sessions[name]!.tabs.firstIndex(where: { !Set(tabPaneIds($0)).isDisjoint(with: parentIds) }) {
            sessions[name]!.tabs.insert(tab, at: index + 1)
        } else {
            sessions[name]!.tabs.append(tab)
        }
        vlog("register: '\(name)' += tab \(ids) (\(carried.count) claimed)")
    }

    /// A session window's tree EMPTIED by ghostty (its only pane dragged
    /// into another window, or exited): the window closes without
    /// ghostty's recreate-the-window undo (that undo would resurrect an
    /// unregistered window holding a view whose pane lives elsewhere).
    /// A pane still listed here was closed, not moved, and is buried; the
    /// session sleeps when no member remains, clears when nothing is left.
    func handleEmptiedTree(_ controller: TerminalController) -> Bool {
        guard let name = sessionName(of: controller) else { return false }
        for id in controller.surfaceTree.compactMap(\.vigilAttachId) where locate(id)?.owner == name {
            if let taken = takePane(id) { buryPane(taken.pane, from: name) }
        }
        memberships.removeObject(forKey: controller)
        dockMap.object(forKey: controller)?.unmount()
        dockMap.removeObject(forKey: controller)
        killController(controller)
        if sessions[name] != nil, members(of: name).isEmpty { sessions[name]!.state = .asleep }
        clearIfEmpty(name)
        persist()
        return true
    }

    /// Close Other Tabs / Close Tabs to the Right in a session window:
    /// each tab leaves through the graveyard, one confirm naming what runs.
    func closeSiblingTabs(of controller: TerminalController, onlyRight: Bool) -> Bool {
        guard let name = sessionName(of: controller), let window = controller.window,
              let group = window.tabGroup?.windows else { return false }
        let current = group.firstIndex(of: window) ?? 0
        let targets = group.enumerated().compactMap { offset, candidate -> TerminalController? in
            guard candidate !== window, !onlyRight || offset > current,
                  let c = candidate.windowController as? TerminalController,
                  sessionName(of: c) == name else { return nil }
            return c
        }
        guard !targets.isEmpty else { return true }
        let busy = busyPrograms(panes: targets.flatMap { $0.surfaceTree.compactMap(\.vigilAttachId) })
        let proceed = { [weak self] in
            for target in targets { self?.closeTabStructurally(target) }
        }
        if busy.isEmpty {
            proceed()
        } else {
            controller.confirmClose(
                messageText: onlyRight ? "Close Tabs on the Right?" : "Close Other Tabs?",
                informativeText: "\(busy.joined(separator: ", ")) still running. Closing the tabs kills it (undo keeps them for \(Int(Self.killGrace))s)."
            ) { proceed() }
        }
        return true
    }

    /// Close All Windows: every embedded session detaches (everything
    /// keeps running, nothing dies); strays close plain.
    func detachAllWindows() -> Bool {
        let names = sessions.values.compactMap { session -> String? in
            if case .embedded = session.state { return session.name }
            return nil
        }
        guard !names.isEmpty else { return false }
        for name in names { detach(name: name) }
        for stray in strayControllers() { stray.closeWindowImmediately() }
        return true
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

    /// The session's live tab runtimes (embedded: member trees + docks;
    /// floating: the waiting rest + the quick terminal's tree; detached:
    /// the held runtimes). Display and occlusion read this; ownership
    /// never does.
    private func runtimes(_ session: Session) -> [TabRuntime] {
        switch session.state {
        case .embedded:
            return members(of: session.name)
                .filter { !$0.surfaceTree.isEmpty }
                .map { TabRuntime(tree: $0.surfaceTree, dock: dockMap.object(forKey: $0)) }
        case .floating(let rest, let floatedDock, _):
            var out = rest
            if floatingName == session.name,
               let quick = quickController(create: false),
               !quick.surfaceTree.isEmpty {
                out.append(TabRuntime(tree: quick.surfaceTree, dock: floatedDock))
            }
            return out
        case .detached(let held):
            return held
        case .asleep:
            return []
        }
    }

    // MARK: Registry (ownership IS the registry; every structural event edits it here)

    /// Every pane id a session owns: its registry, nothing else.
    func ownedPaneIds(_ session: Session) -> Set<String> {
        Set(session.tabs.flatMap(tabPaneIds))
    }

    /// Every daemon id a tab lists (panes + dock).
    func tabPaneIds(_ tab: Tab) -> [String] {
        (tab.panes + (tab.dock?.panes ?? [])).map(\.id)
    }

    /// Where a pane lives right now: a session or a burial, and its tab.
    private func locate(_ id: String) -> (owner: String, buried: Bool, tab: Int)? {
        for (name, session) in sessions {
            if let tab = session.tabs.firstIndex(where: { tabPaneIds($0).contains(id) }) {
                return (name, false, tab)
            }
        }
        for (name, session) in graveyard {
            if let tab = session.tabs.firstIndex(where: { tabPaneIds($0).contains(id) }) {
                return (name, true, tab)
            }
        }
        return nil
    }

    /// The pane's registry entry, wherever it lives.
    private func registered(_ id: String) -> Pane? {
        guard let at = locate(id) else { return nil }
        let tab = (at.buried ? graveyard[at.owner] : sessions[at.owner])!.tabs[at.tab]
        return (tab.panes + (tab.dock?.panes ?? [])).first { $0.id == id }
    }

    /// Take a pane OUT of wherever it lives (a session's tab, a dock, a
    /// burial). An emptied tab is dropped and hands its own name and face
    /// to the taker (the identity travels with the only pane instead of
    /// dying with the husk); an emptied burial is dropped; a held runtime
    /// releases the pane's view so no two trees ever hold one daemon. The
    /// one primitive under every move and every re-claim.
    private func takePane(_ id: String) -> (pane: Pane, tabLabel: String?, tabEmoji: String?)? {
        guard let at = locate(id) else { return nil }
        var session = (at.buried ? graveyard[at.owner] : sessions[at.owner])!
        var tab = session.tabs[at.tab]
        var pane: Pane?
        if let index = tab.panes.firstIndex(where: { $0.id == id }) {
            pane = tab.panes.remove(at: index)
            tab.layout = nil
        } else if var dock = tab.dock, let index = dock.panes.firstIndex(where: { $0.id == id }) {
            pane = dock.panes.remove(at: index)
            dock.active = min(dock.active, max(dock.panes.count - 1, 0))
            tab.dock = dock.panes.isEmpty ? nil : dock
        }
        guard let pane else { return nil }
        let emptied = tab.panes.isEmpty && (tab.dock?.panes.isEmpty ?? true)
        if emptied { session.tabs.remove(at: at.tab) } else { session.tabs[at.tab] = tab }
        func scrub(_ runtimes: inout [TabRuntime]) {
            for index in runtimes.indices {
                if let view = runtimes[index].tree.first(where: { $0.vigilAttachId == id }),
                   let node = runtimes[index].tree.root?.node(view: view) {
                    runtimes[index].tree = runtimes[index].tree.removing(node)
                }
                if let dock = runtimes[index].dock, let vi = dock.views.firstIndex(where: { $0.vigilAttachId == id }) {
                    dock.views.remove(at: vi)
                    dock.active = min(dock.active, max(dock.views.count - 1, 0))
                }
            }
            runtimes.removeAll { $0.tree.isEmpty && ($0.dock?.views.isEmpty ?? true) }
        }
        switch session.state {
        case .detached(var held):
            scrub(&held)
            session.state = held.isEmpty ? .asleep : .detached(held)
        case .floating(var rest, let floatedDock, let floatedIndex):
            scrub(&rest)
            if let dock = floatedDock, let vi = dock.views.firstIndex(where: { $0.vigilAttachId == id }) {
                dock.views.remove(at: vi)
                dock.active = min(dock.active, max(dock.views.count - 1, 0))
            }
            if floatingName == at.owner, let quick = quickController(create: false),
               let view = quick.surfaceTree.first(where: { $0.vigilAttachId == id }),
               let node = quick.surfaceTree.root?.node(view: view) {
                quickTreeSwap = true
                quick.surfaceTree = quick.surfaceTree.removing(node)
                quickTreeSwap = false
            }
            session.state = .floating(rest: rest, floatedDock: floatedDock, floatedIndex: floatedIndex)
        case .embedded, .asleep:
            break
        }
        if at.buried {
            if session.tabs.isEmpty { dropBurial(at.owner) } else { graveyard[at.owner] = session }
        } else {
            sessions[at.owner] = session
        }
        return (pane, emptied ? tab.label : nil, emptied ? tab.emoji : nil)
    }

    /// One live view as a registry pane, carrying the remembered facts of
    /// its current entry (title, and the name and face YOU gave it): a
    /// capture is a rewrite and would otherwise erase what the view does
    /// not know about.
    private func capturedPane(_ view: Ghostty.SurfaceView, id: String, previous: Pane?) -> Pane {
        Pane(
            id: id,
            cwd: view.pwd ?? previous?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            title: capturedTitle(of: view) ?? previous?.title,
            label: previous?.label,
            emoji: previous?.emoji)
    }

    /// A live tree as registry panes (DFS leaf order) + split shape.
    private func capture(
        _ tree: SplitTree<Ghostty.SurfaceView>, carrying previous: [Pane]
    ) -> (panes: [Pane], layout: Layout?) {
        let panes = tree.compactMap { view -> Pane? in
            guard let id = view.vigilAttachId else {
                vlog("!! capture: a surface with NO daemon id in a session tree - skipped")
                return nil
            }
            return capturedPane(view, id: id, previous: previous.first { $0.id == id } ?? registered(id))
        }
        return (panes, Self.captureLayout(tree))
    }

    private func captureDock(_ runtime: VigilDockRuntime, carrying previous: [Pane]) -> DockCapture? {
        let panes = runtime.views.compactMap { view -> Pane? in
            guard let id = view.vigilAttachId else { return nil }
            return capturedPane(view, id: id, previous: previous.first { $0.id == id } ?? registered(id))
        }
        guard !panes.isEmpty else { return nil }
        return DockCapture(
            panes: panes,
            active: min(max(runtime.active, 0), panes.count - 1),
            width: Double(runtime.width),
            collapsed: runtime.collapsed)
    }

    /// THE chokepoint for ghostty-driven structure changes in a session
    /// window: a split born (⌘D), a split closed (⌘W, a process exit, an
    /// undo), a surface dragged between windows. Vigil's own swaps never
    /// arrive here (`withTreeSwap`).
    func treeDidChange(
        _ controller: TerminalController,
        from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>
    ) {
        guard treeSwaps == 0, let name = sessionName(of: controller), sessions[name] != nil else { return }
        applyTreeDiff(session: name, from: from, to: to)
    }

    /// The quick terminal's tree changed while a session floats in it:
    /// same chokepoint, the floated tab.
    func quickTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        guard !quickTreeSwap, let name = floatingName, sessions[name] != nil else { return }
        applyTreeDiff(session: name, from: from, to: to)
    }

    /// Diff the pane ids of one tab's tree before and after, and edit the
    /// registry NOW: joined panes are claimed (taken from wherever they
    /// lived: a burial means an undo, another session means a drag, a
    /// pane already listed cold here means it just materialized), the
    /// tab's shape is recaptured, and closed panes are buried. Nothing
    /// is inferred later, so a close and a move can never be confused.
    private func applyTreeDiff(
        session name: String,
        from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>
    ) {
        let before = Set(from.compactMap(\.vigilAttachId))
        let after = Set(to.compactMap(\.vigilAttachId))
        let touched = before.union(after)
        guard !touched.isEmpty else { return }

        func tabIndex() -> Int? {
            sessions[name]!.tabs.firstIndex { !Set(tabPaneIds($0)).isDisjoint(with: touched) }
        }
        let listedHere = tabIndex().map { Set(tabPaneIds(sessions[name]!.tabs[$0])) } ?? []
        var carried: [Pane] = []
        var inheritedLabel: String?
        var inheritedEmoji: String?
        for id in after.subtracting(before) where !listedHere.contains(id) {
            guard let taken = takePane(id) else {
                vlog("tree: fresh pane '\(id)' joins '\(name)'")
                continue
            }
            carried.append(taken.pane)
            inheritedLabel = inheritedLabel ?? taken.tabLabel
            inheritedEmoji = inheritedEmoji ?? taken.tabEmoji
            chown(id, to: name)
            vlog("tree: pane '\(id)' claimed by '\(name)'")
        }

        var session = sessions[name]!
        let index = tabIndex()
        let previous = index.map { session.tabs[$0].panes } ?? []
        let closed = previous.filter { before.contains($0.id) && !after.contains($0.id) }
        let (panes, layout) = capture(to, carrying: previous + carried)
        if let index {
            // Panes listed but in neither tree are still cold (a tab
            // materializing its splits one tick apart): they stay listed,
            // and the shape is the one being built toward, not the
            // half-built one.
            let cold = session.tabs[index].panes.filter { !touched.contains($0.id) }
            session.tabs[index].panes = panes + cold
            if cold.isEmpty { session.tabs[index].layout = layout }
            if session.tabs[index].label == nil { session.tabs[index].label = inheritedLabel }
            if session.tabs[index].emoji == nil { session.tabs[index].emoji = inheritedEmoji }
            if session.tabs[index].panes.isEmpty, session.tabs[index].dock?.panes.isEmpty ?? true {
                session.tabs.remove(at: index)
            }
        } else if !panes.isEmpty {
            vlog("!! tree: '\(name)' has a live tree with no registry tab -> appended")
            session.tabs.append(Tab(panes: panes, layout: layout, label: inheritedLabel, emoji: inheritedEmoji))
        }
        sessions[name] = session
        for pane in closed { buryPane(pane, from: name) }
        persist()
    }

    /// A closed pane (split ⌘W, process exit, dock tenant close, cold
    /// close) rests in the graveyard as its own one-pane session: same
    /// 120s grace, same undo, same reap as every other death.
    private func buryPane(_ pane: Pane, from owner: String) {
        var buried = Session(
            name: newSessionId(),
            label: pane.label ?? pane.title ?? paneProgram(pane.id)
                ?? URL(fileURLWithPath: pane.cwd).lastPathComponent,
            emoji: pane.emoji,
            cwd: pane.cwd,
            state: .asleep)
        buried.tabs = [Tab(panes: [pane], layout: nil)]
        vlog("close: pane '\(pane.id)' leaves '\(owner)' -> buried as '\(buried.name)'")
        bury(buried)
    }

    /// The reboot mirror of ownership: the daemon's spec carries its
    /// owner (VIGIL_SESSION for `vigild restore`), rewritten at every
    /// claim. Write-only from here; never read back to second-guess the
    /// registry.
    private func chown(_ id: String, to owner: String) {
        runFireAndForget(vigildBin, ["chown", id, owner])
    }

    private var vigildBin: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/vigild").path
    }

    // MARK: Recency (the successor order when the session you are in dies)

    private func touchRecent(_ name: String) {
        guard recent.first != name else { return }
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
    }

    /// The session that takes a viewport when its occupant dies: the most
    /// recently active one that can be MOUNTED (detached or asleep;
    /// embedded and floating already live elsewhere), else manual order.
    private func successor(excluding dying: String) -> String? {
        func mountable(_ session: Session) -> Bool {
            guard session.name != dying else { return false }
            switch session.state {
            case .detached, .asleep: return true
            case .embedded, .floating: return false
            }
        }
        if let hit = recent.compactMap({ sessions[$0] }).first(where: mountable) { return hit.name }
        return sessions.values.filter(mountable)
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .first?.name
    }

    // MARK: Attention (fed by agent adapters through the wake events log)

    private var eventsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/events.jsonl")
    }

    private var eventsOffset: UInt64 = 0
    private var eventsTimer: Timer?

    /// The drain offset survives relaunches: attention that fired while the
    /// app was CLOSED (a watcher verdict, a headless agent finishing in its
    /// daemon) is exactly the attention a relaunch must surface. Only ancient
    /// history (pre-truncation) is not pending.
    private var eventsOffsetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/events.offset")
    }

    private struct WakeEvent: Decodable {
        let container: String
        let event: String
        /// The vigild pane daemon the agent lives in. Ground truth for
        /// ownership: VIGIL_SESSION in the process env is stamped at birth
        /// and goes stale when a tab is dragged into another session.
        let pane: String?
    }

    /// The session owning this pane daemon right now (live surfaces or
    /// captured sentinels). Ownership is derived, never parsed from the id.
    private func sessionOwning(pane: String) -> String? {
        sessions.first { ownedPaneIds($0.value).contains(pane) }?.key
    }

    /// Tail the events log agent adapters append to. A 1s poll is honest
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
        ackVisiblePanes() // the 1s presence pulse rides the events tick
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
            // agent lives in (survives drag-out; env container goes
            // stale), then the birth container.
            let name: String
            if let pane = event.pane, !pane.isEmpty, let owner = sessionOwning(pane: pane) {
                name = owner
            } else if sessions[event.container] != nil {
                name = event.container
            } else {
                continue
            }
            // Presence beats attention, PANE-granular: only an event whose
            // console is actually on screen is already answered. A watched
            // session's hidden tab queues like any other (session-level
            // presence acked those sight-unseen). Pane-less events keep
            // the session-level rule (nothing finer to check).
            if let pane = event.pane, !pane.isEmpty {
                if paneVisible(pane) {
                    lastAck[pane] = Date()
                    changed = true
                    continue
                }
            } else if isWatching(name) {
                changed = true
                continue
            }
            // Notification = permission prompt; Ask = the adapter classifier
            // found a question at turn end (both need input NOW).
            let attention: Attention = ["Notification", "Ask"].contains(event.event) ? .input : .done
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

    /// A pane is under the eyes RIGHT NOW: its view sits in the key
    /// window's hierarchy, unhidden (a collapsed dock hides its tenants),
    /// app active.
    private func paneVisible(_ pane: String) -> Bool {
        guard NSApp.isActive,
              let view = liveView(attachId: pane),
              let window = view.window, window.isKeyWindow else { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }

    /// THE seen-rule, one chokepoint, pane-granular: stamp every pane
    /// visible in the key window; the key session's queued attention
    /// resolves only once no blocked pane remains unseen - focusing tab 1
    /// never forgives an ask living in cold tab 4 (its dot holds, follow
    /// still targets it). Fired by key-window changes and focus syncs
    /// (instant) and the 1s events tick (presence is continuous; the tick
    /// is its pulse).
    func ackVisiblePanes() {
        guard NSApp.isActive, let window = NSApp.keyWindow else { return }
        var name: String?
        var views: [Ghostty.SurfaceView] = []
        if let controller = window.windowController as? TerminalController {
            name = sessionName(of: controller)
            views = Array(controller.surfaceTree)
            if let dock = dockMap.object(forKey: controller) { views += dock.views }
        } else if let quick = window.windowController as? QuickTerminalController {
            name = floatingName
            views = Array(quick.surfaceTree)
        } else {
            return
        }
        if let name { touchRecent(name) }
        let now = Date()
        var changed = false
        for view in views {
            guard let pane = view.vigilAttachId,
                  view.window === window,
                  !view.isHiddenOrHasHiddenAncestor else { continue }
            if let s = paneAgentState(pane),
               s.state == .blocked || s.state == .done,
               (lastAck[pane] ?? .distantPast) < s.since { changed = true }
            lastAck[pane] = now
        }
        if let name, let session = sessions[name],
           session.attention != .none, !blockedUnseen(name) {
            sessions[name]!.attention = .none
            sessions[name]!.attentionSince = nil
            changed = true
            onAttentionChange?()
        }
        if changed {
            // Persist only on a seen-FLIP (a lit pane going seen), not on
            // the 1s presence pulse: the flip is the fact worth surviving
            // a restart; the pulse would be a write per second for free.
            saveAcks()
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
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

    /// The attention FIFO: open the most urgent session. IDEMPOTENT
    /// (Adrian 2026-08-04): with the FIFO drained, fall back to STATE
    /// truth - any session still asking (even one already seen/acked)
    /// stays reachable, rotating past the current one so repeated
    /// presses walk every open ask.
    func next() {
        // Attention navigation is pane-precise: follow() lands on the
        // asking console (shapeshifting the key terminal window when
        // there is one; open() semantics remain the no-window fallback).
        // The session you are STANDING IN is never a target: being there
        // IS having seen it, and a stuck attention head pinned ⌘⇧J to the
        // current session forever - unable to reach any other ask
        // (Adrian 2026-08-06). Rotation emerges from the exclusion:
        // jumping somewhere makes it current, which excludes it from the
        // next press.
        let controller = NSApp.keyWindow?.windowController as? TerminalController
        let current = controller.flatMap { sessionName(of: $0) }
        // The head must EARN the jump like everyone else: a stuck
        // attention entry on a seen session pinned ⌘⇧J once.
        if let session = mostUrgent, session.name != current, unseenNeedy(session.name) {
            follow(session.name, in: controller)
            return
        }
        let queue = sessions.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .filter { $0.name != current && unseenNeedy($0.name) }
            .map(\.name)
        guard let target = queue.first else { return }
        follow(target, in: controller)
    }

    /// The head of the attention FIFO by name (the sidebar's direct-access
    /// key shapeshifts to it).
    var mostUrgentName: String? { mostUrgent?.name }

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

        let floated: TabRuntime
        var rest: [TabRuntime] = []
        var floatedIndex = 0
        switch session.state {
        case .embedded:
            // Which tab floats: the one you were looking at. Identified by
            // its leaf view, not an index: detach stashes runtimes in
            // REGISTRY order, which need not match the native member order.
            let selectedLeaf = (focusWindow(of: name)?.windowController as? TerminalController)?
                .surfaceTree.root?.leftmostLeaf()
            detach(name: name)
            guard case .detached(let held) = sessions[name]!.state, !held.isEmpty else { return }
            floatedIndex = held.firstIndex { $0.tree.root?.leftmostLeaf() === selectedLeaf } ?? 0
            floated = held[floatedIndex]
            rest = held
            rest.remove(at: floatedIndex)
        case .floating:
            // Presence acks once the quick terminal is key (chokepoint).
            quick.animateIn()
            return
        case .detached(let held):
            guard let first = held.first else { return }
            floated = first
            rest = Array(held.dropFirst())
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

        sessions[name]!.state = .floating(rest: rest, floatedDock: floated.dock, floatedIndex: floatedIndex)
        floatingName = name
        quickTreeSwap = true
        quick.surfaceTree = floated.tree
        quickTreeSwap = false
        quick.animateIn()
        if let view = floated.tree.root?.leftmostLeaf() {
            DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
        }
        persist()
    }

    /// The floating session leaves the quick terminal: back to detached
    /// with whatever its tree is NOW (splits made while floating already
    /// edited the registry through the chokepoint), reinserted among its
    /// waiting tabs, and the quick terminal gets its own stashed workspace
    /// back.
    func reclaim(_ name: String, from quick: QuickTerminalController) {
        guard floatingName == name else { return }
        floatingName = nil
        let tree = quick.surfaceTree
        if let session = sessions[name] {
            var held: [TabRuntime] = []
            var index = 0
            var dock: VigilDockRuntime?
            if case .floating(let rest, let floatedDock, let floatedIndex) = session.state {
                held = rest
                index = floatedIndex
                dock = floatedDock
            }
            if !tree.isEmpty {
                held.insert(TabRuntime(tree: tree, dock: dock), at: min(index, held.count))
            }
            sessions[name]!.state = held.isEmpty ? .asleep : .detached(held)
        }
        quickTreeSwap = true
        quick.surfaceTree = stashedQuickTree ?? SplitTree()
        quickTreeSwap = false
        stashedQuickTree = nil
        persist()
    }

    // MARK: Lifecycle

    /// Stamp a fresh window's config so it is daemon-backed from birth (a
    /// vigild attach id + VIGIL_SESSION). Returns nil when the config already
    /// carries vigil identity (attach id or VIGIL_SESSION: create,
    /// resurrection and tab paths handled it), so this only augments plain
    /// windows (⌘N, the startup window, dock reopen). Pair with
    /// registerSession once the controller exists.
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

    /// Register a freshly-created plain window (⌘⇧N, the startup window,
    /// dock reopen) as a session: the window's tree is its first tab.
    func registerSession(controller: TerminalController, name: String, cwd: String) {
        var session = Session(name: name, label: name, cwd: cwd, state: .embedded)
        session.paneSeq = 1 // index 0 consumed at birth
        sessions[name] = session
        registerMember(controller, name: name)
        vlog("born(window): '\(name)' cwd=\(cwd)")
        persist()
    }

    /// Session creation is a REGISTRY fact, never a window fact: mint the
    /// identity plus one cold daemon-backed pane, asleep. The daemon spawns
    /// and the shell/claude lives in it (not any window's pty) the moment a
    /// viewport materializes the pane.
    private func mintSession(cwd: String) -> String {
        let name = newSessionId()
        var session = Session(name: name, label: name, cwd: cwd, state: .asleep)
        session.tabs = [Tab(panes: [Pane(id: "vigil-\(name)-0", cwd: cwd)], layout: nil)]
        session.paneSeq = 1 // index 0 consumed at birth
        sessions[name] = session
        vlog("born(mint): '\(name)' cwd=\(cwd)")
        return name
    }

    /// New Session (⌘N, menu-bar New Session, overview `n`): the fresh
    /// session takes the CURRENT viewport (shapeshift; the occupant stays
    /// alive, detached — the sidebar-click semantic). A window is created
    /// only when no visible viewport exists: viewport necessity, never a
    /// consequence of session creation.
    func newSession(in controller: TerminalController? = nil, cwd explicitCwd: String? = nil) {
        let viewport: TerminalController? = {
            let c = controller ?? TerminalController.preferredParent
            guard let c, c.window?.isVisible == true else { return nil }
            return c
        }()
        let cwd = explicitCwd
            ?? viewport?.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let name = mintSession(cwd: cwd)
        if let viewport {
            shapeshift(in: viewport, to: name)
        } else {
            open(name: name)
        }
    }

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

    /// Mint the next daemon pane index for a session: the persisted
    /// monotonic counter, floored by the owned-id max. NEVER derived from
    /// owned ids alone: an id whose tab left the session (bury, drag-out)
    /// is still a live daemon elsewhere, and re-minting it attaches the
    /// new surface to that daemon's socket - the departed tab replays into
    /// the new pane.
    private func nextPaneIndex(name: String) -> Int {
        guard let session = sessions[name] else { return 0 }
        var maxIndex = 0
        for id in ownedPaneIds(session) {
            if let n = id.split(separator: "-").last.flatMap({ Int($0) }) {
                maxIndex = max(maxIndex, n)
            }
        }
        let minted = max(session.paneSeq, maxIndex + 1)
        sessions[name]!.paneSeq = minted + 1
        return minted
    }

    /// Detach: every live tab (ptys running) moves from its window to this
    /// manager as a held runtime; the windows close. Our strong reference
    /// keeps every surface alive.
    func detach(name: String) {
        guard let session = sessions[name], case .embedded = session.state else { return }
        guard !members(of: name).isEmpty else { return }
        let held = vacate(name, keeping: nil)
        sessions[name]!.state = held.isEmpty ? .asleep : .detached(held)
        persist()
    }

    /// Pull every live tab of an embedded session out of its windows, in
    /// REGISTRY order (the native group rotates the anchored tab first;
    /// tab order must never follow it). Sibling windows close; `keeping`'s
    /// tree is left in place for the caller to REPLACE (an emptied tree
    /// closes the window, a replaced one never does). Membership ends
    /// before any tree empties, so the close cascade sees session-less
    /// controllers. Freezes the session's thumbnail and cwd on the way.
    private func vacate(_ name: String, keeping viewport: TerminalController?) -> [TabRuntime] {
        let ms = members(of: name)
        let focusController = viewport
            ?? (focusWindow(of: name)?.windowController as? TerminalController)
            ?? ms.first
        if let focusController {
            if let pwd = focusController.focusedSurface?.pwd { sessions[name]!.cwd = pwd }
            // Freeze the visual: the overview shows what the workspace
            // looked like at the moment it was released. The selected tab's
            // WHOLE window content: a workspace is its splits.
            let thumb = Self.windowSnapshot(focusController)
                ?? (focusController.focusedSurface ?? focusController.surfaceTree.root?.leftmostLeaf())?.asImage
            if let thumb {
                sessions[name]!.thumbnail = thumb
                persistThumb(name: name, image: thumb)
            }
        }
        var pool = ms.filter { !$0.surfaceTree.isEmpty }
        var held: [TabRuntime] = []
        for tab in sessions[name]!.tabs {
            let ids = Set(tabPaneIds(tab))
            guard let index = pool.firstIndex(where: { member in
                member.surfaceTree.contains { $0.vigilAttachId.map(ids.contains) ?? false }
            }) else { continue } // a cold tab lives in the registry alone
            let member = pool.remove(at: index)
            let liveIds = Set(member.surfaceTree.compactMap(\.vigilAttachId))
            let registered = Set(tab.panes.map(\.id))
            guard registered.isSubset(of: liveIds) else {
                // Half-materialized (vacated between the mount and its
                // split tick): held, this runtime would mount verbatim
                // forever with its cold siblings unreachable. Released
                // instead: the tab goes cold and rebuilds whole.
                vlog("vacate: '\(name)' tab \(registered.sorted()) half-live \(liveIds.sorted()) -> released cold")
                dockMap.object(forKey: member)?.unmount()
                continue
            }
            held.append(TabRuntime(tree: member.surfaceTree, dock: dockMap.object(forKey: member)))
        }
        for stray in pool {
            vlog("!! vacate: '\(name)' member tree \(stray.surfaceTree.compactMap(\.vigilAttachId)) missing from its registry (appended)")
            held.append(TabRuntime(tree: stray.surfaceTree, dock: dockMap.object(forKey: stray)))
        }
        for runtime in held {
            runtime.dock?.unmount()
            setOcclusion(false, [runtime])
        }
        for member in ms {
            dockMap.removeObject(forKey: member)
            memberships.removeObject(forKey: member)
        }
        for member in ms where member !== viewport { killController(member) }
        return held
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

    /// The name to REMEMBER for a live pane: its terminal title, which is
    /// what the program calls itself ("Buscar versión en castellano", not
    /// "adrian"). Ghostty's own default (a bare "👻") and an empty title
    /// are noise, never worth persisting over a real remembered name.
    private func capturedTitle(of view: Ghostty.SurfaceView) -> String? {
        // Claude prefixes its title with a live STATE marker: a braille
        // spinner while working, `✳` when idle. That is a status light, not
        // part of the name, and freezing it into stored state would pin a
        // stale spinner onto a cold pane forever.
        var title = view.title.trimmingCharacters(in: .whitespaces)
        while let first = title.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) || first == "✳" || first == "·" {
            title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty, title != "👻" else {
            return view.vigilAttachId.flatMap { capturedTitle(ofPane: $0) }
        }
        return title
    }

    /// A pane's remembered name, from its registry entry.
    func capturedTitle(ofPane paneId: String) -> String? {
        registered(paneId)?.title
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

        // No manual acknowledge: presence (ackVisiblePanes at the focus
        // chokepoints) resolves attention once the asking console is
        // actually on screen; a hidden ask survives the visit.
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

        case .detached(let held):
            // ONE window, first live tab mounted, the rest released to
            // COLD (registry + daemons; the sidebar mounts them on click).
            // The lazy rule is universal: launch, overview and shapeshift
            // all materialize the same way, so tabs never "disappear"
            // between the first open and the first swap.
            vlog("open: '\(name)' detached tabs=\(held.count) -> mount first, \(held.count - 1) cold")
            guard let first = held.first else {
                sessions[name]!.state = .asleep
                open(name: name)
                return
            }
            let controller = TerminalController.newWindow(ghostty, tree: first.tree, confirmUndo: false)
            registerMember(controller, name: name)
            if let dock = first.dock { dockMap.setObject(dock, forKey: controller) }
            for runtime in held.dropFirst() { runtime.dock?.unmount() }
            setOcclusion(true, [first])
            sessions[name]!.state = .embedded
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

        case .asleep:
            resurrect(name: name, ghostty: ghostty)
        }
        touchRecent(name)
        persist()
    }

    /// Every tab needs a host pane to materialize: a session with nothing
    /// registered (every tab emptied by moves and closes) gets one fresh
    /// pane in its cwd, and a dock-only tab (its split panes moved away,
    /// its tenants staying) gets a fresh host pane in front of its dock,
    /// the moment it is shown.
    private func ensureHostPanes(_ name: String) {
        var tabs = sessions[name]!.tabs
        if tabs.isEmpty { tabs = [Tab(panes: [], layout: nil)] }
        for index in tabs.indices where tabs[index].panes.isEmpty {
            tabs[index].panes = [Pane(id: "vigil-\(name)-\(nextPaneIndex(name: name))", cwd: sessions[name]!.cwd)]
            tabs[index].layout = nil
        }
        sessions[name]!.tabs = tabs
    }

    /// Rebuild the whole workspace from its registry: one window, every
    /// tab regrouped, every pane back in its cwd. Panes reattach natively
    /// (living daemon = living processes, per-pane resume rides the
    /// daemon's own resume pointer); a dead daemon comes back as a fresh
    /// shell.
    private func resurrect(name: String, ghostty: Ghostty.App) {
        ensureHostPanes(name)
        let tabs = sessions[name]!.tabs

        func configFor(_ pane: Pane) -> Ghostty.SurfaceConfiguration {
            resurrectConfig(name: name, pane: pane)
        }

        /// Splits and subsequent tabs wait for their window to actually
        /// present (next runloop tick); building against an unpresented
        /// window drops splits and births invisible tabs.
        vlog("resurrect: '\(name)' tabs=\(tabs.count) panes=\(tabs.map(\.panes.count)) -> native tabs")

        // First tab gets the window; the rest come back as NATIVE tabs
        // behind it (ghostty's regular tab UX, exactly).
        let usable = tabs.filter { !$0.panes.isEmpty }
        guard let first = usable.first else { return }
        let panes = first.panes
        let firstIndex = min(first.layout?.firstLeaf ?? 0, panes.count - 1)
        let controller = TerminalController.newWindow(
            ghostty, withBaseConfig: configFor(panes[firstIndex]))
        registerMember(controller, name: name)
        materializeSplits(controller, tab: first, configFor: configFor)
        materializeDockCapture(controller, first.dock, configFor: configFor)
        // A FRESH window needs one presentation beat (a tab attached to
        // an unpresented window is born invisible); after it, the rest
        // attach together - one wait, no per-tab trickle.
        let rest = Array(usable.dropFirst())
        if !rest.isEmpty, let parent = controller.window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                for tab in rest {
                    let firstPane = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
                    guard let tabController = TerminalController.newTab(
                        ghostty, from: parent, withBaseConfig: configFor(tab.panes[firstPane])
                    ) else { continue }
                    self.registerMember(tabController, name: name)
                    self.materializeSplits(tabController, tab: tab, configFor: configFor)
                    self.materializeDockCapture(tabController, tab.dock, configFor: configFor)
                    self.focusLeftmost(tabController)
                }
                controller.window?.makeKeyAndOrderFront(nil)
                self.focusLeftmost(controller)
            }
        }
        sessions[name]!.state = .embedded
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A pane's resurrection config: cwd + session identity + its native
    /// attach id (a live daemon makes the surface a reattach; a dead one
    /// is spawned fresh on first contact).
    private func resurrectConfig(name: String, pane: Pane) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pane.cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = pane.id
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
        // The closure is BOUND to the tree it was scheduled for: a swap
        // between schedule and fire (a rival mount racing this one) would
        // otherwise graft this tab's splits onto whatever tree the
        // controller holds at fire time - the twin-pane manufacturer
        // (2026-08-07: click-mount + shapeshiftTab re-mount, each
        // materializing pane 8 into the survivor's tree).
        let bornAnchor = controller.surfaceTree.root?.leftmostLeaf()
        // The default delay exists for windows that have not PRESENTED yet
        // (splits against an unhosted surface drop); mounting into a live
        // window passes 0 and splits land on the next runloop tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let anchor = controller.surfaceTree.root?.leftmostLeaf() else {
                self?.vlog("resurrect: splits DROPPED (no anchor surface)")
                return
            }
            guard anchor === bornAnchor else {
                self?.vlog("!! materialize: tree swapped under the mount - stale splits aborted")
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
                // wherever the realized tree matches the layout. Same
                // panes, so the chokepoint only recaptures the shape.
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
            self?.assertInvariants("materialize")
        }
    }

    // MARK: Close (vigil owns every close; scope decides the meaning)

    /// Closing a session's WINDOW (red button, ⌘⇧W) puts the session away:
    /// it detaches, everything keeps running, no confirm, nothing dies
    /// (Adrian 2026-08-22: the red button and ⌘Q never kill; only ⌘W
    /// does). Returns true when handled (the close must be swallowed by
    /// the caller).
    func handleWindowClose(controller: TerminalController) -> Bool {
        guard let name = sessionName(of: controller) else {
            vlog("handleWindowClose: controller has NO session -> not handled (window closes plain)")
            return false
        }
        let empty = members(of: name).allSatisfy { $0.surfaceTree.isEmpty }
        vlog("handleWindowClose: '\(name)' emptyTrees=\(empty)")
        if empty {
            for member in members(of: name) { memberships.removeObject(forKey: member) }
            sessions[name]!.state = .asleep
            persist()
            return false
        }
        detach(name: name)
        return true
    }

    /// ⌘W on a SPLIT pane of a session window: confirm with vigil's
    /// process truth (the program holding the tty, never ghostty's
    /// always-running daemon child), then let ghostty remove the node; the
    /// tree-change chokepoint buries the pane. Returns false when the
    /// close needs no confirm (the caller's plain removal proceeds).
    func closePane(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        in controller: TerminalController,
        withConfirmation: Bool
    ) -> Bool {
        guard withConfirmation, sessionName(of: controller) != nil else { return false }
        let busy = busyPrograms(panes: node.compactMap(\.vigilAttachId))
        guard !busy.isEmpty else {
            controller.closeSurface(node, withConfirmation: false)
            return true
        }
        controller.confirmClose(
            messageText: "Close Pane?",
            informativeText: "\(busy.joined(separator: ", ")) still running. Closing the pane kills it (undo keeps it for \(Int(Self.killGrace))s)."
        ) { [weak controller] in
            controller?.closeSurface(node, withConfirmation: false)
        }
        return true
    }

    /// Confirm-then-kill for surfaces outside the keybind path (sidebar
    /// context menu, overview): same alert, same grace; the viewport the
    /// session showed in moves on to the last active session.
    func killWithConfirm(name: String) {
        guard sessions[name] != nil else { return }
        confirmKill(name: name) { self.kill(name: name) }
    }

    /// Closing one TAB of a multi-tab session is a structural edit, not a
    /// lifecycle event: the tab leaves the session and becomes its own
    /// buried session (120s grace, ⌘⇧T exhumes it into its own window;
    /// expiry kills its pane daemons). Symmetric with drag-out, which also
    /// makes a tab its own session, just an alive one.
    func closeTabStructurally(_ controller: TerminalController) {
        guard let name = sessionName(of: controller) else { return }
        let tree = controller.surfaceTree
        let dock = dockMap.object(forKey: controller)
        memberships.removeObject(forKey: controller)
        dockMap.removeObject(forKey: controller)
        swapTree(controller, SplitTree())
        vlog("closeTab: one tab leaves '\(name)'")
        guard !tree.isEmpty else { persist(); return }
        buryTab(tree: tree, dock: dock, from: name)
        persist()
    }

    /// A live tab leaves its session for the graveyard: its registry entry
    /// moves into a one-tab burial that HOLDS the runtime (views alive, so
    /// an exhume re-embeds without a VT replay). The tab's dock leaves
    /// with it (the dock is the tab's).
    private func buryTab(tree: SplitTree<Ghostty.SurfaceView>, dock: VigilDockRuntime?, from name: String) {
        let ids = Set(tree.compactMap(\.vigilAttachId) + (dock?.views.compactMap(\.vigilAttachId) ?? []))
        var session = sessions[name]!
        let tab: Tab
        if let index = session.tabs.firstIndex(where: { !Set(tabPaneIds($0)).isDisjoint(with: ids) }) {
            tab = session.tabs.remove(at: index)
        } else {
            vlog("!! buryTab: '\(name)' tab \(ids) was not in its registry")
            let (panes, layout) = capture(tree, carrying: [])
            tab = Tab(panes: panes, layout: layout, dock: dock.flatMap { captureDock($0, carrying: []) })
        }
        sessions[name] = session
        let surface = tree.root?.leftmostLeaf()
        let cwd = surface?.pwd ?? tab.panes.first?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        var buried = Session(
            name: newSessionId(),
            label: tab.label ?? surface.flatMap { capturedTitle(of: $0) }
                ?? URL(fileURLWithPath: cwd).lastPathComponent,
            emoji: tab.emoji,
            cwd: cwd,
            state: .detached([TabRuntime(tree: tree, dock: dock)]))
        buried.tabs = [tab]
        buried.thumbnail = surface?.asImage
        dock?.unmount()
        vlog("close: tab \(ids.sorted()) leaves '\(name)' -> buried as '\(buried.name)'")
        bury(buried)
    }

    /// One-gesture detach for the front window (⌘⇧U): keep running in the
    /// background, window closes.
    func detachFrontWindow() {
        guard let controller = TerminalController.preferredParent,
              let name = sessionName(of: controller) else { return }
        detach(name: name)
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
    /// own session (registerMember claims their registry entries from the
    /// old one). The ID stays a fresh random handle (identity is NEVER
    /// derived — the adrian-N lesson); lineage lives in the LABEL:
    /// "<parent label> 2", "… 3", renameable.
    private func mintSession(from controllers: [TerminalController], inheriting old: Session) {
        let name = newSessionId()
        let cwd = controllers.first?.focusedSurface?.pwd ?? old.cwd
        var ordinal = 2
        let taken = Set(sessions.values.map(\.label))
        while taken.contains("\(old.label) \(ordinal)") { ordinal += 1 }
        var session = Session(name: name, label: "\(old.label) \(ordinal)", cwd: cwd, state: .embedded)
        session.emoji = old.emoji // visual lineage, renameable like the label
        sessions[name] = session
        for controller in controllers { registerMember(controller, name: name) }
        vlog("mint(drag-out): '\(name)' ('\(session.label)') from '\(old.name)' tabs=\(controllers.count)")
        // No async label refinement here: the lineage label is already
        // meaningful (unlike an id seed), and silently replacing it would
        // erase exactly the breadcrumb the mint just created. Rename wins.
        persist()
    }

    /// Drag-in: a session's tabs joined another session's window; the window
    /// absorbs them, cold tabs included. Attention escalates; nothing dies.
    private func absorb(_ other: String, into absorberName: String) {
        guard sessions[other] != nil, sessions[absorberName] != nil else { return }
        for controller in members(of: other) {
            registerMember(controller, name: absorberName)
        }
        let absorbed = sessions[other]!
        for tab in absorbed.tabs {
            for id in tabPaneIds(tab) { chown(id, to: absorberName) }
        }
        sessions[absorberName]!.tabs += absorbed.tabs
        if absorbed.attention.rawValue > sessions[absorberName]!.attention.rawValue {
            sessions[absorberName]!.attention = absorbed.attention
            sessions[absorberName]!.attentionSince = absorbed.attentionSince
        }
        sessions[other] = nil
        recent.removeAll { $0 == other }
        try? FileManager.default.removeItem(at: dumpsDir(other))
        vlog("absorb(drag-in): '\(other)' -> '\(absorberName)'")
        persist()
        onAttentionChange?()
    }

    // MARK: Shapeshift (the sidebar's click semantic)

    /// The window is a VIEWPORT: clicking a session in the bar swaps what
    /// this window displays, it never spawns a window. Live targets keep
    /// their home (focus it); detached/asleep targets mount INTO this
    /// window. The current occupant leaves honestly: detached, running,
    /// invisible (a session-less stray is minted a real session first).
    func shapeshift(in controller: TerminalController, to targetName: String, anchor: String? = nil) {
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

        // No manual acknowledge (see open): the mounted panes are stamped
        // seen by the focus sync that follows the mount.
        mount(targetName, into: controller, ghostty: ghostty, anchor: anchor)
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
    /// Rendering follows VISIBILITY, not liveness. Upstream pauses a
    /// surface's renderer via its WINDOW's occlusion notifications - a
    /// surface released to detached has no window, so nothing ever tells
    /// it to stop: every detached tree kept drawing at display refresh
    /// forever (~15 invisible renderers ticking at 120Hz = the scroll
    /// stutter vanilla doesn't have, sampled 2026-08-06). Detach/bury
    /// occlude; mount un-occludes (the window's own notifications take
    /// over from there).
    private func setOcclusion(_ visible: Bool, _ runtimes: [TabRuntime]) {
        for runtime in runtimes {
            setOcclusion(visible, views: Array(runtime.tree) + (runtime.dock?.views ?? []))
        }
    }

    private func setOcclusion(_ visible: Bool, views: [Ghostty.SurfaceView]) {
        for view in views {
            guard let surface = view.surface, view.isWindowVisible != visible else { continue }
            ghostty_surface_set_occlusion(surface, visible)
            view.isWindowVisible = visible
        }
    }

    /// The occupant of a viewport leaves it ALIVE: the session goes
    /// detached with its runtimes held (coming back re-embeds these exact
    /// surfaces: native tabs regroup from live trees, no VT replay, titles
    /// intact); this controller's tree is left for mount to REPLACE.
    private func releaseOccupant(of controller: TerminalController) {
        if let current = sessionName(of: controller) {
            let held = vacate(current, keeping: controller)
            sessions[current]!.state = held.isEmpty ? .asleep : .detached(held)
        } else if !controller.surfaceTree.isEmpty {
            // Safety-net stray: mint it a REAL session (alive, listed,
            // killable) instead of silently burying its tree.
            let tree = controller.surfaceTree
            let surface = controller.focusedSurface ?? tree.root?.leftmostLeaf()
            let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
            let cwd = surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            let runtime = TabRuntime(tree: tree, dock: nil)
            var stray = Session(
                name: newSessionId(),
                label: title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title,
                cwd: cwd,
                state: .detached([runtime]))
            stray.thumbnail = surface?.asImage
            let (panes, layout) = capture(tree, carrying: [])
            stray.tabs = [Tab(panes: panes, layout: layout)]
            sessions[stray.name] = stray
            vlog("!! release: session-less window minted as stray '\(stray.name)'")
            setOcclusion(false, [runtime])
        }
    }

    /// Mount a detached/asleep session INTO an existing window as ONE
    /// synchronous tree swap: its first tab REPLACES the window's tree and
    /// every other tab stays COLD (registry + running daemons; the sidebar
    /// lists them and a click mounts them the same way). No window is ever
    /// created or closed here: a shapeshift must be instant, not a
    /// shuffle (Adrian 2026-08-01). The tree lands BEFORE membership:
    /// registerMember reads the controller's tree, and the old occupant's
    /// tree must never be claimed for the newcomer.
    private func mount(
        _ name: String,
        into controller: TerminalController,
        ghostty: Ghostty.App,
        anchor: String? = nil
    ) {
        guard let session = sessions[name] else { return }
        switch session.state {
        case .detached(let held):
            // The ANCHORED tab (else the first) mounts into THIS window
            // instantly; remaining tabs regroup as NATIVE tab-windows
            // behind it (ghostty's regular tab UX, exactly - Adrian
            // 2026-08-03: session tabs ARE native tabs, period).
            let chosenIndex = anchor.flatMap { a in
                held.firstIndex { runtime in runtime.tree.contains { $0.vigilAttachId == a } }
            } ?? 0
            guard held.indices.contains(chosenIndex) else {
                sessions[name]!.state = .asleep
                mount(name, into: controller, ghostty: ghostty, anchor: anchor)
                return
            }
            let chosen = held[chosenIndex]
            swapTree(controller, chosen.tree)
            if let dock = chosen.dock { dockMap.setObject(dock, forKey: controller) }
            registerMember(controller, name: name)
            // Wake the MOUNTED tab's renderers (the window's occlusion
            // notifications take over from the next change); the rest
            // regroup as unselected tab windows and stay occluded until
            // AppKit reports them visible.
            setOcclusion(true, [chosen])
            focusLeftmost(controller)
            let rest = held.enumerated().filter { $0.offset != chosenIndex }
            if !rest.isEmpty {
                // This window is PRESENTED (it is the live viewport), so
                // the rest attach in ONE next tick - no stagger, no
                // trickle. The 0.3s beat exists only for freshly created
                // windows (launch resurrect). Each tab lands at its
                // REGISTRY position relative to the anchored viewport
                // (before-anchor insert .below it, after-anchor chain
                // .above), so the native bar never rotates anchored-first.
                regroupsInFlight += 1
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    defer { self.regroupsInFlight -= 1; self.syncWindowMarks() }
                    var lastAfter = controller.window
                    for (index, runtime) in rest {
                        let before = index < chosenIndex
                        let tab = TerminalController.vigilNewTab(
                            ghostty, parent: controller, tree: runtime.tree,
                            relativeTo: before ? controller.window : lastAfter,
                            ordered: before ? .below : .above)
                        if !before { lastAfter = tab.window ?? lastAfter }
                        if let dock = runtime.dock { self.dockMap.setObject(dock, forKey: tab) }
                        self.registerMember(tab, name: name)
                        self.focusLeftmost(tab)
                    }
                    controller.window?.makeKeyAndOrderFront(nil)
                    self.focusLeftmost(controller)
                    VigilBars.shared.syncAll()
                }
            }
            sessions[name]!.state = .embedded

        case .asleep:
            ensureHostPanes(name)
            let tabs = sessions[name]!.tabs
            guard let app = ghostty.app else { return }
            let configFor: (Pane) -> Ghostty.SurfaceConfiguration = { [unowned self] in
                self.resurrectConfig(name: name, pane: $0)
            }
            let usable = tabs.enumerated().filter { !$0.element.panes.isEmpty }
            let chosen = anchor.flatMap { a in
                usable.first { tabPaneIds($0.element).contains(a) }
            } ?? usable.first
            guard let chosen else { return }
            let first = chosen.element
            let panes = first.panes
            let firstIndex = min(first.layout?.firstLeaf ?? 0, panes.count - 1)
            let view = Ghostty.SurfaceView(app, baseConfig: configFor(panes[firstIndex]))
            swapTree(controller, SplitTree(view: view))
            registerMember(controller, name: name)
            materializeSplits(controller, tab: first, configFor: configFor, delay: 0)
            materializeDockCapture(controller, first.dock, configFor: configFor)
            focusLeftmost(controller)
            // Remaining tabs come back as NATIVE tabs, ALL in one next
            // tick (the window is presented; stagger was pure trickle),
            // each at its CAPTURE position relative to the anchored one
            // (newTab's placement is config-dependent; capture order
            // decides here), focus returning to the anchored one once.
            let rest = usable.filter { $0.offset != chosen.offset }
            if !rest.isEmpty, let parent = controller.window {
                regroupsInFlight += 1
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    defer { self.regroupsInFlight -= 1; self.syncWindowMarks() }
                    var lastAfter = parent
                    for (offset, tab) in rest {
                        // Silent append (vigilNewTab), NOT newTab: its
                        // per-tab presentation makeKeys every joiner in
                        // sequence - the same festival as the detached
                        // regroup. Surfaces come from the resurrect
                        // config directly.
                        let firstPane = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
                        let view = Ghostty.SurfaceView(app, baseConfig: configFor(tab.panes[firstPane]))
                        let before = offset < chosen.offset
                        let tabController = TerminalController.vigilNewTab(
                            ghostty, parent: controller, tree: SplitTree(view: view),
                            relativeTo: before ? parent : lastAfter,
                            ordered: before ? .below : .above)
                        if !before { lastAfter = tabController.window ?? lastAfter }
                        self.registerMember(tabController, name: name)
                        self.materializeSplits(tabController, tab: tab, configFor: configFor, delay: 0)
                        self.materializeDockCapture(tabController, tab.dock, configFor: configFor)
                        self.focusLeftmost(tabController)
                    }
                    controller.window?.makeKeyAndOrderFront(nil)
                    self.focusLeftmost(controller)
                }
            }
            sessions[name]!.state = .embedded

        case .embedded, .floating:
            // Refusing is correct (the session lives elsewhere) but it
            // must SCREAM: a caller that mounts blind leaves this window
            // stray with the old tree still on screen, and the next
            // release mints that tree as a duplicate session (the
            // 2026-08-04 "Evaluate FFmpeg" twins). Callers route embedded
            // targets to their home window or pick a mountable session.
            vlog("mount REFUSED: '\(name)' is \(stateTag(session.state)) - window left as-is")
        }
    }


    /// Swap WHICH tab of the CURRENT session this window displays: the
    /// mounted tab releases (its daemons keep its exact state), the cold
    /// tab materializes in place. The viewport rule, one level down.
    /// `anchor` is any pane id of the cold tab (indices shift as tabs go
    /// live/cold; pane ids never lie). A tab with ANY pane live in this
    /// session's windows is already showing (its siblings may still be
    /// materializing a tick behind).
    func shapeshiftTab(name: String, anchor: String, in controller: TerminalController) {
        guard sessionName(of: controller) == name, let session = sessions[name] else { return }
        let live = liveAttachIds(of: name)
        guard let target = session.tabs.first(where: { tabPaneIds($0).contains(anchor) }),
              !target.panes.isEmpty else {
            vlog("shapeshiftTab: '\(name)' anchor \(anchor) matches NO registered tab - refused loud")
            return
        }
        guard Set(tabPaneIds(target)).isDisjoint(with: live) else { return } // already showing
        vlog("shapeshiftTab: '\(name)' -> tab anchored at \(anchor)")

        dockMap.object(forKey: controller)?.unmount()
        dockMap.removeObject(forKey: controller)
        mountCapturedTab(target, name: name, in: controller)
        persist()
    }

    /// After ANY tree mount/swap, focus the new tree's leftmost leaf in
    /// its own window: `focusedSurface` drives window AND tab titles, and
    /// a nil/stale one leaves ghostty's literal 👻 default in the tab bar
    /// (per-window first responder; background tabs never steal key).
    private func focusLeftmost(_ controller: TerminalController) {
        guard let leaf = controller.surfaceTree.root?.leftmostLeaf() else { return }
        DispatchQueue.main.async { Ghostty.moveFocus(to: leaf) }
    }

    /// Replace the window's tree with a registered tab, in place. The old
    /// tree's views release (whoever holds their registry entries keeps
    /// their daemons).
    private func mountCapturedTab(_ target: Tab, name: String, in controller: TerminalController) {
        guard !target.panes.isEmpty, let app = ghosttyApp?.app else { return }
        let configFor: (Pane) -> Ghostty.SurfaceConfiguration = { [unowned self] in
            self.resurrectConfig(name: name, pane: $0)
        }
        let panes = target.panes
        let firstIndex = min(target.layout?.firstLeaf ?? 0, panes.count - 1)
        let view = Ghostty.SurfaceView(app, baseConfig: configFor(panes[firstIndex]))
        swapTree(controller, SplitTree(view: view))
        materializeSplits(controller, tab: target, configFor: configFor, delay: 0)
        materializeDockCapture(controller, target.dock, configFor: configFor)
        focusLeftmost(controller)
    }

    // MARK: Viewport ⌘W (the tab closes; the window NEVER does while a session remains)

    /// Adrian 2026-08-03: "cmd+w always closes the TAB, never the window."
    /// The mounted tab buries (structural edit, undo grace, confirm when a
    /// process runs) and the session's next tab takes the viewport; the
    /// LAST tab is the session's death (Kill/Cancel when something runs,
    /// then the undo grace) and the last active session takes the
    /// viewport. Only with nothing left anywhere does the window truly
    /// close. Window close stays reachable: red button / ⌘⇧W / ⌘M.
    /// Returns false when this controller is not a lone viewport (native
    /// multi-tab windows keep the old semantics).
    func closeViewportTab(_ controller: TerminalController) -> Bool {
        guard let name = sessionName(of: controller),
              members(of: name).count <= 1 else { return false }
        let live = liveAttachIds(of: name)
        let cold = sessions[name]!.tabs.filter { tab in
            !tab.panes.isEmpty && Set(tabPaneIds(tab)).isDisjoint(with: live)
        }

        if let next = cold.first {
            let proceed = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.buryMountedTab(thenMount: next, name: name, in: controller)
            }
            let busy = busyPrograms(in: controller)
            if !busy.isEmpty {
                controller.confirmClose(
                    messageText: "Close Tab?",
                    informativeText: "\(busy.joined(separator: ", ")) still running. Closing the tab kills it (undo keeps it for \(Int(Self.killGrace))s).")
                { proceed() }
            } else {
                proceed()
            }
            return true
        }

        // The LAST tab: the session dies; the viewport moves on.
        vlog("closeViewportTab: last tab of '\(name)' -> kill, viewport moves on")
        confirmKill(name: name) { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.kill(name: name, viewport: controller)
        }
        return true
    }

    private func buryMountedTab(thenMount next: Tab, name: String, in controller: TerminalController) {
        let tree = controller.surfaceTree
        let dock = dockMap.object(forKey: controller)
        dockMap.removeObject(forKey: controller)
        if !tree.isEmpty { buryTab(tree: tree, dock: dock, from: name) }
        mountCapturedTab(next, name: name, in: controller)
        persist()
    }

    /// ⌘W with the keyboard in a DOCK tenant closes that tenant alone
    /// (it is not in the tree; without this the close request no-ops or
    /// escalates). Native confirm when its process runs.
    func closeDockTenantIfHosted(
        _ view: Ghostty.SurfaceView, in controller: TerminalController, withConfirmation: Bool
    ) -> Bool {
        guard let runtime = dockMap.object(forKey: controller),
              let index = runtime.views.firstIndex(where: { $0 === view }) else { return false }
        let busy = busyPrograms(panes: [view.vigilAttachId].compactMap { $0 })
        if withConfirmation, !busy.isEmpty {
            controller.confirmClose(
                messageText: "Close Dock Pane?",
                informativeText: "\(busy.joined(separator: ", ")) still running. Closing the pane kills it."
            ) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.closeDockTenant(controller, index: index)
            }
        } else {
            closeDockTenant(controller, index: index)
        }
        return true
    }

    /// Right-click Close Tab from the sidebar: the native flow for
    /// whatever form the tab is in. Live → its window's close-tab (which
    /// carries the viewport semantics and confirms); COLD → buried from
    /// the registry (daemons alive, exhumable), confirming when the tree
    /// files say something runs.
    func closeTabFromSidebar(name: String, anchor: String?, in host: TerminalController?) {
        guard sessions[name] != nil, let anchor else { return }
        if let view = liveView(attachId: anchor),
           let controller = view.window?.windowController as? TerminalController {
            controller.closeTab(nil)
            return
        }
        guard let tab = sessions[name]!.tabs.first(where: { tabPaneIds($0).contains(anchor) }) else { return }
        let busy = busyPrograms(panes: tabPaneIds(tab))
        let proceed = { [weak self] in
            guard let self else { return }
            self.buryColdTab(tab, from: name)
        }
        if !busy.isEmpty, let host {
            host.confirmClose(
                messageText: "Close Tab?",
                informativeText: "\(busy.joined(separator: ", ")) still running. Closing the tab kills it (undo keeps it for \(Int(Self.killGrace))s).")
            { proceed() }
        } else {
            proceed()
        }
    }

    private func buryColdTab(_ tab: Tab, from name: String) {
        let ids = tabPaneIds(tab)
        sessions[name]?.tabs.removeAll { tabPaneIds($0) == ids }
        let cwd = tab.panes.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var buried = Session(
            name: newSessionId(),
            label: tab.label ?? tab.panes.first?.title ?? URL(fileURLWithPath: cwd).lastPathComponent,
            emoji: tab.emoji,
            cwd: cwd,
            state: .asleep)
        buried.tabs = [tab]
        bury(buried)
        vlog("close: cold tab \(ids) leaves '\(name)' -> buried as '\(buried.name)'")
        persist()
    }

    /// Right-click Close Pane: live panes ride the native close flow
    /// (dock tenants included: a collapsed dock's tenant has a live view
    /// and NO window, so the owner is resolved by RUNTIME, never by
    /// window); cold panes leave the registry for the graveyard. Confirms
    /// exactly when something runs.
    func closePaneFromSidebar(name: String, paneId: String?, in host: TerminalController?) {
        guard let paneId else { return }
        if let view = liveView(attachId: paneId) {
            for case let controller as TerminalController in dockMap.keyEnumerator() {
                if closeDockTenantIfHosted(view, in: controller, withConfirmation: true) { return }
            }
            if let controller = view.window?.windowController as? TerminalController {
                controller.closeSurface(view, withConfirmation: true)
                return
            }
            // A held runtime's tenant (detached/floating session): the
            // registry edit is the close, the runtime releases the view.
            if locate(paneId) != nil {
                let busy = busyPrograms(panes: [paneId])
                let proceed = { [weak self] in
                    guard let self else { return }
                    self.removeColdPane(name: name, paneId: paneId)
                }
                if !busy.isEmpty, let host {
                    host.confirmClose(
                        messageText: "Close Dock Pane?",
                        informativeText: "\(busy.joined(separator: ", ")) still running. Closing the pane kills it (undo keeps it for \(Int(Self.killGrace))s).")
                    { proceed() }
                } else {
                    proceed()
                }
                return
            }
            vlog("!! closePane(sidebar): live view '\(paneId)' held by no dock, no window, no registry - refused loud")
            return
        }
        guard sessions[name] != nil else { return }
        let busy = busyPrograms(panes: [paneId])
        let proceed = { [weak self] in
            guard let self else { return }
            self.removeColdPane(name: name, paneId: paneId)
        }
        if !busy.isEmpty, let host {
            host.confirmClose(
                messageText: "Close Pane?",
                informativeText: "\(busy.joined(separator: ", ")) still running. Closing the pane kills it (undo keeps it for \(Int(Self.killGrace))s).")
            { proceed() }
        } else {
            proceed()
        }
    }

    /// A pane that has no window leaves its registry for the graveyard
    /// (takePane releases any held view; the daemon runs until reap).
    private func removeColdPane(name: String, paneId: String) {
        guard let taken = takePane(paneId) else { return }
        buryPane(taken.pane, from: name)
        persist()
    }

    // MARK: Move (drag: registry re-parenting between sessions)
    //
    // Moving panes/tabs/sessions is a REGISTRY operation: a pane's entry
    // leaves one session's tabs and lands in another's. Daemons never
    // notice (the owner mirror is rewritten by chown); live views release
    // first (the daemon holds their exact state) and the target mounts
    // them lazily on click, or splits live when it is on screen.

    /// Take the mounted tab OUT of its window for a move. If the source
    /// still has a tab, the viewport mounts it. If the source is empty, the
    /// controller deliberately stays unclaimed with its moved tree intact;
    /// `settleVacatedController` atomically hands that viewport to the move
    /// target after the target owns the pane. Choosing an arbitrary
    /// session here used to leave a live tree sessionless when that session
    /// was already embedded and `mount` refused (2026-08-12).
    /// Returns the tab's registry entry (dock included).
    private func vacateMountedTab(_ controller: TerminalController, name: String) -> Tab? {
        let tree = controller.surfaceTree
        guard !tree.isEmpty else { return nil }
        let dock = dockMap.object(forKey: controller)
        dockMap.removeObject(forKey: controller)
        var mountedIds = Set<String>()
        for view in tree { if let id = view.vigilAttachId { mountedIds.insert(id) } }
        for view in dock?.views ?? [] { if let id = view.vigilAttachId { mountedIds.insert(id) } }
        let index = sessions[name]?.tabs.firstIndex { !Set(tabPaneIds($0)).isDisjoint(with: mountedIds) }
        let captured = index.map { sessions[name]!.tabs.remove(at: $0) }
        dock?.unmount()

        if members(of: name).count > 1 {
            // A native tab window: it just closes.
            memberships.removeObject(forKey: controller)
            killController(controller)
        } else if let next = sessions[name]?.tabs.first(where: { !$0.panes.isEmpty }) {
            mountCapturedTab(next, name: name, in: controller)
        } else {
            memberships.removeObject(forKey: controller)
        }
        return captured
    }

    /// Finish the empty-source half of a move. The moved tree is still in
    /// `controller`, and the target capture now claims every daemon in it.
    /// A mountable target adopts this exact viewport (no extra window, no
    /// second attach); a target already visible elsewhere keeps its home and
    /// this now-redundant viewport closes empty.
    private func settleVacatedController(
        _ controller: TerminalController,
        movedTo target: String
    ) {
        guard sessionName(of: controller) == nil,
              !controller.surfaceTree.isEmpty,
              let targetSession = sessions[target] else { return }

        switch targetSession.state {
        case .detached(let held):
            // The registry is the durable representation of these cold
            // tabs. Release the held runtimes before promoting the moved
            // live tree, otherwise the target would have two runtime owners.
            for runtime in held { runtime.dock?.unmount() }
            setOcclusion(false, held)
            registerMember(controller, name: target)
            sessions[target]!.state = .embedded
            setOcclusion(true, views: Array(controller.surfaceTree))
            focusLeftmost(controller)
            vlog("move viewport: unclaimed controller -> detached target '\(target)'")

        case .asleep:
            registerMember(controller, name: target)
            sessions[target]!.state = .embedded
            setOcclusion(true, views: Array(controller.surfaceTree))
            focusLeftmost(controller)
            vlog("move viewport: unclaimed controller -> asleep target '\(target)'")

        case .embedded, .floating:
            // The target already owns another live window. Its capture now
            // owns this pane, so releasing this duplicate viewport is safe.
            killController(controller)
            open(name: target)
            vlog("move viewport: target '\(target)' already live -> closed source viewport")
        }
    }

    /// A source emptied by moves clears: identity through the tray
    /// (120s, undoable), never a silent delete.
    private func clearIfEmpty(_ name: String) {
        guard var session = sessions[name] else { return }
        session.tabs.removeAll { $0.panes.isEmpty && ($0.dock?.panes.isEmpty ?? true) }
        sessions[name] = session
        let liveMembers = members(of: name).filter { !$0.surfaceTree.isEmpty }
        guard session.tabs.isEmpty, liveMembers.isEmpty else { return }
        vlog("clearIfEmpty: '\(name)' emptied by a move -> buried")
        for member in members(of: name) {
            memberships.removeObject(forKey: member)
            killController(member)
        }
        var buried = sessions[name]!
        buried.state = .asleep
        sessions[name] = nil
        recent.removeAll { $0 == name }
        bury(buried)
        onAttentionChange?()
    }

    /// Move a whole TAB (anchored by any of its pane ids) to another
    /// session, where it lands as a cold tab.
    func moveTab(anchor: String, from source: String, to target: String) {
        guard source != target, sessions[source] != nil, sessions[target] != nil else { return }
        var moved: Tab?
        if let view = liveView(attachId: anchor),
           let controller = view.window?.windowController as? TerminalController,
           sessionName(of: controller) == source {
            moved = vacateMountedTab(controller, name: source)
        } else if let index = sessions[source]!.tabs.firstIndex(where: { tabPaneIds($0).contains(anchor) }) {
            moved = sessions[source]!.tabs.remove(at: index)
        }
        guard let moved else { return }
        sessions[target]!.tabs.append(moved)
        for id in tabPaneIds(moved) { chown(id, to: target) }
        if let view = liveView(attachId: anchor),
           let controller = view.window?.windowController as? TerminalController {
            settleVacatedController(controller, movedTo: target)
        }
        vlog("moveTab: \(anchor): '\(source)' -> '\(target)'")
        clearIfEmpty(source)
        persist()
        assertInvariants("moveTab")
    }

    /// Move ONE pane to another session. A split pane becomes its own
    /// cold tab there; a dock tenant stays a dock tenant (of the target's
    /// first tab, live-appended when the target is mounted).
    func movePane(paneId: String, from source: String, to target: String, isDock: Bool) {
        guard source != target, sessions[source] != nil, sessions[target] != nil else { return }
        var vacatedController: TerminalController?
        var vacated: Tab?

        // A live view leaves its window first (its registry entry follows
        // below, through the one take primitive). Vigil's own tree edit
        // is a swap, never a close.
        if let view = liveView(attachId: paneId),
           let controller = view.window?.windowController as? TerminalController {
            if let runtime = dockMap.object(forKey: controller),
               let index = runtime.views.firstIndex(where: { $0 === view }) {
                let released = runtime.views.remove(at: index)
                released.removeFromSuperview()
                runtime.active = min(runtime.active, max(runtime.views.count - 1, 0))
                if runtime.views.isEmpty { dockMap.removeObject(forKey: controller) }
                VigilBars.shared.sync(controller)
            } else if let node = controller.surfaceTree.root?.node(view: view) {
                if controller.surfaceTree.root == node {
                    // Last pane of the mounted tab: this IS a tab move.
                    vacated = vacateMountedTab(controller, name: source)
                    vacatedController = controller
                } else {
                    swapTree(controller, controller.surfaceTree.removing(node))
                }
            }
        }
        // The registry entry: from the vacated tab (already lifted out of
        // the source), else taken from wherever it lives. An emptied tab's
        // NAME AND FACE travel with its only pane instead of dying with the
        // husk (a ♠️ typed onto a tab evaporated here, 2026-08-10).
        var pane: Pane?
        var inheritedLabel: String?
        var inheritedEmoji: String?
        if let vacated {
            pane = (vacated.panes + (vacated.dock?.panes ?? [])).first { $0.id == paneId }
            // The tab's cold siblings and its dock tenants stay registered
            // in the source, as a cold tab that keeps the tab's identity;
            // only a tab emptied by this move hands its name to the pane.
            let rest = vacated.panes.filter { $0.id != paneId }
            let restDock = vacated.dock.flatMap { d -> DockCapture? in
                let keep = d.panes.filter { $0.id != paneId }
                return keep.isEmpty ? nil
                    : DockCapture(panes: keep, active: min(d.active, keep.count - 1), width: d.width, collapsed: d.collapsed)
            }
            if rest.isEmpty, restDock == nil {
                inheritedLabel = vacated.label
                inheritedEmoji = vacated.emoji
            } else {
                sessions[source]!.tabs.append(Tab(
                    panes: rest, layout: nil, dock: restDock, label: vacated.label, emoji: vacated.emoji))
            }
        } else if let taken = takePane(paneId) {
            pane = taken.pane
            inheritedLabel = taken.tabLabel
            inheritedEmoji = taken.tabEmoji
        }
        guard let pane else { return }
        chown(paneId, to: target)

        if isDock {
            // Stays a dock tenant. Mounted target: live append (native
            // reattach); otherwise into the first tab's dock capture.
            if let host = members(of: target).first(where: { !$0.surfaceTree.isEmpty }),
               let app = ghosttyApp?.app {
                let view = Ghostty.SurfaceView(app, baseConfig: resurrectConfig(name: target, pane: pane))
                let runtime = dockMap.object(forKey: host) ?? {
                    let r = VigilDockRuntime(views: [], active: 0, width: 340, collapsed: false)
                    dockMap.setObject(r, forKey: host)
                    return r
                }()
                runtime.views.append(view)
                runtime.active = runtime.views.count - 1
                VigilBars.shared.sync(host)
                // The registry entry lands in the HOST tab's dock.
                let hostIds = Set(host.surfaceTree.compactMap(\.vigilAttachId))
                let index = sessions[target]!.tabs.firstIndex { !Set(tabPaneIds($0)).isDisjoint(with: hostIds) }
                    ?? {
                        vlog("!! movePane: host tab \(hostIds.sorted()) of '\(target)' not in its registry - tenant appended as a new tab")
                        sessions[target]!.tabs.append(Tab(panes: [], layout: nil))
                        return sessions[target]!.tabs.count - 1
                    }()
                var dock = sessions[target]!.tabs[index].dock
                    ?? DockCapture(panes: [], active: 0, width: Double(runtime.width), collapsed: false)
                dock.panes.append(pane)
                dock.active = dock.panes.count - 1
                sessions[target]!.tabs[index].dock = dock
            } else {
                if sessions[target]!.tabs.isEmpty {
                    sessions[target]!.tabs = [Tab(panes: [], layout: nil)]
                }
                var dock = sessions[target]!.tabs[0].dock
                    ?? DockCapture(panes: [], active: 0, width: 340, collapsed: false)
                dock.panes.append(pane)
                sessions[target]!.tabs[0].dock = dock
            }
        } else {
            sessions[target]!.tabs.append(Tab(
                panes: [pane], layout: nil,
                label: inheritedLabel, emoji: inheritedEmoji))
        }
        if let vacatedController {
            settleVacatedController(vacatedController, movedTo: target)
        }
        vlog("movePane: \(paneId): '\(source)' -> '\(target)' dock=\(isDock)")
        clearIfEmpty(source)
        persist()
        assertInvariants("movePane")
    }

    /// Move a pane INTO a specific tab of a session (drop on a tab row):
    /// a mounted target splits live (native reattach); a cold one grows
    /// its capture.
    func movePane(paneId: String, from source: String, intoTabAnchoredBy anchor: String, of target: String) {
        guard sessions[target] != nil else { return }
        // Lift the pane out exactly as a session-level move does...
        movePane(paneId: paneId, from: source, to: target, isDock: false)
        // ...then fold the fresh single-pane tab into the anchored tab.
        guard var session = sessions[target] else { return }
        guard let freshIndex = session.tabs.lastIndex(where: {
            $0.panes.count == 1 && $0.panes[0].id == paneId
        }) else { return }
        let fresh = session.tabs.remove(at: freshIndex)
        if liveView(attachId: paneId)?.window != nil {
            // The moved pane became the target's live viewport (its source
            // window was handed over): folding a live pane into a cold tab
            // would list it where it cannot materialize. It stays a tab.
            session.tabs.append(fresh)
            sessions[target] = session
            persist()
            return
        }
        if let view = liveView(attachId: anchor), view.window != nil,
           let controller = view.window?.windowController as? TerminalController,
           controller.surfaceTree.contains(view),
           let app = ghosttyApp?.app,
           let tabIndex = session.tabs.firstIndex(where: { tabPaneIds($0).contains(anchor) }) {
            // Live split, right of the anchor. The registry lists the
            // pane in the anchored tab FIRST, so the chokepoint sees a
            // listed pane materialize, never a foreign one to claim.
            session.tabs[tabIndex].panes.append(contentsOf: fresh.panes)
            sessions[target] = session
            let newView = Ghostty.SurfaceView(app, baseConfig: resurrectConfig(name: target, pane: fresh.panes[0]))
            if let tree = try? controller.surfaceTree.inserting(view: newView, at: view, direction: .right) {
                controller.surfaceTree = tree
            }
        } else if let tabIndex = session.tabs.firstIndex(where: { tabPaneIds($0).contains(anchor) }) {
            session.tabs[tabIndex].panes.append(contentsOf: fresh.panes)
            session.tabs[tabIndex].layout = nil
            sessions[target] = session
        } else {
            session.tabs.append(fresh) // anchor gone: stay a new tab
            sessions[target] = session
        }
        persist()
    }

    /// Merge: every tab of `source` becomes a cold tab of `target`; the
    /// source's windows move on (viewport rule) and its emptied identity
    /// clears through the tray.
    func mergeSession(_ source: String, into target: String) {
        guard source != target, sessions[source] != nil, sessions[target] != nil else { return }
        let ms = members(of: source)
        let moving = sessions[source]!.tabs
        sessions[target]!.tabs.append(contentsOf: moving)
        sessions[source]!.tabs = []
        for tab in moving {
            for id in tabPaneIds(tab) { chown(id, to: target) }
        }
        for member in ms {
            dockMap.object(forKey: member)?.unmount()
            dockMap.removeObject(forKey: member)
            memberships.removeObject(forKey: member)
        }
        if case .detached(let held) = sessions[source]!.state {
            for runtime in held { runtime.dock?.unmount() }
        }
        if sessions[target]!.attention.rawValue < sessions[source]!.attention.rawValue {
            sessions[target]!.attention = sessions[source]!.attention
            sessions[target]!.attentionSince = sessions[source]!.attentionSince
        }
        var buried = sessions[source]!
        buried.state = .asleep
        sessions[source] = nil
        recent.removeAll { $0 == source }
        bury(buried)
        vlog("merge: '\(source)' -> '\(target)' (\(sessions[target]!.tabs.count) tabs)")
        // The source's windows shapeshift to the merged target (first one)
        // or close (the rest).
        var first = true
        for member in ms {
            if first, let ghostty = ghosttyApp, members(of: target).isEmpty {
                first = false
                mount(target, into: member, ghostty: ghostty)
            } else {
                killController(member)
            }
        }
        persist()
        onAttentionChange?()
        assertInvariants("merge")
    }

    /// Is any pane's blocked state FRESH (a real unanswered ask)? A long
    /// tool approved through a hook confirmation leaves blocked STALE (no
    /// hook fires between the approval and the tool's end), so blocked is
    /// only trusted briefly.
    /// A session with any raw-blocked pane, at any age: still asking (or
    /// mid-approved-tool). Used for the auto-follow veto (never yank
    /// while the current session may be mid-answer) and ⌘⇧J's rotation
    /// (every ask stays reachable, seen or not).
    func asking(_ name: String) -> Bool {
        guard let session = sessions[name] else { return false }
        return ownedPaneIds(session).contains { pane in
            paneAgentState(pane)?.state == .blocked
        }
    }

    /// Asking AND not yet seen: the ask fired after its PANE was last on
    /// screen. Auto-follow's herdr seen-flip - visiting the asking console
    /// releases it; only a NEW ask (fresh state mtime) re-targets.
    func blockedUnseen(_ name: String) -> Bool {
        guard let session = sessions[name] else { return false }
        return ownedPaneIds(session).contains { pane in
            guard let s = paneAgentState(pane) else { return false }
            return s.state == .blocked && (lastAck[pane] ?? .distantPast) < s.since
        }
    }

    /// The attention QUEUE's eligibility, ONE rule (Adrian 2026-08-06):
    /// something happened here that has NOT BEEN SEEN - a pane finished
    /// (done) or asked (blocked) after its console was last on screen.
    /// Seen sessions are never queue material, however blocked they look
    /// (a drafted-but-unsent reply reads as blocked forever).
    func unseenNeedy(_ name: String) -> Bool {
        guard let session = sessions[name] else { return false }
        return ownedPaneIds(session).contains { pane in
            guard let s = paneAgentState(pane),
                  s.state == .blocked || s.state == .done else { return false }
            return (lastAck[pane] ?? .distantPast) < s.since
        }
    }

    /// WHERE the ask lives: the most recently blocked pane in the session
    /// (state-file truth; session attention only knows WHO asked). Nil
    /// when nothing is blocked (a done, or the ask was answered since).
    func askingPane(_ name: String) -> String? {
        guard let session = sessions[name] else { return nil }
        return ownedPaneIds(session)
            .compactMap { pane -> (pane: String, since: Date)? in
                guard let s = paneAgentState(pane), s.state == .blocked else { return nil }
                return (pane, s.since)
            }
            .max { $0.since < $1.since }?
            .pane
    }

    /// Attention-driven landing, ONE primitive for every path that grabs
    /// focus because a session asked (auto-follow, ⌘⇧J, the sidebar's ;):
    /// land on the ASKING PANE (its tab mounts, it takes focus), not the
    /// session. A session-level landing mounted the anchored/first tab:
    /// with the ask in tab 4 you arrived at tab 1's console (Adrian
    /// 2026-08-04, "often leads me to the wrong console").
    func follow(_ name: String, in controller: TerminalController?) {
        if let pane = askingPane(name) {
            vlog("follow: '\(name)' -> asking pane \(pane)")
            activatePane(name: name, paneId: pane, in: controller)
        } else if let controller {
            shapeshift(in: controller, to: name)
        } else {
            open(name: name)
        }
    }

    /// The manual-follow affordance: what ⌘⇧J would do RIGHT NOW.
    struct AskHint: Equatable {
        let name: String
        let label: String
        let emoji: String?
        /// The asking pane follow() would land on (nil for a done-head:
        /// session-level landing). The sidebar co-locates the keycap on
        /// this pane's row.
        let pane: String?
        /// Sessions still waiting beyond the head (the queue's depth).
        let more: Int
    }

    /// Mirrors next() exactly (attention FIFO head, else the rotation's
    /// next asking session relative to the key window) WITHOUT executing:
    /// the sidebar renders it as the ⌘⇧J affordance when auto-follow is
    /// off, and visiting the head re-derives the next - the hint IS the
    /// queue, one head at a time (Adrian 2026-08-04).
    func nextAskHint() -> AskHint? {
        // Mirrors next() exactly: the queue is UNSEEN work only (done or
        // blocked after its console was last on screen), never the
        // session you are in. An affordance pointing at the room you are
        // standing in - or at anything already seen - is noise (Adrian
        // 2026-08-06).
        let current = (NSApp.keyWindow?.windowController as? TerminalController)
            .flatMap { sessionName(of: $0) }
        let queue = sessions.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .filter { $0.name != current && unseenNeedy($0.name) }
            .map(\.name)
        let head: String?
        if let urgent = mostUrgentName, urgent != current, unseenNeedy(urgent) {
            head = urgent
        } else {
            head = queue.first
        }
        guard let head, let session = sessions[head] else { return nil }
        var pending = Set(queue)
        pending.insert(head)
        return AskHint(
            name: head, label: session.label, emoji: session.emoji,
            pane: askingPane(head), more: pending.count - 1)
    }

    /// Auto-follow's target: the attention FIFO's input head, else the
    /// first session (overview order) asking AND unseen. Seen asks never
    /// re-yank (Adrian 2026-08-04: "if I already clicked away allow me
    /// to"); they stay reachable through ⌘⇧J.
    var followTarget: String? {
        if let name = sessions.values
            .filter({ $0.attention == .input })
            .sorted(by: { ($0.attentionSince ?? .distantPast) < ($1.attentionSince ?? .distantPast) })
            .first?.name {
            return name
        }
        return sessions.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .first { blockedUnseen($0.name) }?
            .name
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
            // ONE swap, straight to the anchored tab: mounting tab 0 and
            // then swapping again was a visible double-blink.
            shapeshift(in: controller, to: name, anchor: anchor)
        }
        // Liveness is HAVING A WINDOW, never mere view existence: an
        // undo corpse or a released tree can hold a windowless
        // SurfaceView for this pane, and treating it as live made both
        // branches skip - the click (and follow) died in silence
        // (2026-08-05, the unclickable keycap row).
        if let anchor, sessionName(of: controller) == name,
           liveView(attachId: anchor)?.window == nil {
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
        let strays = strayControllers().compactMap(\.window)
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
    private var strayLabels: [ObjectIdentifier: String] = [:]

    func strayLabel(_ controller: TerminalController) -> String? {
        strayLabels[ObjectIdentifier(controller)]
    }

    func renameStray(_ controller: TerminalController, _ label: String) {
        strayLabels[ObjectIdentifier(controller)] = label
    }

    // MARK: Kill + graveyard (the ONE death path: bury, then reap)

    /// Kill with a grace period: the session leaves its windows (every
    /// process keeps running), rests in the graveyard, and only when the
    /// grace expires do its daemons actually die. Undo within the grace
    /// exhumes everything intact. The caller already confirmed; no prompts
    /// here. `keepViewport`: the window the session showed in stays and
    /// the last active session takes it (the tab-close semantic: killing
    /// what you are looking at never closes the window while a session
    /// remains); false = the window closes. `viewport` names that window
    /// when the caller has it.
    func kill(name: String, keepViewport: Bool = true, viewport: TerminalController? = nil) {
        guard let s = sessions[name] else { vlog("kill: '\(name)' NOT in sessions (noop)"); return }
        vlog("kill: '\(name)' state=\(stateTag(s.state)) -> graveyard")
        if case .floating = sessions[name]!.state, let quick = quickController(create: false) {
            quick.animateOut()
            reclaim(name, from: quick)
        }
        var kept: TerminalController?
        if case .embedded = sessions[name]!.state {
            kept = keepViewport
                ? (viewport ?? (focusWindow(of: name)?.windowController as? TerminalController))
                : nil
            let held = vacate(name, keeping: kept)
            sessions[name]!.state = held.isEmpty ? .asleep : .detached(held)
        }
        var session = sessions[name]!
        sessions[name] = nil
        recent.removeAll { $0 == name }
        session.attention = .none
        bury(session)
        if let kept {
            if let next = successor(excluding: name), let ghostty = ghosttyApp {
                vlog("kill: viewport of '\(name)' -> '\(next)'")
                mount(next, into: kept, ghostty: ghostty)
                touchRecent(next)
            } else {
                killController(kept) // nothing left to view: the window closes
            }
        }
        persist()
        onAttentionChange?()
    }

    /// Rest a session in the graveyard: 120s grace, undoable, reaped on
    /// expiry. One burial mechanism for every kind of death (session kill,
    /// tab close, split close, dock tenant close, a source emptied by
    /// moves). Burials are written to vigil.json with their deadline, so
    /// a relaunch honors the remaining grace.
    private func bury(_ session: Session) {
        let name = session.name
        // A corpse never renders: its daemons stay alive for the grace,
        // its renderers must not.
        if case .detached(let held) = session.state { setOcclusion(false, held) }
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

    /// A burial drops without dying (its last pane was re-claimed by an
    /// undo or a move).
    private func dropBurial(_ name: String) {
        graveyard[name] = nil
        graveyardDeadlines[name] = nil
        try? FileManager.default.removeItem(at: dumpsDir(name))
    }

    /// A killed session resting in its grace period, for the overview:
    /// lingers dimmed with a countdown and a recover act.
    struct Burial {
        let name: String
        let label: String
        let emoji: String?
        let deadline: Date
        let thumbnail: NSImage?
    }

    /// The sidebar's burial tray rows: lightweight, equatable, countdown
    /// baked in so the tray re-renders as the grace runs out.
    struct SidebarBurial: Identifiable, Equatable {
        let id: String
        let emoji: String?
        let label: String
        let remaining: Int
    }

    func sidebarBurials() -> [SidebarBurial] {
        burials().map {
            SidebarBurial(
                id: $0.name,
                emoji: $0.emoji,
                label: $0.label,
                remaining: max(0, Int($0.deadline.timeIntervalSinceNow)))
        }
    }

    func burials() -> [Burial] {
        graveyard.values.compactMap { session in
            guard let deadline = graveyardDeadlines[session.name] else { return nil }
            return Burial(
                name: session.name,
                label: session.label,
                emoji: session.emoji,
                deadline: deadline,
                thumbnail: session.thumbnail)
        }
        .sorted { $0.deadline < $1.deadline }
    }

    /// Kill the session you are IN right now, floating or in a normal
    /// window, with no trip to the overview. The floating quick terminal
    /// takes priority when it is the key window (that is what you are
    /// looking at); otherwise the front terminal's session, whose window
    /// stays as the viewport of the last active session. Confirmed when
    /// something runs (a keystroke that kills processes must ask), then
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
            confirmKill(name: name) { self.kill(name: name, viewport: controller) }
        } else {
            let busy = busyPrograms(in: controller)
            guard !busy.isEmpty else { killStray(controller); return }
            let title = controller.focusedSurface?.title.trimmingCharacters(in: .whitespaces)
            confirmKill(
                label: (title?.isEmpty == false ? title! : "this window"),
                info: "\(busy.joined(separator: ", ")) still running. The window closes and it dies."
            ) { self.killStray(controller) }
        }
    }

    /// Confirmation before a kill fired from a keystroke or the sidebar
    /// (not the overview, which has its own). A kill with NOTHING running
    /// asks nothing: there is no work to lose, and asking anyway is the
    /// friction vanilla ghostty never imposes. Otherwise a critical alert
    /// naming what dies, Kill/Cancel, run only on confirm. Shown from
    /// service mode too, hence the activate.
    private func confirmKill(name: String, _ doKill: @escaping () -> Void) {
        let busy = busyPrograms(of: name)
        guard !busy.isEmpty else { doKill(); return }
        let session = sessions[name]
        confirmKill(
            label: [session?.emoji, session?.label ?? name].compactMap { $0 }.joined(separator: " "),
            info: "\(busy.joined(separator: ", ")) still running. Undo within \(Int(Self.killGrace))s.",
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
    /// included), everything still running.
    func exhume(_ name: String) {
        guard let session = graveyard.removeValue(forKey: name) else { return }
        graveyardDeadlines[name] = nil
        sessions[name] = session
        persist()
        open(name: name)
    }

    /// A window that slipped past registration (safety net) gets the same
    /// courtesy as a session on kill: buried with the grace, exhumable.
    func killStray(_ controller: TerminalController) {
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
            state: .detached([TabRuntime(tree: tree, dock: nil)]))
        let (panes, layout) = capture(tree, carrying: [])
        session.tabs = [Tab(panes: panes, layout: layout)]
        bury(session)
    }

    /// Reap NOW, before the grace expires: the daemons die immediately and
    /// the burial is dropped. For "get this out of my face" from the tray
    /// instead of waiting out the 120s.
    func reapNow(_ name: String) {
        graveyardDeadlines[name] = Date.distantPast
        reapIfExpired(name)
    }

    /// The grace ran out: now the death actually happens. The burial's
    /// registry names every daemon; its held runtimes release (views free
    /// synchronously, a leaked view elsewhere changes nothing); then the
    /// daemons are killed AND VERIFIED dead. No deferral, no sweep, no
    /// dependence on what ARC happens to hold.
    private func reapIfExpired(_ name: String) {
        guard let deadline = graveyardDeadlines[name], Date() >= deadline,
              let session = graveyard[name] else { return }
        let ids = ownedPaneIds(session)
        if case .detached(let held) = session.state {
            for runtime in held { runtime.dock?.unmount() }
        }
        dropBurial(name)
        vlog("reap: '\(name)' -> kill \(ids.sorted())")
        killDaemons(ids)
        persist()
    }

    /// Kill pane daemons, deterministically: one `vigild kill` with every
    /// id, which unlinks their survival state, signals, and WAITS until
    /// each is gone (escalating to SIGKILL). Off the main thread (a stuck
    /// daemon must not freeze the app); the verification screams into the
    /// log and the state files of the dead are pruned when it returns.
    private func killDaemons(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let bin = vigildBin
        let sorted = ids.sorted()
        let stateDir = vigildStateDir
        let agentDir = agentStateDir
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["kill"] + sorted
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let survivors = sorted.filter {
                FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("\($0).pid").path)
            }
            for id in sorted where !survivors.contains(id) {
                try? FileManager.default.removeItem(at: agentDir.appendingPathComponent("\(id).state"))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let manager = VigilSessionManager.shared
                    if survivors.isEmpty {
                        manager.vlog("kill: \(sorted) dead (verified)")
                    } else {
                        manager.vlog("!! kill: \(survivors) STILL ALIVE after vigild kill (status \(p.terminationStatus))")
                    }
                    for id in sorted { manager.lastAck[id] = nil }
                }
            }
        }
    }

    /// Orphan collection, at launch: a daemon no session and no burial
    /// lists is owned by nobody and dies. Never mid-life: a pane between
    /// its birth and its registration must not meet a collector. The
    /// registry is the ONLY input - never a live view (ARC liveness is not
    /// ownership), never a spec's owner line (a mirror is not a source).
    /// State files and resume pointers of panes with no daemon and no
    /// owner are pruned with it (a stale resume pointer is typed into
    /// whoever inherits the index; 44 were lying in wait once).
    private func collectOrphans() {
        // Two-instance safety: another instance of THIS bundle shares the
        // vigild state dir and its registry; killing under it would race
        // its own bookkeeping. Caveat until the fork owns its bundle id
        // everywhere: a fork installed under a DIFFERENT id is invisible.
        let me = ProcessInfo.processInfo.processIdentifier
        let rivals = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.processIdentifier != me
        }
        guard rivals.isEmpty else {
            vlog("collect: skipped, another instance of this bundle is running")
            return
        }

        var owned = Set<String>()
        for session in sessions.values { owned.formUnion(ownedPaneIds(session)) }
        for session in graveyard.values { owned.formUnion(ownedPaneIds(session)) }

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: vigildStateDir.path)) ?? []
        var orphans = Set<String>()
        for entry in entries where entry.hasSuffix(".pid") && entry.hasPrefix("vigil-") {
            let id = String(entry.dropLast(".pid".count))
            if !owned.contains(id) { orphans.insert(id) }
        }
        if !orphans.isEmpty {
            vlog("collect: orphan daemons \(orphans.sorted()) -> kill")
            killDaemons(orphans)
        }
        for entry in entries where entry.hasSuffix(".resume") && entry.hasPrefix("vigil-") {
            let id = String(entry.dropLast(".resume".count))
            guard !owned.contains(id),
                  !fm.fileExists(atPath: vigildStateDir.appendingPathComponent("\(id).pid").path)
            else { continue }
            try? fm.removeItem(at: vigildStateDir.appendingPathComponent(entry))
            vlog("collect: stale resume pointer '\(id)' removed")
        }
        for entry in (try? fm.contentsOfDirectory(atPath: agentStateDir.path)) ?? []
        where entry.hasSuffix(".state") {
            let id = String(entry.dropLast(".state".count))
            guard !owned.contains(id),
                  !fm.fileExists(atPath: vigildStateDir.appendingPathComponent("\(id).pid").path)
            else { continue }
            try? fm.removeItem(at: agentStateDir.appendingPathComponent(entry))
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
    /// daemon, VIGIL_SESSION stamped) rooted in the tab's cwd, registered
    /// in the tab's dock the moment it is born.
    @discardableResult
    func addDockTenant(_ controller: TerminalController) -> Ghostty.SurfaceView? {
        guard let name = sessionName(of: controller),
              let app = controller.ghostty.app else { return nil }
        let cwd = controller.focusedSurface?.pwd
            ?? sessions[name]?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let id = "vigil-\(name)-\(nextPaneIndex(name: name))"
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = id
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let runtime = dockMap.object(forKey: controller) ?? {
            let r = VigilDockRuntime(views: [], active: 0, width: 340, collapsed: false)
            dockMap.setObject(r, forKey: controller)
            return r
        }()
        runtime.views.append(view)
        runtime.active = runtime.views.count - 1
        runtime.collapsed = false
        let tabIds = Set(controller.surfaceTree.compactMap(\.vigilAttachId))
        if let index = sessions[name]!.tabs.firstIndex(where: { !Set(tabPaneIds($0)).isDisjoint(with: tabIds) }) {
            var dock = sessions[name]!.tabs[index].dock
                ?? DockCapture(panes: [], active: 0, width: Double(runtime.width), collapsed: false)
            dock.panes.append(Pane(id: id, cwd: cwd))
            dock.active = dock.panes.count - 1
            dock.collapsed = false
            sessions[name]!.tabs[index].dock = dock
        } else {
            vlog("!! dock: '\(name)' tab \(tabIds) not in its registry; tenant '\(id)' unregistered")
        }
        VigilBars.shared.sync(controller)
        persist()
        return view
    }

    /// Close one tenant: the view leaves the dock, the pane leaves the
    /// registry for the graveyard (undo keeps it 120s, reap kills it).
    func closeDockTenant(_ controller: TerminalController, index: Int) {
        guard let runtime = dockMap.object(forKey: controller),
              runtime.views.indices.contains(index),
              let name = sessionName(of: controller) else { return }
        let view = runtime.views.remove(at: index)
        view.removeFromSuperview()
        runtime.active = min(runtime.active, max(runtime.views.count - 1, 0))
        if runtime.views.isEmpty { dockMap.removeObject(forKey: controller) }
        VigilBars.shared.sync(controller)
        if let id = view.vigilAttachId, let taken = takePane(id) {
            buryPane(taken.pane, from: name)
        }
        persist()
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
        // "ssh: /path/ctl [mux]" and friends: daemons that rewrite argv0
        // with a colon are background machinery, never the pane's program.
        if base.hasSuffix(":") { return nil }
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

    /// The label of the pane's deep foreground process (pidfile line 3,
    /// the tty's e_tpgid); nil = the shell itself holds the tty (a pane
    /// at its prompt).
    /// What a close would actually destroy, and the ONLY test any close
    /// confirm may use. Ghostty's `needsConfirmQuit` is meaningless here:
    /// every surface is daemon-backed, so its child shell always reads as a
    /// running process and EVERY close asked, including a bare shell no
    /// vanilla ghostty would ever ask about (Adrian 2026-08-08, correctly
    /// smelling two philosophies in one app). Vigil owns process truth (the
    /// daemon's pidfile line 3 = the deep foreground pid): a pane is busy
    /// only while a real program holds the tty, never a shell at its prompt.
    func busyPrograms(panes: [String]) -> [String] {
        panes.compactMap { paneForegroundLabel($0) }
    }

    /// The busy programs of everything a session owns.
    func busyPrograms(of name: String) -> [String] {
        guard let session = sessions[name] else { return [] }
        return busyPrograms(panes: Array(ownedPaneIds(session)))
    }

    /// The busy programs of one window's tree (its dock rides `ownedPaneIds`).
    private func busyPrograms(in controller: TerminalController) -> [String] {
        busyPrograms(panes: controller.surfaceTree.compactMap(\.vigilAttachId))
    }

    private func paneForegroundLabel(_ pane: String) -> String? {
        let pidLines = paneFileLines(pane, "pid")
        guard pidLines.count >= 3,
              let fg = Int(pidLines[2].trimmingCharacters(in: .whitespaces)) else { return nil }
        for line in paneFileLines(pane, "tree").dropFirst() {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, Int(parts[0]) == fg else { continue }
            return Self.processLabel(String(parts[1]))
        }
        return nil
    }

    /// One pane's "program": what the user actually SEES. The deep
    /// foreground process wins; only when it has no label (a shell at its
    /// prompt) does the deepest interesting descendant speak, so a
    /// background ssh mux or stray daemon in the tree never masquerades
    /// as the pane's program.
    func paneProgram(_ pane: String) -> String? {
        let lines = paneFileLines(pane, "tree")
        guard !lines.isEmpty else { return nil }
        if let fg = paneForegroundLabel(pane) { return fg }
        var out: String?
        for argv in paneCommands(pane, "tree") {
            if let label = Self.processLabel(argv) { out = label }
        }
        return out
    }

    /// Background SENTRIES under a pane: labeled tree processes that are
    /// neither the shell nor the pane's program - "something is keeping
    /// watch under this quiet pane" (a tg watch under an idle claude, a
    /// build, a server). Truth from the daemon's kqueue tree file, never
    /// inferred from the screen. QUIET is the gate, per pane class: an
    /// adapter-managed pane (agent state file exists) is quiet when the
    /// agent isn't working - the view applies that; a PLAIN pane is quiet
    /// only when the shell itself holds the tty. A foreground TUI's own
    /// subprocess churn (lazygit's git calls) is the program working, not
    /// a sentry - antenna semantics, not process accounting (Adrian
    /// 2026-08-07). Declared leases are never gated: the watcher said why
    /// it watches.
    func paneWatchers(_ pane: String) -> [String] {
        if paneAgentState(pane) == nil, paneForegroundLabel(pane) != nil { return [] }
        let program = paneProgram(pane)
        var out: [String] = []
        for argv in paneCommands(pane, "tree") {
            guard let label = Self.processLabel(argv), label != program else { continue }
            let short = argv.count > 90 ? String(argv.prefix(87)) + "…" : argv
            if !out.contains(short) { out.append(short) }
        }
        return out
    }

    // MARK: Watch leases (the declared layer over process-tree truth)

    /// A watcher's self-declaration (sd_notify's shape on vigil's rails):
    /// one JSON file in leases/, written by the watching process itself,
    /// removed on exit. The lease says WHY (note) and UNTIL WHEN
    /// (deadline); liveness is NEVER trusted from the file - the pid must
    /// be alive. Spec: PROTOCOL.md.
    struct WatchLease: Equatable {
        let pane: String
        let note: String
        let deadline: Date?
    }

    private struct LeaseFile: Decodable {
        let pane: String
        let pid: Int32
        let note: String
        let deadline: Double?
    }

    private var leasesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/leases")
    }

    /// All live leases, grouped by pane. A lease whose pid is dead is
    /// garbage (its process broke the remove-on-exit contract or was
    /// SIGKILLed) and is swept here, the read path.
    func watchLeases() -> [String: [WatchLease]] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: leasesDir, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: [WatchLease]] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let lease = try? JSONDecoder().decode(LeaseFile.self, from: data) else { continue }
            guard Darwin.kill(lease.pid, 0) == 0 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            out[lease.pane, default: []].append(WatchLease(
                pane: lease.pane,
                note: lease.note,
                deadline: lease.deadline.map { Date(timeIntervalSince1970: $0) }))
        }
        return out
    }

    private var agentStateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/state")
    }

    /// Event-driven state, not polled: any hook write into the state dir
    /// repaints the projections within the refresh throttle, instead of
    /// waiting for the sidebar's 2s ticker. (Whatever latency remains on a
    /// permission prompt latency is whatever its adapter/source reports.)
    private var stateDirWatcher: DispatchSourceFileSystemObject?

    private func startStateDirWatcher() {
        try? FileManager.default.createDirectory(at: agentStateDir, withIntermediateDirectories: true)
        let fd = Darwin.open(agentStateDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        stateDirWatcher = source
    }

    /// The pane's continuous program state as its adapter last wrote it.
    /// First token only; trailing tokens tolerated (older files carried
    /// a "blocked input" flavor).
    func paneAgentState(_ pane: String) -> (state: AgentState, since: Date)? {
        let url = agentStateDir.appendingPathComponent("\(pane).state")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let state: AgentState
        switch parts.first.map(String.init) ?? "" {
        case "working": state = .working
        case "blocked": state = .blocked
        case "done": state = .done
        case "idle": state = .idle
        default: return nil
        }
        let since = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return (state, since ?? .distantPast)
    }

    /// Display state, ONE rule: `done` and `blocked` decay to idle once
    /// the PANE was SEEN after they fired (its console visible in the key
    /// window - an ask arriving under your eyes clears the moment it
    /// lands); unseen they hold at ANY age. No time-based decay anywhere:
    /// you cannot APPROVE a prompt without seeing it, so seen-decay
    /// already covers the approved long-tool case the old 120s "display
    /// as working" clock existed for - and that clock made a genuinely
    /// stuck prompt invisible. Unseen orange now always tells the truth,
    /// per console: focusing one tab no longer decays its siblings.
    func paneDisplayState(_ pane: String) -> AgentState? {
        guard let s = paneAgentState(pane) else { return nil }
        if s.state == .done || s.state == .blocked,
           let ack = lastAck[pane], ack >= s.since { return .idle }
        // Claude Esc-interrupt fires NO hook (nothing rewrites the state file),
        // so `working` would spin forever. The program's own title is the
        // corrective: claude wears `✳ ` the moment it idles (braille
        // spinner while working). Positive idle marker only - absence of
        // a spinner proves nothing (title races the hook by a beat), and
        // blocked/done stay untouched (an ask must hold orange unseen).
        if s.state == .working,
           let first = liveView(attachId: pane)?.title.unicodeScalars.first,
           first == "✳" { return .idle }
        return s.state
    }

    /// The tree rollup: max state over every pane the session owns.
    func sessionAgentState(_ name: String) -> AgentState? {
        guard let session = sessions[name] else { return nil }
        return ownedPaneIds(session).compactMap { paneDisplayState($0) }.max()
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
    /// disk for this session's panes. Agent panes consume their own via
    /// their SessionStart hook, so what remains is exactly what needs a
    /// human decision.
    func diedProcesses(of name: String) -> [DiedProcess] {
        guard let session = sessions[name] else { return [] }
        var out: [DiedProcess] = []
        for pane in ownedPaneIds(session).sorted() {
            for argv in paneCommands(pane, "died") {
                guard let label = Self.processLabel(argv),
                      !["claude", "codex"].contains(label) else { continue }
                guard !["claude", "codex"].contains(where: {
                    argv.hasPrefix($0) || argv.contains("/\($0)")
                }) else { continue }
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
    /// THE programmatic window exit. Every path that makes a viewport
    /// disappear without the user closing it (regroup siblings, detach,
    /// vacate, kill) goes through here, because an emptied tree alone is
    /// not a close: ghostty's `surfaceTreeDidChange` runs `window.close()`,
    /// but a tab-window that was appended SILENTLY (vigilNewTab, never
    /// shown) does not reliably reach `windowWillClose`, so the
    /// contentView<->window cycle ghostty breaks there stays intact and
    /// the whole NSWindow (titlebar accessories, tab bar, SwiftUI hosting
    /// views, 40 CALayers) lives forever in NSApp.windows. 547 shapeshifts
    /// left 1108 dead terminal windows resident, 1.9 GB and a quarter of a
    /// core idle, WindowServer compositing corpses (2026-08-18). Undo is
    /// disabled around the exit: this is structure moving, nothing a ⌘⇧T
    /// should bring back (burials own their own undo).
    func killController(_ controller: TerminalController) {
        guard let window = controller.window else {
            swapTree(controller, SplitTree())
            return
        }
        let exit = {
            self.swapTree(controller, SplitTree())
            if window.isVisible || window.tabGroup != nil { window.close() }
            window.contentView = nil
        }
        if let undoManager = controller.undoManager {
            undoManager.disableUndoRegistration { exit() }
        } else {
            exit()
        }
    }

    /// Every terminal window NOT registered to a session: should not exist
    /// (every window is session-backed from birth), kept as a safety net so
    /// the overview shows all of ghostty regardless. On-screen windows only:
    /// ghostty retains closed windows for undo-close, and those corpses must
    /// not haunt the overview.
    func strayControllers() -> [TerminalController] {
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
        let title: String         // display: custom label, else program, else surface title
        let program: String?      // the argv truth alone; nil = just a shell
        let state: AgentState?
        let isDock: Bool
        var emoji: String?        // the pane's custom face
        /// Declared watch leases (notes) on this pane - the sentry's own
        /// words ("vigía de Carlos: awaiting his TG reply").
        var watchNotes: [String] = []
        /// Underived truth: background processes alive under the pane
        /// beyond its program (tree file argv, shortened).
        var watchProcs: [String] = []
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
        /// The tab's custom face.
        var emoji: String?
        /// You gave this tab a name or a face: it carries information of
        /// its own, so the tree never elides its row.
        var named: Bool = false
    }

    struct SidebarSessionRow: Identifiable, Equatable {
        let id: String            // the session name (the identity)
        let emoji: String?
        let label: String
        let stateTag: String      // live / floating / detached / asleep
        let attention: Attention
        /// Distinct descendant states, priority-ordered (blocked first),
        /// idle only when it is the only one: the collapsed row's cluster.
        let states: [AgentState]
        let tabs: [SidebarTab]

        /// The ONE tab whose row the tree elides: a lone tab that carries
        /// no information of its own (no name, no face). A lone NAMED tab
        /// earns its row like any tab among many.
        var soleTab: SidebarTab? {
            guard tabs.count == 1, let only = tabs.first, !only.named else { return nil }
            return only
        }
    }

    /// Where you ARE, derived from the key window: session, mounted tab
    /// row, focused pane. Its own channel, read on every key-window and
    /// focus change without the snapshot's throttle: the active chain must
    /// repaint the instant a tab is clicked, never a tick later.
    struct ActiveChain: Equatable {
        let session: String
        let tab: String?
        let pane: String?
    }

    func activeChain() -> ActiveChain? {
        guard let front = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? TerminalController,
              let name = sessionName(of: front), let session = sessions[name] else { return nil }
        let ids = Set(front.surfaceTree.compactMap(\.vigilAttachId)
            + (dockMap.object(forKey: front)?.views.compactMap(\.vigilAttachId) ?? []))
        let tab = session.tabs.first { !Set(tabPaneIds($0)).isDisjoint(with: ids) }
        let anchor = tab.flatMap { $0.panes.first?.id ?? $0.dock?.panes.first?.id }
        return ActiveChain(
            session: name,
            tab: anchor.map { Self.tabRowId(name, anchor: $0) },
            pane: front.focusedSurface?.vigilAttachId)
    }

    /// Row identity FOLLOWS THE TAB (its anchor pane), never its
    /// position: index-based ids made selection, collapse and rename
    /// UI stick to whatever tab happened to sit at that row after a
    /// reorder (the renamed-tab-was-a-different-terminal bug).
    static func tabRowId(_ session: String, anchor: String?, index: Int = 0) -> String {
        anchor.map { "\(session)-tab-\($0)" } ?? "\(session)-t\(index)"
    }

    /// The cluster rule, shared by session and tab rollups: one dot PER
    /// PANE with an active state (two blocked claudes = two orange dots),
    /// most urgent first, capped at 4; idle panes stay out of the cluster
    /// unless idle is all there is (then a single idle dot).
    static func clusterStates(_ states: [AgentState]) -> [AgentState] {
        let active = states.filter { $0 != .idle }.sorted { $0.rawValue > $1.rawValue }
        if !active.isEmpty { return Array(active.prefix(4)) }
        return states.isEmpty ? [] : [.idle]
    }

    /// One immutable projection of everything the left bar shows, READ
    /// FROM THE REGISTRY: every session (live, detached, asleep) → its
    /// tabs → their panes (splits AND dock tenants), each pane decorated
    /// with its live view when one exists (title, focus) and with its
    /// program (argv truth from the daemon's tree file) and continuous
    /// AgentState. A tab materializing its splits one tick apart renders
    /// every registered row from the first paint: nothing flashes.
    func sidebarSnapshot() -> [SidebarSessionRow] {
        let leases = watchLeases()

        func paneRow(_ pane: Pane, view: Ghostty.SurfaceView?, isDock: Bool) -> SidebarPane {
            let program = paneProgram(pane.id)
            let liveTitle = view.flatMap { liveTabTitle($0.title) }
            // The name YOU gave it, else what runs there, else what the
            // program calls itself, else where it lives.
            let title = pane.label
                ?? program
                ?? liveTitle
                ?? pane.title
                ?? URL(fileURLWithPath: pane.cwd).lastPathComponent
            return SidebarPane(
                id: pane.id,
                paneId: pane.id,
                title: title,
                program: program,
                state: paneDisplayState(pane.id),
                isDock: isDock,
                emoji: pane.emoji,
                watchNotes: leases[pane.id]?.map(\.note) ?? [],
                watchProcs: paneWatchers(pane.id))
        }

        /// A tab's skim label: WHERE it lives (cwd basename), never an echo
        /// of its first pane's program or title (the pane rows already say
        /// that; a terminal title is the full path).
        func tabTitle(cwd: String?, fallback: String) -> String {
            guard let cwd, !cwd.isEmpty else { return fallback }
            let base = URL(fileURLWithPath: cwd).lastPathComponent
            return base.isEmpty ? fallback : base
        }

        /// A LIVE title, cleaned: claude's braille-spinner / idle-marker
        /// prefix strips (it ticks several times a second and would
        /// flicker the row), ghost/empty titles yield nil.
        func liveTabTitle(_ raw: String?) -> String? {
            guard var t = raw?.trimmingCharacters(in: .whitespaces),
                  !t.isEmpty, t != "👻" else { return nil }
            while let first = t.unicodeScalars.first,
                  (0x2800...0x28FF).contains(first.value) || first == "✳" || first == "·" {
                t = String(String.UnicodeScalarView(t.unicodeScalars.dropFirst()))
                    .trimmingCharacters(in: .whitespaces)
            }
            return t.isEmpty ? nil : t
        }

        var rows: [SidebarSessionRow] = []
        let ordered = sessions.values.sorted { ($0.order, $0.label) < ($1.order, $1.label) }
        for session in ordered {
            let name = session.name
            // Every live view of this session by pane id: member trees and
            // docks when embedded, held runtimes otherwise.
            var live: [String: Ghostty.SurfaceView] = [:]
            for runtime in runtimes(session) {
                for view in Array(runtime.tree) + (runtime.dock?.views ?? []) {
                    if let id = view.vigilAttachId { live[id] = view }
                }
            }
            var tabs: [SidebarTab] = []
            for (index, tab) in session.tabs.enumerated() {
                let ids = Set(tabPaneIds(tab))
                guard !ids.isEmpty else { continue }
                var panes = tab.panes.map { paneRow($0, view: live[$0.id], isDock: false) }
                panes += (tab.dock?.panes ?? []).map { paneRow($0, view: live[$0.id], isDock: true) }
                let anchor = tab.panes.first?.id ?? tab.dock?.panes.first?.id
                let title = tab.label.flatMap { $0.isEmpty ? nil : $0 }
                    ?? tabTitle(cwd: tab.panes.first?.cwd, fallback: "tab \(index + 1)")
                tabs.append(SidebarTab(
                    id: Self.tabRowId(name, anchor: anchor, index: index),
                    title: title,
                    index: index,
                    panes: panes,
                    anchor: anchor,
                    cold: !ids.contains { live[$0] != nil },
                    emoji: tab.emoji,
                    named: tab.label?.isEmpty == false || tab.emoji?.isEmpty == false))
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
                states: Self.clusterStates(tabs.flatMap(\.panes).compactMap(\.state)),
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

    /// First sync of a session window: freeze the default into the
    /// session (no persist; the next persist carries it).
    func stampSidebar(name: String, _ visible: Bool) {
        guard sessions[name] != nil, sessions[name]!.sidebar == nil else { return }
        sessions[name]!.sidebar = visible
    }

    /// The window's sidebar visibility, stored on the session and synced
    /// to every member window of it.
    func setSidebar(name: String, _ visible: Bool) {
        guard sessions[name] != nil else { return }
        sessions[name]!.sidebar = visible
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

    /// The machine is going down. Cancelling termination now stalls the
    /// shutdown itself, so service mode is off the table from here on.
    fileprivate(set) var systemPoweringOff = false

    /// Cmd+Q with sessions alive: detach every session (everything keeps
    /// running), vanish from the dock. Returns true when the termination
    /// must be cancelled.
    func interceptTermination() -> Bool {
        guard !reallyQuit else { return false }
        // The machine is going down: DIE. prepareForSystemShutdown already
        // froze and persisted the workspace at willPowerOff; anything that
        // cancels here stalls the shutdown (see the observer in init).
        guard !systemPoweringOff else {
            vlog("quit(intercept): power-off in flight -> terminate now")
            return false
        }
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
        vlog("quit(intercept): froze \(frozen.filter(\.value).count)/\(frozen.count) foreground -> \(frozen.filter(\.value).keys.sorted().joined(separator: ","))")
        defer { DispatchQueue.main.async { self.shutdownForeground = nil } }

        if let name = floatingName, let quick = quickController(create: false) {
            reclaim(name, from: quick)
        }
        // Every session detaches and keeps running (service mode).
        // Snapshot names first: detach mutates sessions, which must not
        // happen while iterating it.
        for name in Array(sessions.keys) {
            if case .embedded = sessions[name]?.state { detach(name: name) }
        }
        // Nothing to survive: let the app quit for real.
        guard !sessions.isEmpty else {
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
        // DIE owns its ceremony: freeze foreground truth, persist - for
        // EVERY caller (SIGTERM, the eye menu's explicit Quit). The
        // reallyQuit guard makes interceptTermination skip all
        // bookkeeping, so it must happen here, before terminate.
        prepareForSystemShutdown()
        NSApp.terminate(nil)
    }

    /// System shutdown/restart/logout: the app must DIE (cancelling
    /// termination blocks the shutdown), recording the workspace exactly as
    /// it stands so login rebuilds it: foreground flags frozen while the
    /// windows are still open. Daemons are left for the OS to kill (their
    /// specs survive; `vigild restore` respawns them at login).
    func prepareForSystemShutdown() {
        // Both signals may land (willPowerOff, then the terminate): the
        // first one owns the truth, while the windows still show.
        guard shutdownForeground == nil else { return }
        var frozen: [String: Bool] = [:]
        for (name, session) in sessions { frozen[name] = isForeground(session) }
        shutdownForeground = frozen
        vlog("shutdown(system): froze \(frozen.filter(\.value).count)/\(frozen.count) foreground -> \(frozen.filter(\.value).keys.sorted().joined(separator: ","))")
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
                vlog("!! IMPOSSIBLE [\(site)]: '\(name)' embedded with no members")
            }
        }
        // Every attach surface alive in the process must be REGISTERED (a
        // session or a burial lists its pane). A windowed one that is not
        // was stranded by a move; a WINDOWLESS one is a leak: some UI
        // object retains a view whose pane already died (the dock strip,
        // a stale focusedSurface, a titlebar closure once kept daemons
        // immortal this way when liveness was ownership, 2026-08-22).
        var owned = Set<String>()
        for session in sessions.values { owned.formUnion(ownedPaneIds(session)) }
        for session in graveyard.values { owned.formUnion(ownedPaneIds(session)) }
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects {
            guard let id = view.vigilAttachId, !owned.contains(id) else { continue }
            vlog("!! IMPOSSIBLE [\(site)]: surface for '\(id)' is \(view.window == nil ? "windowless (LEAKED)" : "live") but registered NOWHERE")
        }
        // Dead windows must actually die: a closed terminal window that
        // stays resident keeps its titlebar accessories, tab bar and
        // SwiftUI hosts alive and WindowServer compositing it. Undo-close
        // legitimately retains a few (120s), so the tripwire is a RATIO:
        // resident controllers vs windows a human can see.
        let resident = TerminalController.all.count
        let visible = TerminalController.all.filter {
            $0.window.map { $0.isVisible || $0.isMiniaturized } ?? false
        }.count
        if resident > max(20, visible * 4) {
            vlog("!! IMPOSSIBLE [\(site)]: \(resident) TerminalControllers resident for \(visible) visible windows (window leak)")
        }
        // One daemon = ONE live pane: twin surfaces on one socket replay
        // interleaved frames into garbage (the duplicated-lazygit
        // corruption).
        var liveIds = Set<String>()
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects {
            guard let id = view.vigilAttachId, view.window != nil else { continue }
            if !liveIds.insert(id).inserted {
                vlog("!! IMPOSSIBLE [\(site)]: TWO live surfaces attached to '\(id)'")
            }
        }
        #endif
    }

    /// Self-heal: sessions whose member windows silently died sleep on
    /// their registry; membership vs tabGroup divergence; empty-tree
    /// corpse windows.
    func reconcile() {
        reconcileTabs()
        let orphaned = sessions.filter { _, session in
            if case .embedded = session.state { return members(of: session.name).isEmpty }
            return false
        }
        for (name, _) in orphaned {
            vlog("reconcile: '\(name)' embedded with no members -> asleep")
            sessions[name]!.state = .asleep
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

    /// The identity key of the tab a window currently shows: its ANCHOR
    /// pane, the same key the sidebar uses, so both surfaces name the same
    /// thing.
    func tabIdentityKey(for controller: TerminalController) -> String? {
        controller.surfaceTree.compactMap(\.vigilAttachId).first.map { "tab:\($0)" }
    }

    /// ONE name per tab. The sidebar row and the native tab bar were two
    /// independent names for the same tab: the row showed the stored
    /// identity, the tab bar showed the raw terminal title (ghostty's 👻
    /// default when a swap left it stale), and ghostty's own Change Tab
    /// Title was a THIRD, unstored one. The stored identity is the name,
    /// and ghostty's titleOverride is how it reaches the tab bar.
    /// What a tab is CALLED, one answer for every surface that shows it
    /// (the native tab bar, the sidebar row, the rename prompt's seed).
    /// Two surfaces computing this separately is how a tab ends up as
    /// "Auto-play video thumbnails" in the tab bar and "tab 3" in the
    /// sidebar at the same time.
    func tabDisplayName(anchor: String) -> (emoji: String?, label: String?) {
        let custom = customIdentity("tab:\(anchor)")
        if let label = custom?.label, !label.isEmpty {
            return (custom?.emoji, label)
        }
        // Nothing typed: the tab still knows what it IS - its anchor's
        // remembered terminal title, then the program running there.
        return (custom?.emoji, capturedTitle(ofPane: anchor) ?? paneProgram(anchor))
    }

    func syncTabTitle(_ controller: TerminalController) {
        guard let key = tabIdentityKey(for: controller) else { return }
        // The title carries the NAME alone. The face renders in the face
        // control (tab accessory, sidebar), never inline in the label: an
        // emoji inside the title text inherited the label's dimmed color
        // and washed out, and the titlebar center is session territory.
        let name = tabDisplayName(anchor: String(key.dropFirst(4)))
        controller.titleOverride = (name.label?.isEmpty == false) ? name.label : nil

        if let window = controller.window { VigilTabFaces.sync(window) }
    }

    /// The inline tab-title editor's commit, kept in the one store so it
    /// survives, shows in the sidebar, and is never clobbered by a sync.
    /// Preserves the tab's face: renaming is not un-emoji-ing.
    @discardableResult
    func setTabLabel(_ controller: TerminalController, _ label: String?) -> Bool {
        guard let key = tabIdentityKey(for: controller) else { return false }
        setCustomIdentity(key: key, label: label, emoji: customIdentity(key)?.emoji)
        return true
    }

    /// Rename the TAB shown in this window, through the one identity editor
    /// (emoji picker, transcript-aware suggestion, persisted). Replaces
    /// ghostty's plain text prompt for vigil windows.
    func promptTabIdentity(_ controller: TerminalController) -> Bool {
        guard let key = tabIdentityKey(for: controller) else { return false }
        let anchor = String(key.dropFirst(4))
        let current = customIdentity(key)
        let panes = controller.surfaceTree.compactMap(\.vigilAttachId)
        VigilIdentity.editModal(
            title: "Tab identity",
            label: current?.label ?? controller.window?.title ?? "",
            emoji: current?.emoji,
            context: "a terminal tab.\n" + workContext(panes: panes)
        ) { [weak self, weak controller] label, emoji in
            self?.setCustomIdentity(key: "tab:\(anchor)", label: label, emoji: emoji)
            if let controller { self?.syncTabTitle(controller) }
        }
        return true
    }

    /// What the sparkle (and the persist refinement) reasons from: cwd,
    /// current label, what the daemons actually run, the visible screen.
    func identityContext(name: String) -> String {
        guard let session = sessions[name] else { return "" }
        let screen = anchorController(of: name)?.focusedSurface?.cachedScreenContents.get() ?? ""
        let running = runningSummary(of: name).joined(separator: ", ")
        let work = workContext(panes: Array(ownedPaneIds(session)))
        return "cwd: \(session.cwd)\ntitle: \(session.label)\nrunning: \(running)\n"
            + (work.isEmpty ? "" : "what is being worked on:\n\(work)\n")
            + "screen:\n\(screen.suffix(1500))"
    }

    /// The ACTUAL WORK in these panes, captured by the adapter from the
    /// agent's prompt event: what was asked, in the user's own words. A
    /// screen scrape only ever caught whatever happened to be painted, and
    /// a cwd basename named every $HOME pane "adrian". Legacy Claude entries
    /// without an asks cache fall back to their transcript.
    func workContext(panes: [String]) -> String {
        var out: [String] = []
        for pane in panes.sorted() {
            let asks = agentAsks(ofPane: pane, limit: 6)
            guard !asks.isEmpty else { continue }
            out.append("- pane \(pane):\n  " + asks.joined(separator: "\n  "))
        }
        return out.joined(separator: "\n")
    }

    /// Opening ask + latest asks for one pane. Current adapters write this
    /// bounded cache from their stable prompt hook, so Vigil never depends on
    /// an agent vendor's private transcript schema.
    private func agentAsks(ofPane pane: String, limit: Int) -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/sessions")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        for entry in entries where entry.hasSuffix("--\(pane).json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(entry)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let asks = json["asks"] as? [String], !asks.isEmpty {
                if asks.count <= limit { return asks }
                return [asks[0]] + asks.suffix(limit - 1)
            }
        }
        return []
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
        let sidebar: Bool?
        let buriedUntil: Date?
        /// Had a window at record time; launch restores it as one.
        let foreground: Bool?
        /// Monotonic pane-index counter; indices are never recycled.
        let paneSeq: Int?
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

    /// Display facts of LIVE panes (cwd, title, dock width/active/collapse)
    /// refresh at persist: they are not ownership, only what the registry
    /// remembers about a pane once it goes cold. No entry is ever added or
    /// dropped here.
    private func refreshLiveFacts() {
        for (name, session) in sessions {
            var views: [String: Ghostty.SurfaceView] = [:]
            var docks: [String: VigilDockRuntime] = [:] // keyed by any tenant id
            for runtime in runtimes(session) {
                for view in runtime.tree {
                    if let id = view.vigilAttachId { views[id] = view }
                }
                for view in runtime.dock?.views ?? [] {
                    if let id = view.vigilAttachId {
                        views[id] = view
                        docks[id] = runtime.dock
                    }
                }
            }
            guard !views.isEmpty else { continue }
            var tabs = session.tabs
            for t in tabs.indices {
                for p in tabs[t].panes.indices {
                    if let view = views[tabs[t].panes[p].id] { refreshFacts(&tabs[t].panes[p], from: view) }
                }
                guard var dock = tabs[t].dock else { continue }
                for p in dock.panes.indices {
                    if let view = views[dock.panes[p].id] { refreshFacts(&dock.panes[p], from: view) }
                }
                if let runtime = dock.panes.first.flatMap({ docks[$0.id] }) {
                    dock.width = Double(runtime.width)
                    dock.collapsed = runtime.collapsed
                    dock.active = min(max(runtime.active, 0), dock.panes.count - 1)
                }
                tabs[t].dock = dock
            }
            sessions[name]!.tabs = tabs
        }
    }

    private func refreshFacts(_ pane: inout Pane, from view: Ghostty.SurfaceView) {
        if let pwd = view.pwd { pane.cwd = pwd }
        if let title = capturedTitle(of: view) { pane.title = title }
    }

    private func persist() {
        refreshLiveFacts()
        var entries = sessions.values.map {
            PersistedSession(name: $0.name, label: $0.label, emoji: $0.emoji, cwd: $0.cwd, tabs: $0.tabs, order: $0.order, pinned: $0.pinned, sidebar: $0.sidebar, buriedUntil: nil, foreground: isForeground($0), paneSeq: $0.paneSeq)
        }
        entries += graveyard.values.map {
            PersistedSession(name: $0.name, label: $0.label, emoji: $0.emoji, cwd: $0.cwd, tabs: $0.tabs, order: $0.order, pinned: $0.pinned, sidebar: $0.sidebar, buriedUntil: graveyardDeadlines[$0.name], foreground: false, paneSeq: $0.paneSeq)
        }
        entries.sort { $0.name < $1.name }
        let data = try! JSONEncoder().encode(entries)
        try? FileManager.default.createDirectory(
            at: persistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // This file is the ONLY copy of everything you named. It is
        // rewritten wholesale many times a minute, so it gets the two
        // cheap guarantees that failure mode deserves: the previous good
        // version is kept beside it, and the new one lands ATOMICALLY (a
        // crash mid-write can truncate a plain write to nothing).
        if let previous = try? Data(contentsOf: persistURL), !previous.isEmpty {
            try? previous.write(to: persistBackupURL, options: .atomic)
        }
        try! data.write(to: persistURL, options: .atomic)
        syncWindowMarks()
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// Tab regroups in flight (mount's one-tick native-tab batches): while
    /// any is pending, the tab bar must NOT be force-toggled - see
    /// enforceTabBar.
    private var regroupsInFlight = 0

    /// `.preferred` biases grouping; the bar itself is forced via the tab
    /// group's public visibility. NEVER while a regroup is in flight:
    /// toggleTabBar during the same transition AppKit uses to install the
    /// group's own bar leaves TWO bars stacked on one titlebar (AX-verified
    /// 2026-08-05: a stale solo bar occluding the real tabs, misrouting
    /// every click on the strip by a few pixels). Existing duplicates heal
    /// here - keep the newest, strip the rest, scream in the log - so a
    /// race that slips through self-corrects at the next sync.
    private func enforceTabBar(_ window: NSWindow) {
        window.tabbingMode = .preferred
        guard let group = window.tabGroup, let tw = window as? TerminalWindow else { return }
        // Detection must be upstream's isTabBar: the accessory's TOP view
        // is a plain NSView (AppKit installs the bar in stages - empty
        // accessory first, NSTabBar nested later), so class-name checks
        // on the accessory itself see nothing.
        let bars = tw.titlebarAccessoryViewControllers.enumerated()
            .filter { tw.isTabBar($0.element) }
        if bars.count > 1 {
            // A forced toggle raced that staged install: TWO bars stack
            // on one titlebar, the stale solo bar occluding the real
            // tabs - no hover feedback, dead clicks on the whole strip
            // (AX-verified 2026-08-05). Keep the newest (add order),
            // strip the rest; re-sync next tick re-forces if needed.
            vlog("enforceTabBar: \(bars.count) tab bars stacked on one titlebar - healing")
            for (index, _) in bars.dropLast().reversed() {
                tw.removeTitlebarAccessoryViewController(at: index)
            }
            DispatchQueue.main.async { [weak self] in self?.syncWindowMarks() }
            return
        }
        // A duplicate can ALSO live as a bare NSTabBar VIEW orphaned in
        // the titlebar hierarchy (no accessory to remove). The live bar
        // is the one whose tab-button count matches the group; any other
        // is a corpse - remove the view itself. Ambiguity touches
        // nothing and screams.
        if let titlebar = tw.titlebarView {
            var tabBars: [NSView] = []
            Self.collectDescendants(of: titlebar, className: "NSTabBar", into: &tabBars)
            if tabBars.count > 1 {
                let census = tabBars.map { bar -> String in
                    var buttons: [NSView] = []
                    Self.collectDescendants(of: bar, className: "NSTabButton", into: &buttons)
                    return "\(bar.frame) buttons=\(buttons.count) host=\(bar.superview?.className ?? "?")"
                }
                vlog("enforceTabBar: \(tabBars.count) NSTabBar views on one titlebar: \(census.joined(separator: " | "))")
                let expected = group.windows.count
                let live = tabBars.filter { bar in
                    var buttons: [NSView] = []
                    Self.collectDescendants(of: bar, className: "NSTabButton", into: &buttons)
                    return buttons.count == expected
                }
                if live.count == 1 {
                    for bar in tabBars where bar !== live[0] {
                        vlog("enforceTabBar: removing corpse bar \(bar.frame)")
                        bar.removeFromSuperview()
                    }
                } else {
                    vlog("enforceTabBar: cannot pick the live bar (expected \(expected) tabs) - left alone")
                }
                return
            }
        }
        // Force ONLY when no bar accessory exists at all: mid-install the
        // group's visible flag lags the accessory, and toggling in that
        // gap is exactly how the duplicate is born.
        guard regroupsInFlight == 0, !group.isTabBarVisible, bars.isEmpty else { return }
        // DEFERRED a tick and re-checked as still SOLO: a freshly born
        // window often joins a group within the same breath (⌘T, moves,
        // regroups) and AppKit brings the group's bar itself - toggling
        // the pre-join solo window mints the corpse (heals at 10:41
        // proved the creator survived the launch-path guards).
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, let tw = window as? TerminalWindow,
                  let group = window.tabGroup else { return }
            guard self.regroupsInFlight == 0,
                  group.windows.count == 1,
                  !group.isTabBarVisible,
                  !tw.titlebarAccessoryViewControllers.contains(where: { tw.isTabBar($0) })
            else { return }
            window.toggleTabBar(nil)
        }
    }

    private static func collectDescendants(of view: NSView, className: String, into out: inout [NSView]) {
        for sub in view.subviews {
            if sub.className == className { out.append(sub) }
            collectDescendants(of: sub, className: className, into: &out)
        }
    }

    /// Idempotent: every session window carries the titlebar mark (face
    /// chip, pin, dock toggle) and its tab bar. One sync walks all windows;
    /// called from persist(), the chokepoint every state change already
    /// flows through (plus any window becoming key, for fresh windows).
    private func syncWindowMarks() {
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            // Real terminal windows only (skip corpses without a tree).
            guard window.isVisible || window.isMiniaturized else { continue }
            guard !controller.surfaceTree.isEmpty else { continue }

            let existing = window.titlebarAccessoryViewControllers.enumerated()
                .first { $0.element is VigilTitlebarAccessory }

            // The tab bar is ALWAYS visible (Adrian 2026-08-03): a lone
            // tab shows as one tab + the native plus, so tabbed and
            // tabless windows share one height and switching sessions
            // never shifts the layout vertically.
            enforceTabBar(window)

            let name = sessionName(of: controller)

            // Enforce a session's stored pin intent on its live window
            // (covers resurrection/re-embed for free); session-less windows
            // keep their pure window-level pin.
            if let name, let session = sessions[name] {
                applyPin(window, session.pinned)
            }
            // The tab bar wears the stored tab identity, refreshed at the
            // same chokepoint as every other window mark (mounts, swaps,
            // focus changes) so it can never drift from the sidebar row.
            syncTabTitle(controller)
            let pinned = name.map { sessionPinned($0) } ?? isPinned(controller)

            // Closures capture the controller WEAKLY: the accessory lives
            // on the window, so a strong capture is a window→accessory→
            // controller→window cycle that keeps closed windows resident.
            let mark = VigilWindowMark(
                label: name.flatMap { sessions[$0]?.label },
                emoji: name.flatMap { sessions[$0]?.emoji },
                pinned: pinned,
                dockOpen: dockMap.object(forKey: controller).map { !$0.collapsed } ?? false,
                onEditIdentity: name.map { n in { VigilIdentity.editModal(name: n) } },
                onTogglePin: { [weak self, weak controller] in
                    guard let controller else { return }
                    if let name { self?.togglePinSession(name) }
                    else { self?.togglePin(controller); self?.persist() }
                },
                onToggleDock: name == nil ? nil : { [weak self, weak controller] in
                    guard let controller else { return }
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

            // The side bars ride the same chokepoint: every window that
            // gets its mark gets its bars (idempotent install + state sync).
            VigilBars.shared.sync(controller)
        }
    }

    /// The highest pane index any state file on disk records for a session:
    /// pidfiles, specs, resume pointers, trees, mail, tombstones alike.
    private static func maxPaneIndexOnDisk(session: String) -> Int {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/vigild")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return -1 }
        let prefix = "vigil-\(session)-"
        var maxIndex = -1
        for entry in entries where entry.hasPrefix(prefix) {
            let stem = entry.split(separator: ".").first.map(String.init) ?? entry
            if let n = Int(stem.dropFirst(prefix.count)) {
                maxIndex = max(maxIndex, n)
            }
        }
        return maxIndex
    }

    private func load() {
        // The backup is a fallback, never a merge: whichever file decodes
        // is the workspace. A live file that decodes always wins, even if
        // the backup is newer, because the backup IS an older live file.
        var payload = try? Data(contentsOf: persistURL)
        var decoded = payload.flatMap { try? JSONDecoder().decode([PersistedSession].self, from: $0) }
        if decoded == nil {
            payload = try? Data(contentsOf: persistBackupURL)
            decoded = payload.flatMap { try? JSONDecoder().decode([PersistedSession].self, from: $0) }
            if decoded != nil {
                vlog("!! load: vigil.json unreadable, recovered the workspace from vigil.json.bak")
            }
        }
        guard let entries = decoded else { return }
        var seen = Set<String>()
        for entry in entries {
            var session = Session(
                name: entry.name,
                label: entry.label,
                emoji: entry.emoji,
                cwd: entry.cwd,
                state: .asleep,
                tabs: entry.tabs ?? [],
                order: entry.order ?? 0)
            // One daemon = ONE pane: a registry claiming an id twice would
            // attach two surfaces to one socket (frames interleave into
            // garbage). The writer cannot produce this; a file that has it
            // screams.
            for id in session.tabs.flatMap(tabPaneIds) where !seen.insert(id).inserted {
                vlog("!! load: '\(entry.name)' lists '\(id)' which another entry already lists")
            }
            // The counter must clear every index this session has ever
            // used: a mint that reuses an index inherits a dead pane's
            // resume pointer (rapid-lynx-4 typed `claude --resume` of a
            // long-dead conversation into itself, 2026-08-09). The floor
            // covers every index the STATE DIR has ever seen.
            var maxIndex = Self.maxPaneIndexOnDisk(session: entry.name)
            for id in ownedPaneIds(session) {
                if let n = id.split(separator: "-").last.flatMap({ Int($0) }) {
                    maxIndex = max(maxIndex, n)
                }
            }
            session.paneSeq = max(entry.paneSeq ?? 0, maxIndex + 1)
            session.pinned = entry.pinned ?? false
            session.sidebar = entry.sidebar
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
        tree: SplitTree<Ghostty.SurfaceView>,
        relativeTo: NSWindow? = nil,
        ordered: NSWindow.OrderingMode = .above
    ) -> TerminalController {
        let controller = TerminalController(ghostty, withSurfaceTree: tree)
        controller.isBackgroundOpaque = parent.isBackgroundOpaque
        if let window = controller.window, let anchorWindow = relativeTo ?? parent.window {
            // SILENT append: the tab joins the group's bar without
            // showWindow - ordering a tabbed window front SELECTS its
            // tab, and a batch regroup that shows each joiner flashes
            // every terminal in sequence before the anchored one wins
            // (the mount "layout-shift festival", Adrian 2026-08-04).
            // The anchored tab stays selected throughout; a silent tab
            // renders when first selected.
            anchorWindow.addTabbedWindowSafely(window, ordered: ordered)
        }
        return controller
    }
}
