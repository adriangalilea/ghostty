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
        /// VT dump (scrollback + screen) frozen at capture; replayed with
        /// `cat` on resurrection so the content survives, not just the shape.
        var dump: String?
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
        /// Live for embedded (refreshed on overview open), frozen at the
        /// moment of detach for detached. Runtime-only.
        var thumbnail: NSImage?
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
        linkClaudes(name: name, tree: controller.surfaceTree)
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
        becomeRegular()
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
        // Freeze the visual: the overview shows what the workspace looked
        // like at the moment it was released. The WHOLE window content: a
        // workspace is its splits, one pane is a lie.
        sessions[name]!.thumbnail = Self.windowSnapshot(controller)
            ?? (controller.focusedSurface ?? tree.root?.leftmostLeaf())?.asImage
        sessions[name]!.panes = capturePanes(name: name, tree)
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
            var command: String?
            if let pid = view.surfaceModel?.foregroundPID {
                let args = runCapture("/bin/ps", ["-o", "args=", "-p", String(pid)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let first = args.split(separator: " ").first.map(String.init) ?? ""
                let base = URL(fileURLWithPath: first).lastPathComponent
                let shells = ["fish", "bash", "zsh", "sh", "login"]
                if !args.isEmpty, !shells.contains(base), !base.hasPrefix("-") {
                    command = args
                }
            }
            var dump: String?
            let dumpPath = dir.appendingPathComponent("\(index).vt").path
            if view.surfaceModel?.vigilDump(to: dumpPath) == true {
                dump = dumpPath
            }
            panes.append(Pane(cwd: cwd, command: command, dump: dump))
        }
        return panes
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
    func refreshThumbnails() {
        for (name, session) in sessions {
            if case .embedded(let controller) = session.state {
                if let image = Self.windowSnapshot(controller) {
                    sessions[name]!.thumbnail = image
                }
            }
        }
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
                // State first, program second: replay the frozen content into
                // the fresh terminal, then bring the program back. The dump
                // path is our own slug-derived state dir, shell-safe.
                var parts: [String] = []
                if let dump = pane.dump, FileManager.default.fileExists(atPath: dump) {
                    parts.append("cat '\(dump)'")
                }
                if let command = pane.command {
                    if command.contains("claude"), !claudeAssigned {
                        claudeAssigned = true
                        parts.append("wake pane \(name)")
                    } else {
                        parts.append(command)
                    }
                }
                if !parts.isEmpty {
                    config.initialInput = parts.joined(separator: "; ") + "\n"
                }
                return config
            }

            let controller = TerminalController.newWindow(ghostty, withBaseConfig: configFor(panes[0]))
            sessions[name]!.state = .embedded(controller)
            if panes.count > 1 {
                // Splits wait a beat: the window presents async and a split
                // against an unhosted surface is dropped.
                let rest = Array(panes.dropFirst())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    var anchor = controller.surfaceTree.root?.leftmostLeaf()
                    for pane in rest {
                        guard let at = anchor else { break }
                        anchor = controller.newSplit(at: at, direction: .right, baseConfig: configFor(pane)) ?? anchor
                    }
                }
            }
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

    /// The full kill: whatever the state, after this the session and its
    /// processes are gone. Forget FIRST so nothing intercepts into a detach.
    /// The caller already confirmed; this path must never prompt again.
    func kill(name: String) {
        guard let session = sessions[name] else { return }
        forget(name: name)
        if case .embedded(let controller) = session.state {
            killController(controller)
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

    /// One-gesture detach for any window: adopts first when needed.
    func detachFrontWindow() {
        guard let controller = TerminalController.preferredParent else { return }
        let name = sessionName(of: controller) ?? adopt(controller: controller)
        detach(name: name)
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
            case .embedded, .detached: return true
            case .asleep: return false
            }
        }
        guard hasLive else { return false }

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
        let panes: [Pane]?
    }

    private func persist() {
        let entries = sessions.values.map { PersistedSession(name: $0.name, label: $0.label, cwd: $0.cwd, panes: $0.panes) }
            .sorted { $0.name < $1.name }
        let data = try! JSONEncoder().encode(entries)
        try? FileManager.default.createDirectory(
            at: persistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try! data.write(to: persistURL)
        syncWindowMarks()
    }

    /// Idempotent: every persistent embedded window carries the vigilance
    /// mark (eye + label titlebar pill), every other window carries none.
    /// One sync walks all windows; called from persist(), the chokepoint
    /// every state change already flows through.
    private func syncWindowMarks() {
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let existing = window.titlebarAccessoryViewControllers.enumerated()
                .first { $0.element is VigilTitlebarAccessory }
            if let name = sessionName(of: controller), let session = sessions[name] {
                let mark = VigilWindowMark(label: session.label)
                if let hosting = existing?.element.view as? NSHostingView<VigilWindowMark> {
                    hosting.rootView = mark
                } else {
                    let accessory = VigilTitlebarAccessory()
                    accessory.view = NSHostingView(rootView: mark)
                    accessory.layoutAttribute = .right
                    window.addTitlebarAccessoryViewController(accessory)
                }
            } else if let existing {
                window.removeTitlebarAccessoryViewController(at: existing.offset)
            }
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
                panes: entry.panes ?? [])
            session.thumbnail = NSImage(
                contentsOfFile: dumpsDir(entry.name).appendingPathComponent("thumb.png").path)
            sessions[entry.name] = session
        }
    }
}
