import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Sidebar navigation (rows resolve through shapeshift)

    /// Returns true for every remote viewport, including refusal. A failed
    /// remote command can never fall through to Ghostty's local spawn path.
    @discardableResult
    func remoteSessionCommand(in base: BaseTerminalController, from view: Ghostty.SurfaceView? = nil,
                              operation: String, direction: String? = nil, expectedRevision: String? = nil) -> Bool {
        if !(base is TerminalController), let surface = view ?? base.focusedSurface,
           let device = surface.vigilHost, let pane = surface.vigilAttachId {
            guard let controller = openRemotePane(device: device, pane: pane) else { return true }
            dismissQuickTerminal()
            return remoteSessionCommand(in: controller, from: surface, operation: operation, direction: direction, expectedRevision: expectedRevision)
        }
        guard let controller = base as? TerminalController,
              let composite = mirroredWorkspace(of: controller) else { return false }
        // Another local window is a mirror of the same home registry too.
        // It uses the identical transaction instead of creating an orphan
        // daemon outside that registry through the native split callback.
        guard let split = VigilRemote.split(composite) else {
            guard let session = workspaces[composite],
                  let anchor = (view ?? controller.focusedSurface)?.vigilAttachId else {
                remoteCommandError(controller, "That workspace can't be reached right now.")
                return true
            }
            let request = VigilSessionControl.Request(version: 1, id: UUID(), issuedAt: Date().timeIntervalSince1970,
                session: composite, revision: expectedRevision ?? session.layoutRevision,
                operation: operation, anchor: anchor, direction: direction)
            let reply = VigilSessionControl.transact(request)
            guard reply.ok else { remoteCommandError(controller, reply.message); return true }
            if let name = reply.session, name != composite {
                shapeshift(in: controller, to: name, anchor: reply.pane)
            } else if operation == "new_tab", let pane = reply.pane {
                mirrorInto(controller, name: composite, anchor: pane)
            } else if let pane = reply.pane, let landing = controller.surfaceTree.first(where: { $0.vigilAttachId == pane }) {
                Ghostty.moveFocus(to: landing)
                if controller.window?.isKeyWindow == true { landing.vigilRequestSize(reason: "session edit") }
            }
            return true
        }
        guard let (_, session) = VigilRemote.shared.session(composite),
              let anchor = (view ?? controller.focusedSurface)?.vigilAttachId,
              (session.tabs ?? []).contains(where: { $0.paneIds.contains(anchor) }) else {
            remoteCommandError(controller, "The remote pane is unavailable. No local process was created.")
            return true
        }
        guard !remoteEdits.contains(composite) else {
            remoteCommandError(controller, "The last change to this workspace hasn't been confirmed by its Mac yet.")
            return true
        }
        guard let revision = session.layoutRevision else {
            remoteCommandError(controller, "vigil on that Mac is too old to edit this workspace from here. Update it and relaunch.")
            return true
        }
        let request = VigilSessionControl.Request(version: 1, id: UUID(), issuedAt: Date().timeIntervalSince1970,
            session: split.name, revision: expectedRevision ?? revision,
            operation: operation, anchor: anchor, direction: direction)
        remoteEdits.insert(composite)
        sessionLog.info("remote command sent", [
            "id": request.id.uuidString, "operation": operation, "host": split.device, "workspace": split.name, "pane": anchor,
        ])
        Task { [weak controller] in
            defer { remoteEdits.remove(composite) }
            do {
                let reply = try await VigilRemote.shared.command(split.device, request: request)
                guard reply.ok else {
                    if let controller { remoteCommandError(controller, reply.message) }
                    sessionLog.warn("remote command refused", ["id": request.id.uuidString, "code": reply.code])
                    return
                }
                sessionLog.info("remote command committed", ["id": request.id.uuidString, "pane": reply.pane])
                if let controller, mirroredWorkspace(of: controller) == composite, let pane = reply.pane {
                    remoteLandings[ObjectIdentifier(controller)] = pane
                    if let name = reply.session, name != split.name {
                        remoteDestinations[ObjectIdentifier(controller)] = VigilRemote.compositeId(split.device, name)
                    }
                }
                remoteEdits.remove(composite)
                // The home committed it; its directory stream brings the result.
                remoteDirectoryChanged(split.device)
            } catch {
                sessionLog.error("remote command outcome unknown", ["id": request.id.uuidString, "err": error])
                if let controller {
                    remoteCommandError(controller, "\(error.localizedDescription)\nCommand \(request.id). Check the workspace on its Mac before trying again.")
                }
            }
        }
        return true
    }

    func remoteCommandError(_ controller: TerminalController, _ message: String) {
        let alert = NSAlert()
        alert.messageText = "The workspace was not changed"
        alert.informativeText = message
        if let window = controller.window { alert.beginSheetModal(for: window) }
    }

    /// The one close question, wherever the close is clicked and wherever
    /// the pane lives: asked only when something runs (`busy`: the tty's
    /// foreground program, never a shell at its prompt; the same rule on
    /// every Mac, `Facts.busy`), naming it; nothing running, nothing asked.
    /// `mac`: where it lives, when that is not this Mac.
    func confirmClose(_ what: String, busy: [String], mac: String? = nil, in host: TerminalController?,
                      _ proceed: @escaping () -> Void) {
        guard !busy.isEmpty, let host else { proceed(); return }
        host.confirmClose(
            messageText: "Close \(what)?",
            informativeText: "\(busy.joined(separator: ", ")) still running\(mac.map { " on \($0)" } ?? ""). Closing the \(what.lowercased()) kills it (undo keeps it for \(Int(Self.killGrace))s).")
        { proceed() }
    }

    /// A close in a viewport showing a workspace that lives elsewhere
    /// (another Mac, or another window here): sent to its home as a
    /// command, after the same question a local close asks, answered from
    /// the home's own facts (its directory).
    func confirmRemoteClose(in controller: TerminalController, view: Ghostty.SurfaceView? = nil,
                                    operation: String, confirm: Bool = true) -> Bool {
        guard let composite = mirroredWorkspace(of: controller) else { return false }
        let target = view ?? controller.focusedSurface
        let revision = VigilRemote.shared.session(composite)?.session.layoutRevision
            ?? workspaces[composite]?.layoutRevision
        let proceed = { [weak controller] in
            guard let controller, self.mirroredWorkspace(of: controller) == composite else { return }
            self.remoteSessionCommand(in: controller, from: target, operation: operation, expectedRevision: revision)
        }
        guard confirm, let anchor = target?.vigilAttachId else { proceed(); return true }
        let what = operation == "close_tab" ? "Tab" : "Pane"
        if let remote = VigilRemote.shared.session(composite) {
            let facts = VigilRemote.shared.host(remote.device)?.directory?.panes ?? [:]
            let tab = (remote.session.tabs ?? []).first { $0.paneIds.contains(anchor) }
            let panes = operation == "close_tab" ? tab?.paneIds ?? [anchor] : [anchor]
            confirmClose(what, busy: panes.compactMap { facts[$0]?.busy },
                         mac: VigilRemote.shared.host(remote.device)?.name, in: controller, proceed)
        } else {
            let tab = workspaces[composite]?.tabs.first { $0.paneIds.contains(anchor) }
            confirmClose(what, busy: busyPrograms(panes: operation == "close_tab" ? tab?.paneIds ?? [anchor] : [anchor]),
                         in: controller, proceed)
        }
        return true
    }

    func closeRemoteTab(_ controller: TerminalController) -> Bool {
        confirmRemoteClose(in: controller, operation: "close_tab")
    }

    func remoteDirectoryChanged(_ device: String) {
        for controller in mirrorViewports.keyEnumerator().allObjects.compactMap({ $0 as? TerminalController }) {
            if let destination = remoteDestinations[ObjectIdentifier(controller)],
               VigilRemote.shared.session(destination) != nil {
                mirrorViewports.setObject(destination as NSString, forKey: controller)
                remoteDestinations.removeValue(forKey: ObjectIdentifier(controller))
            }
            guard let composite = mirroredWorkspace(of: controller),
                  let identity = VigilRemote.split(composite), identity.device == device,
                  !remoteEdits.contains(composite) else { continue }
            guard let (_, session) = VigilRemote.shared.session(composite) else {
                // An unreachable host is not a deletion; keep its view.
                guard VigilRemote.shared.host(device)?.directory != nil else { continue }
                endMirrorViewport(controller)
                swapTree(controller, SplitTree())
                controller.window?.close()
                continue
            }
            let ids = Set(controller.surfaceTree.compactMap(\.vigilAttachId))
            let pending = remoteLandings[ObjectIdentifier(controller)]
            let selected = pending.flatMap { id in (session.tabs ?? []).first { $0.paneIds.contains(id) } }
            guard let tab = selected ?? (session.tabs ?? []).first(where: { !ids.isDisjoint(with: $0.paneIds) }) ?? session.tabs?.first else { continue }
            let revision = VigilSessionControl.revision([tab])
            guard remoteLayouts[ObjectIdentifier(controller)] != revision else { continue }
            reconcileWorkspaceTree(controller, tab: tab, host: device, session: identity.name)
            remoteLayouts[ObjectIdentifier(controller)] = revision
            if let pending, let landing = controller.surfaceTree.first(where: { $0.vigilAttachId == pending }) {
                remoteLandings.removeValue(forKey: ObjectIdentifier(controller))
                Ghostty.moveFocus(to: landing)
                if controller.window?.isKeyWindow == true { landing.vigilRequestSize(reason: "remote session edit") }
            }
            sessionLog.info("remote layout reconciled", ["workspace": composite, "panes": tab.panes.count])
        }
    }

    func syncLocalMirrorLayouts() {
        for controller in mirrorViewports.keyEnumerator().allObjects.compactMap({ $0 as? TerminalController }) {
            guard let name = mirroredWorkspace(of: controller), VigilRemote.split(name) == nil else { continue }
            let ids = Set(controller.surfaceTree.compactMap(\.vigilAttachId))
            guard let tabs = workspaces[name]?.tabs,
                  let tab = tabs.first(where: { !ids.isDisjoint(with: $0.paneIds) }) ?? tabs.first else {
                endMirrorViewport(controller)
                swapTree(controller, SplitTree())
                controller.window?.close()
                continue
            }
            let shape = VigilSessionControl.revision([tab])
            guard remoteLayouts[ObjectIdentifier(controller)] != shape else { continue }
            remoteLayouts[ObjectIdentifier(controller)] = shape
            reconcileWorkspaceTree(controller, tab: tab, host: nil, session: name)
        }
    }

    /// Every view of `name` on this Mac (its windows and the local mirrors
    /// of it) brought to its registry, matched by pane id: a view keeps the
    /// tab it shows, gains or loses panes, and a view whose tab is gone
    /// closes. The one step after any edit made outside the views (a
    /// command from another Mac, an undo).
    func reconcileViews(of name: String) {
        let tabs = workspaces[name]?.tabs ?? []
        for controller in members(of: name) {
            let oldIds = Set(controller.surfaceTree.compactMap(\.vigilAttachId))
            if let target = tabs.first(where: { !oldIds.isDisjoint(with: $0.paneIds) }) ?? tabs.first {
                reconcileWorkspaceTree(controller, tab: target, host: nil, session: name)
            } else {
                memberships.removeObject(forKey: controller)
                if let dock = dockMap.object(forKey: controller) {
                    for view in dock.views { view.vigilDestroySurface() }
                    dock.unmount()
                    dockMap.removeObject(forKey: controller)
                }
                swapTree(controller, SplitTree())
                controller.window?.close()
            }
        }
        for controller in mirrorViewports.keyEnumerator().allObjects.compactMap({ $0 as? TerminalController })
            where mirroredWorkspace(of: controller) == name {
            let oldIds = Set(controller.surfaceTree.compactMap(\.vigilAttachId))
            if let target = tabs.first(where: { !oldIds.isDisjoint(with: $0.paneIds) }) ?? tabs.first {
                reconcileWorkspaceTree(controller, tab: target, host: nil, session: name)
            } else {
                endMirrorViewport(controller)
                swapTree(controller, SplitTree())
                controller.window?.close()
            }
        }
    }

    /// The home app's serialized session transaction. Remote callers supply
    /// identities and intent, never a replacement registry or local cwd.
    func applySessionCommand(_ request: VigilSessionControl.Request) -> VigilSessionControl.Reply {
        typealias Reply = VigilSessionControl.Reply
        refreshWorkspaceRevisions()
        // A burial, by its name: undone (back where it stood) or ended now.
        // The tray of every Mac sends these to the burial's home.
        if request.operation == "exhume" || request.operation == "reap" {
            guard graveyard[request.session] != nil else {
                return .failure(request, "not_found", "It is no longer waiting: its time ran out or it was already undone.")
            }
            if request.operation == "reap" {
                reapNow(request.session)
                sessionLog.info("session command committed", ["id": request.id.uuidString, "operation": "reap", "workspace": request.session])
                return Reply(id: request.id, ok: true, code: "committed", message: "Ended on its Mac.", revision: nil, session: request.session)
            }
            let back = exhume(request.session)
            sessionLog.info("session command committed", [
                "id": request.id.uuidString, "operation": "exhume", "workspace": request.session, "back": back,
            ])
            return Reply(id: request.id, ok: true, code: "committed", message: "Back on its Mac.",
                         revision: back.flatMap { workspaces[$0]?.layoutRevision }, session: back)
        }
        // A workspace of its own: in the folder asked (`~` is this Mac's
        // home), running what was asked, through the one birth path.
        if request.operation == "create" {
            let cwd = (request.cwd! as NSString).expandingTildeInPath
            return birthReply(request, apiNewWorkspace(label: request.label, cwd: cwd, command: request.command, openWindow: false))
        }
        guard var session = workspaces[request.session] else {
            return .failure(request, "not_found", "That workspace no longer exists on its Mac.")
        }
        if request.operation == "describe" {
            return Reply(id: request.id, ok: true, code: "snapshot", message: "Home session topology revision.",
                         revision: session.layoutRevision, session: request.session)
        }
        guard session.layoutRevision == request.revision else {
            return .failure(request, "conflict", "The workspace changed in the meantime. Look at it again and retry.")
        }
        guard let index = session.tabs.firstIndex(where: { $0.paneIds.contains(request.anchor) }) else {
            return .failure(request, "not_found", "That pane is no longer in this workspace.")
        }
        guard session.float == nil else {
            return .failure(request, "presentation_busy", "This workspace is in the floating terminal on its Mac. Put it back before changing its tabs or splits.")
        }
        var tab = session.tabs[index]
        var created: Registry.Pane?
        var removed: [Registry.Pane] = []
        /// A whole tab closed: buried as one, where it stood.
        var closedTab: Registry.Tab?
        /// The closed pane was a dock tenant (it goes back into the dock).
        var closedFromDock = false
        switch request.operation {
        case "new_session":
            let cwd = liveView(attachId: request.anchor)?.pwd
                ?? tab.panes.first(where: { $0.id == request.anchor })?.cwd ?? session.cwd
            return birthReply(request, apiNewWorkspace(label: request.label, cwd: cwd, command: request.command, openWindow: false))
        case "split", "new_tab":
            guard let anchor = tab.panes.first(where: { $0.id == request.anchor }) else {
                return .failure(request, "unsupported_target", "A dock tenant cannot anchor a split or tab.")
            }
            if request.operation == "split", !["left", "right", "up", "down"].contains(request.direction ?? "") {
                return .failure(request, "invalid_direction", "Expected left, right, up or down.")
            }
            let id = "vigil-\(request.session)-\(nextPaneIndex(name: request.session))"
            // The home pane supplies cwd. No environment or path is inherited
            // from the sender; its command is the one thing it names.
            let pane = Registry.Pane(id: id, cwd: liveView(attachId: anchor.id)?.pwd ?? anchor.cwd, command: request.command)
            guard startDaemon(pane: pane, session: request.session) else {
                persist() // the allocated identity is never recycled
                return .failure(request, "spawn_failed", "The terminal could not start on its Mac; its log says why (mise run log).")
            }
            created = pane
            session.paneSeq = workspaces[request.session]!.paneSeq
            if request.operation == "new_tab" {
                session.tabs.insert(Registry.Tab(panes: [pane], layout: nil), at: index + 1)
            } else {
                let anchorIndex = tab.panes.firstIndex { $0.id == anchor.id }!
                let newIndex = tab.panes.count
                let layout = Self.completeLayout(tab)
                func insert(_ node: Registry.Layout) -> Registry.Layout {
                    switch node {
                    case .leaf(let i):
                        guard i == anchorIndex else { return node }
                        switch request.direction {
                        case "left": return .h(0.5, .leaf(newIndex), node)
                        case "up": return .v(0.5, .leaf(newIndex), node)
                        case "down": return .v(0.5, node, .leaf(newIndex))
                        default: return .h(0.5, node, .leaf(newIndex))
                        }
                    case .h(let ratio, let left, let right): return .h(ratio, insert(left), insert(right))
                    case .v(let ratio, let left, let right): return .v(ratio, insert(left), insert(right))
                    }
                }
                tab.layout = insert(layout)
                tab.panes.append(pane)
                session.tabs[index] = tab
            }
        case "close_tab":
            closedTab = session.tabs.remove(at: index)
        case "close_pane" where tab.panes.map(\.id) == [request.anchor]:
            // Its tab's last pane: closing it closes the tab, dock and all.
            closedTab = session.tabs.remove(at: index)
        case "close_pane":
            closedFromDock = !tab.panes.contains { $0.id == request.anchor }
            removed = (tab.panes + (tab.dock?.panes ?? [])).filter { $0.id == request.anchor }
            let ids = Set(removed.map(\.id))
            let previous = tab.panes
            tab.panes.removeAll { ids.contains($0.id) }
            let mapping = Dictionary(uniqueKeysWithValues: tab.panes.enumerated().map { ($0.element.id, $0.offset) })
            func prune(_ node: Registry.Layout) -> Registry.Layout? {
                switch node {
                case .leaf(let i):
                    guard previous.indices.contains(i), let next = mapping[previous[i].id] else { return nil }
                    return .leaf(next)
                case .h(let ratio, let l, let r):
                    let left = prune(l), right = prune(r)
                    if let left, let right { return .h(ratio, left, right) }
                    return left ?? right
                case .v(let ratio, let l, let r):
                    let left = prune(l), right = prune(r)
                    if let left, let right { return .v(ratio, left, right) }
                    return left ?? right
                }
            }
            tab.layout = prune(Self.completeLayout(session.tabs[index]))
            if var dock = tab.dock {
                dock.panes.removeAll { ids.contains($0.id) }
                dock.active = min(dock.active, max(0, dock.panes.count - 1))
                tab.dock = dock.panes.isEmpty ? nil : dock
            }
            session.tabs[index] = tab
        default:
            return .failure(request, "unsupported_operation", "vigil on that Mac can't do this; update it.")
        }

        // Invalidate warm caches; live home views are reconciled by identity
        // below, so unchanged panes keep their clients and terminal state.
        session.held = []
        workspaces[request.session] = session
        reconcileViews(of: request.session)
        if let closedTab {
            buryTab(closedTab, held: [], thumbnail: nil, from: request.session, at: index)
        }
        // A closed pane rests beside a pane its tab keeps (a dock tenant
        // goes back into the dock).
        for pane in removed {
            buryPane(pane, from: request.session, origin: Registry.Origin(
                workspace: request.session, tab: index, beside: session.tabs[index].panes.first?.id,
                dock: closedFromDock ? true : nil))
        }
        if session.tabs.isEmpty { workspaces.removeValue(forKey: request.session) }
        persist()
        // Success is the committed registry, not merely a spawned process.
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([Registry.Workspace].self, from: data),
              VigilSessionControl.revision(saved.first { $0.name == request.session && $0.buriedUntil == nil }?.tabs ?? [])
                == VigilSessionControl.revision(session.tabs) else {
            return .failure(request, "commit_failed", "The change could not be confirmed on its Mac. Check the workspace there before retrying.")
        }
        sessionLog.info("session command committed", [
            "id": request.id.uuidString, "operation": request.operation, "workspace": request.session,
            "anchor": request.anchor, "pane": created?.id,
        ])
        return Reply(id: request.id, ok: true, code: "committed", message: "Workspace edit committed.",
                     revision: workspaces[request.session]?.layoutRevision, pane: created?.id)
    }

    /// A workspace born for a command, as its reply: committed only once
    /// its pane runs and vigil.json lists it.
    private func birthReply(_ request: VigilSessionControl.Request, _ birth: Birth) -> VigilSessionControl.Reply {
        guard birth.running else {
            return .failure(request, "spawn_failed", "The workspace was created on its Mac, but its terminal did not start; its log says why (mise run log).")
        }
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([Registry.Workspace].self, from: data),
              saved.contains(where: { $0.name == birth.name && $0.tabs?.first?.panes.first?.id == birth.pane.id }) else {
            return .failure(request, "commit_failed", "The new workspace could not be confirmed on its Mac.")
        }
        sessionLog.info("session command committed", [
            "id": request.id.uuidString, "operation": request.operation, "workspace": birth.name,
            "pane": birth.pane.id, "command": request.command,
        ])
        return VigilSessionControl.Reply(id: request.id, ok: true, code: "committed", message: "Workspace created on its Mac.",
                                         revision: workspaces[birth.name]?.layoutRevision, pane: birth.pane.id, session: birth.name)
    }

    static func completeLayout(_ tab: Registry.Tab) -> Registry.Layout {
        if let layout = tab.layout { return layout }
        let last = max(0, tab.panes.count - 1)
        return (0..<last).reversed().reduce(Registry.Layout.leaf(last)) { .h(0.5, .leaf($1), $0) }
    }

    /// A registry projection, never a user edit. Reuse views by daemon id;
    /// constructing a split tree does not run native "new split" actions.
    private func reconcileWorkspaceTree(_ controller: TerminalController, tab: Registry.Tab, host: String?, session: String) {
        guard let app = ghosttyApp?.app, !tab.panes.isEmpty else { return }
        if mirroredWorkspace(of: controller) != nil {
            remoteLayouts[ObjectIdentifier(controller)] = VigilSessionControl.revision([tab])
        }
        let existing = Dictionary(uniqueKeysWithValues: controller.surfaceTree.compactMap { view in
            view.vigilAttachId.map { ($0, view) }
        })
        let focusedId = controller.focusedSurface?.vigilAttachId
        var views: [Ghostty.SurfaceView] = []
        for pane in tab.panes {
            if let view = existing[pane.id] { views.append(view); continue }
            if host == nil, mirroredWorkspace(of: controller) == nil, let view = adoptable(pane.id) {
                views.append(view); continue
            }
            var config = host == nil ? resurrectConfig(name: session, pane: pane) : Ghostty.SurfaceConfiguration()
            config.vigilAttach = pane.id
            config.workingDirectory = pane.cwd
            config.vigilMirror = mirroredWorkspace(of: controller) != nil
            if let host {
                config.vigilHost = host
                config.vigilMirror = true
                config.vigilExplicitClaim = true
            }
            views.append(Ghostty.SurfaceView(app, baseConfig: config))
        }
        func tree(_ layout: Registry.Layout) -> SplitTree<Ghostty.SurfaceView>.Node {
            switch layout {
            case .leaf(let i): return .leaf(view: views[min(max(i, 0), views.count - 1)])
            case .h(let ratio, let left, let right):
                return .split(.init(direction: .horizontal, ratio: ratio, left: tree(left), right: tree(right)))
            case .v(let ratio, let left, let right):
                return .split(.init(direction: .vertical, ratio: ratio, left: tree(left), right: tree(right)))
            }
        }
        let ids = Set(tab.panes.map(\.id))
        for (id, view) in existing where !ids.contains(id) { view.vigilDestroySurface() }
        swapTree(controller, SplitTree(root: tree(Self.completeLayout(tab)), zoomed: nil))
        if host == nil, mirroredWorkspace(of: controller) == nil {
            let oldDock = dockMap.object(forKey: controller)
            if (oldDock?.views.compactMap(\.vigilAttachId) ?? []) != (tab.dock?.panes.map(\.id) ?? []) {
                if let oldDock {
                    for view in oldDock.views { view.vigilDestroySurface() }
                    oldDock.unmount()
                    dockMap.removeObject(forKey: controller)
                }
                materializeDockCapture(controller, tab.dock) { self.resurrectConfig(name: session, pane: $0) }
                VigilBars.shared.sync(controller)
            }
        }
        if let focus = views.first(where: { $0.vigilAttachId == focusedId }) ?? views.first {
            controller.focusedSurface = focus
            if controller.window?.isKeyWindow == true { Ghostty.moveFocus(to: focus) }
        }
    }

    /// A tab row, anchored by any of its pane ids (indices shift as tabs
    /// go live/cold; pane ids never lie). Live tab → focus its window;
    /// captured tab of THIS window's session → swap it in; anything else →
    /// shapeshift the session here, then swap the tab if it stayed captured.
    func activateTab(name: String, anchor: String?, in controller: TerminalController?) {
        if let anchor, let view = liveView(attachId: anchor), treeHome(of: view) != nil {
            // On screen in THIS window (or no window asked): focus it. On
            // screen in another window: this viewport mirrors it
            // (shapeshift's rule).
            if let window = shownHere(view, controller) {
                window.makeKeyAndOrderFront(nil)
                return
            }
            mirrorInto(controller!, name: name, anchor: anchor)
            return
        }
        guard let controller else { open(name: name); return }
        if workspaceName(of: controller) != name {
            // ONE swap, straight to the anchored tab: mounting tab 0 and
            // then swapping again was a visible double-blink.
            shapeshift(in: controller, to: name, anchor: anchor)
        }
        // On screen is SITTING IN A TREE, never mere view existence nor a
        // view's window: an undo corpse, a warm tab or a released tree
        // can hold this pane's SurfaceView, and treating it as shown made
        // both branches skip - the click (and follow) died in silence.
        if let anchor, workspaceName(of: controller) == name,
           liveView(attachId: anchor).flatMap(treeHome(of:)) == nil {
            shapeshiftTab(name: name, anchor: anchor, in: controller)
        }
    }

    /// A pane row: a live surface gets direct focus; a captured one rides
    /// activateTab, whose mount lands focus on it directly.
    func activatePane(name: String, paneId: String?, in controller: TerminalController?) {
        if VigilRemote.split(name) != nil, let controller {
            mountRemote(controller, composite: name, anchor: paneId)
            return
        }
        guard let paneId else {
            activateTab(name: name, anchor: nil, in: controller)
            return
        }
        if let view = liveView(attachId: paneId), let window = shownHere(view, controller) {
            window.makeKeyAndOrderFront(nil)
            Ghostty.moveFocus(to: view)
            return
        }
        activateTab(name: name, anchor: paneId, in: controller)
    }

}
