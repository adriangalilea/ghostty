import AppKit
import GhosttyKit
import os
import VigilWire

/// What a view of this Mac's pane shows while it has no stream to it: how
/// the pane stands, and what its one button does.
struct VigilPaneNote: Equatable {
    /// "Not connected", "Ended: exit 3".
    let says: String
    /// The button: "Reconnect", "Open a shell".
    let offers: String
    /// The same at length, for the tooltip.
    let explains: String
    let symbol: String
}

/// A pane's life has one owner on its Mac: this. A view dials a daemon and
/// draws what it sends; it starts none, and reads no program's end off a
/// stream (2026-11-16: a lost stream read as an exit closed two live panes,
/// and a view's own birth path ran panes a restore had refused). Every
/// birth of a pane's daemon, every restore, every reopening of an ended
/// pane and every close of one whose program finished is decided here, from
/// what the pane's files say now (`standing`), for one named pane, in the
/// registry first.
extension VigilWorkspaces {
    /// How one of this Mac's panes stands, from its daemon's files.
    enum PaneStanding: Equatable {
        /// A daemon holds the pane (its lock).
        case running
        /// Its spec stands with no daemon: the daemon died and nothing says
        /// its program ended. Restored from the spec.
        case died
        /// Nothing of it on disk: it never ran. Born as its registry says.
        case unborn
        /// Its daemon recorded how its program ended.
        case ended(PaneEnd)
        /// It ran (a pidfile, or a record that does not read) and nothing
        /// says how it ended. Nothing is run for it unasked.
        case lost
    }

    /// The record speaks first: a birth takes it off the disk before it
    /// forks, so a record on disk is the last run's and no run came after,
    /// whatever else is still there (a daemon on its way out holds its lock
    /// a moment longer; one killed between its record and its cleanup left
    /// its spec).
    nonisolated static func standing(_ pane: String) -> PaneStanding {
        if let end = endOnDisk(pane) { return .ended(end) }
        if endRecorded(pane) { return .lost }
        if daemonAlive(pane) { return .running }
        if specExists(pane) { return .died }
        if FileManager.default.fileExists(atPath: VigilPaths.panes.appendingPathComponent("\(pane).pid").path) { return .lost }
        return .unborn
    }

    /// Every birth and every kill, one at a time and off the main thread
    /// (each waits for vigild): a kill asked while a birth of that pane is
    /// still being approved runs after it, never around it.
    nonisolated static let lifeQueue = DispatchQueue(label: "vigil.pane-life", qos: .userInitiated)

    /// This Mac's views of a pane (mirrors too; a remote pane's stream is
    /// its hub's).
    private func views(of pane: String) -> [Ghostty.SurfaceView] {
        Ghostty.SurfaceView.vigilAttachSurfaces.allObjects.filter { $0.vigilHost == nil && $0.vigilAttachId == pane }
    }

    private func note(_ pane: String, _ note: VigilPaneNote?) {
        var said = note
        // An ended pane whose agent left word of how to resume: opening it
        // resumes that conversation, and the button says so.
        if let note, note.offers == Self.opens, Self.resumes(pane) {
            said = VigilPaneNote(says: note.says, offers: "Open and resume", explains: note.explains, symbol: note.symbol)
        }
        for view in views(of: pane) where view.vigilNote != said { view.vigilNote = said }
    }

    private static let opens = "Open a shell"

    /// Its agent left a resume pointer: a shell born for this pane types it.
    nonisolated static func resumes(_ pane: String) -> Bool {
        FileManager.default.fileExists(atPath: VigilPaths.panes.appendingPathComponent("\(pane).resume").path)
    }

    /// `said`: why the last try to start or open it did nothing (the birth
    /// authority's refusal, vigild's word on a restore). Shown whatever the
    /// pane's standing: a pane that stays ended because opening it was
    /// refused says that, never only that it ended.
    private static func note(for standing: PaneStanding, said: String?) -> VigilPaneNote? {
        guard let note = plainNote(for: standing, said: said) else { return nil }
        switch standing {
        case .ended, .lost:
            guard let said else { return note }
            return VigilPaneNote(says: "Not opened", offers: "Try again", explains: "Opening it did nothing: \(said). \(note.explains)", symbol: "exclamationmark.triangle")
        case .running, .died, .unborn:
            return note
        }
    }

