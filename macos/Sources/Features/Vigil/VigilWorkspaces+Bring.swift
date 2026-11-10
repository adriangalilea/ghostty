import AppKit
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
              let source = directory.live.first(where: { $0.name == request.session }) else {
            return .failure(request, "not_found", "This Mac has not heard that workspace from that Mac.")
        }
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        let entry = source.brought(
            as: newWorkspaceId(), from: device, mac: host.name, at: Date().timeIntervalSince1970, home: directory.home,
            here: here, order: (workspaces.values.map(\.order).max() ?? 0) + 1)
        // The pointers first: a pane is in the registry only once its first
        // start can find what it resumes.
        let lines: [Bring.Line]
        do {
            lines = try Local.Client(socket: VigilPaths.hub).bring(
                Bring.Question(panes: directory.bringing(source, as: entry, here: here), commit: true))
        } catch {
            lifecycleLog.error("not brought: vigil-agent did not write its resume pointers", ["workspace": source.name, "from": host.name, "err": error])
            return .failure(request, "agent_unreachable", "vigil-agent did not answer, so nothing was brought (\(error)).")
        }
        var session = Workspace(name: entry.name, label: entry.label, emoji: entry.emoji, cwd: entry.cwd, tabs: entry.tabs ?? [],
                                order: entry.order ?? 0)
        session.paneSeq = entry.paneSeq ?? session.tabs.flatMap(\.members).count
        session.pinned = entry.pinned ?? false
        session.layoutShape = VigilSessionControl.revision(session.tabs)
        workspaces[entry.name] = session
        persist()
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([Registry.Workspace].self, from: data),
              let kept = saved.first(where: { $0.name == entry.name }) else {
            return .failure(request, "commit_failed", "The brought workspace could not be confirmed in this Mac's registry.")
        }
        // The proof is the two registries compared, never an eye.
        let difference = source.differs(fromBrought: kept)
        lifecycleLog.info("brought", [
            "workspace": entry.name, "from": host.name, "was": source.name, "tabs": session.tabs.count,
            "panes": session.tabs.flatMap(\.members).count, "resuming": lines.filter { $0.transcriptHere == true && $0.folderHere }.count,
            "lacking": lines.filter { !$0.lacks.isEmpty }.count, "differs": difference ?? "nothing",
        ])
        return VigilSessionControl.Reply(id: request.id, ok: true, code: "committed", message: "Brought here; nothing runs until a pane is opened.",
                                         revision: workspaces[entry.name]?.layoutRevision, session: entry.name)
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

    /// The sidebar's Bring Here on a workspace of another Mac: the sheet of
    /// what this Mac knows about each pane, then the move.
    func bringWithSheet(device: String, workspace name: String) {
        guard let host = VigilRemote.shared.host(device), let directory = host.directory,
              let source = directory.live.first(where: { $0.name == name }) else { return }
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        let lines: [Bring.Line]
        do {
            lines = try Local.Client(socket: VigilPaths.hub).bring(Bring.Question(panes: directory.bringing(source, here: here), commit: false))
        } catch {
            lifecycleLog.error("bring sheet not read", ["workspace": name, "from": host.name, "err": error])
            let alert = NSAlert()
            alert.messageText = "Can't bring \(source.label) here"
            alert.informativeText = "vigil-agent did not answer: \(error)"
            alert.runModal()
            return
        }
        let lacking = lines.filter { !$0.lacks.isEmpty }
        let alert = NSAlert()
        alert.messageText = "Bring \(source.label) here from \(host.name)?"
        var text = lines.map { line in
            (["\(line.name ?? "A pane"): \(line.opens)"] + line.lacks.map { "   Missing here: \($0)" }).joined(separator: "\n")
        }.joined(separator: "\n")
        text += "\n\nNothing runs until you open a pane."
        if host.away, let received = host.received { text += " \(host.name) is away: this is as of \(VigilRemote.awaySince(received).dropFirst("away since ".count))." }
        alert.informativeText = text
        alert.addButton(withTitle: lacking.isEmpty ? "Bring Here" : "Bring Without Them")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let reply = applySessionCommand(.bring(name, from: device))
        guard !reply.ok else { return }
        let failed = NSAlert()
        failed.messageText = "\(source.label) was not brought"
        failed.informativeText = reply.message
        failed.runModal()
    }
}
