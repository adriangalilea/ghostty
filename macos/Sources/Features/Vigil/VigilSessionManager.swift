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

    /// Why a session wants Adrian. `input` (claude Notification: permission or
    /// question) outranks `done` (turn finished); FIFO within a rank. Cleared
    /// on open/next, never on mere glancing.
    enum Attention: Int {
        case none = 0
        case done = 1
        case input = 2
    }

    struct Session {
        let name: String
        var label: String
        var cwd: String
        var state: State
        var attention: Attention = .none
        var attentionSince: Date?
    }

    private(set) var sessions: [String: Session] = [:]

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

    /// The attention FIFO: open the most urgent session (input beats done,
    /// oldest first within a rank).
    func next() {
        let pending = sessions.values
            .filter { $0.attention != .none }
            .sorted {
                if $0.attention.rawValue != $1.attention.rawValue {
                    return $0.attention.rawValue > $1.attention.rawValue
                }
                return ($0.attentionSince ?? .distantPast) < ($1.attentionSince ?? .distantPast)
            }
        guard let session = pending.first else { return }
        open(name: session.name)
    }

    /// Closing an adopted session's window means detach, not kill. Returns
    /// true when handled (the close must be swallowed by the caller).
    func handleWindowClose(controller: TerminalController) -> Bool {
        guard let name = sessionName(of: controller) else { return false }
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
        persist()
        refineLabel(name: name, screen: surface?.cachedScreenContents.get() ?? "")
        return name
    }

    /// A session born in vigil: the window spawns with VIGIL_SESSION in the
    /// shell env, so every claude launched inside inherits the identity and
    /// its hook events feed the attention queue from birth.
    func create(cwd: String) {
        guard let ghostty = ghosttyApp else { return }
        let seed = URL(fileURLWithPath: cwd).lastPathComponent
        let name = uniqueName(from: seed)
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_SESSION"] = name
        let controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        sessions[name] = Session(name: name, label: seed, cwd: cwd, state: .embedded(controller))
        persist()
        NSApp.activate(ignoringOtherApps: true)
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

        // Opening is the acknowledge: attention clears here and only here.
        sessions[name]!.attention = .none
        sessions[name]!.attentionSince = nil
        onAttentionChange?()

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

    /// State-honest removal. embedded: unadopt, the window returns to being a
    /// normal window (nothing dies; closing it later kills normally).
    /// detached: kill, dropping the only reference releases the surfaces and
    /// the processes die. asleep: forget the registry entry.
    /// wake's own registry is never touched.
    func forget(name: String) {
        sessions[name] = nil
        persist()
        onAttentionChange?()
    }

    /// One-gesture detach for any window: adopts first when needed.
    func detachFrontWindow() {
        guard let controller = TerminalController.preferredParent else { return }
        let name = sessionName(of: controller) ?? adopt(controller: controller)
        detach(name: name)
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
