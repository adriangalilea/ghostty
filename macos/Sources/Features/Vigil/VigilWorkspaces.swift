import AppKit
import AskKit
import AuthzClient
import Listen
import Say
import SwiftUI
import GhosttyKit
import Log
import VigilHarness
import VigilWire

/// vigil: workspaces as a first-class native concept.
///
/// A workspace is a named window-full: every tab (each a SplitTree of
/// surfaces) belongs to one workspace and survives as one unit. Three
/// orthogonal facts, never conflated:
///   workspaces registry entries (identity, label, panes with cwd+command);
///              created, renamed, killed; listed in every sidebar, always
///   processes  one vigild daemon per pane, running from creation to kill
///   viewports  windows, the quick terminal, the phone — they DISPLAY
///              workspaces; one can be displayed in zero, one or several
///              (mirrors). Display is DERIVED (`place`): windowed = the
///              controller→workspace membership map, ordered by the window's
///              tabGroup (AppKit is the single source of truth for
///              grouping); floating = `float` (one tab riding the quick
///              terminal); background = neither, running all the same.
///              `held` is a warm-runtime CACHE (trees kept alive while
///              undisplayed so re-display is instant), never a state.
///
/// Identity is pointer-not-value: `name` is the stable key (a random
/// adjective-noun; feeds VIGIL_WORKSPACE and the registry), `label` is the
/// human device. Tabs and splits are structure INSIDE the workspace, never
/// identities: a new tab joins its window's workspace, a dragged-out tab
/// mints a new workspace (reconcileTabs).
///
/// OWNERSHIP IS THE REGISTRY. `Workspace.tabs` lists every pane a workspace
/// owns, live or captured, in tab order, and it is always current: every
/// structural event (a split born or closed, a tab joining or leaving, a
/// move, a close) edits it synchronously at the moment it happens. Live
/// trees are projections of it, never a source; vigil.json is its mirror.
/// A pane is in exactly one place: a workspace, a burial, or dead. Nothing
/// is inferred at persist time and nothing heals, because there is no
/// second store to disagree with.
///
/// Every workspace survives: window close, ⌘Q and reboot keep its daemons
/// running. The only death is an explicit kill, always through the
/// graveyard (120s undo), and a reap kills daemons deterministically and
/// verifies they died. Daemon lifetime never depends on ARC.
///
/// Durable state lives in vigil's one folder (`VigilPaths`), maintained
/// event-driven by agent adapters. The class is split by responsibility
/// across `VigilWorkspaces+*.swift` (attention, viewports, navigation,
/// lifecycle, graveyard, dock, processes, sidebar, naming,
/// instrumentation); every stored property lives here.
@MainActor
class VigilWorkspaces {
    static let shared = VigilWorkspaces()
    var facts = VigilFacts.Snapshot()
    /// Each pane whose glance file did not read, by the file revision last
    /// said (`paneGlance`): one warning per broken file, never per render.
    var unreadGlances: [String: String] = [:]
    /// The same for each pane's ended record (`paneEnd`).
    var unreadEnds: [String: String] = [:]
    /// Panes born headless (`apiNewWorkspace`) whose pidfile no snapshot has
    /// shown yet. A one-shot command can be born and gone between two reads,
    /// so its pidfile never leaves a snapshot and its end was never noticed:
    /// the dead rows of 2026-10-30. Until a snapshot shows the pidfile, its
    /// absence is the end.
    var bornUnseen: Set<String> = []
    lazy var factsLoader = VigilFacts(root: VigilPaths.root.path, report: { event in
        switch event {
        case .seenUnwritable(let pane, let error): factsLog.error("seen mark not written", ["pane": pane, "err": error])
        case .unwatchable(let folder): factsLog.error("folder not watched", ["folder": folder])
        case .slowRead(let revision, let elapsed): factsLog.warn("slow read", ["revision": revision, "elapsed": elapsed])
        }
    }, deliver: { [weak self] snapshot in
        Task { @MainActor [weak self] in
            guard let self, snapshot.revision > self.facts.revision else { return }
            let sidebarChanged = snapshot.sidebarRevision != self.facts.sidebarRevision
            let ended = self.facts.revision == 0 ? [] : Self.commandsEnded(from: self.facts, to: snapshot)
            // A daemon that just ended: its pidfile left the folder, or it
            // was born and gone before any snapshot showed it.
            let left = self.facts.files.keys.filter { $0.hasPrefix("panes/") && $0.hasSuffix(".pid") && snapshot.files[$0] == nil }
                .map { String($0.dropFirst("panes/".count).dropLast(".pid".count)) }
            self.bornUnseen = self.bornUnseen.filter { snapshot.files["panes/\($0).pid"] == nil }
            // What each pane's state became, as this thread took it: a dot
            // that lags its file is read here, never guessed (2026-10-30).
            for (key, file) in snapshot.files where key.hasSuffix(".state") && self.facts.files[key]?.revision != file.revision {
                factsLog.info("state taken", ["pane": String(key.dropFirst("state/".count).dropLast(".state".count)),
                                                "state": file.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                "revision": snapshot.revision])
            }
            self.facts = snapshot
            self.closeFinished(Set(left).union(self.bornUnseen))
            // Answered: a birth whose spec is gone was closed or marked ended.
            self.bornUnseen = self.bornUnseen.filter { Self.specExists($0) }
            // Owner grids and the content receipt read these facts.
            self.syncOwnerGrids()
            // A long command that just ended is news, the same as an
            // agent's turn ending: one attention path for both.
            if !ended.isEmpty {
                var changed = false
                for pane in ended { changed = self.attend(event: "Stop", pane: pane, container: "") || changed }
                if changed { self.attentionChanged() }
            }
            if sidebarChanged { NotificationCenter.default.post(name: Self.stateDidChange, object: nil) }
        }
    })

    /// One tab's live runtime while it has no window: its split tree (views
    /// alive, daemons attached) and its dock, if any. Held by the session's
    /// state, released as one value.
    struct TabRuntime {
        var tree: SplitTree<Ghostty.SurfaceView>
        var dock: VigilDockRuntime?
    }

    /// One tab riding the quick terminal: the session's other tabs wait
    /// in `rest` (their views alive, unshown), the floated tab's dock
    /// stays alive unshown, and `index` is where the floated tab
    /// reinserts among them on reclaim.
    struct FloatRuntime {
        var rest: [TabRuntime]
        var dock: VigilDockRuntime?
        var index: Int
    }

    /// Where a session is displayed RIGHT NOW. DERIVED for display
    /// surfaces (overview, menu, logs), never stored: window truth is
    /// membership, quick-terminal truth is `float`. Stored display beside
    /// membership would allow "windowed with no members"; derived, that
    /// state cannot exist. Whether warm runtimes are held is
    /// a cache detail, invisible here: a background session runs either
    /// way.
    enum Place: String {
        case windowed    // shown in its member windows
        case floating    // riding the quick terminal
        case background  // running, listed in every sidebar, no viewport
    }

