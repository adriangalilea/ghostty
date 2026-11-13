import AppKit
import VigilWire

/// What a sidebar row offers is the same wherever the row lives. An action
/// on a workspace, a tab or a pane is one `WorkspaceCommand` addressed to
/// the Mac it lives on (`RowHome`): applied here when that is this Mac,
/// sent to its hub otherwise (REMOTE-SESSIONS.md), the way the phone has
/// always closed and created things. The sidebar asks a row's home, never
/// "is this row remote".
///
/// Two things stay where they are on purpose. A close on this Mac goes
/// through its own functions (`closePaneFromSidebar`, `killWithConfirm`):
/// they carry what only the home's windows know (which viewport hands over,
/// what a live view runs). And merging needs both workspaces on one Mac,
/// so it is offered among this Mac's alone.
extension VigilWorkspaces {
    /// Where a row's workspace lives, and what it is called there.
    struct RowHome: Equatable {
        /// The Mac's tether root; nil: this Mac.
        let device: String?
        /// The workspace's name on that Mac.
        let workspace: String

        /// From a sidebar row's id: a workspace's name here, `device/name`
        /// for another Mac's.
        init(row id: String) {
            let remote = VigilRemote.split(id)
            device = remote?.device
            workspace = remote?.name ?? id
        }

        /// A Mac's own, for what names no workspace yet (a `create`).
        init(device: String?, workspace: String) {
            self.device = device
            self.workspace = workspace
        }

        /// The other Mac's name, for a sentence; nil: this Mac.
        @MainActor var mac: String? { device.map { VigilRemote.shared.host($0)?.name ?? "its Mac" } }

        /// A pane or tab anchor as its home names it, from a row's id of it.
        func there(_ id: String) -> String { device == nil ? id : VigilRemote.split(id)?.name ?? id }
    }

    /// One command to a row's home. A refusal, or a Mac that did not
    /// answer, is said in an alert titled `failing`; a success is seen in
    /// the tree, which redraws from the home's own word.
    func ask(_ home: RowHome, _ request: WorkspaceCommand.Request, failing: String) {
        let fields: [String: Any] = [
            "id": request.id.uuidString, "op": request.operation, "workspace": home.workspace, "anchor": request.anchor,
            "mac": home.mac ?? "here",
        ]
        func said(_ problem: String?) {
            guard let problem else { return sidebarLog.info("row action committed", fields) }
            sidebarLog.error("row action not committed", fields.merging(["why": problem]) { a, _ in a })
            let alert = NSAlert()
            alert.messageText = failing
            alert.informativeText = problem
            alert.runModal()
        }
        guard let device = home.device else {
            let reply = applySessionCommand(request)
            return said(reply.ok ? nil : reply.message)
        }
        let mac = home.mac ?? "its Mac"
        DispatchQueue.global(qos: .userInitiated).async {
            let problem: String?
            do {
                let data = try Local.Client(socket: VigilPaths.hub).call(device: device, .session(try request.line))
                let outcome = try JSONDecoder().decode(WorkspaceCommand.Outcome.self, from: data)
                problem = outcome.ok ? nil : outcome.message
            } catch {
                problem = "\(mac) did not answer (\(error)). It may have been done: look at its rows before trying again."
            }
            DispatchQueue.main.async { said(problem) }
        }
    }

    // MARK: Rename

    /// The identity editor for a workspace, a tab (of its pane `anchor`) or
    /// a pane, then the name and face sent to its home.
    func renameRow(_ home: RowHome, anchor: String = "", part: Registry.Workspace.Part? = nil, title: String,
                   label: String, emoji: String?, context: String) {
        VigilIdentity.editModal(title: title, label: label, emoji: emoji, context: context) { [weak self] newLabel, newEmoji in
            // A workspace always has a name (its own, when none is given);
            // a tab or a pane goes back to its own with none.
            let name = part == nil ? newLabel ?? label : newLabel
            self?.ask(home, .rename(home.workspace, anchor: anchor, part: part, label: name, emoji: newEmoji),
                      failing: "Not renamed\(home.mac.map { " on \($0)" } ?? "")")
        }
    }

    // MARK: Priority

    /// A pane's priority as its home holds it.
    func priority(_ home: RowHome, pane: String) -> Registry.Priority {
        guard let device = home.device else { return priority(ofPane: pane) }
        let tabs = VigilRemote.shared.host(device)?.directory?.live.first { $0.name == home.workspace }?.tabs ?? []
        return tabs.flatMap(\.members).first { $0.id == pane }?.priority ?? .normal
    }

    func setPriority(_ home: RowHome, pane: String, _ priority: Registry.Priority) {
        ask(home, .priority(home.workspace, pane: pane, priority), failing: "Priority not set\(home.mac.map { " on \($0)" } ?? "")")
    }

    // MARK: Close