    private static func plainNote(for standing: PaneStanding, said: String?) -> VigilPaneNote? {
        switch standing {
        case .running:
            return VigilPaneNote(says: "Not connected", offers: "Reconnect", explains: "This pane's daemon runs and this view has no connection to it. What you type does not reach it.", symbol: "wifi.slash")
        case .died:
            let why = said ?? "its daemon is gone"
            return VigilPaneNote(says: "Not running", offers: "Try again", explains: "This pane's daemon is gone and was not started again: \(why). What ran in it does not come back; started again, it runs what the pane was made for.", symbol: "bolt.slash")
        case .unborn:
            return VigilPaneNote(says: "Not started", offers: "Start it", explains: "This pane has no daemon: \(said ?? "no reason was given"). Starting it runs what the pane was made for, in its folder.", symbol: "bolt.slash")
        case .ended(let end):
            return VigilPaneNote(says: end.clean ? "Finished" : "Ended: \(end.how)", offers: "Open a shell", explains: "\(end.program.isEmpty ? "Its program" : end.program) ended (\(end.how)). Opening it starts a shell in its folder; the program is not run again, and an agent that left word of how to resume its conversation does so.", symbol: "stop.circle")
        case .lost:
            return VigilPaneNote(says: "Ended, how is not known", offers: "Open a shell", explains: "This pane ran, and nothing says how it ended. Opening it starts a shell in its folder; what it ran is not run again, and an agent that left word of how to resume its conversation does so.", symbol: "questionmark.circle")
        }
    }

    /// What became of an ask to look at a pane.
    enum Tended: Equatable {
        /// Done, or under way (a birth, a restore, a dial).
        case accepted
        /// Kept for when it can be done (a birth in flight, a daemon on its
        /// way out); done then without being asked again.
        case waiting
        /// Nothing is done unasked: the pane says why on its views.
        case noted
        /// No registry of this Mac lists it.
        case unknown
    }

    /// A pane needs looking at: a view of it has no stream, the person
    /// asked, it joined the registry, its daemon is gone. `asked`: a person
    /// asked for it by an act of their own (the note's button, an undo, an
    /// open from another device), which is what turns an ended pane into a
    /// shell and starts one that lost its files. A view existing is no
    /// such act: views are made at launch, by a mount and for a mirror, and
    /// one that never saw its stream open may only have looked late.
    /// `dialFailed`: a view just failed to dial it.
    @discardableResult
    func tend(_ pane: String, asked: Bool = false, dialFailed: Bool = false, why: String) -> Tended {
        guard let at = locate(pane) else {
            // A view made before its tree's change registered it: tended
            // when it joins (`applyTreeDiff`).
            daemonLog.info("pane in no registry yet; tended when it joins", ["pane": pane, "why": why])
            awaitingRegistry.insert(pane)
            return .unknown
        }
        if births.contains(pane) {
            if asked { openAsked.insert(pane) }
            return .waiting
        }
        let standing = Self.standing(pane)
        switch standing {
        case .running:
            // A daemon that runs and could not be dialed is either not
            // listening yet (its `.up` file will say when) or out of this
            // view's reach: said, never dialed in a loop.
            if dialFailed {
                note(pane, Self.note(for: standing, said: nil))
                return .noted
            }
            redial([pane])
            return .accepted
        case .died:
            restoreDied(why: why)
            return .accepted
        case .unborn:
            // Nothing on disk is "never ran" only for a pane this run of
            // the app made (or one brought here and not opened yet). For
            // any other its files are missing, which is no leave to run
            // what the registry says it ran.
            guard asked || fresh.contains(pane) || dormantPanes.contains(pane), let entry = registered(pane) else {
                note(pane, Self.note(for: standing, said: "nothing of it is on disk"))
                return .noted
            }
            bear(entry, in: at.owner, why: why)
            return .accepted
        case .ended(let end) where end.clean && !asked && registered(pane)?.reopened != end.run:
            closeFinished([pane])
            return .accepted
        case .ended, .lost:
            guard asked else {
                note(pane, Self.note(for: standing, said: nil))
                return .noted
            }
            return reopen(pane, why: why)
        }
    }