    /// Why a session wants Adrian. `input` (adapter permission or question)
    /// outranks `done` (turn finished); FIFO within a rank. Cleared
    /// on open/next, never on mere glancing.
    enum Attention: Int {
        case none = 0
        case done = 1
        case input = 2
        /// A MID-TURN blocker: a permission prompt or an AskUserQuestion —
        /// the agent is stalled mid-work until Adrian answers. Outranks a
        /// turn-end question (the documented permission > review ordering,
        /// now real): ⌘⇧J and the summon serve these first.
        case midTurn = 3
    }

    /// Anything projecting session state (sidebar, overview) re-reads on
    /// this: posted from the persist/attention chokepoints.
    static let stateDidChange = Notification.Name("vigilStateDidChange")
    /// Posted from the focus chokepoint (BaseTerminalController.
    /// syncFocusToSurfaceTree): the sidebar re-derives its active chain
    /// the moment keystroke destiny moves, instead of waiting for a tick.
    static let focusDidChange = Notification.Name("vigilFocusDidChange")
    /// Posted when vigil's own modes change what may move the glass:
    /// control mode entered or left, the follow mode switched.
    static let modeDidChange = Notification.Name("vigilModeDidChange")
    /// A live pane's name (its terminal title, status light stripped)
    /// changed; the object is the surface. The sidebar re-draws on it.
    static let titleDidChange = Notification.Name("vigilTitleDidChange")

