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
            // Its birth is awaited off the main thread; the window is
            // landed when the reply comes.
            Task { @MainActor [weak controller] in
                let reply = await VigilSessionControl.transact(request)
                guard let controller else { return }
                guard reply.ok else { return self.remoteCommandError(controller, reply.message) }
                if let name = reply.session, name != composite {
                    self.shapeshift(in: controller, to: name, anchor: reply.pane)
                } else if operation == "new_tab", let pane = reply.pane {
                    self.mirrorInto(controller, name: composite, anchor: pane)
                } else if let pane = reply.pane, let landing = controller.surfaceTree.first(where: { $0.vigilAttachId == pane }) {
                    Ghostty.moveFocus(to: landing)
                    if controller.window?.isKeyWindow == true { landing.vigilRequestSize(reason: "session edit") }
                }
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
            informativeText: "\(busy.joined(separator: ", ")) still running\(mac.map { " on \($0)" } ?? ""). Closing the \(what.lowercased()) kills it (\(Self.undoWords))."
        ) { proceed() }
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
                handOn(controller, from: composite)
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
                handOn(controller, from: name)
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
        // A tab kept warm while another is on screen: its tree and dock were
        // built for the panes it had. Mounted as it is after the registry
        // gave the tab a pane or took one (an undo into it, a move, a
        // command from another Mac), the window showed fewer panes than the
        // sidebar listed (2026-11-16). It is kept only while a tab of the
        // registry has exactly its panes and exactly its dock's; any other
        // (changed, or matching no tab at all) is released to its capture:
        // the next mount builds the whole tab, adopting the views that
        // still exist. A split's ratio is not compared: only an edit in
        // the tab's own window moves one, and that tab is then not held.
        if let held = workspaces[name]?.held, !held.isEmpty {
            workspaces[name]!.held = held.filter { runtime in
                let live = Set(runtime.tree.compactMap(\.vigilAttachId))
                let docked = Set(runtime.dock?.views.compactMap(\.vigilAttachId) ?? [])
                if tabs.contains(where: { Set($0.panes.map(\.id)) == live && Set($0.dock?.panes.map(\.id) ?? []) == docked }) { return true }
                registryLog.info("warm tab released to its capture: no tab has its panes and dock", [
                    "workspace": name, "warm": live.sorted(), "dock": docked.sorted(),
                ])
                runtime.dock?.unmount()
                return false
            }
        }
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
                handOn(controller, from: name)
            }
        }
    }

    /// The operations that start a pane's daemon. They wait on the pane
    /// lifecycle service, awaited off the main thread (a service
    /// that is stuck never freezes the app); every other operation is an
    /// edit of the registry alone (`applySessionEdit`).
    static let birthOperations: Set<String> = ["create", "new_session", "split", "new_tab", "fork", "open_pane", "open_shell"]

    /// The home app's session transaction. Remote callers supply identities
    /// and intent, never a replacement registry or local cwd. A birth is
    /// awaited before its edit: the main thread runs other work meanwhile,
    /// so the edit is checked against the revision asked for once the pane
    /// runs, and a pane born for an edit that no longer applies is closed.
    func applySessionCommand(_ request: VigilSessionControl.Request) async -> VigilSessionControl.Reply {
        if request.operation == "bring" { return await bring(request) }
        if request.operation == "retire_move" {
            return .failure(request, "upgrade_required", "Update the destination and move again. This source requires a handoff before another Mac can open the pane.")
        }
        guard Self.birthOperations.contains(request.operation) else { return applySessionEdit(request) }
        refreshWorkspaceRevisions()
        switch request.operation {
        case "create":
            // A workspace of its own: in the folder asked (`~` is this Mac's
            // home), running what was asked, through the one birth path. A
            // window only for this Mac's own command line (`vigil new
            // --window`): the hub refuses one from another device.
            guard let asked = request.cwd else { return .failure(request, "invalid_request", "A new workspace names its folder.") }
            let cwd = (asked as NSString).expandingTildeInPath
            return birthReply(request, await apiNewWorkspace(label: request.label, emoji: request.emoji, cwd: cwd,
                                                             command: request.command, openWindow: request.window == true))
        case "new_session":
            // The same guards as any edit anchored on a pane: a
            // late request whose anchor moved or went is refused, never
            // born in another folder.
            guard let session = workspaces[request.session] else {
                return .failure(request, "not_found", "That workspace no longer exists on its Mac.")
            }
            guard session.layoutRevision == request.revision else {
                return .failure(request, "conflict", "The workspace changed in the meantime. Look at it again and retry.")
            }
            guard let tab = session.tabs.first(where: { $0.paneIds.contains(request.anchor) }) else {
                return .failure(request, "not_found", "That pane is no longer in this workspace.")
            }
            guard session.float == nil else {
                return .failure(request, "presentation_busy", "This workspace is in the floating terminal on its Mac. Put it back before changing its tabs or splits.")
            }
            let cwd = liveView(attachId: request.anchor)?.pwd
                ?? tab.panes.first(where: { $0.id == request.anchor })?.cwd ?? session.cwd
            return birthReply(request, await apiNewWorkspace(label: request.label, cwd: cwd, command: request.command, openWindow: false))
        case "open_pane", "open_shell":
            // A pane that is not running, opened by a person at another
            // device: what opening it here would do (`tend`).
            guard let session = workspaces[request.session],
                  session.tabs.contains(where: { $0.members.contains { $0.id == request.anchor } }) else {
                return .failure(request, "not_found", "That pane is no longer in this workspace on its Mac.")
            }
            // Done before it is answered, as a split or a new tab is: this
            // reply is kept on disk and answers a retry, so "committed" is
            // said only of a daemon that runs.
            if let why = await openNow(request.anchor, why: "opened from another device", shellOnly: request.operation == "open_shell") {
                return .failure(request, "not_opened", "Not opened on its Mac: \(why).")
            }
            // Read again after the wait: closed meanwhile, it is
            // in a burial now, which ends it at its reap; "open" would be
            // false. Moved to another workspace here, it is still open.
            guard let at = locate(request.anchor), !at.buried else {
                return .failure(request, "not_opened", "It was closed on its Mac while it was being opened.")
            }
            sessionLog.info("session command committed", [
                "id": request.id.uuidString, "operation": request.operation, "workspace": request.session, "anchor": request.anchor,
            ])
            return VigilSessionControl.Reply(id: request.id, ok: true, code: "committed", message: "Open on its Mac.",
                                             revision: workspaces[request.session]?.layoutRevision, session: request.session)
        default:
            break
        }
        // A split, a tab, a fork: what it would run, from the workspace as
        // it stands now; refused here when it cannot apply, before anything
        // is born.
        let planned: (pane: Registry.Pane, born: Registry.Pane)
        switch plannedPane(request) {
        case .failure(let refused): return refused.reply
        case .success(let plan): planned = plan
        }
        // The identity is never recycled, born or not.
        persist()
        // The service records the birth request that owns this provisional pane.
        let birth = Self.birthRequest(planned.born, session: request.session, provisional: true)
        fresh.remove(planned.pane.id)
        births.insert(planned.pane.id)
        let attempt = await Self.attemptBirth(birth)
        let failed = attempt.failure
        settled([planned.pane.id], said: failed.map { [planned.pane.id: $0] } ?? [:])
        if failed != nil {
            if attempt.mayHaveReserved { await Self.abortBirth(birth) }
            switch attempt.result {
            case .answered(let reply) where reply.outcomes.first?.outcome == "collision":
                return .failure(request, "id_in_use", "The reserved pane identity is already in use.")
            case .answered(let reply) where reply.outcomes.first?.outcome == "indeterminate":
                return .failure(request, "spawn_unknown", "Its birth outcome is unknown. Cancellation was requested. Check Recovered panes on the home Mac before retrying.")
            case .indeterminate:
                return .failure(request, "spawn_unknown", "The home Mac could not confirm the birth. Cancellation was requested. Check Recovered panes on the home Mac before retrying.")
            default:
                return .failure(request, "spawn_failed", "The home Mac could not start this pane.")
            }
        }
        refreshWorkspaceRevisions()
        let reply = applySessionEdit(request, preborn: planned.pane)
        // A commit that could not be confirmed on disk came after the edit:
        // the pane is in the workspace in memory and is saved with its next
        // save. It runs and is listed: never closed.
        if !reply.ok, reply.code == "commit_failed" {
            sessionLog.error("pane placed, its save not confirmed; kept", ["id": request.id.uuidString, "pane": planned.pane.id])
            return reply
        }
        if !reply.ok {
            // Born for an edit that no longer applies (the workspace changed
            // or went while it was being born): in no registry, so closed.
            sessionLog.warn("pane born for an edit that no longer applies; closing it", [
                "id": request.id.uuidString, "pane": planned.pane.id, "code": reply.code,
            ])
            await Self.abortBirth(birth)
            return reply
        }
        // Committed: the registry on disk lists it, so it is the app's.
        Self.adopt([planned.pane.id])
        return reply
    }

    /// A refusal, as a value (a `Result` failure).
    struct Refused: Error {
        let reply: VigilSessionControl.Reply
    }

    /// The pane a split, tab or fork would add (its program from then on)
    /// and what it is born running (a fork's line is not its program), with
    /// its id minted; or why the request cannot apply. The same checks the
    /// edit makes again once the pane runs.
    private func plannedPane(_ request: VigilSessionControl.Request) -> Result<(pane: Registry.Pane, born: Registry.Pane), Refused> {
        func refused(_ code: String, _ message: String) -> Result<(pane: Registry.Pane, born: Registry.Pane), Refused> {
            .failure(Refused(reply: .failure(request, code, message)))
        }
        guard let session = workspaces[request.session] else { return refused("not_found", "That workspace no longer exists on its Mac.") }
        guard session.layoutRevision == request.revision else {
            return refused("conflict", "The workspace changed in the meantime. Look at it again and retry.")
        }
        guard let tab = session.tabs.first(where: { $0.paneIds.contains(request.anchor) }) else {
            return refused("not_found", "That pane is no longer in this workspace.")
        }
        guard session.float == nil else {
            return refused("presentation_busy", "This workspace is in the floating terminal on its Mac. Put it back before changing its tabs or splits.")
        }
        guard let anchor = tab.panes.first(where: { $0.id == request.anchor }) else {
            return refused("unsupported_target", "A dock tenant cannot anchor a split or tab.")
        }
        let asTab = request.operation == "new_tab" || (request.operation == "fork" && request.direction == nil)
        if !asTab, !["left", "right", "up", "down"].contains(request.direction ?? "") {
            return refused("invalid_direction", "Expected left, right, up or down.")
        }
        // The home pane supplies cwd. No environment or path is inherited
        // from the sender; its command is the one thing it names.
        let folder = liveView(attachId: anchor.id)?.pwd ?? anchor.cwd
        var command = request.command
        /// What the new pane is born running, when that is not the program
        /// it is from then on (a fork: `Fork.Birth`).
        var born = request.command
        if request.operation == "fork" {
            // The fork's line is this Mac's own: built from its broker's
            // record of the anchor's conversation, never from the wire.
            guard let source = Fork.source(pane: anchor.id, in: VigilPaths.conversations),
                  let birth = Fork.birth(of: source, folder: folder) else {
                return refused("not_forkable", "That pane holds no conversation its agent can fork.")
            }
            command = birth.program
            guard let shell = getpwuid(getuid())?.pointee.pw_shell else { return refused("no_shell", "The login shell could not be read.") }
            born = Fork.recipe(birth, shell: String(cString: shell))
            sessionLog.info("fork", [
                "id": request.id.uuidString, "workspace": request.session, "anchor": anchor.id,
                "harness": source.harness, "conversation": source.conversation, "folder": folder,
            ])
        }
        guard let id = try? mintPane(in: request.session) else { return refused("create_failed", "The home Mac could not reserve and save this workspace before starting its program.") }
        return .success((Registry.Pane(id: id, cwd: folder, command: command), Registry.Pane(id: id, cwd: folder, command: born)))
    }

    /// A session transaction that starts nothing: every operation but a
    /// birth (`birthOperations`), and the placing of a pane already born
    /// (`preborn`, a split's, a tab's or a fork's). Synchronous, on main.
    func applySessionEdit(_ request: VigilSessionControl.Request, preborn: Registry.Pane? = nil) -> VigilSessionControl.Reply {
        typealias Reply = VigilSessionControl.Reply
        precondition(!Self.birthOperations.contains(request.operation) || (preborn != nil && !["create", "new_session", "open_pane", "open_shell"].contains(request.operation)),
                     "\(request.operation) starts a daemon: applySessionCommand awaits it")
        refreshWorkspaceRevisions()
        // A burial, by its name: undone (back where it stood) or ended now.
        // The tray of every Mac sends these to the burial's home.
        if request.operation == "exhume" || request.operation == "reap" {
            guard graveyard[request.session] != nil else {
                return .failure(request, "not_found", "It is no longer waiting: its time ran out or it was already undone.")
            }
            if let burial = graveyard[request.session], conflictingOwnership(ownedPaneIds(burial)) {
                return .failure(request, "ownership_conflict", "More than one registry entry owns a pane in this burial.")
            }
            if request.operation == "reap" {
                guard reapNow(request.session) else {
                    sessionLog.warn("session command not finished", ["id": request.id.uuidString, "operation": "reap", "workspace": request.session])
                    return .failure(request, "closing", "Its close began on its Mac and is not finished; it cannot be undone, and its Mac goes on with it.")
                }
                sessionLog.info("session command committed", ["id": request.id.uuidString, "operation": "reap", "workspace": request.session])
                return Reply(id: request.id, ok: true, code: "committed", message: "Ended on its Mac.", revision: nil, session: request.session)
            }
            let back: String
            switch exhume(request.session) {
            case .refused:
                return .failure(request, "closing", "Its close began on its Mac, or whether it did cannot be read: it cannot be undone.")
            case .saveFailed:
                return .failure(request, "commit_failed", "Undo could not be committed. The burial was kept.")
            case .restored(let workspace): back = workspace
            }
            sessionLog.info("session command committed", [
                "id": request.id.uuidString, "operation": "exhume", "workspace": request.session, "back": back,
            ])
            return Reply(id: request.id, ok: true, code: "committed", message: "Back on its Mac.",
                         revision: workspaces[back]?.layoutRevision, session: back)
        }
        // Panes of a workspace here that another Mac brought: they close.
        guard var session = workspaces[request.session] else {
            return .failure(request, "not_found", "That workspace no longer exists on its Mac.")
        }
        if request.operation == "describe" {
            return Reply(id: request.id, ok: true, code: "snapshot", message: "Home session topology revision.",
                         revision: session.layoutRevision, session: request.session)
        }
        // A name, a priority, the workspace's own end: none of them moves a
        // pane within it, so none compares a revision. Whoever asks (this
        // Mac's sidebar, another Mac's, the phone), it is done here, where
        // the workspace lives and every viewer reads it from.
        func done(_ message: String) -> Reply {
            sessionLog.info("session command committed", [
                "id": request.id.uuidString, "operation": request.operation, "workspace": request.session, "anchor": request.anchor,
            ])
            return Reply(id: request.id, ok: true, code: "committed", message: message,
                         revision: workspaces[request.session]?.layoutRevision, session: request.session)
        }
        let holds = { (pane: String) in session.tabs.contains { $0.members.contains { $0.id == pane } } }
        switch request.operation {
        case "rename":
            switch request.part {
            case nil:
                rename(name: request.session, label: request.label ?? request.session, emoji: request.emoji)
            case .tab?, .pane?:
                guard holds(request.anchor),
                      setCustomIdentity(key: (request.part == .tab ? "tab:" : "") + request.anchor, label: request.label, emoji: request.emoji) else {
                    return .failure(request, "not_found", "That pane is no longer in this workspace on its Mac.")
                }
            }
            return done("Renamed.")
        case "priority":
            guard let priority = request.priority, holds(request.anchor) else {
                return .failure(request, "not_found", "That pane is no longer in this workspace on its Mac.")
            }
            setPriority(pane: request.anchor, priority)
            return done("Priority set.")
        case "close_workspace":
            kill(name: request.session)
            sessionLog.info("session command committed", ["id": request.id.uuidString, "operation": request.operation, "workspace": request.session])
            return Reply(id: request.id, ok: true, code: "committed", message: "Closed on its Mac; its undo keeps it for its grace.",
                         revision: nil, session: request.session)
        default:
            break
        }
        guard session.layoutRevision == request.revision else {
            return .failure(request, "conflict", "The workspace changed in the meantime. Look at it again and retry.")
        }
        if WorkspaceCommand.moveOperations.contains(request.operation) { return applyMove(request) }
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
        case "split", "new_tab", "fork":
            guard let anchor = tab.panes.first(where: { $0.id == request.anchor }) else {
                return .failure(request, "unsupported_target", "A dock tenant cannot anchor a split or tab.")
            }
            // A fork with no direction is a tab of its own, as a new tab is.
            let asTab = request.operation == "new_tab" || (request.operation == "fork" && request.direction == nil)
            if !asTab, !["left", "right", "up", "down"].contains(request.direction ?? "") {
                return .failure(request, "invalid_direction", "Expected left, right, up or down.")
            }
            // Born already, before this edit (`applySessionCommand`): the
            // edit only places it, against the revision it was asked for.
            guard var pane = preborn else { preconditionFailure("a split, tab or fork is placed only once its pane was born") }
            if request.operation == "split" {
                pane.label = request.label
                pane.emoji = request.emoji
            }
            created = pane
            session.paneSeq = workspaces[request.session]!.paneSeq
            if asTab {
                let newTab = Registry.Tab(panes: [pane], layout: nil, label: request.operation == "new_tab" ? request.label : nil, emoji: request.emoji)
                session.tabs.insert(newTab, at: index + 1)
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
            guard let remaining = Self.select(tab, keeping: Set(tab.paneIds).subtracting(ids)) else {
                return .failure(request, "source_changed", "This tab has no remaining member.")
            }
            tab = remaining
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

    /// A move asked by name (`vigil workspace merge`, `tab move|extract`,
    /// `pane move`), done by the very functions the sidebar's drags and its
    /// Merge Into run, then judged by where the registry lists what moved:
    /// those functions log a refusal and change nothing, so the registry is
    /// the outcome. The source's revision was compared by the caller.
    private func applyMove(_ request: VigilSessionControl.Request) -> VigilSessionControl.Reply {
        typealias Reply = VigilSessionControl.Reply
        let source = request.session
        guard workspaces[source]?.float == nil else {
            return .failure(request, "presentation_busy", "This workspace is in the floating terminal on its Mac. Put it back before moving its tabs or panes.")
        }
        if let target = request.target {
            guard workspaces[target] != nil else {
                return .failure(request, "not_found", "The workspace it goes into does not exist on that Mac.")
            }
            guard workspaces[target]?.float == nil else {
                return .failure(request, "presentation_busy", "The workspace it goes into is in the floating terminal on its Mac.")
            }
        }
        if request.operation != "merge" {
            guard locate(request.anchor).map({ $0.owner == source && !$0.buried }) == true else {
                return .failure(request, "not_found", "That pane is no longer in this workspace.")
            }
        }
        /// Where the panes that moved are listed now, and the workspace that
        /// holds them (nil: not where they were asked to go).
        func landed(_ panes: [String], in owner: String) -> Bool {
            !panes.isEmpty && panes.allSatisfy { locate($0).map { $0.owner == owner && !$0.buried } == true }
        }
        func committed(_ owner: String, _ message: String) -> Reply {
            persist()
            sessionLog.info("session command committed", [
                "id": request.id.uuidString, "operation": request.operation, "workspace": source,
                "anchor": request.anchor, "target": owner,
            ])
            return Reply(id: request.id, ok: true, code: "committed", message: message,
                         revision: workspaces[owner]?.layoutRevision, session: owner)
        }
        let refused = { (what: String) in
            Reply.failure(request, "not_moved", "\(what) did not move on its Mac; its log says why (mise run log move).")
        }
        switch request.operation {
        case "merge":
            let target = request.target!
            let panes = workspaces[source]!.tabs.flatMap(\.paneIds)
            mergeWorkspace(source, into: target)
            guard landed(panes, in: target) else { return refused("The workspace") }
            return committed(target, "Merged; the emptied workspace rests in Recently closed.")
        case "move_tab":
            let target = request.target!
            guard target != source else {
                // Among its own tabs: the sidebar's reorder.
                let tabs = workspaces[source]!.tabs
                let onto = request.position.flatMap { tabs.indices.contains($0) ? tabs[$0].paneIds.first : nil }
                reorderTab(anchor: request.anchor, in: source, onto: onto)
                return committed(source, "Tab moved.")
            }
            let panes = workspaces[source]!.tabs.first { $0.paneIds.contains(request.anchor) }?.paneIds ?? []
            moveTab(anchor: request.anchor, from: source, to: target)
            guard landed(panes, in: target) else { return refused("The tab") }
            if let position = request.position, var tabs = workspaces[target]?.tabs,
               let from = tabs.firstIndex(where: { $0.paneIds.contains(request.anchor) }), position < from {
                tabs.insert(tabs.remove(at: from), at: position)
                workspaces[target]!.tabs = tabs
            }
            return committed(target, "Tab moved.")
        case "extract_tab":
            guard let tab = workspaces[source]!.tabs.first(where: { $0.paneIds.contains(request.anchor) }) else {
                return .failure(request, "not_found", "That pane's tab is a dock tenant's; name a pane of the tab.")
            }
            guard workspaces[source]!.tabs.count > 1 else {
                return .failure(request, "unsupported_target", "That is the workspace's only tab: it already is a workspace of its own.")
            }
            let old = workspaces[source]!
            let name = newWorkspaceId()
            // Its name and face: the tab's own, else the drag-out's lineage
            // label and the workspace's face.
            var label = tab.label
            if label == nil {
                var ordinal = 2
                let taken = Set(workspaces.values.map(\.label))
                while taken.contains("\(old.label) \(ordinal)") { ordinal += 1 }
                label = "\(old.label) \(ordinal)"
            }
            var made = Workspace(name: name, label: label!, cwd: tab.panes.first?.cwd ?? old.cwd)
            made.emoji = tab.emoji ?? old.emoji
            workspaces[name] = made
            moveTab(anchor: request.anchor, from: source, to: name)
            guard landed(tab.paneIds, in: name) else {
                if workspaces[name]?.tabs.isEmpty == true { workspaces[name] = nil }
                return refused("The tab")
            }
            // The name is the workspace's now, never the tab's twice.
            if let index = workspaces[name]!.tabs.firstIndex(where: { $0.paneIds.contains(request.anchor) }) {
                workspaces[name]!.tabs[index].label = nil
                workspaces[name]!.tabs[index].emoji = nil
            }
            lifecycleLog.info("minted by a tab extract", ["workspace": name, "label": made.label, "source": source])
            return committed(name, "The tab is a workspace of its own.")
        case "move_pane":
            let target = request.target!
            let isDock = workspaces[source]!.tabs.contains { $0.dock?.panes.contains { $0.id == request.anchor } == true }
            if let into = request.targetTab {
                guard locate(into).map({ $0.owner == target && !$0.buried }) == true else {
                    return .failure(request, "not_found", "The tab it joins is not in that workspace.")
                }
                movePane(paneId: request.anchor, from: source, intoTabAnchoredBy: into, of: target)
                let joined = workspaces[target]?.tabs.first { $0.paneIds.contains(into) }?.paneIds.contains(request.anchor) == true
                guard joined else {
                    return landed([request.anchor], in: target)
                        ? committed(target, "Moved; it stays a tab of its own there (the tab is on screen elsewhere).")
                        : refused("The pane")
                }
                return committed(target, "Pane moved into the tab.")
            }
            movePane(paneId: request.anchor, from: source, to: target, isDock: isDock)
            guard landed([request.anchor], in: target) else { return refused("The pane") }
            return committed(target, "Pane moved.")
        default:
            return .failure(request, "unsupported_operation", "vigil on that Mac can't do this; update it.")
        }
    }

    /// A workspace born for a command, as its reply: committed only once
    /// its pane runs and vigil.json lists it.
    private func birthReply(_ request: VigilSessionControl.Request, _ birth: Birth?) -> VigilSessionControl.Reply {
        guard let birth else { return .failure(request, "create_failed", "The home Mac could not reserve and save this workspace before starting its program.") }
        guard birth.running else {
            return .init(id: request.id, ok: false, code: "created_unavailable", message: "Workspace \(birth.name) was created. Its terminal start is unconfirmed. Open this workspace to continue.", pane: birth.pane.id, session: birth.name)
        }
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([Registry.Workspace].self, from: data),
              saved.contains(where: { $0.name == birth.name && $0.tabs?.first?.panes.first?.id == birth.pane.id }) else {
            return .init(id: request.id, ok: false, code: "created_unavailable", message: "The start of \(birth.name) was accepted. Its current ownership is unconfirmed. Check this workspace before taking further action.", pane: birth.pane.id, session: birth.name)
        }
        sessionLog.info("session command committed", [
            "id": request.id.uuidString, "operation": request.operation, "workspace": birth.name,
            "pane": birth.pane.id, "command": request.command,
        ])
        return VigilSessionControl.Reply(id: request.id, ok: true, code: "committed", message: "Workspace created on its Mac.",
                                         revision: workspaces[birth.name]?.layoutRevision, pane: birth.pane.id, session: birth.name)
    }

    static func select(_ original: Registry.Tab, keeping ids: Set<String>) -> Registry.Tab? {
        var tab = original
        tab.panes = original.panes.filter { ids.contains($0.id) }
        let mapping = Dictionary(uniqueKeysWithValues: tab.panes.enumerated().map { ($0.element.id, $0.offset) })
        func prune(_ node: Registry.Layout) -> Registry.Layout? {
            switch node {
            case .leaf(let i):
                guard original.panes.indices.contains(i), let next = mapping[original.panes[i].id] else { return nil }
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
        tab.layout = prune(completeLayout(original))
        if var dock = original.dock {
            let active = dock.panes.indices.contains(dock.active) ? dock.panes[dock.active].id : nil
            dock.panes.removeAll { !ids.contains($0.id) }
            dock.active = dock.panes.firstIndex { $0.id == active } ?? min(dock.active, max(0, dock.panes.count - 1))
            if tab.panes.isEmpty, !dock.panes.isEmpty {
                tab.panes = [dock.panes.remove(at: dock.active)]
                tab.layout = nil
                dock.active = min(dock.active, max(0, dock.panes.count - 1))
            }
            tab.dock = dock.panes.isEmpty ? nil : dock
        }
        return tab.panes.isEmpty ? nil : tab
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