    /// The note's button: the person asks for what it offers. Another Mac's
    /// pane is opened at its home (`open_pane`), which owns its life.
    func noteAsked(_ view: Ghostty.SurfaceView) {
        guard let pane = view.vigilAttachId else { return }
        daemonLog.info("pane's note pressed", ["pane": pane, "offered": view.vigilNote?.offers, "host": view.vigilHost])
        guard let device = view.vigilHost else {
            tend(pane, asked: true, why: "the person asked")
            return
        }
        guard let remote = VigilRemote.shared.host(device),
              let workspace = remote.directory?.live.first(where: { $0.paneIds.contains(pane) }) else { return }
        ask(RowHome(device: device, workspace: workspace.name),
            WorkspaceCommand.Request(session: workspace.name, revision: "", operation: "open_pane", anchor: pane),
            failing: "Not opened on \(remote.name)")
    }

    /// What a view of another Mac's pane says while that pane does not run
    /// there, from that Mac's own directory; nil while it runs (the view's
    /// stream is then its hub's to make).
    func remoteNote(_ pane: String, on device: String) -> VigilPaneNote? {
        guard let remote = VigilRemote.shared.host(device), let facts = remote.directory?.panes[pane], !facts.alive else { return nil }
        if let end = facts.ended {
            return VigilPaneNote(says: "Ended: \(end.how)", offers: "Open on \(remote.name)", explains: "\(end.program.isEmpty ? "Its program" : end.program) ended on \(remote.name) (\(end.how)). Opening it starts a shell in its folder there; the program is not run again, and an agent that left word of how to resume its conversation does so.", symbol: "stop.circle")
        }
        return VigilPaneNote(says: "Not running on \(remote.name)", offers: "Start it there", explains: "This pane has no daemon on \(remote.name). Starting it restores it from its record there, or opens a shell in its folder.", symbol: "bolt.slash")
    }

    /// `vigild new` for one pane, this app its birth authority. Off the
    /// main thread.
    nonisolated static func birth(_ pane: Registry.Pane, session: String) -> Bool {
        birthSaying(pane, session: session) == nil
    }

    /// The same, saying why it did not come up (nil: it is up): the birth
    /// authority's own words when it refused (a seal that does not verify, a
    /// hub that does not answer), else where to read more.
    nonisolated static func birthSaying(_ pane: Registry.Pane, session: String) -> String? {
        // The folder is vigild's to resolve (a missing one falls back to its
        // nearest existing parent), never this process's working directory.
        var args = ["new", pane.id, "--cwd", pane.cwd]
        if let cmd = pane.command {
            if cmd.hasPrefix("direct:") {
                // ghostty's command syntax: `direct:` argv, space-separated.
                args.append("--")
                args += cmd.dropFirst("direct:".count).split(separator: " ").map(String.init)
            } else {
                args += ["-c", cmd]
            }
        }
        var env = ProcessInfo.processInfo.environment
        env["VIGIL_WORKSPACE"] = session
        let refused = OSAllocatedUnfairLock<String?>(initialState: nil)
        do {
            let status = try PaneBirth.run(args, environment: env, vouch: { question in
                let answer = Self.vouch(question)
                if case .failure(let refusal) = answer { refused.withLock { $0 = refusal.description } }
                return answer
            })
            if status == 0 {
                daemonLog.info("daemon up", ["pane": pane.id])
                return nil
            }
            let said = refused.withLock { $0 }
            daemonLog.error("daemon spawn failed", ["pane": pane.id, "status": status, "refused": said])
            return said.map { "refused: \($0)" } ?? "vigild exited \(status); the pane's log says why"
        } catch {
            daemonLog.error("daemon spawn failed", ["pane": pane.id, "err": error])
            return "vigild could not be run: \(error)"
        }
    }

    private func bear(_ pane: Registry.Pane, in workspace: String, why: String) {
        births.insert(pane.id)
        fresh.remove(pane.id)
        daemonLog.info("pane's daemon asked for", ["pane": pane.id, "workspace": workspace, "command": pane.command, "cwd": pane.cwd, "why": why])
        Self.lifeQueue.async {
            let failed = Self.birthSaying(pane, session: workspace)
            Task { @MainActor in
                VigilWorkspaces.shared.settled([pane.id], said: failed.map { [pane.id: $0] } ?? [:])
            }
        }
    }

