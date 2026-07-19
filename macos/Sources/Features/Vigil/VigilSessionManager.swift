import AppKit
import FoundationModels
import SwiftUI

/// vigil: sessions as a first-class native concept.
///
/// A session is a named workspace, one SplitTree of surfaces. It is in exactly
/// one of three states:
///   embedded  showing in a window (a TerminalController owns the tree)
///   detached  alive with no window (this manager strongly owns the tree,
///             ptys running; the same primitive undo-close uses, minus the timer)
///   asleep    no live surfaces (app relaunch/reboot); only the registry entry
///             remains and opening resurrects via `wake pane <name>`, which
///             resumes the registered claude conversation
///
/// Identity is pointer-not-value: `name` is the stable key (slug, feeds
/// VIGIL_SESSION and the wake registry), `label` is the human display name,
/// auto-derived at adopt (zero naming friction) and refined async by the
/// on-device model when available. Rename touches only the label.
///
/// Durable state lives in the wake registry (~/.local/state/wake), maintained
/// event-driven by Claude Code hooks. This manager persists name + label + cwd
/// so asleep sessions are listable and resurrectable.
@MainActor
class VigilSessionManager {
    static let shared = VigilSessionManager()

    enum State {
        case embedded(TerminalController)
        /// Hosted by the quick terminal (Quake-style peek); the quick
        /// terminal owns the tree while it floats.
        case floating
        case detached(SplitTree<Ghostty.SurfaceView>)
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
    /// ran in it. A claude pane resurrects via `wake pane` (resume); stateless
    /// tools (lazygit, logs) resurrect by re-running their command; a bare
    /// shell resurrects as a bare shell.
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

    /// Recursive shape of a workspace. Pane indices refer to Session.panes,
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

    struct Session {
        let name: String
        var label: String
        var cwd: String
        var state: State
        var attention: Attention = .none
        var attentionSince: Date?
        /// Captured at detach; what resurrection rebuilds.
        var panes: [Pane] = []
        /// The split shape of those panes; nil = single pane or legacy entry.
        var layout: Layout?
        /// Manual overview ordering (drag & drop); lower first.
        var order: Int = 0
        /// Pinned-on-top intent, persisted: applied to the window whenever
        /// the session is embedded (open/re-embed/resurrect), so a pin
        /// survives detach, quit and reboot, and a detached/asleep session
        /// can be pinned before it even has a window.
        var pinned: Bool = false
        /// Survival policy. Ephemeral (false): the daemon is killed on window
        /// close and on quit, and the session is never written to vigil.json.
        /// Persistent (true): survives close/quit/reboot and wears the class
        /// border. ⌘⇧P flips this in place; the daemon keeps running either
        /// way, so there is never a restart.
        var persistent: Bool = false
        /// A buried ephemeral window (no session identity): exhumes to a
        /// plain window, never persisted. Runtime-only.
        var ephemeral: Bool = false
        /// Live for embedded (refreshed on overview open), frozen at the
        /// moment of detach for detached. Runtime-only.
        var thumbnail: NSImage?
    }

    private(set) var sessions: [String: Session] = [:]

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
        reapOrphanDaemons()
        startEventWatcher()
        // Fresh ephemeral windows must wear their ring without waiting for
        // a session state change: any window becoming key re-syncs marks
        // (idempotent, walks a handful of windows).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard notification.object is NSWindow else { return }
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
    }

