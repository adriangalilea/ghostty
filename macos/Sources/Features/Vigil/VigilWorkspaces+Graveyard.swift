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
        guard workspaces[name] != nil else { vlog("kill: '\(name)' NOT in workspaces (noop)"); return }
        vlog("kill: '\(name)' at \(placeTag(name)) -> graveyard")
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
        if let kept {
            if let next = successor(excluding: name), let ghostty = ghosttyApp {
                vlog("kill: viewport of '\(name)' -> '\(next)'")
                mount(next, into: kept, ghostty: ghostty)
                touchRecent(next)
            } else {
                killController(kept) // nothing left to view: the window closes
            }
        }
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
        graveyard[name] = session
        graveyardDeadlines[name] = Date().addingTimeInterval(Self.killGrace)

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.undoManager.registerUndo(
                withTarget: self,
                expiresAfter: .seconds(Int64(Self.killGrace))
            ) { manager in
                manager.exhume(name)
            }
            appDelegate.undoManager.setActionName("Kill Workspace")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace + 1) { [weak self] in
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
    struct SidebarBurial: Identifiable, Equatable {
        let id: String
        let emoji: String?
        let label: String
        let remaining: Int
    }

    func sidebarBurials() -> [SidebarBurial] {
        burials().map {
            SidebarBurial(
                id: $0.name,
                emoji: $0.emoji,
                label: $0.label,
                remaining: max(0, Int($0.deadline.timeIntervalSinceNow)))
        }
    }

    func burials() -> [Burial] {
        graveyard.values.compactMap { session in
            guard let deadline = graveyardDeadlines[session.name] else { return nil }
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
            info: "\(busy.joined(separator: ", ")) still running. Undo within \(Int(Self.killGrace))s.",
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

    /// Undo of a kill: back from the graveyard as a full session (identity
    /// included), everything still running.
    func exhume(_ name: String) {
        guard var session = graveyard.removeValue(forKey: name) else { return }
        session.layoutShape = "" // undo is a new revision, even for the same shape
        graveyardDeadlines[name] = nil
        workspaces[name] = session
        persist()
        open(name: name)
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
    func reapNow(_ name: String) {
        graveyardDeadlines[name] = Date.distantPast
        reapIfExpired(name)
    }

    /// The grace ran out: now the death actually happens. The burial's
    /// registry names every daemon; its held runtimes release (views free
    /// synchronously, a leaked view elsewhere changes nothing); then the
    /// daemons are killed AND VERIFIED dead. No deferral, no sweep, no
    /// dependence on what ARC happens to hold.
    func reapIfExpired(_ name: String) {
        guard let deadline = graveyardDeadlines[name], Date() >= deadline,
              let session = graveyard[name] else { return }
        let ids = ownedPaneIds(session)
        for runtime in session.held { runtime.dock?.unmount() }
        dropBurial(name)
        // Death is explicit for the surfaces too: every view attached to a
        // reaped pane is destroyed BEFORE its daemon dies (the UAF order),
        // whoever still holds the Swift object. Left to ARC, an unknown
        // retainer kept reaped panes' surfaces running for days and the
        // leak tripwire said so thousands of times.
        let doomed = Ghostty.SurfaceView.vigilAttachSurfaces.allObjects
            .filter { $0.vigilHost == nil && $0.vigilAttachId.map(ids.contains) == true }
        for view in doomed { view.vigilDestroySurface() }
        vlog("reap: '\(name)' -> destroyed \(doomed.count) surface(s), kill \(ids.sorted())")
        killDaemons(ids)
        persist()
    }

    /// Kill pane daemons, deterministically: one `vigild kill` with every
    /// id, which unlinks their survival state, signals, and WAITS until
    /// each is gone (escalating to SIGKILL). Off the main thread (a stuck
    /// daemon must not freeze the app); the verification screams into the
    /// log and the state files of the dead are pruned when it returns.
    private func killDaemons(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let bin = Self.vigildBin
        let sorted = ids.sorted()
        let stateDir = vigildStateDir
        let agentDir = agentStateDir
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["kill"] + sorted
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let survivors = sorted.filter { VigilWorkspaces.daemonAlive($0) }
            for id in sorted where !survivors.contains(id) {
                try? FileManager.default.removeItem(at: agentDir.appendingPathComponent("\(id).state"))
                try? FileManager.default.removeItem(at: agentDir.appendingPathComponent("\(id).seen"))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let manager = VigilWorkspaces.shared
                    if survivors.isEmpty {
                        manager.vlog("kill: \(sorted) dead (verified)")
                    } else {
                        manager.vlog("!! kill: \(survivors) STILL ALIVE after vigild kill (status \(p.terminationStatus))")
                    }
                }
            }
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
    /// "pending" with no login to follow. Synchronous
    /// and before collectOrphans, so a restored daemon is never read as
    /// an orphan of a session the registry still lists.
    func respawnMachineKilledDaemons() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.vigildBin)
        proc.arguments = ["restore"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            let respawned = lines.filter { $0.hasSuffix(" up") }.count
            if respawned > 0 || proc.terminationStatus != 0 {
                vlog("restore(daemons): \(respawned) machine-killed daemon(s) respawned from their specs (exit \(proc.terminationStatus))")
                for line in lines where !line.hasSuffix(" up") { vlog("restore(daemons): \(line)") }
            }
        } catch {
            vlog("!! restore(daemons): vigild restore could not run (\(error))")
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
            vlog("collect: skipped, another instance of this bundle is running")
            return
        }

        var owned = Set<String>()
        for session in workspaces.values { owned.formUnion(ownedPaneIds(session)) }
        for session in graveyard.values { owned.formUnion(ownedPaneIds(session)) }

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: vigildStateDir.path)) ?? []
        var orphans = Set<String>()
        for entry in entries where entry.hasSuffix(".lock") && entry.hasPrefix("vigil-") {
            let id = String(entry.dropLast(".lock".count))
            if !owned.contains(id), Self.daemonAlive(id) { orphans.insert(id) }
        }
        if !orphans.isEmpty {
            vlog("collect: orphan daemons \(orphans.sorted()) -> kill")
            killDaemons(orphans)
        }
        for entry in entries where entry.hasSuffix(".resume") && entry.hasPrefix("vigil-") {
            let id = String(entry.dropLast(".resume".count))
            guard !owned.contains(id), !Self.daemonAlive(id) else { continue }
            try? fm.removeItem(at: vigildStateDir.appendingPathComponent(entry))
            vlog("collect: stale resume pointer '\(id)' removed")
        }
        for entry in (try? fm.contentsOfDirectory(atPath: agentStateDir.path)) ?? []
        where entry.hasSuffix(".state") || entry.hasSuffix(".seen") {
            let id = String(entry.prefix(upTo: entry.lastIndex(of: ".")!))
            guard !owned.contains(id), !Self.daemonAlive(id) else { continue }
            try? fm.removeItem(at: agentStateDir.appendingPathComponent(entry))
        }
    }

}
