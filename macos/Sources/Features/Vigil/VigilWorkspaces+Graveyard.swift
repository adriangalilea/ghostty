import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
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
        guard workspaces[name] != nil else { graveyardLog.warn("kill of an unknown workspace ignored", ["workspace": name]); return }
        graveyardLog.info("killed to the graveyard", ["workspace": name, "place": placeTag(name)])
        if workspaces[name]!.float != nil, let quick = quickController(create: false) {
            quick.animateOut()
            reclaim(name, from: quick)
        }
        if mirror?.name == name {
            quickController(create: false)?.animateOut()
            endMirror()
        }
        var kept: TerminalController?
        if windowed(name) {
            kept = keepViewport
                ? (viewport ?? (focusWindow(of: name)?.windowController as? TerminalController))
                : nil
            let vacated = vacate(name, keeping: kept)
            workspaces[name]!.held += vacated
        }
        var session = workspaces[name]!
        workspaces[name] = nil
        recent.removeAll { $0 == name }
        session.attention = .none
        bury(session)
        if let kept { handOn(kept, from: name) }
        persist()
        onAttentionChange?()
    }

    /// Rest a session in the graveyard: 120s grace, undoable, reaped on
    /// expiry. One burial mechanism for every kind of death (session kill,
    /// tab close, split close, dock tenant close, a source emptied by
    /// moves). Burials are written to vigil.json with their deadline, so
    /// a relaunch honors the remaining grace.
    func bury(_ session: Workspace) {
        let name = session.name
        // A corpse never renders: its daemons stay alive for the grace,
        // its renderers must not.
        setOcclusion(false, session.held)
        var session = session
        session.movedTo = movingTo
        session.moveCheckpoint = movingCheckpoint
        if movingCheckpoint?.ticket != nil { session.closing = ownedPaneIds(session).sorted() }
        let members = ownedPaneIds(session)
        session.moveRevisions = movingRevisions?.filter { members.contains($0.key) }
        session.moveTranscripts = movingTranscripts?.filter { members.contains($0.key) }
        graveyard[name] = session
        if movingCheckpoint?.ticket != nil {
            graveyardDeadlines[name] = .distantPast
            DispatchQueue.main.async { [weak self] in self?.reapIfExpired(name) }
            return
        }
        graveyardDeadlines[name] = Date().addingTimeInterval(Registry.closeGrace)

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.undoManager.registerUndo(
                withTarget: self,
                expiresAfter: .seconds(Int64(Registry.closeGrace))
            ) { manager in
                manager.exhume(name)
            }
            appDelegate.undoManager.setActionName("Kill Workspace")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Registry.closeGrace + 1) { [weak self] in
            self?.reapIfExpired(name)
        }
    }

    /// A burial drops without dying (its last pane was re-claimed by an
    /// undo or a move).
    func dropBurial(_ name: String) {
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
    /// Every Mac's burials in one tray: this Mac's from its graveyard,
    /// another's from the directory it streams (vigil.json lists burials
    /// with their deadline and origin). Undo and "end now" go to the
    /// burial's home, which alone holds it.
    struct SidebarBurial: Identifiable, Equatable {
        /// The burial's name here; `<device>/<name>` for another Mac's.
        let id: String
        let name: String
        let emoji: String?
        let label: String
        let remaining: Int
        let waiting: Bool
        let conflict: Bool
        /// Where it stood ("finances › tab 3"); nil for a killed workspace.
        let from: String?
        /// The other Mac holding it (its tether root and name); nil here.
        let device: String?
        let mac: String?
        /// Its close began: no undo, only waiting for it to finish (U2).
        let closing: Bool
        var recoverableMove = false
    }

    func sidebarBurials() -> [SidebarBurial] {
        func from(_ origin: Registry.Origin?, moved: String?, _ label: (String) -> String?) -> String? {
            let parts = [moved.map { "moved to \($0)" }, origin.map { "\(label($0.workspace) ?? $0.workspace) › tab \($0.tab + 1)" }]
                .compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        let conflicts = graveyard.isEmpty ? [] : Registry.conflictingPanes(in: (Array(workspaces.values) + Array(graveyard.values)).map(ownedPaneIds))
        let here = graveyard.values.compactMap { burial -> SidebarBurial? in
            guard let deadline = graveyardDeadlines[burial.name] else { return nil }
            return SidebarBurial(
                id: burial.name, name: burial.name, emoji: burial.emoji, label: burial.label,
                remaining: max(0, Int(deadline.timeIntervalSinceNow)), waiting: deadline == .distantFuture,
                conflict: !conflicts.isDisjoint(with: ownedPaneIds(burial)),
                from: burial.moveCheckpoint?.ticket == nil
                    ? from(burial.buriedFrom, moved: burial.movedTo) { workspaces[$0]?.label }
                    : peerClosedFork(burial) ? "The destination closed its fork"
                    : burial.moveCheckpoint?.final == nil ? "Stopping panes and saving their final history"
                    : "Waiting for " + (burial.movedTo ?? "the destination") + " to acknowledge this transfer",
                device: nil, mac: nil,
                closing: burial.closing != nil, recoverableMove: canTakeBack(burial))
        }
        let elsewhere = VigilRemote.shared.hosts.flatMap { host -> [SidebarBurial] in
            let listed = host.directory?.workspaces ?? []
            let conflicts = Registry.conflictingPanes(in: listed.map { Set($0.paneIds) })
            return listed.compactMap { burial in
                guard let until = burial.buriedUntil else { return nil }
                let conflict = !conflicts.isDisjoint(with: burial.paneIds)
                guard until > Date() || burial.closing != nil || conflict else { return nil }
                return SidebarBurial(
                    id: VigilRemote.compositeId(host.device, burial.name), name: burial.name, emoji: burial.emoji,
                    label: burial.label, remaining: max(0, Int(until.timeIntervalSinceNow)), waiting: until == .distantFuture, conflict: conflict,
                    from: from(burial.buriedFrom, moved: burial.movedTo) { name in listed.first { $0.name == name }?.label },
                    device: host.device, mac: host.name, closing: burial.closing != nil)
            }
        }
        return (here + elsewhere).sorted { $0.remaining < $1.remaining }
    }

    /// Undo from the tray: here, or on the Mac that holds it.
    func undoBurial(_ burial: SidebarBurial) {
        guard !burial.conflict, !burial.closing else { return }
        guard let device = burial.device else { exhume(burial.name); return }
        sendToBurialHome(device, burial, operation: "exhume")
    }

    /// End it now from the tray: here, or on the Mac that holds it.
    func endBurial(_ burial: SidebarBurial) {
        guard !burial.conflict else { return }
        guard let device = burial.device else { reapNow(burial.name); return }
        sendToBurialHome(device, burial, operation: "reap")
    }

    private func sendToBurialHome(_ device: String, _ burial: SidebarBurial, operation: String) {
        let request = WorkspaceCommand.Request.burial(burial.name, operation)
        sessionLog.info("remote command sent", ["request": request.id, "operation": operation, "device": device, "workspace": burial.name])
        Task {
            do {
                let reply = try await VigilRemote.shared.command(device, request: request)
                if reply.ok {
                    sessionLog.info("remote command committed", ["request": request.id])
                } else {
                    sessionLog.warn("remote command refused", ["request": request.id, "code": reply.code])
                }
                guard reply.ok else {
                    let alert = NSAlert()
                    alert.messageText = operation == "exhume" ? "It could not be brought back" : "It could not be ended now"
                    alert.informativeText = reply.message
                    alert.runModal()
                    return
                }
                remoteDirectoryChanged(device)
            } catch {
                sessionLog.error("remote command outcome unknown", ["request": request.id, "err": error])
            }
        }
    }

    func burials() -> [Burial] {
        graveyard.values.compactMap { session in
            // The overview's tray offers recovery: a close begun has none
            // (the sidebar's tray says it is closing).
            guard let deadline = graveyardDeadlines[session.name], session.closing == nil else { return nil }
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
        if let name = panelWorkspace,
           let quick = quickController(create: false),
           quick.window?.isKeyWindow == true {
            confirmKill(name: name) { self.kill(name: name) }
            return
        }
        guard let controller = TerminalController.preferredParent else {
            if let name = panelWorkspace { confirmKill(name: name) { self.kill(name: name) } }
            return
        }
        if let name = workspaceName(of: controller) {
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
    func confirmKill(name: String, _ doKill: @escaping () -> Void) {
        let busy = busyPrograms(of: name)
        guard !busy.isEmpty else { doKill(); return }
        let session = workspaces[name]
        confirmKill(
            label: [session?.emoji, session?.label ?? name].compactMap { $0 }.joined(separator: " "),
            info: "\(busy.joined(separator: ", ")) still running. \(Self.undoWords.prefix(1).uppercased() + Self.undoWords.dropFirst()).",
            thumbnail: session?.thumbnail,
            doKill)
    }

    func confirmKill(
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

    enum Exhumation { case refused, saveFailed, restored(String) }

    /// Undo of a close or a kill, the one undo (⌘⇧T, the tray, a command
    /// from another Mac), everything still running. A closed tab or pane
    /// goes back where it stood (`buriedFrom`): the pane beside the pane it
    /// sat next to (a dock tenant back into the dock) while that tab
    /// exists, else a tab at its old position; every view of the workspace
    /// updates by pane id. A killed workspace, or a burial whose workspace
    /// is gone too, comes back as itself. Returns the workspace it is in.
    @discardableResult
    func exhume(_ name: String) -> Exhumation {
        // A close begun is no undo (U2): its fenced panes are closed for good.
        guard undoAllowed(burial: name), let previous = graveyard[name] else { return .refused }
        let deadline = graveyardDeadlines[name]
        var burial = previous
        graveyard[name] = nil
        graveyardDeadlines[name] = nil
        func commit(_ destination: String, was: Workspace?) -> Bool {
            guard persist(publish: false, durable: true) else {
                workspaces[destination] = was
                graveyard[name] = previous
                graveyardDeadlines[name] = deadline
                return false
            }
            try? FileManager.default.removeItem(at: dumpsDir(name))
            resumeForks(for: ownedPaneIds(previous))
            return true
        }
        if let origin = burial.buriedFrom, var home = workspaces[origin.workspace] {
            for tab in burial.tabs {
                if let beside = origin.beside, let at = home.tabs.firstIndex(where: { $0.paneIds.contains(beside) }) {
                    var target = home.tabs[at]
                    if origin.dock == true {
                        var dock = target.dock ?? Registry.Dock(panes: [], active: 0, width: 340, collapsed: false)
                        dock.panes += tab.panes
                        target.dock = dock
                    } else {
                        var layout = Self.completeLayout(target)
                        for offset in tab.panes.indices { layout = .h(0.5, layout, .leaf(target.panes.count + offset)) }
                        target.panes += tab.panes
                        target.layout = layout
                    }
                    home.tabs[at] = target
                } else {
                    home.tabs.insert(tab, at: min(origin.tab, home.tabs.count))
                }
            }
            // A tab buried warm comes back warm: a click adopts its views.
            home.held += burial.held
            home.layoutShape = "" // a new revision, even for a shape seen before
            let was = workspaces[origin.workspace]
            workspaces[origin.workspace] = home
            guard commit(origin.workspace, was: was) else { return .saveFailed }
            reconcileViews(of: origin.workspace)
            revive(burial.tabs.flatMap(\.paneIds))
            persist()
            graveyardLog.info("exhumed into its workspace", ["burial": name, "workspace": origin.workspace, "tab": origin.tab, "beside": origin.beside])
            return .restored(origin.workspace)
        }
        burial.buriedFrom = nil
        burial.movedTo = nil
        burial.moveRevisions = nil
        burial.moveTranscripts = nil
        burial.moveCheckpoint = nil
        burial.layoutShape = ""
        workspaces[name] = burial
        guard commit(name, was: nil) else { return .saveFailed }
        revive(burial.tabs.flatMap(\.paneIds))
        open(name: name)
        graveyardLog.info("exhumed as itself", ["workspace": name])
        return .restored(name)
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

        var session = Workspace(
            name: newWorkspaceId(),
            label: title.isEmpty ? (cwd as NSString).lastPathComponent : title,
            cwd: cwd,
            held: [TabRuntime(tree: tree, dock: nil)])
        let (panes, layout) = capture(tree, carrying: [])
        session.tabs = [Registry.Tab(panes: panes, layout: layout)]
        bury(session)
    }

    /// Reap NOW, before the grace expires: the daemons die immediately and
    /// the burial is dropped. For "get this out of my face" from the tray
    /// instead of waiting out the 120s.
    /// True when the burial is gone (its close accepted whole); false when
    /// it stays, closing (a fence not accepted), as its reply must say.
    @discardableResult
    func reapNow(_ name: String) -> Bool {
        graveyardDeadlines[name] = Date.distantPast
        reapIfExpired(name, repairInvalid: true)
        return graveyard[name] == nil
    }

    private func keepUnverifiedMove(_ name: String, session: Workspace) {
        graveyardDeadlines[name] = .distantFuture
        if let destination = session.movedTo {
            reportIncompleteMove(session.label, "The source changed or its latest conversation could not be verified on \(destination). It is kept in Recently Closed here. Undo restores it; End Now closes it.")
        }
        graveyardLog.warn("moved panes changed during the grace period; kept for Undo or End Now", ["workspace": name])
        persist()
    }

    /// The grace ran out: now the death actually happens. The burial's
    /// registry names every daemon; its held runtimes release (views free
    /// synchronously, a leaked view elsewhere changes nothing); then the
    /// daemons are killed AND VERIFIED dead. No deferral, no sweep, no
    /// dependence on what ARC happens to hold.
    func reapIfExpired(_ name: String, repairInvalid: Bool = false, refreshed: Bool = false) {
        guard let deadline = graveyardDeadlines[name], Date() >= deadline,
              let session = graveyard[name] else { return }
        let ids = ownedPaneIds(session)
        guard !conflictingOwnership(ids) else {
            withheldReaps.insert(name)
            return
        }
        withheldReaps.remove(name)
        if session.moveCheckpoint?.ticket != nil {
            // Keep membership and transcript offers until the receiving Mac acknowledges.
            if session.moveCheckpoint?.final == nil { stopForHandoff(name, repairInvalid: repairInvalid) }
            return
        }
        let needsTip = !refreshed && session.moveCheckpoint?.transcripts?.keys.contains(where: ids.contains) == true
        if !repairInvalid, session.closing == nil, session.movedTo != nil,
           needsTip || !ids.allSatisfy({ pane in
               guard let expected = session.moveRevisions?[pane] else { return false }
               if let files = session.moveTranscripts?[pane],
                  !files.allSatisfy({ Move.fileVersion($0.key) == $0.value }) { return false }
               return Self.moveRevision(pane) == expected
           }) {
            if !refreshed, let move = session.moveCheckpoint, let device = move.device, let proofs = move.transcripts,
               !proofs.isEmpty, ids.allSatisfy({ Self.moveRevision($0) == session.moveRevisions?[$0] }) {
                // The returning directory resumes expired transfers for this Mac.
                if !moveReachable(device) { return }
                guard verifyingMoves.insert(name).inserted else { return }
                Task { @MainActor in
                    let files = await Self.compareMoveTranscripts(proofs.filter { ids.contains($0.key) }, destination: device)
                    verifyingMoves.remove(name)
                    guard let now = graveyard[name], now.moveCheckpoint == move, ownedPaneIds(now) == ids,
                          graveyardDeadlines[name] == deadline, now.closing == nil else { return }
                    if let files {
                        graveyard[name]?.moveTranscripts = files
                        reapIfExpired(name, refreshed: true)
                    } else if proofs.values.allSatisfy({ $0.files?.isEmpty == false && $0.latest != nil }) {
                        graveyardDeadlines[name] = Date().addingTimeInterval(60)
                        persist()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 61) { [weak self] in self?.reapIfExpired(name) }
                    } else {
                        keepUnverifiedMove(name, session: now)
                    }
                }
                return
            }
            keepUnverifiedMove(name, session: session)
            return
        }
        // The close begins: from here the burial is no undo (a
        // pane fenced is closed for good, and the service finishes a mark
        // the moment it is written), saved as such before the first fence.
        // The work is the burial's members now, never a saved list (a saved list naming a pane the burial does not own would fence
        // it). A saved name that is not a member is said and dropped.
        if let saved = session.closing, !Set(saved).isSubset(of: ids) {
            graveyardLog.error("!! a burial's saved close named panes it does not own; they are not touched", [
                "workspace": name, "panes": Set(saved).subtracting(ids).sorted(),
            ])
        }
        graveyard[name]?.closing = ids.sorted()
        // Accepted on disk (file and folder synced) before any fence, or
        // nothing irreversible happens (a save that failed once
        // left an undoable burial on disk over a pane already fenced). Not
        // saved: no fence, the burial says closing here, and it is tried
        // again; a crash meanwhile leaves the undoable burial that is true.
        guard persist(durable: true) else {
            graveyardLog.error("!! reap not begun: its closing could not be saved; nothing fenced, tried again", ["workspace": name])
            graveyardDeadlines[name] = Date().addingTimeInterval(Self.fenceRetry)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fenceRetry + 1) { [weak self] in self?.reapIfExpired(name) }
            return
        }
        // The close's durable intent: a burial whose panes are
        // not all fenced is not dropped, so its ownership is never removed
        // with no stop decision accepted in its place. It stays, said as a
        // close not finished, tried again in a while.
        // Every member, each time (a fence already there is synced again).
        destroyBuriedViews(session, ids: ids)
        let unfenced = fence(ids, repairInvalid: repairInvalid)
        graveyard[name]?.closing = unfenced.sorted()
        guard unfenced.isEmpty else {
            graveyardLog.error("!! reap not finished: its close could not be fenced; the burial is kept, closing", ["workspace": name, "panes": unfenced.sorted()])
            graveyardDeadlines[name] = Date().addingTimeInterval(Self.fenceRetry)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fenceRetry + 1) { [weak self] in self?.reapIfExpired(name) }
            persist()
            return
        }
        if session.movedTo == nil {
            do {
                for pane in ids {
                    let receipt = Self.closedHereFile(pane)
                    try Durable.folder(receipt.deletingLastPathComponent())
                    try Durable.create(receipt, with: Data())
                }
            } catch {
                graveyardLog.error("could not record the completed local close", ["workspace": name, "err": error])
                graveyardDeadlines[name] = Date().addingTimeInterval(Self.fenceRetry)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.fenceRetry + 1) { [weak self] in self?.reapIfExpired(name) }
                return
            }
        }
        dropBurial(name)
        graveyardLog.info("reaped", ["workspace": name, "panes": ids.sorted()])
        killDaemons(ids)
        if persist(durable: true) { discardUndispatchedMoves(for: ids) }
    }

    /// The lifecycle service observes the first fence and may stop its daemon at once.
    func destroyBuriedViews(_ session: Workspace, ids: Set<String>) {
        for runtime in session.held { runtime.dock?.unmount() }
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects
            where view.vigilHost == nil && view.vigilAttachId.map(ids.contains) == true { view.vigilDestroySurface() }
    }

    /// Kill pane daemons, deterministically: the lifecycle service's close
    /// (one `vigild kill` with every id, which unlinks their survival state,
    /// signals, and WAITS until each is gone, escalating to SIGKILL, then
    /// boots out each job's record). Off the main thread (a stuck daemon
    /// must not freeze the app); the verification screams into the log and
    /// the state files of the dead are pruned when it returns. A close
    /// works with the service down too: then this app runs that same
    /// `vigild kill` itself, which races nothing (what a restore runs from
    /// is gone before the signal).
    func killDaemons(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let unfenced = fence(ids)
        if !unfenced.isEmpty {
            graveyardLog.error("!! close not fenced; asked all the same (vigild's kill fences it first)", ["panes": unfenced.sorted()])
        }
        // Never behind a birth or a restore (`lifeQueue`).
        deliverClose(ids)
    }

    /// How long a reap whose fence failed waits before it tries again.
    static let fenceRetry: TimeInterval = 10

    /// The close's durable intent, in this turn, before the registry
    /// without these panes is saved (a tick later): vigild's closed mark
    /// (`PaneFence`), durably accepted (written or found, and synced), the
    /// one word every party reads. From here no birth of these panes runs,
    /// and the lifecycle service finishes the close (it watches the marks)
    /// after a crash or a reboot as well; it waits on no lock. The panes
    /// whose fence was not accepted.
    func fence(_ ids: Set<String>, repairInvalid: Bool = false) -> Set<String> {
        var failed = Set<String>()
        for id in ids.sorted() {
            do { try PaneFence.fence(id, in: VigilPaths.panes, repairInvalid: repairInvalid) } catch {
                graveyardLog.error("!! close not fenced", ["pane": id, "err": error])
                failed.insert(id)
            }
        }
        return failed
    }

    /// The closes fenced and not finished (marks not `clean`), finished: at
    /// launch, after the restore and the orphans. The service finishes them
    /// at its own start too; this one is for a service that does not answer.
    func finishPendingCloses() {
        switch PaneFence.unfinished(in: VigilPaths.panes) {
        case .failure(let failure):
            graveyardLog.error("!! closes not finished cannot be listed", ["err": failure])
        case .success(let pending):
            if !pending.unreadable.isEmpty {
                graveyardLog.error("!! closes' marks that cannot be read: nothing is decided about them", ["panes": pending.unreadable])
            }
            guard !pending.fenced.isEmpty else { return }
            graveyardLog.warn("closes left unfinished; finishing them", ["panes": pending.fenced])
            Self.closeQueue.async { Self.closePanes(Set(pending.fenced), why: "unfinished") }
        }
    }

    /// Provisional births the registry now holds, told to the service
    /// (`adopt`). Not answered, they stay provisional and are adopted at the
    /// next launch, which finds them listed.
    nonisolated static func adopt(_ panes: Set<String>) {
        lifeQueue.async {
            switch PaneLifeClient.settle(PaneLife.Request(.adopt, panes: panes.sorted())) {
            case .answered(let reply) where reply.ok:
                daemonLog.info("provisional panes adopted", ["panes": panes.sorted()])
            case let other:
                daemonLog.warn("provisional panes not adopted yet; the next launch adopts them", ["panes": panes.sorted(), "said": "\(other)"])
            }
        }
    }

    func conflictingOwnership(_ ids: Set<String>) -> Bool {
        let conflicts = Registry.conflictingPanes(in: (Array(workspaces.values) + Array(graveyard.values)).map(ownedPaneIds))
            .intersection(ids)
        if !conflicts.isEmpty { graveyardLog.error("ownership conflict prevents pane transfer or close", ["panes": conflicts.sorted()]) }
        return !conflicts.isEmpty
    }

    func undoAllowed(burial name: String) -> Bool {
        guard let burial = graveyard[name] else { return false }
        let members = ownedPaneIds(burial)
        guard !conflictingOwnership(members) else { return false }
        let states = members.map { ($0, memberMark($0)) }
        switch Registry.Workspace.undoDecision(closing: burial.closing, marks: states.map(\.1)) {
        case .allowed: return true
        case .unreadable:
            graveyardLog.warn("undo unavailable until the member marks can be read", ["burial": name])
        case .closing:
            if burial.closing == nil {
                graveyard[name]?.closing = states.filter { !PaneFence.provesClose($0.1) }.map(\.0).sorted()
                persist()
            }
        }
        return false
    }

    func permitsJoin(_ pane: String, undoIn workspace: String? = nil) -> Bool {
        guard !conflictingOwnership([pane]) else { return false }
        let at = locate(pane)
        let origin: Registry.JoinOrigin = at.map { $0.buried ? .buried : .live(workspace: $0.owner) }
            ?? .unowned(minted: fresh.contains(pane))
        return origin.permits(undoIn: workspace) { at.map { undoAllowed(burial: $0.owner) } ?? false }
    }



    /// Every close, one at a time, off the main thread and apart from
    /// births (`lifeQueue`).
    nonisolated static let closeQueue = DispatchQueue(label: "vigil.pane-close", qos: .userInitiated)

    /// A close, on `closeQueue`, fenced already (`killDaemons`). Finished
    /// only when vigild's files say so (`PaneLifeClient.closed`: the mark
    /// `clean`, which vigild's kill writes once daemon, recipe and launchd
    /// job are gone, no spec, no daemon). Asked of the lifecycle service;
    /// when nothing reached it, it did not answer in time or it left a pane
    /// unfinished, this app runs the same `vigild kill` itself (bounded:
    /// vigild waits at most 15 s for the lifecycle lock, its mark written
    /// before). What is still unfinished stays so on disk, for the service
    /// and the next launch.
    nonisolated static func closePanes(_ ids: Set<String>, why: String) {
        let sorted = ids.sorted()
        let ask = PaneLifeClient.settle(PaneLife.Request(.close, panes: sorted))
        let isClosed: (String) -> Bool = { PaneLifeClient.closed($0, daemonAlive: VigilWorkspaces.daemonAlive) }
        if case .answered(let reply) = ask, !reply.ok {
            graveyardLog.error("close refused by the lifecycle service", ["panes": sorted, "err": reply.error])
        }
        var open = sorted.filter { !isClosed($0) }
        if !open.isEmpty {
            graveyardLog.warn("closing here with vigild kill", ["panes": open, "service": "\(ask)"])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: vigildBin)
            p.arguments = ["kill"] + open
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // vigild kill bounds its own wait (it escalates to SIGKILL).
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                graveyardLog.error("!! vigild kill could not run", ["panes": open, "err": error])
            }
            open = open.filter { !isClosed($0) }
        }
        let done = sorted.filter { !open.contains($0) }
        let agentDir = VigilPaths.state
        for id in done {
            try? FileManager.default.removeItem(at: agentDir.appendingPathComponent("\(id).state"))
            try? FileManager.default.removeItem(at: agentDir.appendingPathComponent("\(id).seen"))
        }
        if !done.isEmpty {
            DispatchQueue.main.async { VigilWorkspaces.shared.resumeForks(for: Set(done)) }
        }
        if open.isEmpty {
            graveyardLog.success("panes closed, verified", ["panes": sorted, "why": why])
        } else {
            graveyardLog.error("panes fenced, their close not finished; the lifecycle service finishes it", ["panes": open, "why": why])
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
    /// `vigild restore` at every launch, not only at login. A spec with no
    /// live daemon can only mean a machine-death-class event: a deliberate
    /// kill unlinks the spec BEFORE signaling, so respawning from a spec is
    /// never wrong. The login agent alone is not enough: an interrupted
    /// logout SIGTERMs every daemon and leaves launchd's restore spawn
    /// "pending" with no login to follow. Of the panes the registry lists
    /// (a workspace's or a burial's) and no other, so nothing restored is
    /// ever an orphan; awaited off the main thread like every restore
    /// (a stuck service never holds the launch). A spec no
    /// registry lists is closed by `collectOrphans`.
    func respawnMachineKilledDaemons() {
        restoreDied(why: "launch")
    }

    /// The views of these panes that have no stream dial: their daemons
    /// listen now (`<pane>.up`, or a birth this app just made). Mirrors
    /// too; a remote pane's stream is its hub's to redial. Asked of every
    /// view of the pane, whatever this thread last heard of its stream: a
    /// reader that lost it may be waiting already while the word of that is
    /// still on its way here, and an ask it does not need waits in its pipe
    /// and costs one dial at its next loss.
    func redial(_ panes: [String]) {
        guard !panes.isEmpty else { return }
        let ids = Set(panes)
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects
        where view.vigilHost == nil && view.vigilAttachId.map(ids.contains) == true {
            view.vigilRedial()
        }
    }

    /// The pane lifecycle service's restore of `panes` and no others; every
    /// spec when none is named (launch, before anything is read). What it
    /// said of each pane it did not bring up ("refused: …", "held: …",
    /// "ended"), by pane. Nothing reaching the service, or no answer in its
    /// deadline, is said of every pane named: the first restores nothing
    /// (the service restores at its own start), the second may have (each
    /// pane's files say).
    /// `person`: a person's act asked for these panes (it brings them back
    /// even when the service held them).
    @discardableResult
    nonisolated static func restoreFromSpecs(why: String, panes: [String] = [], person: Bool = false, deadline: Duration? = nil) -> [String: String] {
        switch PaneLifeClient.settle(PaneLife.Request(.restore, panes: panes, person: person), deadline: deadline) {
        case .answered(let reply):
            guard reply.ok else {
                daemonLog.error("restore refused by the lifecycle service", ["why": why, "err": reply.error])
                return Dictionary(uniqueKeysWithValues: panes.map { ($0, reply.error ?? "the lifecycle service refused the restore") })
            }
            let notUp = reply.outcomes.filter { $0.outcome != "up" && $0.outcome != "alive" }
            let respawned = reply.outcomes.filter { $0.outcome == "up" }.map(\.pane)
            if !respawned.isEmpty || !notUp.isEmpty {
                daemonLog.info("daemons restored from their specs by the lifecycle service", [
                    "respawned": respawned, "why": why, "others": notUp.map { "\($0.pane) \($0.outcome)" },
                ])
            }
            return Dictionary(notUp.map { ($0.pane, "\($0.outcome)\($0.said.map { ": \($0)" } ?? "")") }, uniquingKeysWith: { $1 })
        case .unanswered(let why):
            daemonLog.error("restore not asked: nothing reached the lifecycle service", ["why": why])
            return Dictionary(uniqueKeysWithValues: panes.map { ($0, why) })
        case .indeterminate(let said):
            daemonLog.error("restore asked, outcome not known", ["why": why, "said": said])
            return Dictionary(uniqueKeysWithValues: panes.map { ($0, "not known whether it was restored: \(said)") })
        }
    }

    func collectOrphans() {
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
            daemonLog.warn("orphan collection skipped: another instance of this bundle is running")
            return
        }
        recoverUnlistedPanes()
    }

    func recoverUnlistedPanes() {
        var owned = Set<String>()
        for session in workspaces.values { owned.formUnion(ownedPaneIds(session)) }
        for session in graveyard.values { owned.formUnion(ownedPaneIds(session)) }

        let fm = FileManager.default
        // The inventory everything below decides from; one that cannot be
        // taken decides nothing, and an incomplete read stays on record.
        let entries: [String]
        let provisional: Set<String>
        do {
            entries = try fm.contentsOfDirectory(atPath: vigildStateDir.path)
            provisional = try PaneLife.provisionals(in: VigilPaths.agent).get()
        } catch {
            daemonLog.error("!! the panes on disk cannot be listed: nothing is closed, cleaned or settled this launch", ["err": error])
            return
        }
        func ids(_ suffix: String) -> Set<String> {
            Set(entries.filter { $0.hasSuffix(suffix) && $0.hasPrefix("vigil-") }.map { String($0.dropLast(suffix.count)) })
        }
        let specs = ids(".spec")
        let live = ids(".lock").filter { !owned.contains($0) && Self.daemonAlive($0) }
        // A pane something on disk still speaks of (its end, its resume
        // pointer) is accounted for like one with a recipe.
        let evidence = ids(".ended").union(ids(".resume")).union(ids(".pid")).union(ids(".up"))
        // A pane is closed or cleaned here only on the proof of a removal,
        // its close's mark. Absence from a registry that decoded
        // proves nothing, a provisional record proves nothing (its edit may
        // have committed), and a mark that cannot be read proves
        // nothing either: such panes are kept, and counted.
        let states = Dictionary(uniqueKeysWithValues: specs.union(live).union(evidence).union(provisional).subtracting(owned).map {
            ($0, PaneFence.state($0, in: VigilPaths.panes))
        })
        let closed = Set(states.filter { PaneFence.provesClose($0.value) }.keys)
        let unreadable = Set(states.filter { if case .unreadable = $0.value { return true } else { return false } }.keys)
        let unlisted = PaneLife.Unlisted(owned: owned.union(births), specs: specs, live: live, evidence: evidence, fenced: closed,
                                         provisional: provisional.subtracting(births), unreadable: unreadable)
        if !unlisted.closes.isEmpty {
            daemonLog.warn("closes no registry lists, finished", ["panes": unlisted.closes.sorted()])
            Self.closeQueue.async { Self.closePanes(unlisted.closes, why: "unlisted, fenced") }
        }
        let recovered = unlisted.lost.union(unlisted.uncertain).union(unlisted.unknown)
        var listed = owned
        if !recovered.isEmpty {
            let name = newWorkspaceId()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var workspace = Workspace(name: name, label: "Recovered panes", cwd: home)
            workspace.tabs = recovered.sorted().map { pane in
                let recipe = VigilPaths.panes.appendingPathComponent(pane + ".spec")
                let cwd = (try? String(contentsOf: recipe, encoding: .utf8))?.components(separatedBy: "\n").first
                return Registry.Tab(panes: [.init(id: pane, cwd: cwd ?? home)], layout: nil)
            }
            if admit(workspace, "recovered panes"), persist(publish: false, durable: true) {
                listed.formUnion(recovered)
                daemonLog.info("unlisted panes recovered into workspace", ["workspace": name, "panes": recovered.sorted()])
            } else {
                daemonLog.error("could not commit recovered pane ownership", ["panes": recovered.sorted()])
            }
        }
        let adopted = provisional.intersection(listed)
        if !adopted.isEmpty { Self.adopt(adopted) }
        if unlisted.settled, registryRead != .current, registryRead != .absent {
            // Nothing on disk depends on what the incomplete read missed.
            do {
                try PaneLife.RegistryProvenance(file: provenanceURL).clear()
                daemonLog.info("the registry's incomplete read is settled: every pane on disk is listed or closed", ["was": registryRead.rawValue])
            } catch {
                daemonLog.error("!! the registry's incomplete read could not be cleared", ["err": error])
            }
        }
        // What a closed pane left that no close removed: only of a pane with
        // its mark, whatever the registry says.
        let fenced = { (pane: String) in PaneFence.provesClose(PaneFence.state(pane, in: VigilPaths.panes)) }
        for entry in entries where entry.hasPrefix("vigil-") && (entry.hasSuffix(".resume") || entry.hasSuffix(".ended")) {
            let id = String(entry.prefix(upTo: entry.lastIndex(of: ".")!))
            guard !owned.contains(id), fenced(id), !Self.daemonAlive(id) else { continue }
            try? fm.removeItem(at: vigildStateDir.appendingPathComponent(entry))
            try? fm.removeItem(at: vigildStateDir.appendingPathComponent(entry + (entry.hasSuffix(".resume") ? ".seal" : ".txt")))
            daemonLog.info("what a closed pane left removed", ["pane": id, "file": entry])
        }
        for entry in (try? fm.contentsOfDirectory(atPath: agentStateDir.path)) ?? []
        where entry.hasSuffix(".state") || entry.hasSuffix(".seen") {
            let id = String(entry.prefix(upTo: entry.lastIndex(of: ".")!))
            guard !owned.contains(id), fenced(id), !Self.daemonAlive(id) else { continue }
            try? fm.removeItem(at: agentStateDir.appendingPathComponent(entry))
        }
    }

}