    /// A birth or a restore is over: each pane is looked at again, as it
    /// stands now. One that runs is dialed by its views; any other says why
    /// on them.
    private func settled(_ panes: [String], said: [String: String]) {
        births.subtract(panes)
        for pane in panes {
            let standing = Self.standing(pane)
            switch standing {
            case .running:
                openAsked.remove(pane)
                note(pane, nil)
                redial([pane])
            case .ended(let end) where end.clean && !openAsked.contains(pane) && said[pane] == nil && registered(pane)?.reopened != end.run:
                // Born and over already (a one-shot command). Never the end
                // of the run before, standing because this birth was
                // refused: that one says why below.
                closeFinished([pane])
            default:
                if openAsked.remove(pane) != nil {
                    tend(pane, asked: true, why: "asked while its birth was in flight")
                    continue
                }
                daemonLog.warn("pane not running after its birth", ["pane": pane, "said": said[pane]])
                note(pane, Self.note(for: standing, said: said[pane]))
            }
        }
    }

    /// A daemon was found gone, or one that was on its way out has exited:
    /// panes that died are restored, and an open asked of a pane whose
    /// daemon was still leaving is done now.
    func daemonsLeft(why: String) {
        restoreDied(why: why)
        for pane in openAsked where !births.contains(pane) && !Self.daemonAlive(pane) {
            openAsked.remove(pane)
            tend(pane, asked: true, why: "asked while its daemon was leaving")
        }
    }

    /// Every owned pane whose daemon died with its spec standing, restored
    /// in one `vigild restore` naming them and no others. A daemon can die
    /// under a running app (2026-11-16: the Dock sent SIGTERM to the broker
    /// and four pane daemons; why those is not known). Asked for when a
    /// pidfile leaves or a daemon is found gone, when a view has no stream,
    /// on the person's ask, and when the hub answers again (a restore needs
    /// its seal, and the hub may have died in the same blow).
    func restoreDied(why: String) {
        let dead = (workspaces.values.flatMap(ownedPaneIds) + graveyard.values.flatMap(ownedPaneIds))
            .filter { !births.contains($0) && Self.standing($0) == .died }.sorted()
        guard !dead.isEmpty else { return }
        births.formUnion(dead)
        daemonLog.warn("daemons gone with their specs on disk; restoring", ["panes": dead, "why": why])
        Self.lifeQueue.async {
            let said = Self.restoreFromSpecs(why: why, panes: dead)
            Task { @MainActor in VigilWorkspaces.shared.settled(dead, said: said) }
        }
    }

    /// An ended pane opened again: a shell in its folder, by the person's
    /// act (they pressed its note, undid its close, or opened it from
    /// another device). Its program leaves the registry, saved before
    /// anything is started, and its views, so no mount or restore runs it
    /// again; the daemon born here removes what a restore would have run
    /// the old program from, takes the record off the disk and writes the
    /// shell's own spec, in that order and before it forks, and for an end
    /// that was not clean shows the final screen above the prompt. Views
    /// that were waiting dial the new daemon. Its resume pointer stays: it
    /// is its agent's own word that the conversation can go on (an agent
    /// that quit by itself removed it), typed into the new shell as into
    /// any shell born with one.
    @discardableResult
    func reopen(_ pane: String, why: String) -> Tended {
        guard let at = locate(pane), !at.buried else { return .unknown }
        // A birth in flight, or its old daemon still on its way out (it
        // holds the lock until it exits): kept, and done when that is over.
        if births.contains(pane) || Self.daemonAlive(pane) {
            openAsked.insert(pane)
            return .waiting
        }
        guard let entry = madeShell(pane, why: why) else { return .noted }
        bear(entry, in: at.owner, why: why)
        return .accepted
    }