    /// Join key for claudes born without a container env (adopted windows):
    /// the event's tty against every session surface's ttyName.
    private func sessionMatching(tty: String) -> String? {
        guard tty.count > 2, tty != "??" else { return nil }
        for (name, session) in sessions {
            let tree: SplitTree<Ghostty.SurfaceView>?
            switch session.state {
            case .embedded(let controller): tree = controller.surfaceTree
            case .floating: tree = quickController(create: false)?.surfaceTree
            case .detached(let detachedTree): tree = detachedTree
            case .asleep: tree = nil
            }
            guard let tree else { continue }
            for view in tree where view.surfaceModel?.ttyName?.hasSuffix(tty) == true {
                return name
            }
        }
        return nil
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
            let name: String
            if sessions[event.container] != nil {
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

    // MARK: Floating (the quick terminal hosts a session)

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
    /// you are in right now (persisting it first if it was ephemeral, since
    /// only sessions can float). That last fallback is why the key felt
    /// dead: with nothing pending it used to no-op.
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

    /// Host a session in the quick terminal. Embedded sessions surrender
    /// their window first (a detach, capture included); asleep ones
    /// resurrect into a real window instead (a rebuild belongs in a
    /// workspace, not a peek).
    func float(name: String) {
        guard let session = sessions[name] else { return }
        guard let quick = quickController(create: true) else { return }

        let tree: SplitTree<Ghostty.SurfaceView>
        switch session.state {
        case .embedded:
            detach(name: name)
            guard case .detached(let detachedTree) = sessions[name]!.state else { return }
            tree = detachedTree
        case .floating:
            sessions[name]!.attention = .none
            sessions[name]!.attentionSince = nil
            onAttentionChange?()
            quick.animateIn()
            return
        case .detached(let detachedTree):
            tree = detachedTree
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

        sessions[name]!.state = .floating
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
    /// and the quick terminal gets its own stashed workspace back.
    func reclaim(_ name: String, from quick: QuickTerminalController) {
        guard floatingName == name else { return }
        floatingName = nil
        let tree = quick.surfaceTree
        if sessions[name] != nil {
            if tree.isEmpty {
                sessions[name]!.state = .asleep
            } else {
                sessions[name]!.panes = capturePanes(name: name, tree)
                sessions[name]!.layout = Self.captureLayout(tree)
                sessions[name]!.state = .detached(tree)
            }
        }
        quickTreeSwap = true
        quick.surfaceTree = stashedQuickTree ?? SplitTree()
        quickTreeSwap = false
        stashedQuickTree = nil
        persist()
    }

    /// Closing an adopted session's window means detach, not kill. Returns
    /// true when handled (the close must be swallowed by the caller).
    func handleWindowClose(controller: TerminalController) -> Bool {
        guard let name = sessionName(of: controller) else {
            vlog("handleWindowClose: controller has NO session -> not handled (window closes plain)")
            return false
        }
        let persistent = sessions[name]!.persistent
        let empty = controller.surfaceTree.isEmpty
        vlog("handleWindowClose: '\(name)' persistent=\(persistent) emptyTree=\(empty)")
        if empty {
            if persistent { sessions[name]!.state = .asleep }
            else { killDaemons(name: name); sessions[name] = nil }
            persist()
            return false
        }
        // Persistent keeps running detached; ephemeral gets a 120s undo grace
        // then its daemon dies (kill's burial).
        if persistent { detach(name: name) } else { kill(name: name) }
        return true
    }

    func sessionName(of controller: TerminalController) -> String? {
        sessions.values.first {
            if case .embedded(let c) = $0.state { return c === controller }
            return false
        }?.name
    }

    // MARK: Lifecycle

    /// Set a session's survival policy directly (menu entry point). Flag flip,
    /// no restart.
    func setPersistent(name: String, _ value: Bool) {
        guard sessions[name] != nil else { return }
        sessions[name]!.persistent = value
        if value, case .embedded(let c) = sessions[name]!.state {
            refineLabel(name: name, screen: c.focusedSurface?.cachedScreenContents.get() ?? "")
        }
        persist()
    }

    /// Stamp a fresh window's config so it is daemon-backed from birth (a
    /// vigild attach id + VIGIL_SESSION). Returns nil when the config already
    /// carries an attach id (create / resurrection / tab already handled it),
    /// so this only augments plain windows (⌘N, the startup window, dock
    /// reopen). Pair with registerEphemeralSession once the controller exists.
    func newWindowConfig(
        base: Ghostty.SurfaceConfiguration?
    ) -> (config: Ghostty.SurfaceConfiguration, name: String, cwd: String)? {
        if base?.vigilAttach != nil { return nil }
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
        var session = Session(name: name, label: name, cwd: cwd, state: .embedded(controller))
        session.panes = [Pane(cwd: cwd, command: "\(Self.attachSentinel)vigil-\(name)-0", dump: nil)]
        sessions[name] = session
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
        var session = Session(name: name, label: name, cwd: cwd, state: .embedded(controller))
        session.panes = [Pane(cwd: cwd, command: "\(Self.attachSentinel)vigil-\(name)-0", dump: nil)]
        sessions[name] = session // persistent defaults false → ephemeral
        vlog("born(create): '\(name)' cwd=\(cwd)")
        persist()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pane commands with this prefix are daemon attach ids, not shell
    /// commands; resurrection sets the surface's native attach config.
    static let attachSentinel = "vigil-attach:"

    /// Splits inside a persistent session are daemon-backed: called by the
    /// split path for EVERY split; passes through untouched unless this
    /// controller is a persistent session. The pane id derives from the
    /// highest existing id (live tree + persisted panes), so it never
    /// collides across resurrections. cwd inherits from the split's origin
    /// pane so the daemon shell starts where you were.
    func configForNewSplit(
        in controller: BaseTerminalController,
        from oldView: Ghostty.SurfaceView,
        base: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceConfiguration? {
        guard let terminal = controller as? TerminalController,
              let name = sessionName(of: terminal) else { return base }
        var config = base ?? Ghostty.SurfaceConfiguration()
        guard config.vigilAttach == nil else { return config }

        config.vigilAttach = "vigil-\(name)-\(nextPaneIndex(name: name, tree: terminal.surfaceTree))"
        config.environmentVariables["VIGIL_SESSION"] = name
        if config.workingDirectory == nil {
            config.workingDirectory = oldView.pwd
        }
        return config
    }

    /// The next free daemon pane index for a session: max over live attach
    /// ids and captured attach sentinels, plus one. Collision-free across
    /// resurrections and upgrades.
    private func nextPaneIndex(name: String, tree: SplitTree<Ghostty.SurfaceView>) -> Int {
        func paneIndex(_ id: String) -> Int? {
            id.split(separator: "-").last.flatMap { Int($0) }
        }
        var maxIndex = 0
        for view in tree {
            if let id = view.vigilAttachId, let n = paneIndex(id) { maxIndex = max(maxIndex, n) }
        }
        for pane in sessions[name]?.panes ?? [] {
            if let cmd = pane.command, cmd.hasPrefix(Self.attachSentinel),
               let n = paneIndex(String(cmd.dropFirst(Self.attachSentinel.count))) {
                maxIndex = max(maxIndex, n)
            }
        }
        return maxIndex + 1
    }

    /// Detach: the tree (ptys running) moves from the window to this manager.
    /// Emptying the controller's tree closes its window; our strong reference
    /// keeps every surface alive.
    func detach(name: String) {
        guard let session = sessions[name], case .embedded(let controller) = session.state else { return }
        let tree = controller.surfaceTree
        if let pwd = controller.focusedSurface?.pwd { sessions[name]!.cwd = pwd }
        // Freeze the visual: the overview shows what the workspace looked
        // like at the moment it was released. The WHOLE window content: a
        // workspace is its splits, one pane is a lie.
        sessions[name]!.thumbnail = Self.windowSnapshot(controller)
            ?? (controller.focusedSurface ?? tree.root?.leftmostLeaf())?.asImage
        sessions[name]!.panes = capturePanes(name: name, tree)
        sessions[name]!.layout = Self.captureLayout(tree)
        linkClaudes(name: name, tree: tree)
        sessions[name]!.state = .detached(tree)
        controller.surfaceTree = SplitTree()
        // The frozen visual survives relaunch too: asleep sessions keep their
        // face in the overview.
        if let thumb = sessions[name]!.thumbnail,
           let tiff = thumb.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dumpsDir(name).appendingPathComponent("thumb.png"))
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
    /// its captured panes: all attach sentinels = daemons waiting).
    func daemonBacked(session: Session) -> Bool {
        switch session.state {
        case .embedded(let controller):
            return Self.daemonBacked(controller.surfaceTree)
        case .floating:
            guard let quick = quickController(create: false) else { return false }
            return Self.daemonBacked(quick.surfaceTree)
        case .detached(let tree):
            return Self.daemonBacked(tree)
        case .asleep:
            return !session.panes.isEmpty && session.panes.allSatisfy {
                $0.command?.hasPrefix(Self.attachSentinel) == true
            }
        }
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

    /// What is running where, plus what was on screen, for resurrection. The
    /// foreground process of a pane is its command; a bare shell reads as nil.
    /// Every pane's content (scrollback + screen) is frozen as a VT dump.
    private func capturePanes(name: String, _ tree: SplitTree<Ghostty.SurfaceView>) -> [Pane] {
        let dir = dumpsDir(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var panes: [Pane] = []
        for (index, view) in tree.enumerated() {
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

    private func runCapture(_ bin: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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
            guard case .embedded(let controller) = session.state else { continue }
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
    func open(name: String) {
        guard let session = sessions[name] else { return }
        guard let ghostty = ghosttyApp else { return }

        // Opening is the acknowledge: attention clears here and only here.
        sessions[name]!.attention = .none
        sessions[name]!.attentionSince = nil
        onAttentionChange?()
        becomeRegular()

        switch session.state {
        case .floating:
            quickController(create: false)?.animateIn()

        case .embedded(let controller):
            guard let window = controller.window else {
                // The window died without us noticing (closed by hand). Treat as asleep.
                sessions[name]!.state = .asleep
                open(name: name)
                return
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

        case .detached(let tree):
            let controller = TerminalController.newWindow(ghostty, tree: tree, confirmUndo: false)
            sessions[name]!.state = .embedded(controller)
            NSApp.activate(ignoringOtherApps: true)

        case .asleep:
            // Rebuild the whole workspace: every captured pane comes back in
            // its cwd. The claude pane resumes via wake pane; other commands
            // re-run (stateless tools ARE their command); shells come back
            // bare. One claude resume per session, the registry has one uuid.
            var panes = session.panes
            if panes.isEmpty { panes = [Pane(cwd: session.cwd, command: "claude")] }
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

            let firstIndex = session.layout?.firstLeaf ?? 0
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: configFor(panes[firstIndex]))
            sessions[name]!.state = .embedded(controller)
            if panes.count > 1 {
                // Splits wait a beat: the window presents async and a split
                // against an unhosted surface is dropped.
                let layout = session.layout
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    guard let anchor = controller.surfaceTree.root?.leftmostLeaf() else { return }
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
            NSApp.activate(ignoringOtherApps: true)
        }
        persist()
    }

    /// Modal-less cycling, cmd+backtick with the overview's order: focus
    /// moves through LIVE windows only (embedded sessions by manual order,
    /// ephemeral windows last), wrapping. Opening a detached or asleep
    /// session is a deliberate act (overview, Next, the menu); a focus
    /// cycle key must never resurrect windows as a side effect (shipped
    /// that way first; every press materialized another sleeping session).
    func cycle() {
        reconcile()
        let sessionWindows = sessions.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .compactMap { session -> TerminalController? in
                if case .embedded(let controller) = session.state,
                   controller.window != nil { return controller }
                return nil
            }
        let ring = sessionWindows + ephemeralControllers()
        guard !ring.isEmpty else { return }

        var current = -1
        if let key = NSApp.keyWindow {
            current = ring.firstIndex { $0.window === key } ?? -1
        }
        if current == -1, let front = TerminalController.preferredParent {
            current = ring.firstIndex { $0 === front } ?? -1
        }

        let target = ring[(current + 1) % ring.count]
        guard let window = target.window else { return }
        NSLog("vigil: cycle %d -> %d of %d (%@)",
              current, (current + 1) % ring.count, ring.count,
              sessionName(of: target) ?? "ephemeral")
        becomeRegular()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
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

    /// Ephemeral windows have no registry entry, so their overview name is
    /// a runtime override keyed by the controller (lost on close, like the
    /// window itself). Lets the default launch window be named too.
    private var ephemeralLabels: [ObjectIdentifier: String] = [:]

    func ephemeralLabel(_ controller: TerminalController) -> String? {
        ephemeralLabels[ObjectIdentifier(controller)]
    }

    func renameEphemeral(_ controller: TerminalController, _ label: String) {
        ephemeralLabels[ObjectIdentifier(controller)] = label
    }

    /// State-honest removal. embedded: unadopt, the window returns to being a
    /// normal (ephemeral) window (nothing dies; closing it later kills
    /// normally). detached: kill, dropping the only reference releases the
    /// surfaces and the processes die. asleep: forget the registry entry.
    /// wake's own registry is never touched.
    func forget(name: String) {
        sessions[name] = nil
        try? FileManager.default.removeItem(at: dumpsDir(name))
        persist()
        onAttentionChange?()
    }

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
        // The buried tree keeps its daemons alive until expiry or exhume. An
        // ephemeral session's burial is not written to vigil.json.
        session.ephemeral = !session.persistent
        sessions[name] = nil
        session.attention = .none
        graveyard[name] = session
        graveyardDeadlines[name] = Date().addingTimeInterval(Self.killGrace)
        persist()
        onAttentionChange?()

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
    /// looking at); otherwise the front terminal's session; a plain
    /// ephemeral window dies as an ephemeral kill. Always confirmed first
    /// (a keystroke that kills processes must ask), then undo grace.
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

    /// Undo of a kill: back from the graveyard, everything still running.
    func exhume(_ name: String) {
        guard let session = graveyard.removeValue(forKey: name) else { return }
        graveyardDeadlines[name] = nil
        if session.ephemeral {
            if case .detached(let tree) = session.state, let ghostty = ghosttyApp {
                becomeRegular()
                _ = TerminalController.newWindow(ghostty, tree: tree, confirmUndo: false)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        sessions[name] = session
        persist()
        open(name: name)
    }

    /// Ephemeral windows get the same courtesy as sessions: kill holds the
    /// live tree buried for the grace, undo brings the window back intact.
    /// Runtime-only: an app death kills their processes regardless.
    private var closedCounter = 0
    func killEphemeral(_ controller: TerminalController) {
        let tree = controller.surfaceTree
        guard !tree.isEmpty else {
            killController(controller)
            return
        }
        let surface = controller.focusedSurface ?? tree.root?.leftmostLeaf()
        let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
        let cwd = surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        closedCounter += 1
        let name = "closed-\(closedCounter)"
        killController(controller)

        var session = Session(
            name: name,
            label: title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title,
            cwd: cwd,
            state: .detached(tree))
        session.ephemeral = true
        graveyard[name] = session
        graveyardDeadlines[name] = Date().addingTimeInterval(Self.killGrace)

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.undoManager.registerUndo(
                withTarget: self,
                expiresAfter: .seconds(Int64(Self.killGrace))
            ) { manager in
                manager.exhume(name)
            }
            appDelegate.undoManager.setActionName("Close Window")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace + 1) { [weak self] in
            self?.reapIfExpired(name)
        }
    }

    /// The grace ran out: now the kill actually happens. Dropping the
    /// buried tree releases surfaces (recreation processes die) and every
    /// pane daemon is killed.
    /// Reap NOW, before the grace expires: the daemons die immediately and
    /// the burial is dropped. For "get this out of my face" from the
    /// overview instead of waiting out the 120s.
    func reapNow(_ name: String) {
        graveyardDeadlines[name] = Date.distantPast
        reapIfExpired(name)
    }

    private func reapIfExpired(_ name: String) {
        guard let deadline = graveyardDeadlines[name], Date() >= deadline else { return }
        graveyard[name] = nil
        graveyardDeadlines[name] = nil
        try? FileManager.default.removeItem(at: dumpsDir(name))
        killDaemons(name: name)
        persist()
    }

    /// Kill every pane daemon of a session (vigil-<name>-<index>).
    private func killDaemons(name: String) {
        let vigildBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/vigild").path
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/vigild")
        // Boundary-safe match: a bare prefix test murders innocent neighbors
        // (vigil-2026- would match vigil-2026-2-0, session "2026-2").
        let prefix = "vigil-\(name)-"
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        where entry.hasSuffix(".pid") {
            let stem = String(entry.dropLast(4))
            guard stem.hasPrefix(prefix),
                  stem.dropFirst(prefix.count).allSatisfy({ $0.isNumber })
            else { continue }
            runFireAndForget(vigildBin, ["kill", stem])
        }
    }

    /// Silent, total window kill: emptying the tree closes the window without
    /// ghostty's own close confirmation (same mechanism detach uses), and with
    /// no reference kept the surfaces free and the processes die.
    func killController(_ controller: TerminalController) {
        controller.surfaceTree = SplitTree()
    }

    /// Every terminal window NOT adopted as a session: the ephemeral ones.
    /// The overview shows all of ghostty, not just what vigil owns; ephemeral
    /// vs persistent is a toggle, not a boundary. On-screen windows only:
    /// ghostty retains closed windows for undo-close, and those corpses must
    /// not haunt the overview (observed: closed-via-X window as a card).
    func ephemeralControllers() -> [TerminalController] {
        let adopted = sessions.values.compactMap { session -> TerminalController? in
            if case .embedded(let controller) = session.state { return controller }
            return nil
        }
        return TerminalController.all.filter { controller in
            guard let window = controller.window else { return false }
            guard window.isVisible || window.isMiniaturized else { return false }
            guard !controller.surfaceTree.isEmpty else { return false }
            return !adopted.contains { $0 === controller }
        }
    }

    /// Mark the window's session persistent (survives close/quit/reboot). The
    /// window is already daemon-backed, so this only flips the flag.
    func persistFully(controller: TerminalController) {
        guard let name = sessionName(of: controller) else { return }
        sessions[name]?.persistent = true
        refineLabel(name: name,
            screen: controller.focusedSurface?.cachedScreenContents.get() ?? "")
        persist()
    }

    // MARK: Window scope = the whole tabGroup

    /// Every tab-controller sharing a window (tabGroup) with this one, this
    /// one included. A session's scope is the WINDOW: what you do to one tab
    /// applies to all (Adrian 2026-07-18, the tab data-loss bug).
    private func tabSiblings(_ controller: TerminalController) -> [TerminalController] {
        guard let group = controller.window?.tabGroup?.windows, !group.isEmpty else {
            return [controller]
        }
        let siblings = group.compactMap { $0.windowController as? TerminalController }
        return siblings.isEmpty ? [controller] : siblings
    }

    /// True when ANY tab in the window is a persistent session.
    func windowPersistent(_ controller: TerminalController) -> Bool {
        tabSiblings(controller).contains {
            guard let name = sessionName(of: $0) else { return false }
            return sessions[name]?.persistent == true
        }
    }

    /// The eye toggle at window scope: flip every tab of the window between
    /// persistent and ephemeral as one unit. A pure flag flip, no restart:
    /// the daemons keep running, only their survival policy changes.
    func toggleWindowPersist(_ controller: TerminalController) {
        let makePersistent = !windowPersistent(controller)
        for tab in tabSiblings(controller) {
            guard let name = sessionName(of: tab) else { continue }
            sessions[name]?.persistent = makePersistent
            if makePersistent {
                refineLabel(name: name,
                    screen: tab.focusedSurface?.cachedScreenContents.get() ?? "")
            }
        }
        persist()
    }

    /// Every new tab is daemon-backed from birth (like every window): this
    /// augments its surface config with a daemon attach id + VIGIL_SESSION and
    /// returns the name to register once the controller exists.
    func newTabConfig(
        parent: TerminalController,
        base: Ghostty.SurfaceConfiguration?
    ) -> (config: Ghostty.SurfaceConfiguration, name: String)? {
        var config = base ?? Ghostty.SurfaceConfiguration()
        let cwd = config.workingDirectory
            ?? parent.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let name = newSessionId()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = "vigil-\(name)-0"
        return (config, name)
    }

    /// Register a freshly-created tab controller as a session. It inherits the
    /// window's survival class (window scope): persistent iff a sibling tab is.
    func registerTabSession(controller: TerminalController, name: String, cwd: String) {
        var session = Session(name: name, label: name, cwd: cwd, state: .embedded(controller))
        session.panes = [
            Pane(cwd: cwd, command: "\(Self.attachSentinel)vigil-\(name)-0", dump: nil)
        ]
        session.persistent = tabSiblings(controller).contains {
            guard let n = sessionName(of: $0), n != name else { return false }
            return sessions[n]?.persistent == true
        }
        sessions[name] = session
        persist()
    }

    /// One-gesture detach for any window: detaching means keep-running-in-the-
    /// background, which is what persistent is, so every tab is marked
    /// persistent then detached as one group.
    func detachFrontWindow() {
        guard let controller = TerminalController.preferredParent else { return }
        for tab in tabSiblings(controller) {
            guard let name = sessionName(of: tab) else { continue }
            sessions[name]?.persistent = true
            detach(name: name)
        }
        persist()
    }

    /// The eye on/off toggle: flip the front window between persistent
    /// (survives quit) and ephemeral (dies on close), in place.
    func toggleFrontPersist() {
        guard let controller = TerminalController.preferredParent else { return }
        toggleWindowPersist(controller) // window scope (whole tabGroup)
    }

    /// True when the front window is a persistent session.
    var frontWindowPersistent: Bool {
        guard let controller = TerminalController.preferredParent else { return false }
        return sessionName(of: controller) != nil
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

    /// Toggle pin for an ephemeral (session-less) window: pure window level.
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
    /// a live window gets it applied immediately.
    func togglePinSession(_ name: String) {
        guard sessions[name] != nil else { return }
        sessions[name]!.pinned.toggle()
        let pin = sessions[name]!.pinned
        if case .embedded(let controller) = sessions[name]!.state, let window = controller.window {
            applyPin(window, pin)
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
        // now, not on the next focus change. The session path already syncs via
        // persist(); the ephemeral togglePin() does not, so the keybind left a
        // stale icon (the window DID float, only the glyph lagged).
        syncWindowMarks()
    }

    /// True while quitting should mean "become a menu bar service" instead of
    /// dying. Flipped by quitForReal (the eye menu's explicit kill).
    private var reallyQuit = false

    /// Cmd+Q with sessions alive: detach every embedded session, close every
    /// other window (those processes die exactly as a normal quit would have
    /// killed them), vanish from the dock. Returns true when the termination
    /// must be cancelled.
    func interceptTermination() -> Bool {
        guard !reallyQuit else { return false }
        reconcile()

        if let name = floatingName, let quick = quickController(create: false) {
            reclaim(name, from: quick)
        }
        // Persistent sessions detach and keep running (service mode); ephemeral
        // ones die with the app. Snapshot names first: detach/remove mutate
        // sessions, which must not happen while iterating it.
        let persistentNames = Array(sessions.filter { $0.value.persistent }.keys)
        let ephemeralNames = Array(sessions.filter { !$0.value.persistent }.keys)
        for name in persistentNames {
            if case .embedded = sessions[name]?.state { detach(name: name) }
        }
        for name in ephemeralNames {
            killDaemons(name: name)
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
        case .embedded(let c): return c.window == nil ? "embedded(WINDOW=nil)" : "embedded"
        case .floating: return "floating"
        case .detached: return "detached"
        case .asleep: return "asleep"
        }
    }

    /// Scream (loudly, in the log) when a session is in a state that must never
    /// exist, so the impossible state is caught the moment it appears instead
    /// of guessed at. Does not crash: the caller self-heals and the app stays
    /// usable for repeated repro.
    func assertInvariants(_ site: String) {
        for (name, s) in sessions {
            if case .embedded(let c) = s.state, c.window == nil {
                vlog("!! IMPOSSIBLE [\(site)]: '\(name)' embedded but window==nil, persistent=\(s.persistent)")
            }
            if !s.persistent, case .asleep = s.state {
                vlog("!! IMPOSSIBLE [\(site)]: ephemeral '\(name)' is asleep")
            }
        }
    }

    /// Sessions whose embedded window silently died: persistent sleeps,
    /// ephemeral dies (its window IS its life). Empty-tree corpse windows close.
    func reconcile() {
        let orphaned = sessions.filter { _, session in
            if case .embedded(let controller) = session.state { return controller.window == nil }
            return false
        }
        for (name, session) in orphaned {
            vlog("reconcile: '\(name)' embedded window==nil, persistent=\(session.persistent) -> \(session.persistent ? "asleep" : "killed")")
            if session.persistent {
                sessions[name]!.state = .asleep
            } else {
                killDaemons(name: name)
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

    /// Slugified, deduped stable key from a human seed.
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

    // MARK: Persistence (identity + cwd only; trees are runtime state)

    private struct PersistedSession: Codable {
        let name: String
        let label: String
        let cwd: String
        let panes: [Pane]?
        let layout: Layout?
        let order: Int?
        let pinned: Bool?
        let buriedUntil: Date?
    }

    private func persist() {
        var entries = sessions.values.filter { $0.persistent }.map {
            PersistedSession(name: $0.name, label: $0.label, cwd: $0.cwd, panes: $0.panes, layout: $0.layout, order: $0.order, pinned: $0.pinned, buriedUntil: nil)
        }
        entries += graveyard.values.filter { !$0.ephemeral }.map {
            PersistedSession(name: $0.name, label: $0.label, cwd: $0.cwd, panes: $0.panes, layout: $0.layout, order: $0.order, pinned: $0.pinned, buriedUntil: graveyardDeadlines[$0.name])
        }
        entries.sort { $0.name < $1.name }
        let data = try! JSONEncoder().encode(entries)
        try? FileManager.default.createDirectory(
            at: persistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try! data.write(to: persistURL)
        syncWindowMarks()
    }

    /// Idempotent: every persistent embedded window carries the vigilance
    /// mark (eye + label titlebar pill, colored by survival class) and a
    /// matching content border; every other window carries none. One sync
    /// walks all windows; called from persist(), the chokepoint every
    /// state change already flows through (plus any window becoming key,
    /// for fresh ephemeral windows).
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
            // (covers resurrection/re-embed for free); ephemeral windows
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
                    // Window scope: the eye moves the WHOLE window (all its
                    // tabs) between persistent and ephemeral as one unit.
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
                panes: entry.panes ?? [],
                layout: entry.layout,
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

    /// At launch, kill any daemon no session owns. Ephemeral daemons never
    /// survive a clean quit, but a crash can leave one that `vigild restore`
    /// then respawns at login; with no owner it is a leak.
    private func reapOrphanDaemons() {
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/vigild")
        let vigildBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/vigild").path
        let owned = Set(sessions.keys).union(graveyard.keys)
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        where entry.hasSuffix(".pid") {
            let stem = String(entry.dropLast(4)) // vigil-<name>-<index>
            guard stem.hasPrefix("vigil-") else { continue }
            let body = stem.dropFirst("vigil-".count)
            guard let dash = body.lastIndex(of: "-"),
                  body[body.index(after: dash)...].allSatisfy({ $0.isNumber })
            else { continue }
            let name = String(body[..<dash])
            if !owned.contains(name) {
                runFireAndForget(vigildBin, ["kill", stem])
            }
        }
    }
}
