import AppKit

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
/// The durable state lives in the wake registry (~/.local/state/wake), which is
/// maintained event-driven by Claude Code hooks. This manager persists only the
/// session names + cwd so asleep sessions are listable and resurrectable.
@MainActor
class VigilSessionManager {
    static let shared = VigilSessionManager()

    enum State {
        case embedded(TerminalController)
        case detached(SplitTree<Ghostty.SurfaceView>)
        case asleep
    }

    struct Session {
        let name: String
        var cwd: String
        var state: State
    }

    private(set) var sessions: [String: Session] = [:]

    /// Set once at app launch by VigilStatusItem; needed to spawn windows.
    weak var ghosttyApp: Ghostty.App?

    private var persistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/wake/vigil.json")
    }

    private init() {
        load()
    }

    // MARK: Lifecycle

    /// Name a live window's workspace as a session. It stays embedded; the
    /// gain is identity: it becomes listable, detachable and resurrectable.
    func adopt(controller: TerminalController, name: String) {
        let cwd = controller.focusedSurface?.pwd
            ?? controller.surfaceTree.root?.leftmostLeaf().pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        sessions[name] = Session(name: name, cwd: cwd, state: .embedded(controller))
        persist()
    }

    /// Detach: the tree (ptys running) moves from the window to this manager.
    /// Emptying the controller's tree closes its window; our strong reference
    /// keeps every surface alive.
    func detach(name: String) {
        guard let session = sessions[name], case .embedded(let controller) = session.state else { return }
        let tree = controller.surfaceTree
        if let pwd = controller.focusedSurface?.pwd { sessions[name]!.cwd = pwd }
        sessions[name]!.state = .detached(tree)
        controller.surfaceTree = SplitTree()
        persist()
    }

    /// Open: focus if embedded, re-embed if detached, resurrect if asleep.
    func open(name: String) {
        guard let session = sessions[name] else { return }
        guard let ghostty = ghosttyApp else { return }

        switch session.state {
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
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = session.cwd
            config.environmentVariables["VIGIL_SESSION"] = name
            config.initialInput = "wake pane \(name)\n"
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
            sessions[name]!.state = .embedded(controller)
            NSApp.activate(ignoringOtherApps: true)
        }
        persist()
    }

    func forget(name: String) {
        // A detached tree dropped here releases its surfaces: processes die.
        // That is what forget means; wake's registry entry is not touched.
        sessions[name] = nil
        persist()
    }

    /// Sessions whose embedded window silently died collapse to asleep so the
    /// menu never lies about state.
    func reconcile() {
        for (name, session) in sessions {
            if case .embedded(let controller) = session.state, controller.window == nil {
                sessions[name]!.state = .asleep
            }
        }
    }

    // MARK: Persistence (names + cwd only; trees are runtime state)

    private struct PersistedSession: Codable {
        let name: String
        let cwd: String
    }

    private func persist() {
        let entries = sessions.values.map { PersistedSession(name: $0.name, cwd: $0.cwd) }
            .sorted { $0.name < $1.name }
        let data = try! JSONEncoder().encode(entries)
        try? FileManager.default.createDirectory(
            at: persistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try! data.write(to: persistURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistURL) else { return }
        guard let entries = try? JSONDecoder().decode([PersistedSession].self, from: data) else { return }
        for entry in entries {
            sessions[entry.name] = Session(name: entry.name, cwd: entry.cwd, state: .asleep)
        }
    }
}
