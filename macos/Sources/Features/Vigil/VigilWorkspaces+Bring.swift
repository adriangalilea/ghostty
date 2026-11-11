import AppKit
import SwiftUI
import VigilWire

/// The sheet of a Bring Here as rows, one per pane: what it is called, its
/// agent's mark, what opening it does here, and what this Mac lacks for it.
struct BringSheetRows: View {
    static let width: CGFloat = 440
    let lines: [Bring.Line]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        mark(line).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.name ?? Directory.folder(line.folder, home: NSHomeDirectory()))
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(line.opens).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let at = line.transcriptAt {
                                Text("Last written here \(Self.when.localizedString(for: Date(timeIntervalSince1970: at), relativeTo: Date()))")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            ForEach(line.lacks, id: \.self) { lack in
                                Label(lack, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if line.work == nil {
                                Label(Bring.Line.workNotKnown, systemImage: "questionmark.circle")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(width: Self.width)
    }

    @ViewBuilder
    private func mark(_ line: Bring.Line) -> some View {
        if let agent = line.agent, AgentMark.knows(agent) {
            AgentMark(agent: agent, size: 12)
        } else {
            Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private static let when = RelativeDateTimeFormatter()
}

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
        let entry = source.brought(
            as: newWorkspaceId(), from: device, mac: host.name, at: Date().timeIntervalSince1970, home: directory.home,
            here: here, order: (workspaces.values.map(\.order).max() ?? 0) + 1, names: names)
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
        let difference = source.differs(fromBrought: kept, names: names)
        lifecycleLog.info("brought", [
            "workspace": entry.name, "from": host.name, "was": source.name, "tabs": session.tabs.count,
            "panes": session.tabs.flatMap(\.members).count, "resuming": lines.filter { $0.transcriptHere == true && $0.folderHere }.count,
            "lacking": lines.filter { !$0.lacks.isEmpty }.count, "differs": difference ?? "nothing",
        ])
        // Its Mac is told: those panes close there, so the conversation is
        // written on one Mac. Kept by the hub while that Mac is away.
        let told = WorkspaceCommand.Request.moved(
            source.name, panes: (source.tabs ?? []).flatMap(\.paneIds), to: Host.current().localizedName ?? "another Mac")
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

    /// The `moved` workspace command, from the Mac that brought panes of a
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
        let leaving = Set(moved.panes).intersection(session.tabs.flatMap(\.paneIds))
        guard !leaving.isEmpty else { return done("None of those panes is open here.") }
        movingTo = moved.mac
        defer { movingTo = nil }
        lifecycleLog.info("panes brought to another Mac close here", ["workspace": request.session, "to": moved.mac, "panes": leaving.sorted()])
        if leaving == Set(session.tabs.flatMap(\.paneIds)) {
            kill(name: request.session)
            return done("Closed here: it is on \(moved.mac) now.")
        }
        // Tab by tab from the registry as it stands: a tab that left whole
        // closes as one, else its panes that left, one by one.
        for pane in moved.panes where leaving.contains(pane) {
            refreshWorkspaceRevisions()
            guard let now = workspaces[request.session], let tab = now.tabs.first(where: { $0.paneIds.contains(pane) }) else { continue }
            let whole = Set(tab.paneIds).isSubset(of: leaving)
            let reply = applySessionCommand(VigilSessionControl.Request(
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

    /// The sidebar's Bring Here on a workspace of another Mac: the sheet of
    /// what this Mac knows about each pane, then the move. On a tab or a
    /// pane row: that much of it (`part` of the pane `anchor`).
    func bringWithSheet(device: String, workspace name: String, anchor: String = "", part: Registry.Workspace.Part? = nil) {
        guard let host = VigilRemote.shared.host(device), let directory = host.directory,
              let whole = directory.live.first(where: { $0.name == name }),
              let source = part.map({ whole.only($0, of: anchor) }) ?? whole else { return }
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
        let what = switch part {
        case .tab: "this tab of \(source.label)"
        case .pane: "this pane of \(source.label)"
        case nil: source.label
        }
        alert.messageText = "Bring \(what) here from \(host.name)?"
        var text = "Nothing runs until you open a pane."
        if host.away, let received = host.received { text += " \(host.name) is away: this is as of \(VigilRemote.awaySince(received).dropFirst("away since ".count))." }
        alert.informativeText = text
        let rows = NSHostingView(rootView: BringSheetRows(lines: lines))
        rows.frame = NSRect(origin: .zero, size: NSSize(width: BringSheetRows.width, height: min(rows.fittingSize.height, 420)))
        alert.accessoryView = rows
        alert.addButton(withTitle: lacking.isEmpty ? "Bring Here" : "Bring Without Them")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let reply = applySessionCommand(.bring(name, from: device, anchor: anchor, part: part))
        guard !reply.ok else { return }
        let failed = NSAlert()
        failed.messageText = "\(source.label) was not brought"
        failed.informativeText = reply.message
        failed.runModal()
    }
}