    /// A whole workspace closed on its Mac: one burial there, its undo
    /// bringing the workspace back as itself. Always asked first, by its
    /// name (and its Mac's, when that is not this one).
    func killRow(_ home: RowHome, label: String) {
        guard let device = home.device else { return killWithConfirm(name: home.workspace) }
        guard let remote = VigilRemote.shared.host(device),
              let session = remote.directory?.live.first(where: { $0.name == home.workspace }) else { return }
        let panes = (session.tabs ?? []).flatMap(\.members).map(\.id)
        let busy = panes.compactMap { remote.directory?.panes[$0]?.busy }
        let alert = NSAlert()
        alert.messageText = "Kill \(label) on \(remote.name)?"
        alert.informativeText = (busy.isEmpty ? "" : "\(busy.joined(separator: ", ")) still running there. ")
            + "Its \(panes.count == 1 ? "pane ends" : "\(panes.count) panes end") on \(remote.name), "
            + "which keeps the workspace in Recently closed for \(Int(Self.killGrace))s."
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ask(home, .closeWorkspace(home.workspace), failing: "Not killed on \(remote.name)")
    }

    // MARK: Births: a new tab, a fork

    /// A new tab after the tab of its pane `anchor`, born at the row's home
    /// in that pane's folder.
    func newTab(_ home: RowHome, after anchor: String, in host: TerminalController?) {
        born(home, failing: "No tab made", in: host) {
            .birth(in: home.workspace, revision: $0, anchor: home.there(anchor), split: nil, command: nil)
        }
    }

    /// A fork of the conversation the pane `anchor` holds, in a pane of its
    /// own: a split to its right (`beside`), or a tab after its tab. The
    /// original goes on; its home starts the fork from its own record.
    func fork(_ home: RowHome, pane anchor: String, beside: Bool, in host: TerminalController?) {
        born(home, failing: "Not forked", in: host) {
            .fork(in: home.workspace, revision: $0, anchor: home.there(anchor), split: beside ? "right" : nil)
        }
    }

    /// A pane born at a row's home by `request` (given the workspace's
    /// revision there). This Mac's lands in `host`'s viewport, focused;
    /// another Mac's appears in its rows from that Mac's own word.
    private func born(_ home: RowHome, failing: String, in host: TerminalController?,
                      _ request: (String) -> WorkspaceCommand.Request) {
        guard let device = home.device else {
            guard let revision = workspaces[home.workspace]?.layoutRevision else {
                return sidebarLog.warn("birth refused: no such workspace", ["workspace": home.workspace])
            }
            let request = request(revision)
            let reply = applySessionCommand(request)
            guard reply.ok, let pane = reply.pane else {
                sidebarLog.error("row action not committed", [
                    "op": request.operation, "workspace": home.workspace, "anchor": request.anchor, "why": reply.message])
                let alert = NSAlert()
                alert.messageText = failing
                alert.informativeText = reply.message
                alert.runModal()
                return
            }
            sidebarLog.info("row action committed", [
                "op": request.operation, "workspace": home.workspace, "anchor": request.anchor, "pane": pane])
            return activatePane(name: home.workspace, paneId: pane, in: host)
        }
        guard let remote = VigilRemote.shared.host(device),
              let revision = remote.directory?.live.first(where: { $0.name == home.workspace })?.layoutRevision else {
            return sidebarLog.warn("birth refused: not in that Mac's directory", ["workspace": home.workspace])
        }
        ask(home, request(revision), failing: "\(failing) on \(remote.name)")
    }

    // MARK: New workspace

    /// A workspace born on the Mac `device`, a shell in its home folder, as
    /// a Mac's row offers it: it appears in that Mac's rows from its own word,
    /// as a remote new tab does.
    func newWorkspace(on device: String) {
        ask(RowHome(device: device, workspace: ""), .create(cwd: "~", command: nil, label: nil),
            failing: "No workspace made on \(VigilRemote.shared.host(device)?.name ?? "its Mac")")
    }

    /// A tab (of its pane `anchor`) or a pane of another Mac closed at its
    /// home, open here or not; asked first only when something runs in it
    /// (`Facts.busy`), as every close is.
    func closeRow(_ home: RowHome, anchor: String, tab: Bool, in host: TerminalController?) {
        guard let device = home.device, let remote = VigilRemote.shared.host(device), let directory = remote.directory,
              let session = directory.live.first(where: { $0.name == home.workspace }), let revision = session.layoutRevision else {
            return sidebarLog.warn("close refused: not in that Mac's directory", ["workspace": home.workspace])
        }
        let ending = tab ? (session.tabs ?? []).first { $0.paneIds.contains(anchor) }?.paneIds ?? [anchor] : [anchor]
        confirmClose(tab ? "Tab" : "Pane", busy: ending.compactMap { directory.panes[$0]?.busy }, mac: remote.name, in: host) { [weak self] in
            self?.ask(home, WorkspaceCommand.Request(
                session: home.workspace, revision: revision, operation: tab ? "close_tab" : "close_pane", anchor: anchor),
                      failing: "Not closed on \(remote.name)")
        }
    }
}
