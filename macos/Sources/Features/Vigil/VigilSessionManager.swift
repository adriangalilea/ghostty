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
        guard let controller = TerminalController.preferredParent else { return }
        let name = sessionName(of: controller) ?? persistFully(controller: controller)
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
        guard let name = sessionName(of: controller) else { return false }
        // An empty tree has nothing to detach; let the corpse close and the
        // session sleeps on its captured panes.
        if controller.surfaceTree.isEmpty {
            sessions[name]!.state = .asleep
            persist()
            return false
        }
        detach(name: name)
        return true
    }

    func sessionName(of controller: TerminalController) -> String? {
        sessions.values.first {
            if case .embedded(let c) = $0.state { return c === controller }
            return false
        }?.name
    }

    // MARK: Lifecycle

    /// Adopt the workspace of a live window as a session. Zero friction: no
    /// dialog, the name is derived from what the terminal already knows about
    /// itself (title beats cwd basename) and refined async by the on-device
    /// model. Rename later if it guessed wrong.
    @discardableResult
    func adopt(controller: TerminalController) -> String {
        let surface = controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
        let cwd = surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path

        let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
        let seed = title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title
        let name = uniqueName(from: seed)

        sessions[name] = Session(name: name, label: seed, cwd: cwd, state: .embedded(controller))
        sessions[name]!.panes = capturePanes(name: name, controller.surfaceTree)
        sessions[name]!.layout = Self.captureLayout(controller.surfaceTree)
        linkClaudes(name: name, tree: controller.surfaceTree)
        persist()
        refineLabel(name: name, screen: surface?.cachedScreenContents.get() ?? "")
        return name
    }

    /// A session born in vigil: the window spawns with VIGIL_SESSION in the
    /// shell env, so every claude launched inside inherits the identity and
    /// its hook events feed the attention queue from birth.
    ///
    /// Daemon-backed from birth: the shell (and everything launched in it)
    /// lives in a vigild daemon; the window is a disposable client. Close
    /// the window, quit the app, crash: the processes never notice, and the
    /// next attach replays the backlog. State preserved, not recreated.
    func create(cwd: String) {
        guard let ghostty = ghosttyApp else { return }
        let seed = URL(fileURLWithPath: cwd).lastPathComponent
        let name = uniqueName(from: seed)
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        // NATIVE: the surface's termio backend attaches to the daemon; no
        // shell trickery, no typed exec. The Zig core spawns the daemon on
        // first contact.
        config.vigilAttach = "vigil-\(name)-0"
        becomeRegular()
        let controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        sessions[name] = Session(name: name, label: seed, cwd: cwd, state: .embedded(controller))
        // The resurrect identity is known from birth: even a crash (no
        // detach, no capture) resurrects by reattach while the daemon lives.
        sessions[name]!.panes = [
            Pane(cwd: cwd, command: "\(Self.attachSentinel)vigil-\(name)-0", dump: nil)
        ]
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

    /// Argv that survives being typed into a shell verbatim: plain
    /// path/word characters only, nothing a shell reinterprets.
    static func shellSafe(_ arg: String) -> Bool {
        !arg.isEmpty && arg.allSatisfy {
            $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0)
        }
    }

    /// Move every capture+resume pane of a live session into its own
    /// daemon, IN PLACE: freeze content now, put a fresh daemon pane in
    /// the same spot (same cwd), and let the daemon type the restore line
    /// (content replay + program resume) once its shell truly booted (the
    /// daemon's own first-attach quiescence mechanism, via VIGILD_RESUME).
    /// The old processes die exactly as an app quit would have killed
    /// them; the difference is the resume happens here and now, and from
    /// then on the window survives everything.
    func upgrade(name: String) {
        guard let ghostty = ghosttyApp, let app = ghostty.app else { return }
        guard let session = sessions[name],
              case .embedded(let controller) = session.state else { return }
        let tree = controller.surfaceTree
        guard !Self.daemonBacked(tree) else { return }

        sessions[name]!.panes = capturePanes(name: name, tree)
        let panes = sessions[name]!.panes
        var claudeAssigned = false
        var nextIndex = nextPaneIndex(name: name, tree: tree)

        for (index, view) in tree.enumerated() {
            guard view.vigilAttachId == nil, index < panes.count else { continue }
            let pane = panes[index]

            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.cwd
            config.environmentVariables["VIGIL_SESSION"] = name
            config.vigilAttach = "vigil-\(name)-\(nextIndex)"
            nextIndex += 1

            var parts: [String] = []
            if let dump = pane.dump, FileManager.default.fileExists(atPath: dump) {
                parts.append("cat '\(dump)'")
            }
            if Self.isClaudePane(pane.command) {
                if !claudeAssigned {
                    claudeAssigned = true
                    parts.append("wake pane \(name)")
                }
            } else if let argv = pane.argv, argv.allSatisfy(Self.shellSafe) {
                parts.append(argv.joined(separator: " "))
            }
            if !parts.isEmpty {
                config.environmentVariables["VIGILD_RESUME"] = parts.joined(separator: "; ")
            }

            let newView = Ghostty.SurfaceView(app, baseConfig: config)
            guard let node = controller.surfaceTree.root?.node(view: view),
                  let newTree = try? controller.surfaceTree.replacing(node: node, with: .leaf(view: newView))
            else { continue }
            controller.surfaceTree = newTree
        }
        persist()
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
                if let dump = pane.dump, FileManager.default.fileExists(atPath: dump) {
                    parts.append("cat '\(dump)'")
                }
                if Self.isClaudePane(pane.command), !claudeAssigned {
                    claudeAssigned = true
                    parts.append("wake pane \(name)")
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
        guard sessions[name] != nil else { return }
        if case .floating = sessions[name]!.state, let quick = quickController(create: false) {
            quick.animateOut()
            reclaim(name, from: quick)
        }
        if case .embedded = sessions[name]!.state {
            detach(name: name)
        }
        var session = sessions[name]!
        // A detached tree in the graveyard keeps its surfaces (and for
        // recreation panes, their processes) alive until expiry or exhume.
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
        let vigildBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/vigild").path
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/vigild")
        // Boundary-safe match: pane ids are vigil-<name>-<index>, and a bare
        // prefix test murders innocent neighbors (vigil-2026- matched
        // vigil-2026-2-0, session "2026-2"'s live daemon; found live).
        let prefix = "vigil-\(name)-"
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        where entry.hasSuffix(".pid") {
            let stem = String(entry.dropLast(4))
            guard stem.hasPrefix(prefix),
                  stem.dropFirst(prefix.count).allSatisfy({ $0.isNumber })
            else { continue }
            runFireAndForget(vigildBin, ["kill", stem])
        }
        persist()
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

    /// Persistent MEANS survives everything: adopt + move every pane into
    /// daemons, one gesture. Two modes only (Adrian 2026-07-18): ephemeral
    /// or persistent, and persistent always reboots; the capture+resume
    /// middle class survives only as a fallback state (legacy sessions, a
    /// pane whose upgrade failed), never as a destination.
    @discardableResult
    func persistFully(controller: TerminalController) -> String {
        let name = adopt(controller: controller)
        upgrade(name: name)
        return name
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
        tabSiblings(controller).contains { sessionName(of: $0) != nil }
    }

    /// The eye toggle at window scope: if the window has any persistent tab,
    /// make the WHOLE window ephemeral (forget every tab); otherwise persist
    /// every tab. Everything in the window moves as one unit.
    func toggleWindowPersist(_ controller: TerminalController) {
        let siblings = tabSiblings(controller)
        if windowPersistent(controller) {
            for tab in siblings {
                if let name = sessionName(of: tab) { forget(name: name) }
            }
        } else {
            for tab in siblings where sessionName(of: tab) == nil {
                persistFully(controller: tab)
            }
        }
    }

    /// A new tab born in a persistent window inherits persistence from
    /// birth: this augments its surface config with a daemon attach id +
    /// VIGIL_SESSION so it comes up daemon-backed, and returns the session
    /// name to register once the controller exists. Returns nil when the
    /// parent window is ephemeral (the new tab stays ephemeral too).
    func newTabConfig(
        parent: TerminalController,
        base: Ghostty.SurfaceConfiguration?
    ) -> (config: Ghostty.SurfaceConfiguration, name: String)? {
        guard windowPersistent(parent) else { return nil }
        var config = base ?? Ghostty.SurfaceConfiguration()
        let cwd = config.workingDirectory
            ?? parent.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let seed = URL(fileURLWithPath: cwd).lastPathComponent
        let name = uniqueName(from: seed)
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        config.vigilAttach = "vigil-\(name)-0"
        return (config, name)
    }

    /// Register a freshly-created tab controller as a daemon-backed session
    /// (called by TerminalController.newTab right after it builds the tab
    /// with the config from newTabConfig).
    func registerTabSession(controller: TerminalController, name: String, cwd: String) {
        let seed = URL(fileURLWithPath: cwd).lastPathComponent
        sessions[name] = Session(name: name, label: seed, cwd: cwd, state: .embedded(controller))
        sessions[name]!.panes = [
            Pane(cwd: cwd, command: "\(Self.attachSentinel)vigil-\(name)-0", dump: nil)
        ]
        persist()
    }

    /// One-gesture detach for any window: persists the whole window first
    /// (every tab) when needed, then detaches every tab of the group.
    func detachFrontWindow() {
        guard let controller = TerminalController.preferredParent else { return }
        if !windowPersistent(controller) { persistFully(controller: controller) }
        for tab in tabSiblings(controller) {
            if let name = sessionName(of: tab) { detach(name: name) }
        }
    }

    /// The eye on/off toggle: flip the front window between persistent
    /// (survives quit) and ephemeral (dies on close), in place.
    func toggleFrontPersist() {
        guard let controller = TerminalController.preferredParent else { return }
        if let name = sessionName(of: controller) {
            forget(name: name)
        } else {
            persistFully(controller: controller)
        }
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
        let hasLive = sessions.values.contains {
            switch $0.state {
            case .embedded, .floating, .detached: return true
            case .asleep: return false
            }
        }
        guard hasLive else { return false }

        if let name = floatingName, let quick = quickController(create: false) {
            reclaim(name, from: quick)
        }
        for (name, session) in sessions {
            if case .embedded = session.state { detach(name: name) }
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

    /// Sessions whose embedded window silently died collapse to asleep so the
    /// menu never lies about state. Windows left with an EMPTY tree (observed
    /// zombie: blank window, no surfaces, 2026-07-17) are corpses; close them.
    func reconcile() {
        for (name, session) in sessions {
            if case .embedded(let controller) = session.state, controller.window == nil {
                sessions[name]!.state = .asleep
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
    private func uniqueName(from seed: String) -> String {
        var slug = seed.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch == "-" && out.hasSuffix("-") { return }
                out.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 24 { slug = String(slug.prefix(24)) }
        if slug.isEmpty { slug = "session" }
        func taken(_ s: String) -> Bool { sessions[s] != nil || graveyard[s] != nil }
        if !taken(slug) { return slug }
        var n = 2
        while taken("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
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
        var entries = sessions.values.map {
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
            let persistent = name != nil
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
            // Survival class lives on the titlebar pill's color only. NO
            // window border: injecting a subview into the private frame view
            // (NSThemeFrame) destabilized window teardown (cmd+W left blank
            // zombie windows, 2026-07-18). The pill is a native accessory,
            // safe; the ring was a hack, gone.
        }
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
