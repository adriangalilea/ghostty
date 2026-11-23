import AppKit
import VigilWire

/// What a sidebar row offers is the same wherever the row lives. An action
/// on a workspace, a tab or a pane is one `WorkspaceCommand` addressed to
/// the Mac it lives on (`RowHome`): applied here when that is this Mac,
/// sent to its hub otherwise (REMOTE-SESSIONS.md), the way the phone has
/// always closed and created things. The sidebar asks a row's home, never
/// "is this row remote".
///
/// The home chooses how to bury a mounted, floating or captured tab.
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
            // A birth among them is awaited off the main thread.
            Task { @MainActor in
                let reply = await VigilSessionControl.transact(request, origin: .gesture)
                said(reply.ok ? nil : reply.message)
            }
            return
        }
        let mac = home.mac ?? "its Mac"
        Task { @MainActor in
            let problem: String?
            do {
                let outcome = try await VigilRemote.shared.command(device, request: request)
                problem = outcome.ok ? nil : outcome.message
            } catch {
                problem = "\(mac): \(error.localizedDescription)"
            }
            said(request.operation == "move_to" ? problem.map { Move.olderVigil($0, mac: mac) } : problem)
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
        guard let device = home.device else {
            refreshWorkspaceRevisions()
            guard let session = workspaces[home.workspace] else { return }
            let request = WorkspaceCommand.Request.closeWorkspace(home.workspace, revision: session.layoutRevision)
            return confirmKill(name: home.workspace) { self.ask(home, request, failing: "Not closed") }
        }
        guard let remote = VigilRemote.shared.host(device),
              let session = remote.directory?.live.first(where: { $0.name == home.workspace }) else { return }
        let panes = (session.tabs ?? []).flatMap(\.members).map(\.id)
        let busy = panes.flatMap { remote.directory?.panes[$0]?.closingPrograms ?? [] }
        let alert = NSAlert()
        alert.messageText = "Kill \(label) on \(remote.name)?"
        alert.informativeText = (busy.isEmpty ? "" : "\(busy.joined(separator: ", ")) still running there. ")
            + "Its \(panes.count == 1 ? "pane ends" : "\(panes.count) panes end") on \(remote.name), "
            + "which keeps the workspace in Recently closed: \(Self.undoWords)."
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ask(home, .closeWorkspace(home.workspace, revision: session.layoutRevision ?? ""), failing: "Not killed on \(remote.name)")
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
            // Its birth is awaited off the main thread; the pane is landed
            // on when the reply comes.
            Task { @MainActor [weak host] in
                let reply = await VigilSessionControl.transact(request, origin: .gesture)
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
                self.activatePane(name: home.workspace, paneId: pane, in: host)
            }
            return
        }
        guard let remote = VigilRemote.shared.host(device),
              let revision = remote.directory?.live.first(where: { $0.name == home.workspace })?.layoutRevision else {
            return sidebarLog.warn("birth refused: not in that Mac's directory", ["workspace": home.workspace])
        }
        ask(home, request(revision), failing: "\(failing) on \(remote.name)")
    }

    // MARK: New workspace

    /// How long a Mac has to list a workspace it said it made before the
    /// person is told it isn't listed yet: the phone's bound for the same wait.
    static let createListedWithin: Duration = .seconds(10)

    /// A workspace born on the Mac `device` (nil: this one), a shell in its
    /// home folder, as a Mac's header offers it, taking the window the person
    /// is in, as ⌘N's does. This Mac's is ⌘N's own; another Mac's goes
    /// through `create(_:on:from:)`, and what keeps it from opening is said
    /// in an alert.
    func newWorkspace(on device: String?) {
        guard let device else {
            newWorkspace(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }
        let origin = CreationOrigin.now(self)
        let mac = VigilRemote.shared.host(device)?.name ?? "its Mac"
        Task { @MainActor in
            guard case .problem(let problem) = await create(
                .create(cwd: "~", command: nil, label: nil), on: device, from: origin) else { return }
            let alert = NSAlert()
            alert.messageText = "No workspace opened on \(mac)"
            alert.informativeText = problem
            alert.runModal()
        }
    }

    /// Where a creation was asked from: the window the person was in and
    /// what it showed, so a workspace that arrives later opens only if
    /// they are still there.
    struct CreationOrigin {
        weak var viewport: TerminalController?
        /// There was a window to be in at all.
        let hadViewport: Bool
        let showing: String?

        @MainActor static func now(_ manager: VigilWorkspaces) -> CreationOrigin {
            let viewport = TerminalController.preferredParent.flatMap { $0.window?.isVisible == true ? $0 : nil }
            return CreationOrigin(viewport: viewport, hadViewport: viewport != nil,
                                  showing: viewport.flatMap { manager.workspaceName(of: $0) ?? manager.mirroredWorkspace(of: $0) })
        }
    }

    /// How a creation ended for the person.
    enum Created {
        /// It took the window they asked from (or one of its own, when
        /// there was none).
        case opened
        /// They had moved on: it waits in the sidebar, said once by a pill.
        case ready
        /// Not made, not known to be made, or not listed in time: the
        /// caller says it where the person looks. Nothing else opens.
        case problem(String)
    }

    /// One creation, from a Mac's header or the creation sheet, on this Mac
    /// or another (`device`). Another Mac's is opened only once that Mac's
    /// own directory lists its pane, within the phone's bound. It takes the
    /// window it was asked from (`take`) when the person is still there:
    /// that window is the main one and shows what it showed then. Otherwise
    /// nothing moves under them, and a pill says it is ready. `opening` runs
    /// just before either (the sheet closes itself there).
    func create(_ request: WorkspaceCommand.Request, on device: String?, from origin: CreationOrigin,
                opening: @MainActor () -> Void = {}) async -> Created {
        let mac = device.map { VigilRemote.shared.host($0)?.name ?? "its Mac" } ?? "this Mac"
        var fields: [String: Any] = ["id": request.id.uuidString, "mac": mac]
        func problem(_ why: String) -> Created {
            sidebarLog.error("new workspace not opened", fields.merging(["why": why]) { a, _ in a })
            return .problem(why)
        }
        let reply: VigilSessionControl.Reply
        if let device {
            do {
                reply = try await VigilRemote.shared.command(device, request: request)
            } catch let error as NSError where error.domain == "VigilRemote" {
                // Out of reach: nothing was sent.
                return problem(error.localizedDescription)
            } catch {
                return problem("\(error.localizedDescription). It may have been made: check \(mac)'s workspaces before trying again.")
            }
        } else {
            reply = await VigilSessionControl.transact(request, origin: .gesture)
        }
        guard reply.ok, let pane = reply.pane else { return problem(reply.message) }
        fields["pane"] = pane
        sidebarLog.info("new workspace made", fields)
        let name: String
        let label: String
        if let device {
            guard let listed = await listedWorkspace(of: pane, on: device, within: Self.createListedWithin) else {
                return problem("Made on \(mac), but it isn't listed yet. It appears in \(mac)'s workspaces once it is.")
            }
            name = VigilRemote.compositeId(device, listed.name)
            label = listed.label
        } else {
            guard let session = reply.session, let here = workspaces[session] else {
                return problem("Made on this Mac, but its workspace is not in the registry here.")
            }
            name = session
            label = here.label
        }
        let anchor = device.map { VigilRemote.compositeId($0, pane) } ?? pane
        fields["workspace"] = name
        opening()
        let viewport = origin.viewport
        let stillThere = viewport.map { viewport in
            viewport.window?.isVisible == true && NSApp.mainWindow === viewport.window
                && (workspaceName(of: viewport) ?? mirroredWorkspace(of: viewport)) == origin.showing
        } ?? !origin.hadViewport
        guard stillThere else {
            sidebarLog.info("new workspace ready: the person moved on, nothing opened", fields)
            VigilFollowSplash.show(in: NSApp.mainWindow, text: "\(label) is ready on \(mac)")
            return .ready
        }
        sidebarLog.info("new workspace opened", fields)
        take(name, anchor: anchor, in: viewport)
        return .opened
    }

    /// The workspace `device`'s own directory lists `pane` in, as soon as it
    /// does; nil when it has not within `bound`. Read again at every
    /// directory change, and once more at the bound.
    private func listedWorkspace(of pane: String, on device: String, within bound: Duration) async -> Registry.Workspace? {
        // Among the workspaces a remote mount opens (`VigilRemote.session`).
        func listed() -> Registry.Workspace? {
            VigilRemote.shared.host(device)?.directory?.live.first { $0.paneIds.contains(pane) }
        }
        if let name = listed() { return name }
        let waiting = Task { @MainActor () -> Registry.Workspace? in
            for await _ in NotificationCenter.default.notifications(named: Self.stateDidChange) {
                if let name = listed() { return name }
            }
            return nil
        }
        let bounded = Task { @MainActor in
            try? await Task.sleep(for: bound)
            waiting.cancel()
        }
        defer { bounded.cancel() }
        return await waiting.value ?? listed()
    }

    /// A tab (of its pane `anchor`) or a pane of another Mac closed at its
    /// home, open here or not; asked first only when something runs in it
    /// (`Facts.busy`), as every close is.
    func closeRow(_ home: RowHome, anchor: String, tab: Bool, in host: TerminalController?) {
        let revision: String
        let member: Registry.Tab
        let busy: [String]
        if let device = home.device {
            guard let dir = VigilRemote.shared.host(device)?.directory,
                  let place = dir.place(of: anchor), place.workspace.name == home.workspace,
                  let current = place.workspace.layoutRevision else { return }
            revision = current
            member = place.tab
            busy = member.closingPanes(anchor, tab: tab).flatMap { dir.panes[$0]?.closingPrograms ?? [] }
        } else {
            refreshWorkspaceRevisions()
            guard let session = workspaces[home.workspace],
                  let found = session.tabs.first(where: { $0.paneIds.contains(anchor) }) else { return }
            revision = session.layoutRevision
            member = found
            busy = busyPrograms(panes: member.closingPanes(anchor, tab: tab))
        }
        let request = WorkspaceCommand.Request(session: home.workspace, revision: revision,
                                               operation: tab ? "close_tab" : "close_pane", anchor: anchor)
        confirmClose(tab || member.closesWithPane(anchor) ? "Tab" : "Pane", busy: busy, mac: home.mac, in: host) { [weak self] in
            self?.ask(home, request, failing: "Not closed\(home.mac.map { " on \($0)" } ?? "")")
        }
    }
}