    /// Calls `body` on every event after which what is in front of the
    /// human may read differently: a pane's state, focus, the key window,
    /// the app's activation, a window covered, minimized or closed, a Space
    /// or display change, the quick terminal shown or hidden, vigil's
    /// modes. The one list every "who is looking" reader observes (the
    /// summon, auto-follow, the screen context sent to authz), so none of
    /// them needs a heartbeat. `body` runs on main, possibly while AppKit
    /// is mid-change: readers re-read on the next turn.
    static func onPresenceInputs(_ body: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            stateDidChange, focusDidChange, modeDidChange, .quickTerminalDidChangeVisibility,
            NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { body() } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    /// When each PANE was last under the eyes (its view visible in the key
    /// window), keyed by pane daemon id: blocked/done older than the pane's
    /// ack display as idle (seen), herdr's seen-flip without a stored flag.
    /// Pane-keyed because seen is a property of the CONSOLE, not the
    /// session: the session-keyed ledger acked asks living in unmounted
    /// tabs of the watched session sight-unseen (dot decayed, no attention,
    /// no follow - an invisible console you could never have answered).
    /// The home stores the exact observed state revision. File timestamps are
    /// presentation clocks, never authority to acknowledge a later state.
    private func stateRevision(_ pane: String) -> String? {
        facts.files["state/\(pane).state"]?.revision
    }

    func lastAck(_ pane: String) -> Date? {
        if let remote = VigilRemote.split(pane) {
            return VigilRemote.shared.host(remote.device)?.directory?.panes[remote.name]?.seen.map(Date.init(timeIntervalSince1970:))
        }
        guard let state = facts.files["state/\(pane).state"],
              facts.files["state/\(pane).seen"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) == state.revision
        else { return nil }
        return state.since
    }

    func markSeen(_ pane: String, revision: String? = nil) {
        guard let observed = revision ?? stateRevision(pane), stateRevision(pane) == observed else { return }
        factsLoader.markSeen(pane, revision: observed)
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
        for session in workspaces.values.map({ $0 }) + graveyard.values.map({ $0 }) {
            for tab in session.tabs {
                if wantsTab {
                    guard tab.paneIds.first == target else { continue }
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

    /// True when a workspace owns `key` and stored the identity.
    @discardableResult
    func setCustomIdentity(key: String, label: String?, emoji: String?) -> Bool {
        let wantsTab = key.hasPrefix("tab:")
        let target = wantsTab ? String(key.dropFirst(4)) : key
        var landed = false
        for (name, session) in workspaces {
            var tabs = session.tabs
            var hit = false
            for index in tabs.indices {
                // CONTAINS, not "is first": the anchor is the tab's stable
                // handle, but requiring first position made a rename
                // silently do nothing (Adrian, naming a tab '*-utils').
                if wantsTab, tabs[index].paneIds.contains(target) {
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
            // Evaluate fully, THEN assign: an expression reading `workspaces`
            // inside a `workspaces[...]` write is an exclusivity trap.
            if hit {
                workspaces[name]?.tabs = tabs
                landed = true
            }
        }
        // A name the user typed must never vanish quietly.
        if !landed {
            registryLog.error("rename not stored: nothing owns it", ["key": key])
        }
        persist()
        // A tab renamed anywhere (sidebar row, tab bar, ⌘-rename) repaints
        // every surface that shows it: one name, no drift.
        if wantsTab {
            for controller in TerminalController.all { syncTabTitle(controller) }
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        return landed
    }

    /// A workspace as this app holds it: the registry's record (`Registry`,
    /// VigilWire: the one format of vigil.json and every directory) plus
    /// what only a running app has (warm views, the float, attention).
    struct Workspace {
        let name: String
        var label: String
        /// The session's face: 1–3 emoji, display-only ornament (never
        /// identity, same rule as the label). nil = none.
        var emoji: String?
        var cwd: String
        /// Warm view runtimes for tabs currently in NO window: a cache so
        /// re-display is instant (views alive, daemons attached). Display
        /// truth is never stored — a session is displayed iff it has
        /// member windows or rides the quick terminal (`float`). Empty
        /// held + no members + no float = the registry alone; display
        /// then rebuilds from `tabs` (resurrect).
        var held: [TabRuntime] = []
        /// Set while one tab rides the quick terminal.
        var float: FloatRuntime?
        var attention: Attention = .none
        var attentionSince: Date?
        /// THE REGISTRY: every pane this session owns, live or captured, one
        /// entry per tab in tab order, always current (edited at every
        /// structural event, never inferred). Resurrection rebuilds it as
        /// tabs of ONE window.
        var tabs: [Registry.Tab] = []
        /// Manual overview ordering (drag & drop); lower first.
        var order: Int = 0
        /// Pinned-on-top intent, persisted: applied to the window whenever
        /// the session is windowed (open/re-embed/resurrect), so a pin
        /// survives detach, quit and reboot, and a background session can
        /// be pinned before it even has a window.
        var pinned: Bool = false
        /// The session tree sidebar of this session's window: shown or
        /// hidden, persisted; nil = the app-wide default (the last toggle
        /// anywhere). Per window, never global: toggling one window must
        /// not repaint another.
        var sidebar: Bool?
        /// Loaded intent: this session had a WINDOW when the app last
        /// recorded it (crash or shutdown), so launch restores it as one.
        /// Detached-in-background workspaces load with this false and stay
        /// background: startup rebuilds the workspace exactly as it was.
        var foreground: Bool = false
        /// Live while windowed (refreshed on overview open), frozen at the
        /// moment of detach while it holds runtimes. Runtime-only.
        var thumbnail: NSImage?
        /// Next pane daemon index to mint, monotonic and persisted: a pane
        /// index is IDENTITY and is never recycled. Deriving "next" from
        /// currently-owned ids alone reused the index of a tab that had
        /// just left (bury, drag-out) while its daemon still ran - the new
        /// surface attached to the departed tab's socket and replayed it
        /// (⌘T resurrecting a ⌘W-closed tab).
        var paneSeq: Int = 0
        /// Opaque, durable CAS token. Returning to an earlier shape must
        /// never make a stale command current again.
        var layoutRevision = UUID().uuidString
        var layoutShape = ""
        /// A burial of a closed tab or pane: where it stood (undo returns
        /// it there). nil for a live workspace and a killed one.
        var buriedFrom: Registry.Origin?

        var paneCount: Int { tabs.reduce(0) { $0 + $1.panes.count } }
    }

    /// Every edit is saved: an edit schedules one save a tick later, so a
    /// path that forgets `persist()` can no longer leave vigil.json behind
    /// the registry (a ⌘T tab lived only in memory, invisible to the other
    /// Mac, and the next launch killed its daemon as an orphan).
    var workspaces: [String: Workspace] = [:] { didSet { savePending() } }

    /// Live membership: which session each tab-controller belongs to. Weak
    /// keys: a controller that dies simply leaves the map. The tabGroup
    /// orders members; this map only assigns them.
    let memberships = NSMapTable<TerminalController, NSString>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory)

    /// Live docks, keyed by tab controller (the dock is per TAB: its
    /// tenants are context-bound, lazygit of THIS tab's repo). Weak keys;
    /// the runtime strongly owns the tenant SurfaceViews. A windowless
    /// tab's dock rides its `TabRuntime`.
    let dockMap = NSMapTable<TerminalController, VigilDockRuntime>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory)

    /// Killed workspaces rest here for a grace period before their daemons
    /// actually die. Undo (ghostty's native `undo` action; bind cmd+shift+T
    /// to it) exhumes the session intact: kill was a detach + a deadline,
    /// nothing had died yet. Ghostty's own ExpiringUndoManager drives the
    /// expiry. 120s: long enough for regret, short enough that hidden
    /// daemons never linger (config key candidate if it feels wrong).
    /// EVERY close rests here - a session, a tab, a split pane, a dock
    /// tenant - one death path, one undo.
    var graveyard: [String: Workspace] = [:] { didSet { savePending() } }
    var graveyardDeadlines: [String: Date] = [:] { didSet { savePending() } }
    static let killGrace: TimeInterval = 120

    /// Most recently active workspaces, newest first: the successor order
    /// when the session you are in dies (the tab-close semantic: the
    /// viewport goes to the last one you were in, never closes while any
    /// session remains). Runtime-only; manual order is the fallback.
    var recent: [String] = []

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
    func swapTree(_ controller: TerminalController, _ tree: SplitTree<Ghostty.SurfaceView>) {
        controller.undoManager?.removeAllActions(withTarget: controller)
        withTreeSwap { controller.surfaceTree = tree }
    }

    /// Set once at app launch by VigilStatusItem; needed to spawn windows.
    weak var ghosttyApp: Ghostty.App?

    /// SIGTERM handler (see init): a signal must never leave a service-mode
    /// survivor behind a dev restart.
    private var sigtermSource: DispatchSourceSignal?
    private var sessionControlSource: DispatchSourceRead?
    private var dictationSource: DispatchSourceRead?

    /// Status item hook: called whenever attention state changes.
    var onAttentionChange: (() -> Void)?

    var pendingCount: Int {
        Set(attentionQueue().map { $0.candidate.name }).count
    }

    var persistURL: URL {
        VigilPaths.registry
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
    /// relaunches an app on its own after a `pkill -9`, so two instances
    /// can be born the same second. First instance wins the flock; a
    /// duplicate activates the holder and exits before touching anything.
    private func acquireInstanceLock() {
        let dir = VigilPaths.root
        do { try VigilPaths.secureRoot() } catch {
            lifecycleLog.error("state folder not made private", ["path": dir.path, "err": error])
        }
        // O_CLOEXEC or every spawned vigild inherits the fd and HOLDS THE
        // FLOCK after the app dies, locking the app out of its own lock:
        // flock rides the file description, which fork shares and only
        // exec+CLOEXEC severs.
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

    // MARK: Stored state of the parts in the extension files

    /// Attention (+Attention): the events log's drain offset and the vnode
    /// watch on the log.
    var eventsOffset: UInt64 = 0
    var eventsWatch: DispatchSourceFileSystemObject?
    /// The content receipt's settle checks, one pending per pane: a screen
    /// hash is judged only after it held still (`checkScreen`).
    var screenSettle: [String: DispatchWorkItem] = [:]

    /// Name of the session currently hosted by the quick terminal.
    var floatingName: String?
    /// The quick terminal's own workspace, stashed while a session floats
    /// in it; restored when the session leaves.
    var stashedQuickTree: SplitTree<Ghostty.SurfaceView>?
    /// True while vigil swaps trees in/out of the quick terminal, so its
    /// tree-change observer must not auto-animate the window in.
    var quickTreeSwap = false
    /// The panel's second client on one pane (+Viewports, `Mirror`).
    var mirror: Mirror?
    /// MIRROR VIEWPORTS: windows showing a second view of a session that
    /// is windowed elsewhere (a sidebar click on it from another window
    /// opens it in this window, even if already opened in another). The
    /// same problem as the phone,
    /// local: two clients on one daemon. The viewport is NOT a member:
    /// its views are mirrors (own nothing, never captured, never counted
    /// as the pane's live view), the size follows whichever client is
    /// focused (vigild's owner claim), and the mirrors die explicitly
    /// when the viewport shows something else or closes.
    let mirrorViewports = NSMapTable<TerminalController, NSString>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    var remoteLayouts: [ObjectIdentifier: String] = [:]
    var remoteLandings: [ObjectIdentifier: String] = [:]
    var remoteDestinations: [ObjectIdentifier: String] = [:]
    var remoteEdits: Set<String> = []

    /// When each session's overview thumbnail was last captured (transient;
    /// the capture itself is persisted via persistThumb).
    var thumbStamp: [String: Date] = [:]
    /// True while vigil itself is mutating memberships/trees, so the
    /// key-window observer must not reconcile half-finished states.
    var reconcilingTabs = false
    /// Windows that slipped past registration (should not exist; safety
    /// net) keep a runtime label keyed by the controller.
    var strayLabels: [ObjectIdentifier: String] = [:]

    /// The panes the phones registered here follow, as the hub's
    /// board records it (`board-status.json`, its one writer): read off main
    /// whenever the harness directory changes, so the sidebar's "Follow on
    /// iPhone" says what is true, whichever side followed.
    var phoneFollows: Set<String> = [] {
        didSet { if phoneFollows != oldValue { NotificationCenter.default.post(name: Self.stateDidChange, object: nil) } }
    }
    /// Some phone is registered with this Mac's hub: only then is there
    /// anything to follow on or ring on (the same read as `phoneFollows`).
    var phonesRegistered = false {
        didSet { if phonesRegistered != oldValue { NotificationCenter.default.post(name: Self.stateDidChange, object: nil) } }
    }
    var boardWatch: DispatchSourceFileSystemObject?

    /// True while quitting should mean "become a menu bar service" instead of
    /// dying. Flipped by quitForReal (the eye menu's explicit kill).
    var reallyQuit = false
    /// The machine is going down. Cancelling termination now stalls the
    /// shutdown itself, so service mode is off the table from here on.
    fileprivate(set) var systemPoweringOff = false
    /// Panes whose leaked surface was already reported this run.
    var reportedLeaks = Set<String>()

    private init() {
        Record.keep(service: "vigil")
        _ = Self.launchedAt // a static is lazy: stamp it at launch, not at the first status read
        acquireInstanceLock()
        load()
        respawnMachineKilledDaemons()
        closeFinished(workspaces.values.flatMap(ownedPaneIds))
        collectOrphans()
        // Publish revisions for older registries without changing their
        // saved login-restoration intent before any windows are restored.
        shutdownForeground = Dictionary(uniqueKeysWithValues: workspaces.values.map { ($0.name, $0.foreground) })
        persist(publish: false)
        shutdownForeground = nil
        sessionControlSource = VigilSessionControl.start()
        dictationSource = VigilDictation.start()
        VigilRemotePaste.install()
        // A logout/restart/shutdown is starting. THE signal, and the only
        // reliable one: the AppleEvent probe in applicationShouldTerminate
        // (kAEShutDown/kAERestart) does not arrive on macOS 26, and without
        // this a restart runs the ⌘Q intercept, which CANCELS termination
        // into service mode: the app refuses to quit, macOS waits on it and
        // the machine wedges (a shutdown_stall). Freeze the workspace here,
        // while the windows still show, and from now on termination can
        // never be cancelled.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let manager = VigilWorkspaces.shared
                manager.systemPoweringOff = true
                manager.prepareForSystemShutdown()
            }
        }
        startEventWatcher()
        startStateDirWatcher()
        watchPhoneFollows()
        // The broker runs on every Mac and the screen's context follows
        // focus (VigilHarnessCoordinator observes its own chokepoints). Next
        // tick: it reads this manager, which is still being built here
        // (a re-entrant `shared` traps before anything is logged).
        DispatchQueue.main.async { VigilHarnessCoordinator.shared.start() }
        NotificationCenter.default.addObserver(
            forName: Self.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncLocalMirrorLayouts() }
        }
        // The summon engine subscribes to the same chokepoints; next tick,
        // never re-entrant with this init.
        DispatchQueue.main.async { _ = VigilSummon.shared }
        // SIGTERM means DIE (vigil-dev restarts, system tooling). Without
        // this, AppKit routes it into the ⌘Q intercept, which CANCELS
        // termination into menu-bar service mode while workspaces exist, and
        // invisible survivors stack up behind pkill + open -n. Freeze
        // foreground truth, persist, really terminate.
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler {
            MainActor.assumeIsolated {
                VigilWorkspaces.shared.quitForReal()
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
                VigilWorkspaces.shared.reconcileTabs()
                VigilWorkspaces.shared.syncWindowMarks()
            }
        }
        // The quick terminal dismissing (any way: toggle, esc-out, focus
        // loss) is the moment a floating session returns to background, and
        // the moment a mirror ends.
        NotificationCenter.default.addObserver(
            forName: .quickTerminalDidChangeVisibility,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                let manager = VigilWorkspaces.shared
                guard let quick = notification.object as? QuickTerminalController,
                      !quick.visible else { return }
                if let name = manager.floatingName {
                    manager.reclaim(name, from: quick)
                } else {
                    manager.endMirror()
                }
            }
        }
    }

    // MARK: Membership (session = the window, tabs are members)

    /// The session this tab-controller belongs to.
    func workspaceName(of controller: TerminalController) -> String? {
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
        guard workspaces[name] != nil else { return }
        let dock = dockMap.object(forKey: controller)
        let ids = controller.surfaceTree.compactMap(\.vigilAttachId)
            + (dock?.views.compactMap(\.vigilAttachId) ?? [])
        guard let first = ids.first, !ownedPaneIds(workspaces[name]!).contains(first) else { return }
        var carried: [Registry.Pane] = []
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
        let tab = Registry.Tab(
            panes: panes, layout: layout,
            dock: dock.flatMap { captureDock($0, carrying: carried) },
            label: label, emoji: emoji)
        // A ⌘T lands right after its parent tab (where AppKit places the
        // native tab), never at the end: registry order IS the tab order.
        let parentIds = Set(parent?.surfaceTree.compactMap(\.vigilAttachId) ?? [])
        if !parentIds.isEmpty,
           let index = workspaces[name]!.tabs.firstIndex(where: { !Set($0.paneIds).isDisjoint(with: parentIds) }) {
            workspaces[name]!.tabs.insert(tab, at: index + 1)
        } else {
            workspaces[name]!.tabs.append(tab)
        }
        registryLog.info("tab registered", ["workspace": name, "panes": ids, "claimed": carried.count])
    }

    /// A session window's tree EMPTIED by ghostty (its only pane dragged
    /// into another window, or exited): the window closes without
    /// ghostty's recreate-the-window undo (that undo would resurrect an
    /// unregistered window holding a view whose pane lives elsewhere).
    /// A pane still listed here was closed, not moved, and is buried; the
    /// session sleeps when no member remains, clears when nothing is left.
    func handleEmptiedTree(_ controller: TerminalController) -> Bool {
        guard let name = workspaceName(of: controller) else { return false }
        for id in controller.surfaceTree.compactMap(\.vigilAttachId) where locate(id)?.owner == name {
            if let taken = takePane(id) { buryPane(taken.pane, from: name, origin: taken.origin) }
        }
        memberships.removeObject(forKey: controller)
        dockMap.object(forKey: controller)?.unmount()
        dockMap.removeObject(forKey: controller)
        killController(controller)
        clearIfEmpty(name)
        persist()
        return true
    }

    /// Close Other Tabs / Close Tabs to the Right in a session window:
    /// each tab leaves through the graveyard, one confirm naming what runs.
    func closeSiblingTabs(of controller: TerminalController, onlyRight: Bool) -> Bool {
        guard let name = workspaceName(of: controller), let window = controller.window,
              let group = window.tabGroup?.windows else { return false }
        let current = group.firstIndex(of: window) ?? 0
        let targets = group.enumerated().compactMap { offset, candidate -> TerminalController? in
            guard candidate !== window, !onlyRight || offset > current,
                  let c = candidate.windowController as? TerminalController,
                  workspaceName(of: c) == name else { return nil }
            return c
        }
        guard !targets.isEmpty else { return true }
        confirmClose(onlyRight ? "Tabs on the Right" : "Other Tabs",
                     busy: busyPrograms(panes: targets.flatMap { $0.surfaceTree.compactMap(\.vigilAttachId) }),
                     in: controller) { [weak self] in
            for target in targets { self?.closeTabStructurally(target) }
        }
        return true
    }

    /// Close All Windows: every windowed session goes background
    /// (everything keeps running, nothing dies); strays close plain.
    func detachAllWindows() -> Bool {
        let names = workspaces.keys.filter { windowed($0) }
        guard !names.isEmpty else { return false }
        for name in names { detach(name: name) }
        for stray in strayControllers() {
            endMirrorViewport(stray)
            stray.closeWindowImmediately()
        }
        return true
    }

    /// The session's live tab-controllers in tab order. Controllers whose
    /// window died are not members (weak map + window filter).
    func members(of name: String) -> [TerminalController] {
        var found: [TerminalController] = []
        for controller in TerminalController.all
        where workspaceName(of: controller) == name && controller.window != nil {
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

    /// Display truth, derived, never stored: in windows, in the quick
    /// terminal, or background (running, no viewport).
    func place(_ name: String) -> Place {
        if workspaces[name]?.float != nil { return .floating }
        return members(of: name).isEmpty ? .background : .windowed
    }

    /// The session shows in at least one window.
    func windowed(_ name: String) -> Bool { !members(of: name).isEmpty }

    /// The log tag: where the session is, plus what the cache holds.
    func placeTag(_ name: String) -> String {
        guard let session = workspaces[name] else { return "unknown" }
        let p = place(name).rawValue
        return session.held.isEmpty ? p : "\(p)(\(session.held.count) tabs held)"
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

    /// The controller behind the session's focus window (windowed only).
    func anchorController(of name: String) -> TerminalController? {
        guard let window = focusWindow(of: name) else { return nil }
        return window.windowController as? TerminalController
    }

    /// The session's live tab runtimes (windowed: member trees + docks;
    /// floating: the waiting rest + the quick terminal's tree; else the
    /// held cache). Display and occlusion read this; ownership never
    /// does.
    func runtimes(_ session: Workspace) -> [TabRuntime] {
        if let float = session.float {
            var out = float.rest
            if floatingName == session.name,
               let quick = quickController(create: false),
               !quick.surfaceTree.isEmpty {
                out.append(TabRuntime(tree: quick.surfaceTree, dock: float.dock))
            }
            return out
        }
        // Every live tab: the ones on screen and the warm ones held while
        // another tab or session has the viewport.
        return members(of: session.name).filter { !$0.surfaceTree.isEmpty }
            .map { TabRuntime(tree: $0.surfaceTree, dock: dockMap.object(forKey: $0)) }
            + session.held
    }

    // MARK: Registry (ownership IS the registry; every structural event edits it here)

    /// Every pane id a session owns: its registry, nothing else.
    func ownedPaneIds(_ session: Workspace) -> Set<String> {
        Set(session.tabs.flatMap(\.paneIds))
    }

    /// The live session that owns a pane (never a burial): where a link to
    /// the pane lands.
    func owner(ofPane id: String) -> String? {
        guard let found = locate(id), !found.buried else { return nil }
        return found.owner
    }

    /// Where a pane lives right now: a session or a burial, and its tab.
    func locate(_ id: String) -> (owner: String, buried: Bool, tab: Int)? {
        for (name, session) in workspaces {
            if let tab = session.tabs.firstIndex(where: { $0.paneIds.contains(id) }) {
                return (name, false, tab)
            }
        }
        for (name, session) in graveyard {
            if let tab = session.tabs.firstIndex(where: { $0.paneIds.contains(id) }) {
                return (name, true, tab)
            }
        }
        return nil
    }

    /// The pane's registry entry, wherever it lives.
    func registered(_ id: String) -> Registry.Pane? {
        guard let at = locate(id) else { return nil }
        let tab = (at.buried ? graveyard[at.owner] : workspaces[at.owner])!.tabs[at.tab]
        return (tab.panes + (tab.dock?.panes ?? [])).first { $0.id == id }
    }

    /// Take a pane OUT of wherever it lives (a session's tab, a dock, a
    /// burial). An emptied tab is dropped and hands its own name and face
    /// to the taker (the identity travels with the only pane instead of
    /// dying with the husk); an emptied burial is dropped; a held runtime
    /// releases the pane's view so no two trees ever hold one daemon. The
    /// one primitive under every move and every re-claim.
    func takePane(_ id: String) -> TakenPane? {
        guard let at = locate(id) else { return nil }
        var session = (at.buried ? graveyard[at.owner] : workspaces[at.owner])!
        var tab = session.tabs[at.tab]
        var pane: Registry.Pane?
        var fromDock = false
        if let index = tab.panes.firstIndex(where: { $0.id == id }) {
            pane = tab.panes.remove(at: index)
            tab.layout = nil
        } else if var dock = tab.dock, let index = dock.panes.firstIndex(where: { $0.id == id }) {
            fromDock = true
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
        // A mirror of a pane that just died shows a corpse: the panel goes.
        if mirror?.pane == id {
            quickController(create: false)?.animateOut()
            endMirror()
        }
        if var float = session.float {
            scrub(&float.rest)
            if let dock = float.dock, let vi = dock.views.firstIndex(where: { $0.vigilAttachId == id }) {
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
            session.float = float
        } else {
            scrub(&session.held)
        }
        if at.buried {
            if session.tabs.isEmpty { dropBurial(at.owner) } else { graveyard[at.owner] = session }
        } else {
            workspaces[at.owner] = session
        }
        // Where it stood, for a burial's undo: beside a pane that stays in its
        // tab, or (the tab emptied) at the tab's position.
        let origin = at.buried ? nil : Registry.Origin(
            workspace: at.owner, tab: at.tab, beside: emptied ? nil : tab.panes.first?.id, dock: fromDock ? true : nil)
        return TakenPane(pane: pane, tabLabel: emptied ? tab.label : nil, tabEmoji: emptied ? tab.emoji : nil, origin: origin)
    }

    /// What `takePane` hands the taker: the pane, the emptied tab's name and
    /// face (nil when the tab stays), and where it stood.
    struct TakenPane {
        let pane: Registry.Pane
        let tabLabel: String?
        let tabEmoji: String?
        let origin: Registry.Origin?
    }

    /// One live view as a registry pane, carrying the remembered facts of
    /// its current entry (title, and the name and face YOU gave it): a
    /// capture is a rewrite and would otherwise erase what the view does
    /// not know about.
    private func capturedPane(_ view: Ghostty.SurfaceView, id: String, previous: Registry.Pane?) -> Registry.Pane {
        Registry.Pane(
            id: id,
            cwd: view.pwd ?? previous?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            title: capturedTitle(of: view) ?? previous?.title,
            label: previous?.label,
            emoji: previous?.emoji,
            command: view.vigilCommand ?? previous?.command,
            priority: previous?.priority)
    }

    /// A live tree as registry panes (DFS leaf order) + split shape.
    func capture(
        _ tree: SplitTree<Ghostty.SurfaceView>, carrying previous: [Registry.Pane]
    ) -> (panes: [Registry.Pane], layout: Registry.Layout?) {
        let panes = tree.compactMap { view -> Registry.Pane? in
            guard let id = view.vigilAttachId else {
                registryLog.error("capture skipped a surface with no daemon id")
                return nil
            }
            return capturedPane(view, id: id, previous: previous.first { $0.id == id } ?? registered(id))
        }
        return (panes, Self.captureLayout(tree))
    }

    func captureDock(_ runtime: VigilDockRuntime, carrying previous: [Registry.Pane]) -> Registry.Dock? {
        let panes = runtime.views.compactMap { view -> Registry.Pane? in
            guard let id = view.vigilAttachId else { return nil }
            return capturedPane(view, id: id, previous: previous.first { $0.id == id } ?? registered(id))
        }
        guard !panes.isEmpty else { return nil }
        return Registry.Dock(
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
        guard treeSwaps == 0, let name = workspaceName(of: controller), workspaces[name] != nil else { return }
        applyTreeDiff(session: name, from: from, to: to)
    }

    /// The quick terminal's tree changed while a session floats in it:
    /// same chokepoint, the floated tab.
    func quickTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        guard !quickTreeSwap, let name = floatingName, workspaces[name] != nil else { return }
        applyTreeDiff(session: name, from: from, to: to)
    }

    /// Diff the pane ids of one tab's tree before and after, and edit the
    /// registry NOW: joined panes are claimed (taken from wherever they
    /// lived: a burial means an undo, another session means a drag, a
    /// pane already listed captured here means it just materialized), the
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
            workspaces[name]!.tabs.firstIndex { !Set($0.paneIds).isDisjoint(with: touched) }
        }
        let listedHere = tabIndex().map { Set(workspaces[name]!.tabs[$0].paneIds) } ?? []
        var carried: [Registry.Pane] = []
        var inheritedLabel: String?
        var inheritedEmoji: String?
        for id in after.subtracting(before) where !listedHere.contains(id) {
            guard let taken = takePane(id) else {
                registryLog.info("fresh pane joins", ["pane": id, "workspace": name])
                continue
            }
            carried.append(taken.pane)
            inheritedLabel = inheritedLabel ?? taken.tabLabel
            inheritedEmoji = inheritedEmoji ?? taken.tabEmoji
            chown(id, to: name)
            registryLog.info("pane claimed", ["pane": id, "workspace": name])
        }

        var session = workspaces[name]!
        let index = tabIndex()
        let previous = index.map { session.tabs[$0].panes } ?? []
        let closed = previous.filter { before.contains($0.id) && !after.contains($0.id) }
        let (panes, layout) = capture(to, carrying: previous + carried)
        if let index {
            // Panes listed but in neither tree are still captured-only (a
            // tab whose anchor is mounted and whose whole tree lands in
            // the same turn): they stay listed, and the shape is the one
            // being built toward, not the anchor alone.
            let captured = session.tabs[index].panes.filter { !touched.contains($0.id) }
            session.tabs[index].panes = panes + captured
            if captured.isEmpty { session.tabs[index].layout = layout }
            if session.tabs[index].label == nil { session.tabs[index].label = inheritedLabel }
            if session.tabs[index].emoji == nil { session.tabs[index].emoji = inheritedEmoji }
            if session.tabs[index].panes.isEmpty, session.tabs[index].dock?.panes.isEmpty ?? true {
                session.tabs.remove(at: index)
            }
        } else if !panes.isEmpty {
            registryLog.error("live tree with no registry tab appended", ["workspace": name])
            session.tabs.append(Registry.Tab(panes: panes, layout: layout, label: inheritedLabel, emoji: inheritedEmoji))
        }
        workspaces[name] = session
        // Beside a pane the tab keeps; at the tab's place when it emptied.
        let origin = index.map { Registry.Origin(workspace: name, tab: $0, beside: panes.first?.id) }
        for pane in closed { buryPane(pane, from: name, origin: origin) }
        persist()
    }

    /// A closed pane (split ⌘W, process exit, dock tenant close, captured
    /// close) rests in the graveyard as its own one-pane burial: same 120s
    /// grace, same undo, same reap as every other death. `origin` is where
    /// it stood, so undo puts it back there.
    func buryPane(_ pane: Registry.Pane, from owner: String, origin: Registry.Origin?) {
        var buried = Workspace(
            name: newWorkspaceId(),
            label: pane.label ?? pane.title ?? paneProgram(pane.id)
                ?? (pane.cwd as NSString).lastPathComponent,
            emoji: pane.emoji,
            cwd: pane.cwd)
        buried.tabs = [Registry.Tab(panes: [pane], layout: nil)]
        buried.buriedFrom = origin
        graveyardLog.info("pane buried", ["pane": pane.id, "workspace": owner, "burial": buried.name])
        bury(buried)
    }

    /// A closed tab rests in the graveyard whole (its panes, layout, dock
    /// and name, and its running views when it had them): the one burial
    /// for a tab, whoever closed it, here or from another Mac. `index` is
    /// its position in `owner`, where undo puts it back.
    func buryTab(_ tab: Registry.Tab, held: [TabRuntime], thumbnail: NSImage?, from owner: String, at index: Int) {
        let cwd = tab.panes.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var buried = Workspace(
            name: newWorkspaceId(),
            label: tab.label ?? tab.panes.first.flatMap { $0.label ?? $0.title } ?? (cwd as NSString).lastPathComponent,
            emoji: tab.emoji,
            cwd: cwd,
            held: held)
        buried.tabs = [tab]
        buried.thumbnail = thumbnail
        buried.buriedFrom = Registry.Origin(workspace: owner, tab: index, beside: nil)
        graveyardLog.info("tab buried", ["panes": tab.paneIds, "workspace": owner, "burial": buried.name])
        bury(buried)
    }

    /// The reboot mirror of ownership: the daemon's spec carries its
    /// owner (VIGIL_WORKSPACE for `vigild restore`), rewritten at every
    /// claim. Write-only from here; never read back to second-guess the
    /// registry.
    func chown(_ id: String, to owner: String) {
        runFireAndForget(Self.vigildBin, ["chown", id, owner])
    }

    /// THE vigild path: every spawn (chown, sendraw, restore) derives it
    /// here (`VigilDictation` reads the same `VigilPaths.vigild`).
    static let vigildBin = VigilPaths.vigild.path

    // MARK: Persistence (identity + cwd + captured tabs; trees are runtime)

    /// Frozen foreground truth for the shutdown persist: the flags must
    /// record the windows as OPEN while the app dies with them showing.
    var shutdownForeground: [String: Bool]?

    /// Was this session showing (window or quick terminal) at persist time?
    func isForeground(_ session: Workspace) -> Bool {
        if let frozen = shutdownForeground { return frozen[session.name] ?? false }
        return place(session.name) != .background
    }

    /// Every attach id LIVE in a session's member windows (trees + docks).
    func liveAttachIds(of name: String) -> Set<String> {
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
    /// remembers about a pane once its views release. No entry is ever added or
    /// dropped here.
    private func refreshLiveFacts() {
        for (name, session) in workspaces {
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
            workspaces[name]!.tabs = tabs
        }
    }

    private func refreshFacts(_ pane: inout Registry.Pane, from view: Ghostty.SurfaceView) {
        if let pwd = view.pwd { pane.cwd = pwd }
        if let title = capturedTitle(of: view) { pane.title = title }
    }

    func refreshWorkspaceRevisions() {
        for name in Array(workspaces.keys) {
            let shape = VigilSessionControl.revision(workspaces[name]!.tabs)
            if workspaces[name]!.layoutShape != shape {
                workspaces[name]!.layoutShape = shape
                workspaces[name]!.layoutRevision = UUID().uuidString
            }
        }
    }

    private var saveScheduled = false
    private var persisting = false
    private var lastSaved: Data?

    /// One save per runloop turn however many edits it held; a save's own
    /// bookkeeping (refreshLiveFacts) never schedules another.
    private func savePending() {
        guard !saveScheduled, !persisting else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.persist(publish: true, onlyIfChanged: true)
        }
    }

    /// `onlyIfChanged`: the scheduled save, which writes and publishes
    /// nothing when the registry encodes to the bytes already on disk.
    func persist(publish: Bool = true, onlyIfChanged: Bool = false) {
        persisting = true
        if publish { refreshLiveFacts() }
        refreshWorkspaceRevisions()
        persisting = false
        var entries = workspaces.values.map {
            Registry.Workspace(name: $0.name, label: $0.label, emoji: $0.emoji, cwd: $0.cwd, tabs: $0.tabs, order: $0.order, pinned: $0.pinned, sidebar: $0.sidebar, buriedUntil: nil, foreground: isForeground($0), paneSeq: $0.paneSeq, layoutRevision: $0.layoutRevision)
        }
        entries += graveyard.values.map {
            Registry.Workspace(name: $0.name, label: $0.label, emoji: $0.emoji, cwd: $0.cwd, tabs: $0.tabs, order: $0.order, pinned: $0.pinned, sidebar: $0.sidebar, buriedUntil: graveyardDeadlines[$0.name], foreground: false, paneSeq: $0.paneSeq, layoutRevision: $0.layoutRevision, buriedFrom: $0.buriedFrom)
        }
        entries.sort { $0.name < $1.name }
        guard let data = try? JSONEncoder().encode(entries) else {
            registryLog.error("registry not encoded")
            return
        }
        if onlyIfChanged, data == lastSaved { return }
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
        do {
            try data.write(to: persistURL, options: .atomic)
        } catch {
            registryLog.error("registry not saved", ["err": error])
            return
        }
        lastSaved = data
        if publish {
            syncWindowMarks()
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }

    /// Tab regroups in flight (mount's one-tick native-tab batches): while
    /// any is pending, the tab bar must NOT be force-toggled - see
    /// enforceTabBar.
    var regroupsInFlight = 0

    /// `.preferred` biases grouping; the bar itself is forced via the tab
    /// group's public visibility. NEVER while a regroup is in flight:
    /// toggleTabBar during the same transition AppKit uses to install the
    /// group's own bar leaves TWO bars stacked on one titlebar (a stale
    /// solo bar occluding the real tabs, misrouting every click on the
    /// strip by a few pixels; the accessibility tree shows both). Existing
    /// duplicates heal
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
            // tabs - no hover feedback, dead clicks on the whole strip.
            // Keep the newest (add order),
            // strip the rest; re-sync next tick re-forces if needed.
            viewportLog.warn("stacked tab bars healed", ["bars": bars.count])
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
                viewportLog.warn("several tab bar views on one titlebar", ["bars": census])
                let expected = group.windows.count
                let live = tabBars.filter { bar in
                    var buttons: [NSView] = []
                    Self.collectDescendants(of: bar, className: "NSTabButton", into: &buttons)
                    return buttons.count == expected
                }
                if live.count == 1 {
                    for bar in tabBars where bar !== live[0] {
                        viewportLog.warn("corpse tab bar removed", ["frame": "\(bar.frame)"])
                        bar.removeFromSuperview()
                    }
                } else {
                    viewportLog.warn("live tab bar not identified; left alone", ["tabs": expected])
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

    /// Tab presentation. "sidebar" (the default): the sidebar IS the tab
    /// UI — a mount places only the anchored tab, sibling tabs stay warm in
    /// the held cache or captured (a sidebar row click mounts them), no
    /// native tab bar, so a session switch is ONE tree swap with zero
    /// window churn (a regroup creates and destroys a window per sibling
    /// tab on every click). "native" restores ghostty's regular tab windows and
    /// the forced bar: `defaults write com.mitchellh.ghostty.debug
    /// vigil.tabs native`.
    var nativeTabs: Bool {
        let raw = UserDefaults.standard.string(forKey: "vigil.tabs")
        if let raw, raw != "native", raw != "sidebar", !Self.tabsModeWarned {
            Self.tabsModeWarned = true
            viewportLog.error("unknown vigil.tabs value; reading as sidebar", ["value": raw])
        }
        return raw == "native"
    }
    private static var tabsModeWarned = false

    /// Sidebar mode's counterpart to enforceTabBar: no bar, equally
    /// uniform height. Only a single-window group hides (AppKit pins the
    /// bar visible on real multi-tab groups; those collapse to one window
    /// as their workspaces re-mount in sidebar mode).
    private func retireTabBar(_ window: NSWindow) {
        window.tabbingMode = .automatic
        // enforceTabBar's rules apply here too: never toggle mid-regroup,
        // and decide from the ACCESSORY (the staged install's truth), never
        // the group flag alone, which lags it — a toggle in that gap is how
        // stacked corpse bars are born, and sidebar mode never runs the
        // healer.
        guard regroupsInFlight == 0,
              let group = window.tabGroup, group.windows.count == 1,
              let tw = window as? TerminalWindow else { return }
        let bars = tw.titlebarAccessoryViewControllers.filter { tw.isTabBar($0) }
        guard bars.count == 1, group.isTabBarVisible else { return }
        window.toggleTabBar(nil)
    }

    /// Idempotent: every session window carries the titlebar mark (face
    /// chip, pin, dock toggle) and its tab bar. One sync walks all windows;
    /// called from persist(), the chokepoint every state change already
    /// flows through (plus any window becoming key, for fresh windows).
    func syncWindowMarks() {
        let t0 = Date()
        defer {
            let ms = Date().timeIntervalSince(t0) * 1000
            if ms > 25 { viewportLog.warn("slow window marks sync", ["elapsed": Duration.milliseconds(ms)]) }
        }
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            // Real terminal windows only (skip corpses without a tree).
            guard window.isVisible || window.isMiniaturized else { continue }
            guard !controller.surfaceTree.isEmpty else { continue }

            let existing = window.titlebarAccessoryViewControllers
                .first { $0 is VigilTitlebarAccessory }

            // native mode: the bar is ALWAYS visible (one height
            // everywhere). sidebar mode: no bar at
            // all — equally uniform, and the sidebar carries the tabs.
            if nativeTabs { enforceTabBar(window) } else { retireTabBar(window) }

            let name = workspaceName(of: controller)

            // Enforce a session's stored pin intent on its live window
            // (covers resurrection/re-embed for free); session-less windows
            // keep their pure window-level pin.
            if let name, let session = workspaces[name] {
                applyPin(window, session.pinned)
            }
            // The tab bar wears the stored tab identity, refreshed at the
            // same chokepoint as every other window mark (mounts, swaps,
            // focus changes) so it can never drift from the sidebar row.
            syncTabTitle(controller)
            let pinned = name.map { workspacePinned($0) } ?? isPinned(controller)

            // Closures capture the controller WEAKLY: the accessory lives
            // on the window, so a strong capture is a window→accessory→
            // controller→window cycle that keeps closed windows resident.
            let mark = VigilWindowMark(
                label: name.flatMap { workspaces[$0]?.label },
                emoji: name.flatMap { workspaces[$0]?.emoji },
                pinned: pinned,
                dockOpen: dockMap.object(forKey: controller).map { !$0.collapsed } ?? false,
                onEditIdentity: name.map { n in { VigilIdentity.editModal(name: n) } },
                onTogglePin: { [weak self, weak controller] in
                    guard let controller else { return }
                    if let name {
                        self?.togglePinWorkspace(name)
                    } else {
                        self?.togglePin(controller)
                        self?.persist()
                    }
                },
                onToggleDock: name == nil ? nil : { [weak self, weak controller] in
                    guard let controller else { return }
                    self?.toggleDock(controller)
                })

            if let hosting = existing?.view as? NSHostingView<VigilWindowMark> {
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
        let dir = VigilPaths.panes
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
        var decoded = payload.flatMap { try? JSONDecoder().decode([Registry.Workspace].self, from: $0) }
        if decoded == nil {
            payload = try? Data(contentsOf: persistBackupURL)
            decoded = payload.flatMap { try? JSONDecoder().decode([Registry.Workspace].self, from: $0) }
            if decoded != nil {
                registryLog.error("registry unreadable; recovered from backup")
            }
        }
        guard let entries = decoded else { return }
        var seen = Set<String>()
        for entry in entries {
            var session = Workspace(
                name: entry.name,
                label: entry.label,
                emoji: entry.emoji,
                cwd: entry.cwd,
                tabs: entry.tabs ?? [],
                order: entry.order ?? 0)
            // One daemon = ONE pane: a registry claiming an id twice would
            // attach two surfaces to one socket (frames interleave into
            // garbage). The writer cannot produce this; a file that has it
            // screams.
            for id in session.tabs.flatMap(\.paneIds) where !seen.insert(id).inserted {
                registryLog.error("pane listed twice", ["workspace": entry.name, "pane": id])
            }
            // The counter must clear every index this session has ever
            // used: a mint that reuses an index inherits a dead pane's
            // resume pointer and resumes a long-dead conversation in a
            // fresh pane. The floor covers every index the STATE DIR has
            // ever seen.
            var maxIndex = Self.maxPaneIndexOnDisk(session: entry.name)
            for id in ownedPaneIds(session) {
                if let n = id.split(separator: "-").last.flatMap({ Int($0) }) {
                    maxIndex = max(maxIndex, n)
                }
            }
            session.paneSeq = max(entry.paneSeq ?? 0, maxIndex + 1)
            session.layoutRevision = entry.layoutRevision ?? UUID().uuidString
            session.layoutShape = VigilSessionControl.revision(session.tabs)
            session.pinned = entry.pinned ?? false
            session.sidebar = entry.sidebar
            session.foreground = entry.foreground ?? false
            session.thumbnail = NSImage(
                contentsOfFile: dumpsDir(entry.name).appendingPathComponent("thumb.png").path)
            if let deadline = entry.buriedUntil {
                // Buried across a relaunch: honor the remaining grace (the
                // daemons are still out there), reap immediately if spent.
                session.buriedFrom = entry.buriedFrom
                graveyard[entry.name] = session
                graveyardDeadlines[entry.name] = deadline
                let wait = max(deadline.timeIntervalSinceNow, 0) + 1
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.reapIfExpired(entry.name)
                }
            } else {
                workspaces[entry.name] = session
            }
        }
    }
}

extension TerminalController {
    /// A new tab in an existing window hosting an EXISTING split tree: the
    /// re-embed primitive for multi-tab workspaces (newWindow(tree:) is the
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
            // every terminal in sequence before the anchored one wins.
            // The anchored tab stays selected throughout; a silent tab
            // renders when first selected.
            anchorWindow.addTabbedWindowSafely(window, ordered: ordered)
        }
        return controller
    }
}
