import AppKit
import FoundationModels

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
        case detached(SplitTree<Ghostty.SurfaceView>)
        case asleep
    }

    struct Session {
        let name: String
        var label: String
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
        persist()
        refineLabel(name: name, screen: surface?.cachedScreenContents.get() ?? "")
        return name
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

    func rename(name: String, label: String) {
        guard sessions[name] != nil else { return }
        sessions[name]!.label = label
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
        if sessions[slug] == nil { return slug }
        var n = 2
        while sessions["\(slug)-\(n)"] != nil { n += 1 }
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
    }

    private func persist() {
        let entries = sessions.values.map { PersistedSession(name: $0.name, label: $0.label, cwd: $0.cwd) }
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
            sessions[entry.name] = Session(name: entry.name, label: entry.label, cwd: entry.cwd, state: .asleep)
        }
    }
}
