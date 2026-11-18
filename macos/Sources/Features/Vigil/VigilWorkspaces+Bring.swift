import AppKit
import Ink
import SwiftUI
import VigilWire

/// Bring Here (PORTABILITY.md "The design"): a workspace of another Mac,
/// here or away, arrives on this one as itself. The registry gains the
/// workspace with its tabs, splits and pane names; nothing runs. Each pane
/// is dormant until its first mount, which starts it as any captured pane
/// starts: its daemon reads the resume pointer vigil-agent sealed for it.
extension VigilWorkspaces {
    /// The `bring` workspace command, from the sidebar or `vigil move`.
    func bring(_ request: VigilSessionControl.Request) -> VigilSessionControl.Reply {
        guard let device = request.from, let host = VigilRemote.shared.host(device), let directory = host.directory,
              let whole = directory.live.first(where: { $0.name == request.session }) else {
            return .failure(request, "not_found", "This Mac has not heard that workspace from that Mac.")
        }
        guard let source = request.part.map({ whole.only($0, of: request.anchor) }) ?? whole else {
            return .failure(request, "not_found", "That workspace has no such pane on that Mac.")
        }
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        let names = directory.conversationNames(of: source)
        let members = Set(source.paneIds)
        let revisions = directory.panes.filter { members.contains($0.key) }.compactMapValues(\.moveRevision)
        guard Set(revisions.keys) == members,
              let digest = try? Registry.Workspace.moveDigest(label: whole.label, emoji: whole.emoji, cwd: whole.cwd, pinned: whole.pinned ?? false, revision: whole.layoutRevision,
                                                               tabs: whole.tabs ?? [], facts: revisions) else {
            return .failure(request, "source_unknown", "The home Mac has not published a complete version of these panes. Refresh it before moving them.")
        }
        for pane in members {
            guard let facts = directory.panes[pane], let version = revisions[pane] else {
                return .failure(request, "source_unknown", "The source pane facts are unavailable.")
            }
            let fields = version.split(separator: "/")
            guard fields.count == 10, fields[2] == "-" || facts.ended != nil,
                  fields[3] == "-" || facts.meaning?.conversation != nil,
                  facts.glanceError == nil, facts.conflict == nil else {
                return .failure(request, "source_unknown", "The end or conversation of \(pane) could not be transferred with certainty. The source stays open.")
            }
        }
        let name = newWorkspaceId()
        let owned = (Array(workspaces.values) + Array(graveyard.values)).reduce(into: Set<String>()) {
            $0.formUnion(ownedPaneIds($1))
        }
        let entry: Registry.Workspace
        do {
            var floor = 0
            entry = try source.brought(as: name, from: device, mac: host.name, at: Date().timeIntervalSince1970,
                                       home: directory.home, here: here, order: (workspaces.values.map(\.order).max() ?? 0) + 1,
                                       names: names) {
                let index = try PaneLife.reserve(workspace: name, startingAt: floor, owned: owned,
                                                 panes: VigilPaths.panes, agent: VigilPaths.agent, arrival: true)
                floor = index + 1
                return index
            }
        } catch {
            return .failure(request, "allocation_failed", "This Mac could not reserve the arriving panes: \(error)")
        }
        var retainFiles = false
        defer {
            if !retainFiles {
                for pane in entry.paneIds {
                    for suffix in [".ended", ".resume", ".resume.seal"] {
                        let file = VigilPaths.panes.appendingPathComponent(pane + suffix)
                        do { try Durable.remove(file) } catch {
                            lifecycleLog.error("could not remove an uncommitted arrival file", ["file": file.path, "err": error])
                        }
                    }
                }
            }
        }
        // An end belongs to the imported pane too. Its first opening
        // must use the same shell-only path as an opening at home.
        do {
            for (old, new) in zip(source.paneIds, entry.paneIds) {
                if let end = directory.panes[old]?.ended {
                    try Durable.replace(VigilPaths.panes.appendingPathComponent(new + ".ended"), with: JSONEncoder().encode(end))
                }
            }
        } catch {
            return .failure(request, "end_unavailable", "The source is still open. Its end record could not be saved here.")
        }
        // The pointers first: a pane is in the registry only once its first
        // start can find what it resumes.
        let lines: [Bring.Line]
        do {
            let answer = try Local.Client(socket: VigilPaths.hub).bring(
                Bring.Question(panes: directory.bringing(source, as: entry, here: here), commit: true))
            guard answer.failed.isEmpty else { return .failure(request, "resume_failed", answer.failed.values.sorted().joined(separator: "\n")) }
            lines = answer.lines
        } catch {
            lifecycleLog.error("not brought: vigil-agent did not write its resume pointers", ["workspace": source.name, "from": host.name, "err": error])
            return .failure(request, "agent_unreachable", "vigil-agent did not answer, so nothing was brought (\(error)).")
        }
        var session = Workspace(name: entry.name, label: entry.label, emoji: entry.emoji, cwd: entry.cwd, tabs: entry.tabs ?? [],
                                order: entry.order ?? 0)
        session.paneSeq = entry.paneSeq ?? session.tabs.flatMap(\.members).count
        session.pinned = entry.pinned ?? false
        session.layoutShape = VigilSessionControl.revision(session.tabs)
        if let difference = source.differs(fromBrought: entry, names: names) {
            return .failure(request, "commit_failed", "The destination differs: " + difference)
        }
        guard admit(session, "brought") else {
            return .failure(request, "commit_failed", "This Mac's registry already lists that workspace's name or one of its panes; nothing was brought.")
        }
        guard persist(publish: false, durable: true) else {
            retainFiles = registryInstallUncertain
            if !retainFiles { workspaces[entry.name] = nil }
            return .init(id: request.id, ok: false, code: "commit_unknown", message: "The copy \(entry.name) could not be confirmed. The source stays open.", session: entry.name)
        }
        retainFiles = true
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([Registry.Workspace].self, from: data),
              let kept = saved.first(where: { $0.name == entry.name && $0.buriedUntil == nil }), kept.tabs == entry.tabs else {
            return .init(id: request.id, ok: false, code: "commit_unknown", message: "The destination \(entry.name) was written but could not be verified. The source stays open.", session: entry.name)
        }
        persist()
        lifecycleLog.info("brought", [
            "workspace": entry.name, "from": host.name, "was": source.name, "tabs": session.tabs.count,
            "panes": session.tabs.flatMap(\.members).count, "resuming": lines.filter { $0.transcriptHere == true && $0.folderHere }.count,
            "lacking": lines.filter { !$0.lacks.isEmpty }.count,
        ])
        if lines.contains(where: { line in
            line.conversation != nil && (!line.folderHere || line.transcriptHere != true || line.needs.contains { $0.kind == .transcript })
        }) {
            return .init(id: request.id, ok: true, code: "copied", message: "Copied here. The source stays open because its conversation could not be transferred in full.", session: entry.name)
        }
        // Its Mac is told: those panes close there, so the conversation is
        // written on one Mac. Kept by the hub while that Mac is away.
        let told = WorkspaceCommand.Request.moved(
            source.name, panes: (source.tabs ?? []).flatMap(\.paneIds), to: Host.current().localizedName ?? "another Mac", digest: digest)
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try Local.Client(socket: VigilPaths.hub).call(device: device, .session(try told.line))
                lifecycleLog.info("its Mac told of the move (delivered, or kept until it is back)", ["workspace": source.name, "mac": host.name, "request": told.id])
            } catch {
                lifecycleLog.error("its Mac not told of the move: the workspace stays open there too", ["workspace": source.name, "mac": host.name, "err": error])
            }
        }
        return VigilSessionControl.Reply(id: request.id, ok: true, code: "committed", message: "Brought here; nothing runs until a pane is opened.",
                                         revision: workspaces[entry.name]?.layoutRevision, session: entry.name)
    }

    static func moveRevision(_ pane: String) -> String? {
        let root = VigilPaths.panes.deletingLastPathComponent()
        var revision = ""
        for (folder, ext) in [("panes","up"), ("panes","pid"), ("panes","ended"), ("panes","resume"), ("panes","command"), ("state","state"), ("state","glance"), ("panes","tree"), ("state","conflict"), ("state","work")] {
            var info = stat()
            let file = root.appendingPathComponent(folder).appendingPathComponent(pane + "." + ext)
            if stat(file.path, &info) == 0 {
                let time = info.st_mtimespec
                revision += "\(info.st_ino)-\(time.tv_sec * 1_000_000_000 + time.tv_nsec)/"
            } else if errno == ENOENT {
                revision += "-/"
            } else { return nil }
        }
        return revision
    }

    /// The conditional move-completion, from the Mac that brought panes of a
    /// workspace here: those panes close here as any pane closes (recently
    /// closed and undoable for its grace, then ended), each burial saying
    /// where they went. All of the workspace's panes: the workspace. Panes
    /// born here since that Mac last heard are not named and stay.
    func moved(_ request: VigilSessionControl.Request) -> VigilSessionControl.Reply {
        typealias Reply = VigilSessionControl.Reply
        guard let moved = request.moved else { return .failure(request, "invalid_request", "A move names the panes that left.") }
        func done(_ message: String) -> Reply {
            Reply(id: request.id, ok: true, code: "committed", message: message, revision: workspaces[request.session]?.layoutRevision, session: request.session)
        }
        guard let session = workspaces[request.session] else { return done("Nothing of it is open here.") }
        var revisions: [String: String] = [:]
        for pane in moved.panes {
            guard let revision = Self.moveRevision(pane) else {
                return .failure(request, "source_unknown", "A pane could not be checked. The workspace is still here.")
            }
            revisions[pane] = revision
        }
        guard let digest = try? Registry.Workspace.moveDigest(label: session.label, emoji: session.emoji, cwd: session.cwd, pinned: session.pinned,
                                                              revision: session.layoutRevision, tabs: session.tabs, facts: revisions),
              digest == request.revision else {
            return .failure(request, "source_changed", "The source changed after the destination saw it. Both copies were kept.")
        }
        let leaving = Set(moved.panes).intersection(session.tabs.flatMap(\.paneIds))
        guard !leaving.isEmpty else { return done("None of those panes is open here.") }
        movingTo = moved.mac
        movingRevisions = revisions
        defer { movingTo = nil; movingRevisions = nil }
        lifecycleLog.info("panes brought to another Mac close here", ["workspace": request.session, "to": moved.mac, "panes": leaving.sorted()])
        if leaving == Set(session.tabs.flatMap(\.paneIds)) {
            kill(name: request.session)
            guard persist(publish: false, durable: true) else { return .failure(request, "commit_unknown", "The source burial could not be confirmed.") }
            return done("Closed here: it is on \(moved.mac) now.")
        }
        // Tab by tab from the registry as it stands: a tab that left whole
        // closes as one, else its panes that left, one by one.
        for pane in moved.panes where leaving.contains(pane) {
            refreshWorkspaceRevisions()
            guard let now = workspaces[request.session], let tab = now.tabs.first(where: { $0.paneIds.contains(pane) }) else { continue }
            let whole = Set(tab.paneIds).isSubset(of: leaving)
            let reply = applySessionEdit(VigilSessionControl.Request(
                session: request.session, revision: now.layoutRevision, operation: whole ? "close_tab" : "close_pane", anchor: pane))
            guard reply.ok else {
                lifecycleLog.error("a pane brought to another Mac did not close here", ["pane": pane, "why": reply.message])
                return .failure(request, reply.code, "Not every pane closed on its Mac: \(reply.message)")
            }
        }
        return done("Closed here: they are on \(moved.mac) now.")
    }

    /// Every pane brought here and not started yet.
    var dormantPanes: Set<String> {
        Set(workspaces.values.flatMap { $0.tabs.flatMap(\.members) }.filter { $0.dormant == true }.map(\.id))
    }

    /// A brought pane's daemon exists: it is a pane like any other from now.
    func wake(_ started: Set<String>) {
        guard !started.isEmpty else { return }
        for (name, session) in workspaces {
            var tabs = session.tabs
            var changed = false
            for t in tabs.indices {
                for p in tabs[t].panes.indices where started.contains(tabs[t].panes[p].id) && tabs[t].panes[p].dormant == true {
                    tabs[t].panes[p].dormant = nil
                    changed = true
                }
                guard var dock = tabs[t].dock else { continue }
                for p in dock.panes.indices where started.contains(dock.panes[p].id) && dock.panes[p].dormant == true {
                    dock.panes[p].dormant = nil
                    changed = true
                }
                tabs[t].dock = dock
            }
            if changed {
                workspaces[name]!.tabs = tabs
                lifecycleLog.info("brought panes started", ["workspace": name, "panes": Array(started)])
            }
        }
    }

    // MARK: Move to (VigilWire's `Move`)

    /// Every Mac a workspace of `home` (nil: this Mac) may move to: the
    /// paired Macs serving vigil as this Mac hears them, one out of reach
    /// said as its header says it.
    func moveTargets(home: String?) -> [Move.Target] {
        Move.targets(home: home, macs: VigilRemote.shared.hosts.map { host in
            Move.Mac(device: host.device, name: host.name,
                     unreachable: host.error == nil ? nil : host.away ? host.received.map(VigilRemote.awaySince) ?? host.error : host.error)
        })
    }

    /// A row's move: the dialog of what stands between the workspace (or the
    /// tab or pane of its pane `anchor`, `part`) and `target`, then the move,
    /// done by the target. To this Mac it is the Bring Here this Mac does;
    /// to another, the dialog is that Mac's sheet and the move is asked of it.
    func moveWithSheet(_ home: RowHome, to target: Move.Target, anchor: String = "", part: Registry.Workspace.Part? = nil) {
        guard let device = target.device else {
            guard let source = home.device else { return lifecycleLog.error("a move to this Mac of its own workspace", ["workspace": home.workspace]) }
            return bringWithSheet(device: source, workspace: home.workspace, anchor: anchor, part: part)
        }
        // Only its name is read here: what moves is read by the target, from
        // what it heard of the workspace's Mac.
        let sourceHost = home.device.flatMap(VigilRemote.shared.host)
        guard let label = home.device == nil
            ? workspaces[home.workspace]?.label
            : sourceHost?.directory?.live.first(where: { $0.name == home.workspace })?.label
        else { return lifecycleLog.error("move: the workspace is not listed", ["workspace": home.workspace, "to": target.name]) }
        let targetHome = VigilRemote.shared.host(device)?.directory?.home
        let sourceHome = home.device == nil ? FileManager.default.homeDirectoryForCurrentUser.path : sourceHost?.directory?.home
        let hub = Local.Client(socket: VigilPaths.hub)
        let workspace = home.workspace
        let homeDevice = home.device
        lifecycleLog.info("move: reading the sheet there", ["workspace": workspace, "to": target.name, "part": part?.rawValue ?? "all"])
        DispatchQueue.global(qos: .userInitiated).async {
            let read = Result { () throws -> (from: String, answer: Bring.Answer) in
                let from = try homeDevice ?? hub.me()
                return (from, try hub.bringSheet(device: device, Move.Ask(from: from, workspace: workspace, anchor: anchor, part: part)))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let manager = VigilWorkspaces.shared
                    switch read {
                    case .failure(let error):
                        lifecycleLog.error("move sheet not read", ["workspace": workspace, "to": target.name, "err": error])
                        let alert = NSAlert()
                        alert.messageText = "Can't move \(label) to \(target.name)"
                        alert.informativeText = "\(target.name) did not answer: \(error)"
                        alert.runModal()
                    case .success(let (from, answer)):
                        let ask = Move.Ask(from: from, workspace: workspace, anchor: anchor, part: part)
                        let model = BringDialogModel(
                            workspace: workspace, anchor: anchor, part: part, mac: sourceHost?.name ?? "this Mac", target: target.name,
                            what: Self.moving(label, part), away: Self.away(sourceHost), home: targetHome ?? "/",
                            lines: answer.lines, read: { _ in try hub.bringSheet(device: device, ask) })
                        manager.present(model, source: homeDevice, sourceHome: sourceHome, targetHome: targetHome) {
                            guard let order = Move.order(workspace, home: homeDevice, to: target, me: from, anchor: anchor, part: part) else {
                                return lifecycleLog.error("move: no order", ["workspace": workspace, "to": target.name])
                            }
                            manager.ask(RowHome(device: device, workspace: workspace), order.request, failing: "\(label) was not moved to \(target.name)")
                        }
                    }
                }
            }
        }
    }

    private static func moving(_ label: String, _ part: Registry.Workspace.Part?) -> String {
        switch part {
        case .tab: "this tab of \(label)"
        case .pane: "this pane of \(label)"
        case nil: label
        }
    }

    private static func away(_ host: VigilRemote.Host?) -> String? {
        guard let host, host.away else { return nil }
        return host.received.map { String(VigilRemote.awaySince($0).dropFirst("away since ".count)) }
    }

    /// The sidebar's Bring Here on a workspace of another Mac: the sheet of
    /// what this Mac knows about each pane, then the move. On a tab or a
    /// pane row: that much of it (`part` of the pane `anchor`).
    func bringWithSheet(device: String, workspace name: String, anchor: String = "", part: Registry.Workspace.Part? = nil) {
        guard let host = VigilRemote.shared.host(device), let directory = host.directory,
              let whole = directory.live.first(where: { $0.name == name }),
              let source = part.map({ whole.only($0, of: anchor) }) ?? whole else { return }
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        let hub = Local.Client(socket: VigilPaths.hub)
        let lines: [Bring.Line]
        do {
            lines = try hub.bring(Bring.Question(panes: directory.bringing(source, here: here), commit: false)).lines
        } catch {
            lifecycleLog.error("bring sheet not read", ["workspace": name, "from": host.name, "err": error])
            let alert = NSAlert()
            alert.messageText = "Can't bring \(source.label) here"
            alert.informativeText = "vigil-agent did not answer: \(error)"
            alert.runModal()
            return
        }
        // Read again from the directory as this Mac holds it then.
        let read: @Sendable ([Bring.Need]) throws -> Bring.Answer = { needs in
            let question: Bring.Question? = DispatchQueue.main.sync { MainActor.assumeIsolated {
                guard let directory = VigilRemote.shared.host(device)?.directory,
                      let whole = directory.live.first(where: { $0.name == name }),
                      let source = part.map({ whole.only($0, of: anchor) }) ?? whole else { return nil }
                return Bring.Question(panes: directory.bringing(source, here: here), commit: false, settle: needs.isEmpty ? nil : needs)
            } }
            guard let question else { throw WireError.refused("\(host.name) no longer lists it") }
            return try hub.bring(question)
        }
        let model = BringDialogModel(
            workspace: name, anchor: anchor, part: part, mac: host.name, target: nil, what: Self.moving(source.label, part),
            away: Self.away(host), home: here, lines: lines, read: read)
        present(model, source: device, sourceHome: directory.home, targetHome: here) { [weak self] in
            guard let self else { return }
            let reply = self.applySessionEdit(.bring(name, from: device, anchor: anchor, part: part))
            guard !reply.ok || reply.code == "copied" else { return }
            let failed = NSAlert()
            failed.messageText = reply.ok ? "\(source.label) was copied" : "\(source.label) was not brought"
            failed.informativeText = reply.message
            failed.runModal()
        }
    }

    /// A move's dialog on the window it was asked from (so the terminal
    /// behind it stays readable; with none, asked from the menu bar, a
    /// window of its own), and what its buttons do. `source` is the
    /// workspace's Mac (nil: this one), where what is only there is opened
    /// and read.
    private func present(_ model: BringDialogModel, source: String?, sourceHome: String?, targetHome: String?,
                         move: @escaping () -> Void) {
        // The sheet names a folder as the target would; its own Mac reads it
        // under its own home.
        model.there = { root in
            guard let theirs = sourceHome, let mine = targetHome else { return root }
            return root == mine ? theirs : root.hasPrefix(mine + "/") ? theirs + root.dropFirst(mine.count) : root
        }
        model.changes = { [unowned model] group in
            guard let pane = group.panes.first?.pane, let root = group.root else { return AnyView(EmptyView()) }
            let id = source.map { VigilRemote.compositeId($0, pane) } ?? pane
            return AnyView(VigilChangesPanel.view(pane: id, repository: model.there(root)).inkEmbedded())
        }
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = NSHostingController(rootView: BringDialog(model: model))
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let workspace = model.workspace
        model.close = { [weak self] outcome in
            if let parent, panel.sheetParent === parent { parent.endSheet(panel) } else { panel.close() }
            switch outcome {
            case .cancel:
                break
            case .open(let pane):
                guard let self else { return }
                if let source {
                    self.openRemotePane(device: source, pane: pane)
                } else {
                    self.activatePane(name: workspace, paneId: pane, in: parent?.windowController as? TerminalController)
                }
            case .bring:
                move()
            }
        }
        if let parent {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Whether a workspace of another Mac has something a move would leave
    /// behind there, from what this Mac already holds of that Mac's
    /// directory (no question asked of anyone): what marks a move in a row's
    /// menu before the dialog says the rest. This Mac's own workspace says
    /// it in the dialog alone: its panes' work is read by the hub, never
    /// from a menu.
    func leavesBehind(_ home: RowHome) -> Bool {
        guard let device = home.device, let directory = VigilRemote.shared.host(device)?.directory,
              let source = directory.live.first(where: { $0.name == home.workspace }) else { return false }
        return (source.tabs ?? []).flatMap(\.paneIds).contains { pane in
            directory.panes[pane]?.work?.onlyThere(home: directory.home).isEmpty == false
        }
    }
}