    /// The pane's registry entry as a shell's, saved: its program out of the
    /// registry and its views, and the registry on disk read back to hold
    /// it so, in a live workspace. Nil, with a note on its views, when that
    /// could not be saved: nothing is then started, since a registry on
    /// disk that still named the old program, or still held the pane in a
    /// burial, would undo the opening at the next launch.
    private func madeShell(_ pane: String, why: String) -> Registry.Pane? {
        let was = registered(pane)?.command
        // The end being answered, by its run: it closes this pane no more
        // (`closeFinishedNow`), also when the shell asked for here is
        // refused and the record therefore stays on disk.
        let answered = Self.endOnDisk(pane)?.run
        editPane(pane) {
            $0.command = nil
            if let answered { $0.reopened = answered }
        }
        for view in views(of: pane) { view.vigilForgetCommand() }
        persist()
        guard let entry = registered(pane), Self.savedCommand(of: pane, in: persistURL) == .some(nil) else {
            daemonLog.error("ended pane not opened: the registry could not be saved without its program", ["pane": pane, "was": was])
            note(pane, VigilPaneNote(says: "Not opened", offers: "Try again", explains: "This pane's registry entry could not be saved as a shell's, so nothing was started. The app's log says why.", symbol: "exclamationmark.triangle"))
            return nil
        }
        daemonLog.info("ended pane opened as a shell", ["pane": pane, "was": was, "why": why])
        return entry
    }

    /// Open a pane and say what happened, on this thread and done when it
    /// returns: for a command whose reply is kept and answers a retry
    /// (`open_pane`), which may say "done" only of what is done. Nil: its
    /// daemon runs. Else why it does not.
    func openNow(_ pane: String, why: String) -> String? {
        guard let at = locate(pane), !at.buried else { return "no workspace of this Mac lists it" }
        guard !births.contains(pane) else { return "it is being started" }
        let entry: Registry.Pane
        switch Self.standing(pane) {
        case .running:
            redial([pane])
            return nil
        case .died:
            births.insert(pane)
            let said = Self.restoreFromSpecs(why: why, panes: [pane])
            settled([pane], said: said)
            return Self.daemonAlive(pane) ? nil : (said[pane] ?? "it was not restored")
        case .ended, .lost:
            guard !Self.daemonAlive(pane) else { return "its last daemon is still closing" }
            guard let shell = madeShell(pane, why: why) else { return "its registry entry could not be saved as a shell's" }
            entry = shell
        case .unborn:
            guard let listed = registered(pane) else { return "no workspace of this Mac lists it" }
            entry = listed
        }
        births.insert(pane)
        fresh.remove(pane)
        let failed = Self.birthSaying(entry, session: at.owner)
        settled([pane], said: failed.map { [pane: $0] } ?? [:])
        return failed
    }

