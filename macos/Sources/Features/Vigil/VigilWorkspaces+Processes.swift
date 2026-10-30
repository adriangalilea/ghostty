import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Process truth (the daemons' tree/died files, surfaced)

    var vigildStateDir: URL {
        VigilPaths.panes
    }

    /// A pane's daemon is alive exactly while it holds `<id>.lock`
    /// (vigild's liveness, PROTOCOL.md). A pidfile is a receipt for
    /// viewers and outlives a SIGKILL, so it never answers this.
    nonisolated static func daemonAlive(_ id: String) -> Bool {
        let path = VigilPaths.panes.appendingPathComponent("\(id).lock").path
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }

    /// Immutable file facts are loaded by the directory watcher off main.
    struct PaneState {
        let state: AgentState
        let flavor: BlockFlavor?
        let since: Date
        let revision: String
    }
    func paneFileLines(_ pane: String, _ ext: String) -> [String] {
        facts.files["panes/\(pane).\(ext)"]?.lines ?? []
    }

    /// argv column of a tree/died file. Line 1 is the daemon's child: a
    /// shell for an ordinary pane, the PROGRAM for a session-API pane
    /// (`/bin/sh -lc cmd` execs in place). Never skipped by position;
    /// `Program.label` nils shells by name.
    private func paneCommands(_ pane: String, _ ext: String) -> [String] {
        paneFileLines(pane, ext).map {
            $0.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? ""
        }
    }

    /// The label of the pane's deep foreground process (pidfile line 3,
    /// the tty's e_tpgid); nil = the shell itself holds the tty (a pane
    /// at its prompt).
    /// What a close would actually destroy, and the ONLY test any close
    /// confirm may use. Ghostty's `needsConfirmQuit` is meaningless here:
    /// every surface is daemon-backed, so its child shell always reads as a
    /// running process and EVERY close would ask, including a bare shell no
    /// vanilla ghostty would ever ask about. Vigil owns process truth (the
    /// daemon's pidfile line 3 = the deep foreground pid): a pane is busy
    /// only while a real program holds the tty, never a shell at its prompt.
    func busyPrograms(panes: [String]) -> [String] {
        panes.compactMap { paneForegroundLabel($0) }
    }

    /// The busy programs of everything a session owns.
    func busyPrograms(of name: String) -> [String] {
        guard let session = workspaces[name] else { return [] }
        return busyPrograms(panes: Array(ownedPaneIds(session)))
    }

    /// The busy programs of one window's tree (its dock rides `ownedPaneIds`).
    func busyPrograms(in controller: TerminalController) -> [String] {
        busyPrograms(panes: controller.surfaceTree.compactMap(\.vigilAttachId))
    }

    /// The tty's foreground pid (`<pane>.pid`'s third line, the tty's
    /// e_tpgid).
    private func paneForeground(_ pane: String) -> Int32? {
        let lines = paneFileLines(pane, "pid")
        return lines.count >= 3 ? Int32(lines[2].trimmingCharacters(in: .whitespaces)) : nil
    }

    private func paneForegroundLabel(_ pane: String) -> String? {
        Program.foreground(tree: paneFileLines(pane, "tree"), pid: paneForeground(pane))
    }

    /// One pane's program, what you see in it (`Program.of`, the rule every
    /// row on every device names a pane by).
    func paneProgram(_ pane: String) -> String? {
        Program.of(tree: paneFileLines(pane, "tree"), foreground: paneForeground(pane))
    }

    /// What this Mac knows of one of its panes, in the directory's own shape
    /// (`Directory.Facts`, what `vigild dir` would print for it), so the
    /// sidebar names its rows by the very rule the phone and a remote
    /// sidebar apply to the same pane (`Directory.titles`).
    /// The pane's spec is on disk: its daemon runs, is starting, or died
    /// with the machine (only a deliberate end removes it).
    nonisolated static func specExists(_ pane: String) -> Bool {
        FileManager.default.fileExists(atPath: VigilPaths.panes.appendingPathComponent("\(pane).spec").path)
    }

    /// Its program ended badly and the record is still unopened.
    nonisolated static func endRecorded(_ pane: String) -> Bool {
        FileManager.default.fileExists(atPath: VigilPaths.panes.appendingPathComponent("\(pane).ended").path)
    }

    func paneFacts(_ pane: String) -> Directory.Facts {
        Directory.Facts(alive: true, tree: paneFileLines(pane, "tree"),
                        pid: paneFileLines(pane, "pid").joined(separator: "\n"),
                        title: paneFileLines(pane, "title").first, glance: paneGlance(pane), ended: paneEnd(pane))
    }

    /// `panes/<pane>.ended`: its program ended badly and nobody has opened
    /// it yet (`PaneEnd`). A record that does not read is said once per
    /// change of the file, and the pane is drawn unmarked.
    func paneEnd(_ pane: String) -> PaneEnd? {
        guard let file = facts.files["panes/\(pane).ended"] else { return nil }
        do { return try JSONDecoder().decode(PaneEnd.self, from: file.data) } catch {
            if unreadEnds.updateValue(file.revision, forKey: pane) != file.revision {
                sidebarLog.warn("ended record not read: the pane is drawn unmarked", ["pane": pane, "err": error])
            }
            return nil
        }
    }

    /// The pane's glance (`state/<pane>.glance`, its broker's), nil when it
    /// has none. One that does not read is said once per change of the
    /// file, and the pane is named as if it had none.
    func paneGlance(_ pane: String) -> PaneGlance? {
        guard let file = facts.files["state/\(pane).glance"] else { return nil }
        do { return try JSONDecoder().decode(PaneGlance.self, from: file.data) } catch {
            if unreadGlances.updateValue(file.revision, forKey: pane) != file.revision {
                sidebarLog.warn("glance not read: the pane is named without it", ["pane": pane, "err": error])
            }
            return nil
        }
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
    /// a sentry - antenna semantics, not process accounting. Declared
    /// leases are never gated: the watcher said why it watches.
    func paneWatchers(_ pane: String) -> [String] {
        if paneAgentState(pane) == nil, paneForegroundLabel(pane) != nil { return [] }
        let program = paneProgram(pane)
        var out: [String] = []
        for argv in paneCommands(pane, "tree") {
            guard let label = Program.label(argv), label != program else { continue }
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

    func watchLeases() -> [String: [WatchLease]] {
        Dictionary(grouping: facts.leases.map {
            WatchLease(pane: $0.pane, note: $0.note, deadline: $0.deadline.map(Date.init(timeIntervalSince1970:)))
        }, by: \.pane)
    }

    var agentStateDir: URL {
        VigilPaths.state
    }

    func startStateDirWatcher() {
        VigilWatchdog.arm()
        factsLoader.start()
    }

    /// The pane's continuous program state as its broker last published it
    /// (`StateToken`), here or on the pane's own Mac.
    func paneAgentState(_ pane: String) -> PaneState? {
        if let remote = VigilRemote.split(pane) {
            guard let truth = VigilRemote.shared.host(remote.device)?.directory?.panes[remote.name],
                  let token = truth.token, let revision = truth.stateRevision else { return nil }
            return PaneState(state: token.state, flavor: token.flavor, since: Date(timeIntervalSince1970: truth.since ?? 0), revision: revision)
        }
        guard let file = facts.files["state/\(pane).state"] else { return nil }
        guard let token = StateToken(file.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            attentionLog.error("state file holds no state", ["pane": pane, "text": file.text])
            return nil
        }
        return PaneState(state: token.state, flavor: token.flavor, since: file.since, revision: file.revision)
    }

    /// Seen-ack changes presentation only; it never resolves a broker request.
    func paneDisplayState(_ pane: String) -> AgentState? {
        guard let state = paneAgentState(pane) else { return nil }
        if state.state == .done || state.state == .blocked,
           let ack = lastAck(pane), ack >= state.since { return .idle }
        return state.state
    }

    /// What a session is RUNNING right now, compact and deduped, straight
    /// from the daemons' live tree files.
    func runningSummary(of name: String) -> [String] {
        guard let session = workspaces[name] else { return [] }
        var out: [String] = []
        for pane in ownedPaneIds(session).sorted() {
            for argv in paneCommands(pane, "tree") {
                if let label = Program.label(argv), !out.contains(label) {
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
        guard let session = workspaces[name] else { return [] }
        var out: [DiedProcess] = []
        for pane in ownedPaneIds(session).sorted() {
            for argv in paneCommands(pane, "died") {
                guard let label = Program.label(argv),
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
            if let label = Program.label(died.command), !out.contains(label) {
                out.append(label)
            }
        }
        return out
    }

    /// True when the pane's shell sits at a prompt (pidfile line 3, the
    /// deep foreground, equals the child shell): safe to type into.
    private func paneIdleAtShell(_ pane: String) -> Bool {
        guard let child = paneFileLines(pane, "pid").first?.split(separator: " ").last.flatMap({ Int32($0) }),
              let fg = paneForeground(pane)
        else { return false }
        return child == fg
    }

    /// The surface attached to a pane's daemon. Never `.first` over the
    /// UNORDERED weak set: it yields whichever twin the hash table holds,
    /// and focus, float and move then aim at a WINDOWLESS view and silently
    /// do nothing. The windowed one is the answer; a second match is a
    /// leak to report.
    /// What `vigil doctor` asks the app: its views by kind and its memory
    /// as the kernel counts it (phys_footprint is Activity Monitor's
    /// "Memory"; heap in use is every malloc zone's live bytes).
    func status() -> VigilSessionControl.Status {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var heap = malloc_statistics_t()
        malloc_zone_statistics(nil, &heap)
        let views = Ghostty.SurfaceView.vigilAttachSurfaces.allObjects
        let mb = { (bytes: UInt64) in (Double(bytes) / 1_048_576).rounded() }
        return .init(
            footprintMB: read == KERN_SUCCESS ? mb(info.phys_footprint) : -1,
            heapInUseMB: mb(UInt64(heap.size_in_use)),
            views: views.count,
            windowedViews: views.filter { $0.window != nil }.count,
            mirrorViews: views.filter(\.vigilMirror).count,
            sessions: workspaces.count,
            heldTabs: workspaces.values.reduce(0) { $0 + $1.held.count },
            uptimeSeconds: (Date().timeIntervalSince(Self.launchedAt)).rounded())
    }

    static let launchedAt = Date()

    func liveView(attachId: String) -> Ghostty.SurfaceView? {
        if let remote = VigilRemote.split(attachId) {
            return Ghostty.SurfaceView.vigilAttachSurfaces.allObjects.first {
                $0.vigilHost == remote.device && $0.vigilAttachId == remote.name && $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor
            }
        }
        let matches = Ghostty.SurfaceView.vigilAttachSurfaces.allObjects
            .filter { $0.vigilAttachId == attachId && !$0.vigilMirror }
        if matches.count > 1 {
            invariantsLog.error("twin surfaces on one daemon", ["pane": attachId, "surfaces": matches.count])
        }
        return matches.first { $0.window != nil } ?? matches.first
    }

    /// The window whose split tree holds this view: where a pane is on
    /// screen. `view.window` is not that fact (a view released from a tree
    /// can keep its window), and trusting it turned tab and pane clicks in
    /// a window showing another Mac's session into silent "focus it here".
    func treeHome(of view: Ghostty.SurfaceView) -> TerminalController? {
        TerminalController.all.first { $0.surfaceTree.contains(where: { $0 === view }) }
    }

    /// Is the view on screen in this controller's window or one of its
    /// native tab siblings (nil controller = anywhere)?
    func shownHere(_ view: Ghostty.SurfaceView, _ controller: TerminalController?) -> NSWindow? {
        guard let home = treeHome(of: view), let window = home.window else { return nil }
        guard let controller else { return window }
        if home === controller { return window }
        if let mine = controller.window, window.tabGroup?.windows.contains(mine) ?? false { return window }
        return nil
    }

    /// Is this view currently DISPLAYED anywhere (a window's tree, a dock
    /// strip, the quick panel)? A view that is placed belongs to that
    /// placement; one that is placed nowhere is adoptable.
    func placed(_ view: Ghostty.SurfaceView) -> Bool {
        if let quick = quickController(create: false),
           quick.surfaceTree.contains(where: { $0 === view }) { return true }
        for controller in TerminalController.all {
            if controller.surfaceTree.contains(where: { $0 === view }) { return true }
            if dockMap.object(forKey: controller)?.views.contains(where: { $0 === view }) ?? false { return true }
        }
        for session in workspaces.values {
            for runtime in runtimes(session) {
                if runtime.tree.contains(where: { $0 === view }) { return true }
                if runtime.dock?.views.contains(where: { $0 === view }) ?? false { return true }
            }
        }
        return false
    }

    /// ONE daemon, ONE view. A surface that exists for this pane but sits
    /// in no placement (released from a tree, still attached to its
    /// daemon socket) is ADOPTED by the next mount instead of minting a
    /// second client on the same socket (each round trip through the
    /// sidebar would add one, and the twins make panes unfocusable).
    /// Minting is for panes with no surface at all.
    /// A WARM view (its tab held by its session while another tab or session
    /// is on screen) is the first answer: the mount takes the whole held tab
    /// out of the cache, so every leaf of it adopts the exact surfaces that
    /// kept running, with no reconnect and no replay.
    func adoptable(_ id: String) -> Ghostty.SurfaceView? {
        guard let view = liveView(attachId: id) else { return nil }
        if let (owner, index) = heldRuntime(containing: view) {
            var held = workspaces[owner]!.held
            let runtime = held.remove(at: index)
            workspaces[owner]!.held = held
            viewportLog.info("warm tab adopted", ["workspace": owner, "panes": runtime.tree.compactMap(\.vigilAttachId)])
        } else if placed(view) {
            return nil
        } else {
            viewportLog.info("live surface adopted", ["pane": id])
        }
        // Rendering resumes for the view going on screen, whichever way it
        // was released (a warm tab, a moved or merged pane are occluded);
        // its siblings wake as the same mount adopts them.
        setOcclusion(true, views: [view])
        return view
    }

    /// A tab leaving its session takes its warm runtime with it: out of the
    /// session's cache, to wherever the tab goes (a burial, another session).
    /// Left behind, the cache would hold surfaces of panes the session no
    /// longer owns, and a later mount or reap would act on them.
    func takeWarm(_ tab: Registry.Tab, from name: String) -> [TabRuntime] {
        let ids = Set(tab.paneIds)
        guard let held = workspaces[name]?.held else { return [] }
        func belongs(_ runtime: TabRuntime) -> Bool {
            runtime.tree.contains { $0.vigilAttachId.map(ids.contains) == true }
                || (runtime.dock?.views.contains { $0.vigilAttachId.map(ids.contains) == true } ?? false)
        }
        workspaces[name]!.held = held.filter { !belongs($0) }
        return held.filter(belongs)
    }

    /// Warm tabs in the order the session lists their tabs.
    func registryOrdered(_ runtimes: [TabRuntime], of session: Workspace) -> [TabRuntime] {
        func position(_ runtime: TabRuntime) -> Int {
            let ids = Set(runtime.tree.compactMap(\.vigilAttachId))
            return session.tabs.firstIndex { !ids.isDisjoint(with: $0.paneIds) } ?? Int.max
        }
        return runtimes.sorted { position($0) < position($1) }
    }

    /// The held tab (session, index) whose tree or dock holds this view.
    private func heldRuntime(containing view: Ghostty.SurfaceView) -> (String, Int)? {
        for (name, session) in workspaces {
            if let index = session.held.firstIndex(where: { runtime in
                runtime.tree.contains(where: { $0 === view })
                    || (runtime.dock?.views.contains(where: { $0 === view }) ?? false)
            }) { return (name, index) }
        }
        return nil
    }

    /// Adopt-or-mint, the one way a mount gets a pane's view.
    func surface(for pane: Registry.Pane, configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
        if let view = adoptable(pane.id) { return view }
        guard let app = ghosttyApp?.app else { return nil }
        return Ghostty.SurfaceView(app, baseConfig: configFor(pane))
    }

    /// Relaunch what died: the exact captured argv, typed into the pane it
    /// died in — ONLY when that pane's shell is idle at a prompt (never
    /// into a running program), and only from an explicit user click (the
    /// click IS the approval that makes replaying a captured command
    /// acceptable). Busy panes keep their tombstone for a later attempt.
    func relaunchDied(name: String) {
        guard windowed(name) else {
            open(name: name)
            return
        }
        let byPane = Dictionary(grouping: diedProcesses(of: name), by: \.pane)
        for (pane, procs) in byPane {
            guard paneIdleAtShell(pane), let view = liveView(attachId: pane) else {
                daemonLog.info("relaunch deferred: pane busy or unattached", ["pane": pane])
                continue
            }
            for died in procs {
                view.surfaceModel?.sendText(died.command + "\r")
                daemonLog.info("relaunched", ["pane": pane, "command": died.command])
            }
            try? FileManager.default.removeItem(
                at: vigildStateDir.appendingPathComponent("\(pane).died"))
        }
    }

    /// Drop a session's tombstones without acting on them.
    func dismissDied(name: String) {
        guard let session = workspaces[name] else { return }
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
    /// views, 40 CALayers) lives forever in NSApp.windows: hundreds of
    /// shapeshifts leave a thousand dead windows resident, gigabytes and a
    /// quarter of a core idle, WindowServer compositing corpses. Undo is
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
            return workspaceName(of: controller) == nil
        }
    }

}