    /// The command the registry ON DISK holds for a pane: `.some(nil)` a
    /// pane listed with none, `.some(command)` one listed with it, nil when
    /// the file does not read or does not list the pane.
    nonisolated static func savedCommand(of pane: String, in file: URL) -> String?? {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Registry.Workspace].self, from: data) else { return nil }
        // Where it lives, never where it rests: a burial listing it is the
        // close being undone, and says nothing of the undo having been saved.
        for workspace in saved where workspace.buriedUntil == nil {
            for tab in workspace.tabs ?? [] {
                if let found = (tab.panes + (tab.dock?.panes ?? [])).first(where: { $0.id == pane }) { return .some(found.command) }
            }
        }
        return nil
    }

    /// Panes taken back from a burial (an undo, from the tray or a split's
    /// own): one whose program had ended comes back as a shell, since the
    /// close that buried it is the thing undone. A pane that still runs is
    /// untouched.
    func revive(_ panes: some Sequence<String>) {
        for pane in panes {
            switch Self.standing(pane) {
            case .ended, .lost: reopen(pane, why: "its close was undone")
            case .running, .died, .unborn: break
            }
        }
    }

    /// A program that FINISHED cleanly closes its pane, whether or not a
    /// window shows it. The one fact that says so is its daemon's record of
    /// a clean end (`<pane>.ended`, `PaneEnd.clean`): never a spec, a
    /// pidfile or a stream that is gone, which say nothing of the program.
    /// The ids given are the panes to look at: at launch all of them, then
    /// any whose record or pidfile changed, a birth no snapshot saw running
    /// (`bornUnseen`) and those that could not be closed yet. The close is
    /// of that one pane, in the registry (the edit a close from another Mac
    /// makes, `applySessionCommand`), and every view follows the registry;
    /// it never passes through a window's own close, whose scope is the
    /// tab. A workspace whose every pane finished is killed whole (its
    /// window goes to the next workspace). A program that ended any other
    /// way keeps its pane, marked, for the person to open or close (Adrian
    /// 2026-10-30: an end nobody saw is lost visibility).
    ///
    /// Asked from anywhere, it runs in a turn of the main thread of its own
    /// and reads the registry as it stands then: a close is a structural
    /// edit, and made inside another one (a kill reclaiming the floating
    /// terminal, a command, a tree's change) it would edit a workspace the
    /// outer operation still holds, and turn one asked close into two.
    func closeFinished(_ ids: some Sequence<String>) {
        finishedAsked.formUnion(ids)
        guard !finishedPassDue, !finishedAsked.isEmpty else { return }
        finishedPassDue = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let owner = VigilWorkspaces.shared
                owner.finishedPassDue = false
                let asked = owner.finishedAsked
                owner.finishedAsked = []
                owner.closeFinishedNow(asked)
            }
        }
    }

    private func closeFinishedNow(_ ids: Set<String>) {
        // The ids say which workspaces to look at; what is closed is read
        // from each workspace as it stands now, every pane of it: a pane
        // kept beside its dock is closable once the dock's pane has gone,
        // and a workspace is finished when all of it is, however many
        // deliveries its ends came in.
        var touched: Set<String> = []
        for id in ids {
            guard let at = locate(id), !at.buried else {
                finishedWaiting.remove(id)
                continue
            }
            touched.insert(at.owner)
        }
        for name in touched {
            // A pass closes what it can; a pane that closed may free another
            // (the dock's last pane gone), so it is looked at again until a
            // pass closes nothing.
            var closed = true
            while closed, let session = workspaces[name] {
                closed = false
                let owned = ownedPaneIds(session)
                let ends = owned.sorted().compactMap { id -> (id: String, end: PaneEnd)? in
                    guard !births.contains(id), !openAsked.contains(id), let end = Self.endOnDisk(id), end.clean,
                          // An end the person already answered by opening
                          // the pane again closes it no more.
                          registered(id)?.reopened != end.run else { return nil }
                    return (id, end)
                }
                guard !ends.isEmpty else { break }
                if ends.count == owned.count {
                    graveyardLog.info("finished workspace closed", ["workspace": name, "panes": ends.map(\.id), "cause": "program_exit", "runs": ends.map { $0.end.run ?? 0 }])
                    finishedWaiting.subtract(owned)
                    kill(name: name)
                    break
                }
                for (id, end) in ends where finish(id, end: end, in: name) { closed = true }
            }
        }
    }

    /// True when the pane was closed.
    private func finish(_ pane: String, end: PaneEnd, in name: String) -> Bool {
        refreshWorkspaceRevisions()
        guard let session = workspaces[name], let tab = session.tabs.first(where: { $0.paneIds.contains(pane) }) else { return false }
        // Its tab's only pane with a dock beside it: closing it would take
        // the dock's panes with it, which no program asked for. It stays,
        // said finished, until the person closes the tab or opens a shell.
        if tab.panes.map(\.id) == [pane], !(tab.dock?.panes.isEmpty ?? true) {
            finishedWaiting.remove(pane)
            if views(of: pane).contains(where: { $0.vigilNote == nil }) {
                graveyardLog.info("finished pane kept: its tab's dock holds panes", ["pane": pane, "workspace": name, "dock": tab.dock?.panes.map(\.id)])
            }
            note(pane, Self.note(for: .ended(end), said: nil))
            return false
        }
        // In the floating terminal its tabs and splits are not edited
        // (`presentation_busy`): closed when it is back (`reclaim`).
        if session.float != nil {
            finishedWaiting.insert(pane)
            note(pane, Self.note(for: .ended(end), said: nil))
            return false
        }
        let reply = applySessionCommand(VigilSessionControl.Request(
            session: name, revision: session.layoutRevision, operation: "close_pane", anchor: pane))
        if reply.ok {
            finishedWaiting.remove(pane)
            graveyardLog.info("finished pane closed", ["pane": pane, "workspace": name, "cause": "program_exit", "run": end.run])
            return true
        }
        finishedWaiting.insert(pane)
        graveyardLog.error("finished pane not closed", ["pane": pane, "workspace": name, "code": reply.code, "message": reply.message])
        note(pane, Self.note(for: .ended(end), said: nil))
        return false
    }
}
