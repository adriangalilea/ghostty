import AppKit
import Combine
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
    func bring(_ request: VigilSessionControl.Request) async -> VigilSessionControl.Reply {
        guard let device = request.from, let host = VigilRemote.shared.host(device),
              let held = VigilRemote.shared.sourceDirectory(device) else {
            return .failure(request, "not_found", "This Mac has not heard that workspace from that Mac.")
        }
        let reading: Bring.Source
        do {
            reading = try await Bring.source(in: held, request: request, unavailable: host.error) {
                try await Task.detached(priority: .utility) {
                    let bytes = try Local.Client(socket: VigilPaths.hub).call(device: device, .moveSource(request.session))
                    return try JSONDecoder().decode(Directory.self, from: bytes)
                }.value
            }
        } catch {
            return .failure(request, "source_unknown", String(describing: error))
        }
        let directory = reading.directory, whole = reading.whole, source = reading.selected
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        let names = directory.conversationNames(of: source)
        let revisions = reading.revisions
        guard let digest = try? Registry.Workspace.moveDigest(label: whole.label, emoji: whole.emoji, cwd: whole.cwd, pinned: whole.pinned ?? false,
                                                               revision: whole.layoutRevision, tabs: whole.tabs ?? [], facts: revisions) else {
            return .failure(request, "source_unknown", "Could not encode the source workspace for transfer.")
        }
        for entry in (source.tabs ?? []).flatMap(\.members) {
            let pane = entry.id
            guard let facts = directory.panes[pane], let version = revisions[pane] else {
                return .failure(request, "source_unknown", "The source pane facts are unavailable.")
            }
            let fields = version.split(separator: "/")
            guard fields.count == 5, fields[1] == "-" || facts.ended != nil,
                  fields[3] == "-", fields[2] == "-" || directory.moveConversation(of: entry)?.conversation != nil,
                  facts.glanceError == nil, facts.conflict == nil else {
                return .failure(request, "source_unknown", "The end or conversation of \(pane) could not be transferred with certainty. The source stays open.")
            }
        }
        guard !(source.tabs ?? []).flatMap(\.members).contains(where: { $0.from?.ticket != nil && $0.dormant == true && $0.from?.accepted != true }) else {
            return .failure(request, "moving", "A pane is still waiting for its previous move.")
        }
        func overlapsPendingMove() -> Bool {
            let originals = Set(source.paneIds)
            if (Array(workspaces.values) + Array(graveyard.values)).contains(where: { entry in
                entry.tabs.flatMap(\.members).contains { pane in
                    pane.from.map { $0.device == device && originals.contains($0.pane) && $0.accepted == true } == true
                }
            }) { return true }
            return incomingMoves.values.contains {
                $0.source == device && $0.refusal == nil && !originals.isDisjoint(with: $0.panes.keys) &&
                    ($0.requested || $0.panes.values.contains { locate($0) != nil })
            }
        }
        guard !overlapsPendingMove() else { return .failure(request, "moving", "A move of these panes is already staged here.") }
        let receiver = try? await moveDevice()
        guard let receiver else { return .failure(request, "unavailable", "This Mac cannot identify itself to the source.") }
        let name = newWorkspaceId()
        let owned = (Array(workspaces.values) + Array(graveyard.values)).reduce(into: Set<String>()) {
            $0.formUnion(ownedPaneIds($1))
        }
        let entry: Registry.Workspace
        do {
            var floor = 0
            entry = try source.brought(as: name, from: device, mac: host.name, at: Date().timeIntervalSince1970,
                                       home: directory.home, here: here, order: (workspaces.values.map(\.order).max() ?? 0) + 1,
                                       names: names, facts: directory.panes, ticket: request.id) {
                let index = try PaneLife.reserve(workspace: name, startingAt: floor, owned: owned,
                                                 panes: VigilPaths.panes, agent: VigilPaths.agent, arrival: true, transferring: true)
                floor = index + 1
                return index
            }
        } catch {
            return .failure(request, "allocation_failed", "This Mac could not reserve the arriving panes: \(error)")
        }
        let arrivals = Set(entry.paneIds)
        births.formUnion(arrivals)
        var retainFiles = false
        defer {
            births.subtract(arrivals)
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
            for pane in (entry.tabs ?? []).flatMap(\.members) {
                if let end = pane.from?.ended {
                    try Durable.replace(VigilPaths.panes.appendingPathComponent(pane.id + ".ended"), with: JSONEncoder().encode(end))
                }
            }
        } catch {
            return .failure(request, "end_unavailable", "The source is still open. Its end record could not be saved here.")
        }
        // The pointers first: a pane is in the registry only once its first
        // start can find what it resumes.
        let lines: [Bring.Line]
        do {
            let question = Bring.Question(panes: directory.bringing(source, as: entry, here: here), commit: true, requireStoppedWriter: true)
            let answer = try await Task.detached(priority: .utility) {
                try Local.Client(socket: VigilPaths.hub).bring(question)
            }.value
            guard answer.failed.isEmpty else { return .failure(request, "resume_failed", answer.failed.values.sorted().joined(separator: "\n")) }
            lines = answer.lines
            let revision = Bring.checkoutRevision(lines)
            if !revision.isEmpty && revision != request.revision {
                let differences = Bring.standing(lines).filter { item in
                    item.panes.contains { $0.checkoutNeeds.contains(item.need) }
                }.map(\.need.text).joined(separator: "\n")
                // Only a digest of what was accepted is kept, so what moved
                // is said as what it may be: the words below can read as
                // before when only the paths they sample, or their status,
                // changed.
                return .failure(request, "checkout_changed", "This Mac's checkout differs from the sheet you accepted: a need came or went, or the changed paths behind one of these (which paths, or their status) are not the ones you saw.\n" + differences + "\nReview the move and choose Bring Anyway, or use --without to accept the destination checkout.")
            }
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
        let proofs = Dictionary(uniqueKeysWithValues: lines.compactMap { line in line.proof.map { (line.pane, $0) } })
        guard Set(lines.map(\.pane)) == Set(source.paneIds),
              lines.allSatisfy({ $0.conversation == nil || ($0.folderHere && $0.proof?.files?.isEmpty == false) }) else {
            return .failure(request, "copy_incomplete", "The destination has no usable checkpoint for every conversation. The source is still open.")
        }
        let conversations = Set(proofs.values.flatMap { proof in (proof.files ?? [:]).keys.map { proof.agent + "/" + $0 } })
        func overlapsConversation() -> Bool {
            incomingMoves.values.contains(where: { ticket in
                ticket.refusal == nil && (ticket.requested || ticket.panes.values.contains { locate($0) != nil }) &&
                    (ticket.request.moved?.transcripts ?? [:]).contains { original, proof in
                    guard let local = ticket.panes[original] else { return true }
                    if ticket.accepted && locate(local) == nil && memberMark(local) == .clean { return false }
                    return (proof.files ?? [:]).keys.contains { conversations.contains(proof.agent + "/" + $0) }
                }
            })
        }
        guard !overlapsConversation() else { return .failure(request, "moving", "A transfer of this conversation is already in progress here.") }
        var move = WorkspaceCommand.Request.Moved(panes: source.paneIds, mac: Host.current().localizedName ?? "another Mac", transcripts: proofs)
        do {
            move.sourceWork = try Dictionary(uniqueKeysWithValues: source.paneIds.map { pane in
                // A source that never published its work: the sheet said
                // "not known" and the person accepted that, so it binds
                // nothing, as a `.work` cut to no repository does.
                guard let work = directory.panes[pane]?.work else { return (pane, Bring.WorkStrength.untold.rawValue) }
                return (pane, try Bring.sourceWorkRevision(work))
            })
        } catch { return .failure(request, "source_unknown", "The source checkout facts could not be recorded.") }
        move.device = receiver
        move.arrival = name
        move.ticket = request.id
        let mapping = Dictionary(uniqueKeysWithValues: session.tabs.flatMap(\.members).compactMap { pane in pane.from.map { ($0.pane, pane.id) } })
        move.arrivals = mapping
        let release = WorkspaceCommand.Request(id: request.id, session: source.name, revision: digest, operation: "release_move_v2", anchor: "", moved: move)
        let folders = Dictionary(uniqueKeysWithValues: session.tabs.flatMap(\.members).map { ($0.id, $0.cwd) })
        let ticket = IncomingMove(source: device, request: release, panes: mapping, folders: folders)
        if !proofs.isEmpty {
            let selected = directory.bringing(source, as: entry, here: here).filter { proofs[$0.pane] != nil }
            var checkpoint = Bring.Question(panes: selected, commit: false, checkpoints: proofs)
            checkpoint.handoff = .archive(request.id)
            checkpoint.allowLongerPrefix = true
            do {
                let result = try await readMove(checkpoint)
                guard result.failed.isEmpty else { throw WireError.refused("Incomplete checkpoint") }
            } catch { return .failure(request, "checkpoint_unavailable", "The local history could not be saved before moving: \(error)") }
        }
        guard !overlapsPendingMove() else { return .failure(request, "moving", "A move of these panes is already staged here.") }
        guard !overlapsConversation() else { return .failure(request, "moving", "A transfer of this conversation is already in progress here.") }
        do { try ticket.save() } catch { return .failure(request, "commit_failed", "The handoff request could not be saved: \(error)") }
        guard admit(session, "brought") else {
            return .failure(request, "commit_failed", "This Mac's registry already lists that workspace's name or one of its panes; nothing was brought.")
        }
        guard persist(publish: false, durable: true) else {
            retainFiles = registryInstallUncertain
            if !retainFiles { workspaces[entry.name] = nil }
            return .init(id: request.id, ok: false, code: "commit_unknown", message: "The copy \(entry.name) could not be confirmed. Check the move on both Macs.", session: entry.name)
        }
        retainFiles = true
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([Registry.Workspace].self, from: data),
              let kept = saved.first(where: { $0.name == entry.name && $0.buriedUntil == nil }), kept.tabs == entry.tabs else {
            return .init(id: request.id, ok: false, code: "commit_unknown", message: "The destination \(entry.name) was written but could not be verified. Check the move on both Macs.", session: entry.name)
        }
        persist()
        lifecycleLog.info("brought", [
            "workspace": entry.name, "from": host.name, "was": source.name, "tabs": session.tabs.count,
            "panes": session.tabs.flatMap(\.members).count, "resuming": lines.filter { $0.transcriptHere == true && $0.folderHere }.count,
            "lacking": lines.filter { !$0.lacks.isEmpty }.count,
        ])
        incomingMoves[request.id] = ticket
        resumeMoves(from: device)
        return .init(id: request.id, ok: true, code: "committed", message: "Saved here. An open waits for the source to stop and its last conversation bytes to arrive.", session: name)
    }

    /// The receiver owns delivery. Its request and accepted receipt survive either Mac
    /// restarting and a lost reply. Only the source can release these exact pane ids.
    struct IncomingMove: Codable {
        let source: String
        var request: WorkspaceCommand.Request
        let panes: [String: String]
        let folders: [String: String]
        var requested = false
        var released: [String: Bring.TranscriptProof]?
        var accepted = false
        var refusal: String?
        var takeover: Bool?
        var localCheckpoint: [String: Bring.TranscriptProof]?
        var superseded: Bool?
        var privatePages: Bool?
        var cursor: Int?
        var page: Bring.Page?
        var finalPage: Bool?
        var granted: Bool?
        var parent: UUID?
        var seedArchive: UUID?
        var previousHold: UUID?
        var withdrawals: [Withdrawal]?
        static func completion(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".done") }
        func openFile(_ pane: String) -> URL { Self.folder.appendingPathComponent(request.id.uuidString + "." + pane + ".open") }
        static var folder: URL { VigilPaths.root.appendingPathComponent("incoming-moves") }
        var file: URL { Self.folder.appendingPathComponent(request.id.uuidString + ".json") }
        func save() throws {
            try Durable.folder(Self.folder)
            try Durable.replace(file, with: JSONEncoder().encode(self))
        }
    }

    struct MoveSuccessor: Codable, Sendable, Equatable {
        let device: String
        let workspace: String
        let pane: String
        let ticket: UUID

        var valid: Bool { [device, workspace, pane].allSatisfy(Open.validPane) }
    }

    struct Withdrawal: Codable {
        let id: UUID
        let old: String
        let next: MoveSuccessor
    }

    static func closedHereFile(_ pane: String) -> URL {
        VigilPaths.root.appendingPathComponent("move-closed-here").appendingPathComponent(pane)
    }

    private static var successorsFolder: URL { VigilPaths.root.appendingPathComponent("move-successors") }

    /// A pane id is never reused. Keep its first onward grant even after the
    /// source burial is acknowledged. A later withdrawal follows that same
    /// chain until it reaches the pane that actually inherited the work.
    private func successors(of move: WorkspaceCommand.Request.Moved, recording: Bool) throws -> [String: MoveSuccessor] {
        guard let device = move.device, let workspace = move.arrival, let ticket = move.ticket,
              let arrivals = move.arrivals else { throw WireError.invalid("missing onward pane identities") }
        var next: [String: MoveSuccessor] = [:]
        let folder = Self.successorsFolder
        if recording { try Durable.folder(folder) }
        for pane in move.panes {
            guard let arrival = arrivals[pane], Open.validPane(pane) else { throw WireError.invalid("missing onward pane") }
            let intended = MoveSuccessor(device: device, workspace: workspace, pane: arrival, ticket: ticket)
            let file = folder.appendingPathComponent(pane)
            if recording, try Durable.decode(MoveSuccessor.self, file).get() == nil {
                try Durable.replace(file, with: JSONEncoder().encode(intended))
            }
            guard let edge = try Durable.decode(MoveSuccessor.self, file).get(), edge.valid else {
                throw WireError.refused("The source has no durable onward receipt for " + pane)
            }
            if edge.device != device || edge.pane != arrival { next[pane] = edge }
        }
        return next
    }

    func discardUndispatchedMoves(for panes: Set<String>) {
        guard registryRead == .current else { return }
        for (id, ticket) in incomingMoves where ticket.parent == nil && !ticket.requested &&
            !panes.isDisjoint(with: ticket.panes.values) && ticket.panes.values.allSatisfy({ locate($0) == nil && memberMark($0) == .clean }) {
            do {
                for pane in ticket.panes.values { try Durable.remove(ticket.openFile(pane)) }
                try Durable.remove(ticket.file)
                incomingMoves[id] = nil
                moveRetry.removeValue(forKey: id)?.cancel()
                moveWaiting[id] = nil
                moveDelay[id] = nil
            } catch { reportIncompleteMove(ticket.request.session, String(describing: error)) }
        }
    }

    func loadIncomingMoves() {
        do {
            try Durable.folder(IncomingMove.folder)
            for file in try FileManager.default.contentsOfDirectory(at: IncomingMove.folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                do {
                    var ticket = try JSONDecoder().decode(IncomingMove.self, from: Data(contentsOf: file))
                    if ticket.request.operation == "release_move", var move = ticket.request.moved {
                        let old = ticket.request
                        move.arrivals = ticket.panes
                        ticket.request = .init(id: old.id, issuedAt: old.issuedAt, session: old.session, revision: old.revision,
                                               operation: "release_move_v2", anchor: "", moved: move)
                        guard ticket.file.lastPathComponent == file.lastPathComponent, ticket.request.refusal == nil, move.ticket == old.id else {
                            throw WireError.invalid("Unreadable identities in the saved handoff.")
                        }
                        try ticket.save()
                    }
                    guard ticket.file.lastPathComponent == file.lastPathComponent,
                          ticket.request.operation == "release_move_v2", ticket.request.refusal == nil,
                          ticket.request.moved?.ticket == ticket.request.id else {
                        lifecycleLog.error("invalid incoming move", ["file": file.path, "why": ticket.request.refusal ?? "ticket identity"])
                        continue
                    }
                    // Earlier clients saved an old peer's protocol error as
                    // a terminal refusal, with only the message on disk.
                    if ticket.refusal == "only a move names the panes that left" {
                        ticket.refusal = nil
                        try ticket.save()
                    }
                    if ticket.parent == nil, (!ticket.requested || ticket.refusal != nil), registryRead == .current,
                       ticket.panes.values.allSatisfy({ locate($0) == nil }) {
                        for pane in ticket.panes.values { try Durable.remove(ticket.openFile(pane)) }
                        try Durable.remove(ticket.file)
                    } else { incomingMoves[ticket.request.id] = ticket }
                } catch { lifecycleLog.error("unreadable incoming move", ["file": file.path, "err": error]) }
            }
        } catch { lifecycleLog.error("incoming moves could not be loaded", ["err": error]) }
        do { savedMoveHistories = try Durable.decode([UUID: SavedMoveHistory].self, savedMoveHistoriesFile).get() ?? [:] }
        catch { reportIncompleteMove("saved histories", String(describing: error)) }
        do { firstFailedProbe = try Durable.decode([String: Date].self, moveOutagesFile).get() ?? [:] }
        catch { lifecycleLog.error("move outage clock unreadable", ["err": error]) }
        let sources = Set(incomingMoves.values.map(\.source))
        for device in sources.union(graveyard.values.compactMap { $0.moveCheckpoint?.device }) {
            if !moveReachable(device) { moveContact(device, waiting: true) }
        }
        for device in sources { resumeMoves(from: device) }
    }

    func moveContact(_ device: String, waiting: Bool = false, recheck: Bool = false) {
        if !waiting { unpairedMoves.remove(device); moveProbes[device] = nil; setMoveOffline(device, false); return }
        guard incomingMoves.values.contains(where: { $0.source == device }) ||
                graveyard.values.contains(where: { $0.moveCheckpoint?.device == device }) else { return }
        guard (recheck || moveOffline[device] == nil), moveProbes[device] == nil else { return }
        let token = UUID()
        moveProbes[device] = token
        Task { @MainActor in
            let offline: Bool
            var unpaired = false
            do { try await probeMove(device); offline = false }
            catch WireError.offline { offline = true }
            catch WireError.unpaired where firstFailedProbe[device] != nil {
                guard moveProbes[device] == token else { return }
                unpaired = true
                offline = true
            }
            catch {
                if moveProbes[device] == token { moveProbes[device] = nil }
                return
            }
            guard moveProbes[device] == token else { return }
            moveProbes[device] = nil
            let changed = unpaired != unpairedMoves.contains(device)
            if unpaired { unpairedMoves.insert(device) } else { unpairedMoves.remove(device) }
            setMoveOffline(device, offline)
            if changed {
                for t in incomingMoves.values where t.source == device { updateMoveNotes(t) }
                NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
            }
        }
    }

    private func setMoveOffline(_ device: String, _ offline: Bool) {
        let since = offline ? (firstFailedProbe[device] ?? Date()) : nil
        if firstFailedProbe[device] != since {
            firstFailedProbe[device] = since
            do { try Durable.replace(moveOutagesFile, with: JSONEncoder().encode(firstFailedProbe)) }
            catch { lifecycleLog.error("move outage clock could not be saved", ["err": error]) }
        }
        guard moveOffline[device] != since else { return }
        moveOffline[device] = since
        for ticket in incomingMoves.values where ticket.source == device {
            if !offline { moveWaiting[ticket.request.id] = nil }
            updateMoveNotes(ticket)
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    private func updateMoveNotes(_ ticket: IncomingMove) {
        for pane in ticket.panes.values where waitingForMove(pane) { showMoveNote(pane) }
    }

    func canTakeOver(_ ticket: IncomingMove) -> Bool {
        guard moveOffline[ticket.source] != nil, !ticket.accepted, ticket.takeover != true,
              (ticket.released == nil || ticket.finalPage == false || ticket.page != nil), ticket.refusal == nil, ticket.superseded != true else { return false }
        let originals = Set(ticket.panes.keys)
        return !incomingMoves.values.contains { other in
            other.request.id != ticket.request.id && other.source == ticket.source && other.refusal == nil &&
                !originals.isDisjoint(with: other.panes.keys) &&
                (other.requested || other.panes.values.contains { locate($0)?.buried == false })
        }
    }

    func canTakeBack(_ burial: Workspace) -> Bool {
        guard let move = burial.moveCheckpoint, let device = move.device, moveOffline[device] != nil,
              move.arrivals != nil,
              !recoveredMoveBurials.contains(burial.name) else { return false }
        return ownedPaneIds(burial).allSatisfy { memberMark($0) == .clean && !Self.daemonAlive($0) }
    }

    /// Re-probe after confirmation. Any positive contact while it was open
    /// invalidates the original offline episode, even if a later dial fails.
    func stillOffline(_ device: String, since: Date) async -> Bool {
        guard moveOffline[device] == since else { return false }
        do { try await probeMove(device) }
        catch WireError.offline { return moveOffline[device] == since }
        catch WireError.unpaired {
            // A prior measured failure survived the loss of pairing. If
            // this is the first time the UI learns why checking is no
            // longer possible, redraw and ask for a new confirmation.
            guard moveOffline[device] == since, firstFailedProbe[device] == since else { return false }
            let known = !unpairedMoves.insert(device).inserted
            if !known {
                for t in incomingMoves.values where t.source == device { updateMoveNotes(t) }
                NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
            }
            return known
        }
        catch { return false }
        moveContact(device)
        return false
    }

    func resumeMoves(from device: String) {
        for (name, burial) in graveyard where burial.moveCheckpoint?.device == device && burial.moveCheckpoint?.ticket == nil
            && graveyardDeadlines[name].map({ $0 <= Date() }) == true {
            reapIfExpired(name)
        }
        for (id, ticket) in incomingMoves where ticket.source == device && ticket.refusal == nil && !activeMoves.contains(id) {
            moveRetry.removeValue(forKey: id)?.cancel()
            activeMoves.insert(id)
            let epoch = moveEpoch[id]
            Task { @MainActor in
                defer { if moveEpoch[id] == epoch { activeMoves.remove(id) } }
                do {
                    try await advanceIncoming(ticket)
                } catch {
                    guard moveEpoch[id] == epoch else { return }
                    let why = String(describing: error)
                    if moveWaiting[id] != why {
                        moveWaiting[id] = why
                        lifecycleLog.warn("handoff waiting", ["move": id, "why": why])
                        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
                        for pane in ticket.panes.values where waitingForMove(pane) { showMoveNote(pane) }
                    }
                }
                guard moveEpoch[id] == epoch, let pending = incomingMoves[id], pending.refusal == nil,
                      pending.requested || matchesArrival(pending) else { return }
                if pending.withdrawals?.contains(where: { incomingMoves[$0.id] != nil }) == true { return }
                // A disconnected peer wakes this work on its next directory.
                // An unanswered RPC or a replica still catching up while online
                // retries only this outstanding transfer, with a bounded backoff.
                let pause = min((moveDelay[id] ?? 1) * 2, 60)
                moveDelay[id] = pause
                moveRetry[id] = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(pause)) } catch { return }
                    guard moveReachable(device) else { return }
                    resumeMoves(from: device)
                }
            }
        }
    }

    private func matchesArrival(_ ticket: IncomingMove) -> Bool {
        guard !ticket.panes.isEmpty, !conflictingOwnership(Set(ticket.panes.values)), Set(ticket.panes.keys) == Set(ticket.request.moved?.panes ?? []),
              Set(ticket.panes.values).count == ticket.panes.count else { return false }
        if ticket.parent != nil {
            return ticket.request.moved?.priorGrant != nil && ticket.takeover == true && ticket.granted == true && ticket.accepted
        }
        return ticket.panes.allSatisfy { old, new in
            guard let pane = registered(new) else { return ticket.requested && PaneFence.provesClose(memberMark(new)) }
            guard let from = pane.from else { return false }
            return from.ticket == ticket.request.id && from.device == ticket.source && from.pane == old
        }
    }

    func advanceIncoming(_ saved: IncomingMove) async throws {
        var ticket = saved
        let request = ticket.request
        let epoch = moveEpoch[request.id]
        guard matchesArrival(ticket) else { throw WireError.refused("the local registry cannot account for this transfer") }
        func current() throws {
            guard let saved = incomingMoves[request.id], moveEpoch[request.id] == epoch, saved.superseded != true, saved.refusal == nil, saved.takeover == ticket.takeover, matchesArrival(ticket) else {
                throw WireError.refused("the transfer decision changed")
            }
        }
        func save() throws {
            try current()
            try ticket.save()
            incomingMoves[request.id] = ticket
            updateMoveNotes(ticket)
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
        func command(_ command: WorkspaceCommand.Request) async throws -> VigilSessionControl.Reply {
            if ticket.parent != nil, ticket.source == request.moved?.device { return await handoffCommand(command) }
            return try await moveCommand(ticket.source, command)
        }
        let staged = request.moved?.transcripts ?? [:]
        func panes(_ proofs: [String: Bring.TranscriptProof]) throws -> [Bring.Pane] {
            try proofs.map { old, proof in
                guard let new = ticket.panes[old], let folder = ticket.folders[new] else { throw WireError.refused("missing staged pane") }
                let arriving = registered(new) == nil || PaneFence.provesClose(memberMark(new)) ? "" : new
                return .init(pane: old, arriving: arriving, agent: proof.agent, conversation: proof.start, cwd: folder, name: nil)
            }
        }
        if !ticket.requested {
            if ticket.panes.values.allSatisfy({ locate($0)?.buried == true }) {
                // Closing the entire staged copy before sending withdraws the move.
                // Undo can resume the transfer through its original ticket.
                throw WireError.refused("Move paused while the staged panes are closed.")
            }
            guard persist(publish: false, durable: true) else { throw WireError.refused("destination registry not saved") }
            if ticket.takeover == true {
                ticket.requested = true
                try save()
            }
        }
        let forced = ticket.takeover == true
        func receive() async throws {
            while ticket.released == nil || ticket.finalPage == false || ticket.page != nil {
                if ticket.page == nil {
                    var query = request
                    query.offset = ticket.cursor
                    query.takenOver = forced ? true : nil
                    query.conflictBase = forced ? ticket.localCheckpoint : nil
                    let reply: VigilSessionControl.Reply
                    if !ticket.requested {
                        try current()
                        guard ticket.panes.values.contains(where: { locate($0)?.buried == false }) else {
                            throw WireError.refused("Move paused while the staged panes are closed.")
                        }
                        ticket.requested = true
                        try save()
                    }
                    do {
                        reply = try await command(query)
                    } catch WireError.offline {
                        moveContact(ticket.source, waiting: true)
                        throw WireError.offline
                    }
                    moveContact(ticket.source)
                    try current()
                    if reply.code == "unsupported_operation" || reply.code == "invalid_request" {
                        // A peer may reject a newer wire format after already
                        // fencing the same ticket. Keep its identity retryable.
                        throw WireError.refused("The source could not read this move. Check the Vigil versions on both Macs. Its release state is unknown here. " + reply.message)
                    }
                    if reply.code == "source_changed" {
                        ticket.refusal = reply.message
                        try save()
                        for pane in ticket.panes.values where waitingForMove(pane) { showMoveNote(pane) }
                        reportIncompleteMove(request.session, reply.message)
                        throw WireError.refused(reply.message)
                    }
                    guard reply.ok, reply.id == request.id, ["released", "transferring"].contains(reply.code),
                          let final = reply.released, final.values.allSatisfy(\.valid), (forced ? Set(final.keys).isSubset(of: Set(ticket.panes.keys)) : Set(final.keys) == Set(staged.keys) && final.allSatisfy {
                              staged[$0.key]?.agent == $0.value.agent && staged[$0.key]?.start == $0.value.start
                          }),
                          ticket.released == nil || ticket.released == final,
                          (reply.page?.more ?? false) == (reply.code == "transferring"),
                          reply.code == "released" || (reply.page?.parts.isEmpty == false && reply.page?.more == true)
                    else { throw WireError.refused(reply.message) }
                    if ticket.released == nil {
                        ticket.released = final
                        ticket.finalPage = false
                        try save()
                    }
                    ticket.page = reply.page
                    ticket.finalPage = reply.code == "released"
                }
                if let page = ticket.page, let final = ticket.released {
                    var importing = Bring.Question(panes: [], commit: false, checkpoints: final)
                    if !forced, ticket.privatePages == true { importing.staging = request.id }
                    importing.seedArchive = ticket.seedArchive
                    importing.handoff = .receive(page, conflict: forced ? .init(device: ticket.source, ticket: request.id) : nil)
                    let result = try await readMove(importing)
                    guard result.failed.isEmpty else { throw WireError.refused(result.failed.values.joined(separator: ", ")) }
                    try recordMoveHistory(result.keptHistories ?? [], for: ticket)
                    ticket.cursor = (ticket.cursor ?? 0) + page.parts.reduce(0) { $0 + $1.bytes.count }
                    ticket.page = nil
                }
                if ticket.finalPage == true { try save() }
                else {
                    // Private files accept a replay by prefix hash. Keep the
                    // cursor in memory until the last complete file is synced.
                    try current()
                    incomingMoves[request.id] = ticket
                }
            }
        }
        if !forced && !ticket.accepted {
            if !ticket.requested && ticket.released == nil && !staged.isEmpty {
                var preflight = Bring.Question(panes: [], commit: false, checkpoints: staged)
                preflight.handoff = .prepare
                let prepared = try await readMove(preflight)
                guard prepared.failed.isEmpty else { throw WireError.refused(prepared.failed.values.joined(separator: ", ")) }
                try current()
            }
            if ticket.privatePages != true && (ticket.released == nil || ticket.finalPage == false || ticket.page != nil) {
                if !staged.isEmpty {
                    var base = Bring.Question(panes: try panes(staged), commit: false, checkpoints: staged)
                    base.handoff = .archive(request.id)
                    base.allowLongerPrefix = true
                    let answer = try await readMove(base)
                    guard answer.failed.isEmpty else { throw WireError.refused("Could not keep the local handoff checkpoint.") }
                }
                // An older receipt may have imported part of the tail into
                // native history. Replay from its verified original prefix
                // into private files. A fully received old release grants locally.
                ticket.privatePages = true
                ticket.cursor = nil
                ticket.page = nil
                if ticket.released != nil { ticket.finalPage = false }
                try save()
            }
            try await receive()
        }
        if !ticket.accepted {
            if forced, let previous = ticket.previousHold, !staged.isEmpty {
                var release = Bring.Question(panes: [], commit: false, checkpoints: staged)
                release.handoff = .relinquish(previous)
                let result = try await readMove(release)
                guard result.failed.isEmpty else { throw WireError.refused("Cannot transfer the stopped history reservation.") }
            }
            if forced, !staged.isEmpty {
                var recover = Bring.Question(panes: try panes(staged), commit: false, checkpoints: staged)
                recover.handoff = .recoverPrefix(request.id)
                let answer = try await readMove(recover)
                guard answer.failed.isEmpty else { throw WireError.refused("The partial legacy transfer has no verified checkpoint.") }
                try recordMoveHistory(answer.keptHistories ?? [], for: ticket)

                let observed = try await readMove(.init(panes: try panes(staged), commit: false, compareTranscripts: true, requireStoppedWriter: true))
                let here = Dictionary(uniqueKeysWithValues: observed.lines.compactMap { line in line.proof.map { (line.pane, $0) } })
                guard observed.failed.isEmpty, Set(here.keys) == Set(staged.keys), here.allSatisfy({ pane, proof in
                    proof.valid && proof == staged[pane]
                }) else { throw WireError.refused("This Mac has no complete local conversation to take over.") }
                ticket.localCheckpoint = here
                try save()
            }
            let final = forced ? ticket.localCheckpoint ?? [:] : ticket.released ?? [:]
            if !final.isEmpty {
                var question = Bring.Question(panes: try panes(final), commit: true, compareTranscripts: true, requireStoppedWriter: true, checkpoints: final)
                if !forced, ticket.privatePages == true {
                    question.staging = request.id
                    question.originalCheckpoints = staged
                }
                question.handoff = .grant(takeover: forced ? request.id : nil)
                try current()
                let answer = try await readMove(question)
                guard answer.failed.isEmpty, Set(answer.lines.map(\.pane)) == Set(final.keys),
                      answer.lines.allSatisfy({ $0.folderHere && $0.proof == final[$0.pane] })
                else { throw WireError.refused("The saved conversation could not be verified on this Mac.") }
                try recordMoveHistory(answer.keptHistories ?? [], for: ticket)
            }
            if !forced && !final.isEmpty {
                var accepted = Bring.Question(panes: [], commit: false, checkpoints: final)
                accepted.handoff = .acceptSource(ticket.source)
                let answer = try await readMove(accepted)
                guard answer.failed.isEmpty else { throw WireError.refused(answer.failed.values.joined(separator: ", ")) }
            }
            ticket.accepted = true
            try save()
        }
        if ticket.granted != true {
            // Once accepted, future writes on either Mac never decide this movement again.
            for pane in ticket.panes.values where registered(pane)?.from?.ticket == request.id {
                if registered(pane)?.from?.accepted != true {
                    if let at = locate(pane), at.buried, var burial = graveyard[at.owner] {
                        var tab = burial.tabs[at.tab]
                        if let i = tab.panes.firstIndex(where: { $0.id == pane }) { tab.panes[i].from?.accepted = true }
                        else if let i = tab.dock?.panes.firstIndex(where: { $0.id == pane }) { tab.dock?.panes[i].from?.accepted = true }
                        burial.tabs[at.tab] = tab
                        graveyard[at.owner] = burial
                    } else { _ = editPane(pane) { $0.from?.accepted = true } }
                }
            }
            guard persist(publish: false, durable: true) else { throw WireError.refused("could not save transfer acceptance") }
            for pane in ticket.panes.values where registered(pane)?.from?.ticket == request.id {
                let mark = VigilPaths.agent.appendingPathComponent("panes-minted/" + pane)
                switch Durable.read(mark, limit: 7) {
                case .data(let bytes) where bytes == Data("moving".utf8):
                    try Durable.replace(mark, with: Data("arrival".utf8))
                case .data(let bytes) where bytes.isEmpty || bytes == Data("arrival".utf8):
                    try Durable.syncFolder(mark.deletingLastPathComponent().path)
                default: throw WireError.refused("unreadable reservation for " + pane)
                }
                let queued = Durable.read(ticket.openFile(pane), limit: 0) == .data(Data())
                if (waitingToOpen.remove(pane) != nil || queued), locate(pane)?.buried == false {
                    _ = tend(pane, asked: true, why: forced ? "the person took over here" : "the source released the opened pane")
                }
                if queued { try Durable.remove(ticket.openFile(pane)) }
            }
            ticket.granted = true
            try save()
        }
        if forced && (ticket.released == nil || ticket.finalPage == false || ticket.page != nil) { try await receive() }
        try current()
        if ticket.withdrawals == nil {
            var ack = WorkspaceCommand.Request(session: request.session, revision: request.revision, operation: "ack_move_v2", anchor: "", moved: request.moved)
            ack.takenOver = ticket.takeover
            let reply = try await command(ack)
            moveContact(ticket.source)
            try current()
            guard reply.ok, reply.id == ack.id, reply.code == "acknowledged" else { throw WireError.refused(reply.message) }
            let onward = reply.successors ?? [:]
            guard (forced || onward.isEmpty), onward.allSatisfy({ ticket.panes[$0.key] != nil && $0.value.valid }) else {
                throw WireError.invalid("unexpected onward grant")
            }
            ticket.withdrawals = onward.map { Withdrawal(id: UUID(), old: $0.key, next: $0.value) }
            try save()
        }
        for leg in ticket.withdrawals ?? [] {
            if Durable.read(IncomingMove.completion(leg.id), limit: 0) == .data(Data()) { continue }
            if incomingMoves[leg.id] == nil {
                guard let destination = ticket.panes[leg.old], let home = request.moved else { throw WireError.invalid("missing withdrawal destination") }
                let next = leg.next
                var move = WorkspaceCommand.Request.Moved(panes: [next.pane], mac: home.mac)
                move.arrival = home.arrival
                move.device = home.device
                move.arrivals = [next.pane: destination]
                move.ticket = leg.id
                move.priorGrant = next.ticket
                var order = WorkspaceCommand.Request(id: leg.id, session: next.workspace, revision: request.revision, operation: "release_move_v2", anchor: "", moved: move)
                order.takenOver = true
                var downstream = IncomingMove(source: next.device, request: order, panes: [next.pane: destination], folders: [:])
                downstream.parent = request.id
                downstream.seedArchive = ticket.seedArchive ?? request.id
                if let base = ticket.localCheckpoint?[leg.old] { downstream.localCheckpoint = [next.pane: base] }
                downstream.requested = true
                downstream.takeover = true
                downstream.accepted = true
                downstream.granted = true
                try downstream.save()
                incomingMoves[leg.id] = downstream
            }
            resumeMoves(from: leg.next.device)
            throw WireError.refused("Waiting for the onward copy to retire.")
        }
        if forced, ticket.parent == nil, let claim = ticket.localCheckpoint, !claim.isEmpty {
            var release = Bring.Question(panes: [], commit: false, checkpoints: claim)
            release.handoff = .finishedWithdrawal(request.id, source: ticket.source)
            let answer = try await readMove(release)
            guard answer.failed.isEmpty else { throw WireError.refused("Could not release the completed takeover reservation.") }
        }
        try current()
        if ticket.parent != nil { try Durable.replace(IncomingMove.completion(request.id), with: Data()) }
        for pane in ticket.panes.values { try Durable.remove(ticket.openFile(pane)) }
        try Durable.remove(ticket.file)
        incomingMoves[request.id] = nil
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        moveDelay[request.id] = nil
        moveWaiting[request.id] = nil
        activeMoves.remove(request.id)
        moveEpoch[request.id] = nil
        for leg in ticket.withdrawals ?? [] { try Durable.remove(IncomingMove.completion(leg.id)) }
        if let parent = ticket.parent, let home = incomingMoves[parent]?.source {
            Task { @MainActor in resumeMoves(from: home) }
        }
    }

    private func recordMoveHistory(_ paths: [String], for ticket: IncomingMove) throws {
        guard !paths.isEmpty else { return }
        let id = ticket.request.id
        var all = try Durable.decode([UUID: SavedMoveHistory].self, savedMoveHistoriesFile).get() ?? [:]
        let kept = Set((all[id]?.files ?? []) + paths).sorted()
        all[id] = .init(id: id, workspace: ticket.request.session, files: kept)
        try Durable.replace(savedMoveHistoriesFile, with: JSONEncoder().encode(all))
        savedMoveHistories = all
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    func inspectMoveHistory(_ history: SavedMoveHistory) {
        let urls = history.files.map { URL(fileURLWithPath: $0) }
        guard urls.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
            reportIncompleteMove(history.workspace, "A preserved history cannot be opened. Its recorded location remains in the sidebar.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        do {
            var all = try Durable.decode([UUID: SavedMoveHistory].self, savedMoveHistoriesFile).get() ?? [:]
            guard all[history.id]?.files == history.files else { return }
            all[history.id] = nil
            try Durable.replace(savedMoveHistoriesFile, with: JSONEncoder().encode(all))
            savedMoveHistories = all
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        } catch { reportIncompleteMove(history.workspace, String(describing: error)) }
    }

    var pendingMoveWarnings: [String] {
        incomingMoves.values.compactMap { ticket in
            guard ticket.superseded != true else { return nil }
            if ticket.takeover != true {
                guard let reason = ticket.refusal ?? moveWaiting[ticket.request.id] else { return nil }
                return "\(ticket.request.session): \(reason)"
            }
            let source = VigilRemote.shared.host(ticket.source)?.name ?? ticket.source
            let state = ticket.refusal ?? moveWaiting[ticket.request.id] ?? "Waiting for its final history."
            return "\(ticket.request.session): a second writer may exist on \(source). \(state)"
        }.sorted()
    }

    func queueMoveOpen(_ pane: String) {
        waitingToOpen.insert(pane)
        guard let id = registered(pane)?.from?.ticket else { return }
        let path = IncomingMove.folder.appendingPathComponent(id.uuidString + "." + pane + ".open")
        guard Durable.read(path, limit: 0) != .data(Data()) else { return }
        do { try Durable.folder(IncomingMove.folder); try Durable.replace(path, with: Data()) }
        catch { lifecycleLog.error("could not save queued open", ["pane": pane, "err": error]) }
    }

    func takeOverHere(_ pane: String, since: Date) async {
        guard let source = registered(pane)?.from?.device, await stillOffline(source, since: since) else {
            reportIncompleteMove(pane, "This Mac could not confirm that the source is still out of reach. The saved pane remains here.")
            showMoveNote(pane)
            return
        }
        guard let id = registered(pane)?.from?.ticket, var ticket = incomingMoves[id],
              canTakeOver(ticket), matchesArrival(ticket), locate(pane)?.buried == false else {
            reportIncompleteMove(pane, "The move changed while its confirmation was open. Check its current state.")
            showMoveNote(pane)
            return
        }
        do {
            queueMoveOpen(pane)
            ticket.takeover = true
            // The normal cursor addresses a different file series. A forced
            // recovery begins a new comparison against the chosen local tip.
            ticket.released = nil
            ticket.page = nil
            ticket.cursor = nil
            ticket.finalPage = nil
            ticket.localCheckpoint = nil
            try ticket.save()
            incomingMoves[id] = ticket
            moveEpoch[id] = UUID()
            activeMoves.remove(id)
            resumeMoves(from: ticket.source)
        } catch { reportIncompleteMove(ticket.request.session, String(describing: error)) }
    }

    func recoverStoppedMove(_ name: String, since: Date) async throws {
        guard let device = graveyard[name]?.moveCheckpoint?.device, await stillOffline(device, since: since) else {
            throw WireError.refused("The destination is no longer confirmed offline.")
        }
        guard let burial = graveyard[name], let sent = burial.moveCheckpoint, let original = sent.ticket,
              let device = sent.device, let remoteName = sent.arrival, let arrivals = sent.arrivals,
              Set(arrivals.keys) == ownedPaneIds(burial), !conflictingOwnership(ownedPaneIds(burial)),
              canTakeBack(burial),
              acceptingMove.insert(original).inserted else { throw WireError.refused("The source transfer is busy or its panes have not stopped.") }
        defer { acceptingMove.remove(original) }
        let id = UUID()
        let local = newWorkspaceId()
        let me = try await moveDevice()
        let source = Registry.Workspace(name: name, label: burial.label, emoji: burial.emoji, cwd: burial.cwd, tabs: burial.tabs,
                                        order: burial.order, pinned: burial.pinned, sidebar: burial.sidebar, buriedUntil: nil, foreground: false, paneSeq: nil, layoutRevision: nil)
        let owned = (Array(workspaces.values) + Array(graveyard.values)).reduce(into: Set<String>()) { $0.formUnion(ownedPaneIds($1)) }
        var floor = 0
        let staged = try source.brought(as: local, from: device, mac: sent.mac, at: Date().timeIntervalSince1970,
                                        home: nil, here: NSHomeDirectory(), order: burial.order, ticket: id) {
            let i = try PaneLife.reserve(workspace: local, startingAt: floor, owned: owned, panes: VigilPaths.panes, agent: VigilPaths.agent, arrival: true, transferring: true)
            floor = i + 1
            return i
        }
        var tabs = staged.tabs ?? []
        var mapping: [String: String] = [:], folders: [String: String] = [:]
        var questions: [Bring.Pane] = []
        func restore(_ pane: inout Registry.Pane) throws {
            guard let old = pane.from?.pane, let remote = arrivals[old] else { throw WireError.refused("incomplete return identity") }
            pane.from?.workspace = remoteName
            pane.from?.pane = remote
            mapping[remote] = pane.id
            folders[pane.id] = pane.cwd
            let history = sent.histories?[old] ?? sent.transcripts?[old].map { .init($0.agent, $0.start) }
            if let history {
                questions.append(.init(pane: remote, arriving: pane.id, agent: history.agent, conversation: history.start, cwd: pane.cwd, name: nil))
            }
            if let end = sent.ends?[old] ?? burial.tabs.flatMap(\.members).first(where: { $0.id == old })?.from?.ended {
                pane.from?.ended = end
                try Durable.replace(VigilPaths.panes.appendingPathComponent(pane.id + ".ended"), with: JSONEncoder().encode(end))
            }
        }
        for t in tabs.indices {
            for i in tabs[t].panes.indices { try restore(&tabs[t].panes[i]) }
            if var dock = tabs[t].dock {
                for i in dock.panes.indices { try restore(&dock.panes[i]) }
                tabs[t].dock = dock
            }
        }
        let answer = try await readMove(.init(panes: questions, commit: true, compareTranscripts: true, requireStoppedWriter: true))
        let proofs = Dictionary(uniqueKeysWithValues: answer.lines.compactMap { line in line.proof.map { (line.pane, $0) } })
        guard answer.failed.isEmpty, Set(proofs.keys) == Set(questions.map(\.pane)), graveyard[name]?.moveCheckpoint == sent, moveOffline[device] == since
        else { throw WireError.refused("Could not recover the stopped conversations.") }
        var move = WorkspaceCommand.Request.Moved(panes: mapping.keys.sorted(), mac: Host.current().localizedName ?? "another Mac", transcripts: proofs)
        move.device = me
        move.arrival = local
        move.arrivals = mapping
        move.returnOf = original
        move.ticket = id
        let request = WorkspaceCommand.Request(id: id, session: remoteName, revision: String(repeating: "0", count: 64), operation: "release_move_v2", anchor: "", moved: move)
        // The original ids must still lead to their first grant if a third
        // Mac reports an offline decision after this return.
        _ = try successors(of: sent, recording: true)
        var ticket = IncomingMove(source: device, request: request, panes: mapping, folders: folders)
        ticket.takeover = true
        if sent.forcedWithdrawal == true { ticket.previousHold = original }
        try ticket.save()
        var workspace = Workspace(name: local, label: staged.label, emoji: staged.emoji, cwd: staged.cwd, tabs: tabs, order: burial.order)
        workspace.pinned = burial.pinned
        workspace.paneSeq = staged.paneSeq ?? 0
        workspace.layoutShape = VigilSessionControl.revision(tabs)
        if let first = tabs.first?.panes.first { try Durable.replace(ticket.openFile(first.id), with: Data()) }
        guard admit(workspace, "reclaimed move") else { throw WireError.refused("The recovery workspace could not be admitted.") }
        let deadline = graveyardDeadlines[name]
        graveyard[name] = nil
        graveyardDeadlines[name] = nil
        guard persist(durable: true) else {
            if !registryInstallUncertain {
                workspaces[local] = nil
                graveyard[name] = burial
                graveyardDeadlines[name] = deadline
            } else { incomingMoves[id] = ticket }
            throw WireError.refused("Recovery could not be committed. Check the registry before retrying.")
        }
        incomingMoves[id] = ticket
        resumeMoves(from: device)
    }

    func stopForHandoff(_ name: String, repairInvalid: Bool = false) {
        guard !recoveredMoveBurials.contains(name), let session = graveyard[name],
              let ticket = session.moveCheckpoint?.ticket, let requested = session.moveCheckpoint?.panes,
              Set(requested) == ownedPaneIds(session), session.closing != nil,
              !conflictingOwnership(Set(requested)), stoppingMoves.insert(name).inserted else { return }
        let ids = Set(requested)
        if ids.allSatisfy({ memberMark($0) == .clean }) { stoppingMoves.remove(name); return }
        if persist(publish: false, durable: true) {
            destroyBuriedViews(session, ids: ids)
            if fence(ids, repairInvalid: repairInvalid).isEmpty { deliverClose(ids) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fenceRetry) { [weak self] in
            guard let self else { return }
            self.stoppingMoves.remove(name)
            if self.graveyard[name]?.moveCheckpoint?.ticket == ticket { self.stopForHandoff(name) }
        }
    }

    /// Bytes may leave the Mac only for the conversation its own pane named.
    /// A digest received from a peer cannot authorize an arbitrary local file.
    func historyAtHome(_ pane: String) throws -> WorkspaceCommand.Request.Moved.History? {
        if let glance = try Durable.decode(PaneGlance.self, VigilPaths.root.appendingPathComponent("state/" + pane + ".glance")).get(),
           let id = glance.conversation { return .init(glance.agent, id) }
        if let arrival = registered(pane)?.from {
            if let from = arrival.continuation, let id = from.conversation { return .init(from.agent, id) }
            if let ticket = arrival.ticket, let proof = incomingMoves[ticket]?.request.moved?.transcripts?[arrival.pane] {
                return .init(proof.agent, proof.start)
            }
        }
        let folder = VigilPaths.root.appendingPathComponent("conversations")
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        let records = try files.filter { $0.lastPathComponent.hasSuffix("--" + pane + ".json") }.map { file in
            (file, try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
        }
        guard let file = records.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        struct Owner: Decodable { let pane: String; let agent: String; let conversation: String }
        guard let row = try Durable.decode(Owner.self, file).get(), row.pane == pane,
              TranscriptOffer.agents.contains(row.agent), Open.validPane(row.conversation) else { throw WireError.refused("Unreadable local conversation identity.") }
        return .init(row.agent, row.conversation)
    }

    /// Offline, people can retab or close panes independently on the two Macs.
    /// A takeover withdraws exactly its immutable IDs, wherever they now live.
    /// Preserve the other members in their own registry entries in the same save.
    private func withdrawTakenOver(_ request: VigilSessionControl.Request, move: WorkspaceCommand.Request.Moved, histories: [String: WorkspaceCommand.Request.Moved.History]) throws {
        let ids = Set(move.panes)
        guard !conflictingOwnership(ids), registryRead != .unreadable, registryRead != .recovered else {
            throw WireError.refused("Resolve registry ownership before withdrawing panes.")
        }
        let owners = Set(ids.compactMap { locate($0)?.owner })
        var saved = move
        saved.histories = histories
        saved.forcedWithdrawal = true
        var withdrawn: [Registry.Tab] = []
        var ends: [String: PaneEnd] = [:]
        for pane in ids {
            if locate(pane) == nil {
                guard memberMark(pane) == .clean && !Self.daemonAlive(pane) else { throw WireError.refused("Cannot establish ownership of " + pane) }
                guard Durable.read(Self.closedHereFile(pane), limit: 0) == .data(Data()) else {
                    throw WireError.refused("This Mac has a closed pane without a destination receipt. An older Vigil may have moved it onward. Check the other Macs for " + pane + ".")
                }
                // Its close was committed here without an onward transfer.
                withdrawn.append(.init(panes: [.init(id: pane, cwd: NSHomeDirectory())], layout: nil))
            }
            switch Durable.read(VigilPaths.panes.appendingPathComponent(pane + ".ended"), limit: 65536) {
            case .absent: break
            case .data(let bytes): ends[pane] = try JSONDecoder().decode(PaneEnd.self, from: bytes)
            case .unreadable(let why): throw WireError.refused(why)
            }
        }
        saved.ends = ends.isEmpty ? nil : ends
        for owner in owners.sorted() {
            guard let entry = workspaces[owner] ?? graveyard[owner],
                  entry.moveCheckpoint?.ticket == nil else { throw WireError.refused("A competing handoff owns these panes.") }
            withdrawn += entry.tabs.compactMap { Self.select($0, keeping: ids) }
        }
        // The other Mac chose its own checkpoint. Save what these panes were
        // called and where they actually sat here, including edits made offline.
        var folder = VigilPaths.root
        for component in ["transcripts", "copies", "handoff", request.id.uuidString] {
            folder.appendPathComponent(component)
            try Durable.folder(folder)
        }
        let record = folder.appendingPathComponent("workspaces.json")
        let entries = owners.sorted().compactMap { owner -> Registry.Workspace? in
            guard let w = workspaces[owner] ?? graveyard[owner] else { return nil }
            return .init(name: w.name, label: w.label, emoji: w.emoji, cwd: w.cwd, tabs: w.tabs, order: w.order, pinned: w.pinned,
                         sidebar: w.sidebar, buriedUntil: graveyardDeadlines[owner], foreground: nil, paneSeq: w.paneSeq, layoutRevision: w.layoutRevision)
        }
        try Durable.create(record, with: JSONEncoder().encode(entries))
        let was = workspaces, buried = graveyard, deadlines = graveyardDeadlines
        let initial = was[request.session] ?? buried[request.session] ?? owners.sorted().compactMap { was[$0] ?? buried[$0] }.first
        let keepsName = initial?.name == request.session && initial.map(ownedPaneIds) == ids
        let name = keepsName ? request.session : newWorkspaceId()
        var entry = Workspace(name: name, label: initial?.label ?? request.session, emoji: initial?.emoji,
                              cwd: initial?.cwd ?? NSHomeDirectory(), tabs: withdrawn, order: initial?.order ?? 0)
        entry.pinned = initial?.pinned ?? false
        entry.moveCheckpoint = saved
        entry.movedTo = move.mac
        entry.closing = ids.sorted()
        for owner in owners {
            var original = (was[owner] ?? buried[owner])!
            let kept = ownedPaneIds(original).subtracting(ids)
            original.tabs = original.tabs.compactMap { Self.select($0, keeping: kept) }
            if was[owner] != nil { workspaces[owner] = kept.isEmpty ? nil : original }
            else {
                graveyard[owner] = kept.isEmpty ? nil : original
                if kept.isEmpty { graveyardDeadlines[owner] = nil }
            }
        }
        graveyard[name] = entry
        graveyardDeadlines[name] = .distantPast
        guard persist(durable: true) else {
            if !registryInstallUncertain { workspaces = was; graveyard = buried; graveyardDeadlines = deadlines }
            throw WireError.refused("Could not save withdrawal before stopping the source.")
        }
        for owner in owners where was[owner] != nil {
            if workspaces[owner] == nil {
                for controller in members(of: owner) { memberships.removeObject(forKey: controller); handOn(controller, from: owner) }
            }
            reconcileViews(of: owner)
        }
    }

    func handoffCommand(_ request: VigilSessionControl.Request) async -> VigilSessionControl.Reply {
        guard let move = request.moved, let ticket = move.ticket, move.final == nil else {
            return .failure(request, "invalid_request", "A handoff requires a ticket.")
        }
        if let caller = move.device { moveContact(caller) }
        guard acceptingMove.insert(ticket).inserted else { return .failure(request, "busy", "This handoff is in progress.") }
        defer { acceptingMove.remove(ticket) }
        func record() -> Workspace? {
            graveyard.values.first { $0.moveCheckpoint?.ticket == ticket }
        }
        func same(_ session: Workspace) -> Bool {
            var saved = session.moveCheckpoint
            saved?.final = nil
            saved?.ends = nil
            saved?.histories = nil
            saved?.forcedWithdrawal = nil
            if saved?.arrivals == nil { saved?.arrivals = move.arrivals }
            return saved == move && ownedPaneIds(session) == Set(move.panes)
        }
        if let reverse = incomingMoves.values.first(where: {
            $0.request.moved?.returnOf == ticket && $0.superseded != true &&
                ($0.granted == true || $0.panes.values.contains { locate($0) != nil })
        }) {
            resumeMoves(from: reverse.source)
            return .failure(request, "reclaiming", "The person recovered this pane here. Its return is pending; preserve both histories until it completes.")
        }
        if request.operation == "ack_move_v2" {
            let onward: [String: MoveSuccessor]
            if let record = record() {
                guard same(record), record.moveCheckpoint?.final != nil,
                      !conflictingOwnership(ownedPaneIds(record)), ownedPaneIds(record).allSatisfy({ memberMark($0) == .clean }) else {
                    return .failure(request, "waiting", "The source has not released this transfer.")
                }
                var releases: [UUID: [String: Bring.TranscriptProof]] = [:]
                for pane in record.tabs.flatMap(\.members) {
                    if let proof = record.moveCheckpoint?.final?[pane.id] {
                        if request.takenOver == true { releases[ticket, default: [:]][pane.id] = proof }
                    }
                }
                for (owner, proofs) in releases {
                    var release = Bring.Question(panes: [], commit: false, checkpoints: proofs)
                    release.handoff = .relinquish(owner)
                    guard let answer = try? await readMove(release), answer.failed.isEmpty else {
                        return .failure(request, "waiting", "The source transcript reservation could not be released.")
                    }
                }
                if let destination = move.device, let proofs = record.moveCheckpoint?.final, !proofs.isEmpty {
                    var nextOwner = Bring.Question(panes: [], commit: false, checkpoints: proofs)
                    nextOwner.handoff = .acceptSource(destination)
                    guard let result = try? await readMove(nextOwner), result.failed.isEmpty else {
                        return .failure(request, "waiting", "Could not acknowledge the new conversation owner.")
                    }
                }
                do { onward = try successors(of: move, recording: true) }
                catch { return .failure(request, "waiting", String(describing: error)) }
                dropBurial(record.name)
            } else {
                do { onward = try successors(of: move, recording: false) }
                catch { return .failure(request, "waiting", String(describing: error)) }
            }
            guard persist(publish: false, durable: true) else { return .failure(request, "waiting", "Could not save acknowledgement.") }
            if let original = move.returnOf, let previous = incomingMoves[original], previous.superseded == true {
                do {
                    if let proofs = previous.localCheckpoint ?? previous.request.moved?.transcripts, !proofs.isEmpty {
                        var release = Bring.Question(panes: [], commit: false, checkpoints: proofs)
                        release.handoff = .finishedWithdrawal(original, source: previous.source)
                        let answer = try await readMove(release)
                        guard answer.failed.isEmpty else { throw WireError.refused(answer.failed.values.joined(separator: "\n")) }
                    }
                    try Durable.remove(previous.file)
                    incomingMoves[original] = nil
                }
                catch { return .failure(request, "waiting", "The superseded transfer receipt could not be removed.") }
            }
            return .init(id: request.id, ok: true, code: "acknowledged", message: "Transfer acknowledged.", successors: onward.isEmpty ? nil : onward)
        }
        if record() == nil {
            guard request.id == ticket, request.takenOver == true || workspaces[request.session].map({ Set(move.panes).isSubset(of: ownedPaneIds($0)) }) == true else {
                return .failure(request, "source_changed", "This workspace no longer owns the requested panes.")
            }
            if let prior = move.priorGrant, !move.panes.allSatisfy({ pane in
                registered(pane)?.from?.ticket == prior || (locate(pane) == nil && memberMark(pane) == .clean)
            }) { return .failure(request, "source_changed", "The onward pane does not belong to the stated grant.") }
            if let original = move.returnOf {
                guard request.takenOver == true, move.panes.allSatisfy({ pane in
                    if let prior = incomingMoves[original], prior.granted == true,
                       prior.panes.values.contains(pane), prior.source == move.device { return true }
                    guard let from = registered(pane)?.from else { return memberMark(pane) == .clean }
                    return from.ticket == original && from.device == move.device
                }) else { return .failure(request, "source_changed", "These panes do not belong to the transfer being reclaimed.") }
                if var superseded = incomingMoves[original] {
                    superseded.superseded = true
                    superseded.refusal = "Its source reclaimed this move."
                    do { try superseded.save(); incomingMoves[original] = superseded }
                    catch { return .failure(request, "waiting", "Cannot save the return decision.") }
                }
            }
            var histories: [String: WorkspaceCommand.Request.Moved.History] = [:]
            do {
                var forwarded = Set<String>()
                for pane in move.panes {
                    if request.takenOver == true, locate(pane) == nil, memberMark(pane) == .clean,
                       let onward = try Durable.decode(MoveSuccessor.self, Self.successorsFolder.appendingPathComponent(pane)).get() {
                        guard onward.valid, !Self.daemonAlive(pane) else { throw WireError.refused("Invalid onward grant for " + pane) }
                        forwarded.insert(pane)
                    } else { histories[pane] = try historyAtHome(pane) }
                }
                // Already transferred in full. The onward owner now holds the
                // stopped history and any later work. A native transcript on
                // this Mac may since belong to an unrelated writer.
                if forwarded.count == move.panes.count {
                    return .init(id: request.id, ok: true, code: "released", message: "This Mac recorded an onward grant. Its recipient may still be running.", released: [:])
                }
            }
            catch { return .failure(request, "waiting", "The source could not read its conversation identities.") }
            if request.takenOver == true {
                do { try withdrawTakenOver(request, move: move, histories: histories) }
                catch { return .failure(request, "waiting", String(describing: error)) }
            } else {
                let proofs = move.transcripts ?? [:]
                var checked: [String: [String: String]] = [:]
                guard proofs.allSatisfy({ pane, proof in histories[pane] == .init(proof.agent, proof.start) }) else {
                    return .failure(request, "source_changed", "A checkpoint names a conversation the source pane no longer holds.")
                }
                if !proofs.isEmpty {
                    let panes = proofs.map { Bring.Pane(pane: $0.key, agent: $0.value.agent, conversation: $0.value.start, cwd: NSHomeDirectory(), name: nil) }
                    guard let answer = try? await readMove(.init(panes: panes, commit: false, compareTranscripts: true, checkpoints: proofs)),
                          answer.failed.isEmpty, Set(answer.lines.map(\.pane)) == Set(proofs.keys) else {
                        return .failure(request, "checkpoint_unavailable", "The source could not read the staged conversation checkpoint.")
                    }
                    for line in answer.lines {
                        guard let proof = line.proof, let original = proofs[line.pane], let files = line.checkedFiles else {
                            return .failure(request, "checkpoint_unavailable", "The source could not verify the staged conversation prefix.")
                        }
                        guard proof.files == original.files, proof.digest == original.digest, proof.start == original.start else {
                            return .failure(request, "source_changed", "The source history differs from the staged checkpoint. The source stays open.")
                        }
                        checked[line.pane] = files
                    }
                }
                if move.panes.contains(where: { if case .unreadable = memberMark($0) { return true }; return false }) {
                    return .failure(request, "waiting", "A source close mark could not be read.")
                }
                guard workspaces[request.session] != nil,
                      move.panes.allSatisfy({ memberMark($0) == .none && (move.returnOf != nil || !waitingForMove($0)) }) else {
                    return .failure(request, "source_changed", "A source pane is already closing or awaiting its own transfer.")
                }
                if let expected = move.sourceWork, expected.values.contains(where: Bring.recordedBefore) {
                    return .failure(request, "source_changed", "This move was asked by an earlier vigil, whose record of the source checkout this one cannot check. Review a fresh move sheet. Its panes remain here.")
                }
                if let expected = move.sourceWork, !expected.isEmpty {
                    let members = workspaces[request.session]?.tabs.flatMap(\.members) ?? []
                    let panes = members.filter { expected[$0.id] != nil }.map {
                        Bring.Pane(pane: $0.id, agent: nil, conversation: nil, cwd: $0.cwd, name: nil)
                    }
                    var q = Bring.Question(panes: panes, commit: false)
                    q.readWork = true
                    do {
                        let answer = try await readMove(q)
                        // Compared at the strength each was recorded at: a
                        // destination that held a trimmed `.work` recorded
                        // only what it said.
                        let fresh = Dictionary(answer.lines.compactMap { line in line.work.map { (line.pane, $0) } },
                                               uniquingKeysWith: { first, _ in first })
                        let same = try Set(fresh.keys) == Set(expected.keys) && expected.allSatisfy { pane, recorded in
                            try fresh[pane].map { try Bring.sourceWorkMatches(recorded: recorded, fresh: $0) } ?? false
                        }
                        guard same else {
                            return .failure(request, "source_changed", "The source checkout changed. Review a fresh move sheet. Its panes remain here.")
                        }
                    } catch { return .failure(request, "waiting", "The source checkout could not be checked.") }
                }
                let began = moved(request, checked: checked)
                guard began.ok else { return began }
            }
        }
        if let session = record(), same(session), move.panes.allSatisfy({ memberMark($0) == .clean }) {
            recoveredMoveBurials.remove(session.name)
        }
        guard let session = record(), same(session), !recoveredMoveBurials.contains(session.name),
              !conflictingOwnership(ownedPaneIds(session)) else { return .failure(request, "waiting", "No matching committed source transfer.") }
        if request.takenOver == true && session.moveCheckpoint?.forcedWithdrawal != true {
            graveyard[session.name]?.moveCheckpoint?.forcedWithdrawal = true
            guard persist(publish: false, durable: true) else {
                graveyard[session.name]?.moveCheckpoint?.forcedWithdrawal = nil
                return .failure(request, "waiting", "Could not save the takeover decision.")
            }
        } else if session.moveCheckpoint?.forcedWithdrawal == true && request.takenOver != true {
            return .failure(request, "source_changed", "This move is completing an explicit takeover.")
        }
        stopForHandoff(session.name)
        guard move.panes.allSatisfy({ memberMark($0) == .clean && !Self.daemonAlive($0) }) else {
            return .failure(request, "waiting", "Waiting for the source processes to stop.")
        }
        if session.moveCheckpoint?.final == nil {
            let histories = session.moveCheckpoint?.histories ?? (move.transcripts ?? [:]).mapValues { .init($0.agent, $0.start) }
            var final: [String: Bring.TranscriptProof] = [:]
            if !histories.isEmpty {
                let panes = histories.map { Bring.Pane(pane: $0.key, agent: $0.value.agent, conversation: $0.value.start, cwd: NSHomeDirectory(), name: nil) }
                guard let result = try? await readMove(.init(panes: panes, commit: false, compareTranscripts: true, requireStoppedWriter: true)), result.failed.isEmpty else { return .failure(request, "waiting", "The source transcript could not be read.") }
                for line in result.lines {
                    guard let proof = line.proof, let original = histories[line.pane], proof.agent == original.agent,
                          proof.start == original.start, proof.files?.isEmpty == false else {
                        return .failure(request, "waiting", "The final conversation is unavailable.")
                    }
                    final[line.pane] = proof
                }
            }
            if !final.isEmpty {
                let inputs = final.map { Bring.Pane(pane: $0.key, agent: $0.value.agent, conversation: $0.value.start, cwd: NSHomeDirectory(), name: nil) }
                var archive = Bring.Question(panes: inputs, commit: false, checkpoints: final)
                archive.handoff = .archive(ticket)
                guard let answer = try? await readMove(archive), answer.failed.isEmpty else {
                    return .failure(request, "waiting", "The stopped history has not been archived. Its final receipt is still pending.")
                }
            }
            guard Set(final.keys) == Set(histories.keys), let now = record(), same(now) else { return .failure(request, "waiting", "The source transfer changed.") }
            graveyard[session.name]?.moveCheckpoint?.final = final
            guard persist(publish: false, durable: true) else {
                graveyard[session.name]?.moveCheckpoint?.final = nil
                return .failure(request, "waiting", "Could not save the final handoff receipt.")
            }
        }
        guard let final = graveyard[session.name]?.moveCheckpoint?.final else { return .failure(request, "waiting", "Final record missing.") }
        // A stopped pane can have an earlier fork outstanding against
        // another Mac. Scope that reservation to the old source before
        // granting this conversation to its next owner.
        for prior in incomingMoves.values.filter({ $0.takeover == true && $0.granted == true }) {
            let forwarded = prior.panes.filter { move.panes.contains($0.value) }
            let claims = (prior.localCheckpoint ?? [:]).filter { forwarded[$0.key] != nil }
            if claims.isEmpty { continue }
            var release = Bring.Question(panes: [], commit: false, checkpoints: claims)
            release.handoff = .forwardClaim(prior.request.id, source: prior.source)
            guard let result = try? await readMove(release), result.failed.isEmpty else {
                return .failure(request, "waiting", "Could not transfer the previous fork reservation.")
            }
        }
        var reply = VigilSessionControl.Reply(id: request.id, ok: true, code: "released", message: "The source is stopped.", released: final)
        if !final.isEmpty {
            let panes = final.map { Bring.Pane(pane: $0.key, agent: $0.value.agent, conversation: $0.value.start, cwd: NSHomeDirectory(), name: nil) }
            var q = Bring.Question(panes: panes, commit: false, checkpoints: final)
            do {
                if request.takenOver == true && (request.offset ?? 0) == 0 {
                    q.handoff = .holdOrigin(ticket)
                    let result = try await readMove(q)
                    guard result.failed.isEmpty else { throw WireError.refused("Could not reserve the stopped history.") }
                }
                var from = move.transcripts ?? [:]
                if final == (request.takenOver == true ? request.conflictBase : move.transcripts) { return reply }
                if (request.offset ?? 0) == 0 {
                    q.handoff = .archive(ticket)
                    let kept = try await readMove(q)
                    guard kept.failed.isEmpty else { throw WireError.refused(kept.failed.values.joined(separator: ", ")) }
                }
                if request.takenOver == true { from = request.conflictBase ?? [:] }
                q.handoff = .page(from: from, offset: request.offset ?? 0, archive: ticket)
                let answer = try await readMove(q)
                guard answer.failed.isEmpty, let page = answer.page else { throw WireError.refused("Missing stopped transcript bytes.") }
                reply.page = page
                if page.more { return .init(id: request.id, ok: true, code: "transferring", message: "Transferring saved history.", released: final, page: page) }
            } catch { return .failure(request, "waiting", String(describing: error)) }
        }
        return reply
    }

    static func moveRevision(_ pane: String) -> String? {
        let root = VigilPaths.panes.deletingLastPathComponent()
        var revision = ""
        for (folder, ext) in [("panes","up"), ("panes","ended"), ("panes","resume"), ("state","conflict")] {
            var info = stat()
            let file = root.appendingPathComponent(folder).appendingPathComponent(pane + "." + ext)
            if stat(file.path, &info) == 0 {
                let time = info.st_mtimespec
                revision += "\(info.st_ino)-\(time.tv_sec * 1_000_000_000 + time.tv_nsec)/"
            } else if errno == ENOENT {
                revision += "-/"
            } else { return nil }
        }
        let glance: PaneGlance?
        switch Durable.read(root.appendingPathComponent("state/" + pane + ".glance"), limit: 512 * 1024) {
        case .absent: glance = nil
        case .unreadable: return nil
        case .data(let bytes):
            guard let read = try? JSONDecoder().decode(PaneGlance.self, from: bytes) else { return nil }
            glance = read
        }
        return Registry.Workspace.moveIdentity(revision, glance: glance)
    }

    /// Verify a burial created by an earlier app which let its destination run during grace.
    nonisolated static func compareMoveTranscripts(_ proofs: [String: Bring.TranscriptProof], destination: String) async -> [String: [String: String]]? {
        await Task.detached(priority: .utility) {
            let panes = proofs.map { pane, proof in
                Bring.Pane(pane: pane, agent: proof.agent, conversation: proof.start, cwd: NSHomeDirectory(), name: nil)
            }
            guard let answer = try? Local.Client(socket: VigilPaths.hub).bring(.init(panes: panes, commit: false, compareTranscripts: true)),
                  answer.failed.isEmpty else { return nil }
            var result: [String: [String: String]] = [:]
            for line in answer.lines {
                guard let original = proofs[line.pane], let current = line.proof,
                      current.agent == original.agent, current.start == original.start,
                      let files = line.checkedFiles, !files.isEmpty else { return nil }
                guard current.confirms(original, read: { ask in
                    let hub = Local.Client(socket: VigilPaths.hub)
                    guard let bytes = try? hub.call(device: destination, .transcript(ask)) else { return nil }
                    return try? JSONDecoder().decode(TranscriptAnswer.self, from: bytes)
                }) else { return nil }
                result[line.pane] = files
            }
            return Set(result.keys) == Set(proofs.keys) ? result : nil
        }.value
    }

    func moved(_ request: VigilSessionControl.Request, checked: [String: [String: String]] = [:]) -> VigilSessionControl.Reply {
        typealias Reply = VigilSessionControl.Reply
        guard let moved = request.moved else { return .failure(request, "invalid_request", "A move names the panes that left.") }
        func done(_ message: String) -> Reply {
            Reply(id: request.id, ok: true, code: "committed", message: message, revision: workspaces[request.session]?.layoutRevision, session: request.session)
        }
        guard let session = workspaces[request.session] else { return done("Nothing of it is open here.") }
        guard Set(checked.keys) == Set((moved.transcripts ?? [:]).keys) else {
            return .failure(request, "source_changed", "The source transcript changed during its comparison. Both copies were kept.")
        }
        var revisions: [String: String] = [:]
        for pane in moved.panes {
            guard let revision = Self.moveRevision(pane) else {
                return .failure(request, "source_unknown", "A pane could not be checked. The workspace is still here.")
            }
            if revision.split(separator: "/")[2] != "-", checked[pane] == nil {
                return .failure(request, "source_unknown", "The destination did not confirm the source conversation. Both copies were kept.")
            }
            revisions[pane] = revision
        }
        guard let digest = try? Registry.Workspace.moveDigest(label: session.label, emoji: session.emoji, cwd: session.cwd, pinned: session.pinned,
                                                              revision: session.layoutRevision, tabs: session.tabs, facts: revisions),
              digest == request.revision else {
            return .failure(request, "source_changed", "The source changed after the destination saw it. Both copies were kept.")
        }
        let leaving = Set(moved.panes).intersection(session.tabs.flatMap(\.paneIds))
        if moved.ticket != nil {
            guard leaving == Set(moved.panes), !conflictingOwnership(leaving),
                  leaving == ownedPaneIds(session) || session.tabs.contains(where: { Set($0.paneIds) == leaving }) || leaving.count == 1 else {
                return .failure(request, "source_changed", "The requested panes no longer form one transferable workspace, tab or pane.")
            }
            if leaving.count == 1, let id = leaving.first, let tab = session.tabs.first(where: { $0.panes.map(\.id) == [id] }),
               !Set(tab.paneIds).isSubset(of: leaving) {
                return .failure(request, "source_changed", "Move this tab with its dock, or move the dock panes out first.")
            }
        }
        guard !leaving.isEmpty else { return done("None of those panes is open here.") }
        defer { movingTo = nil; movingRevisions = nil; movingTranscripts = nil; movingCheckpoint = nil }
        movingTo = moved.mac
        movingRevisions = revisions
        movingTranscripts = checked
        movingCheckpoint = moved
        if moved.ticket != nil {
            var ends: [String: PaneEnd] = [:]
            for id in leaving {
                switch Durable.read(VigilPaths.panes.appendingPathComponent(id + ".ended"), limit: 65536) {
                case .absent: break
                case .data(let bytes):
                    guard let end = try? JSONDecoder().decode(PaneEnd.self, from: bytes) else {
                        return .failure(request, "waiting", "Unreadable source end record.")
                    }
                    ends[id] = end
                case .unreadable:
                    return .failure(request, "waiting", "Cannot read the source end record.")
                }
            }
            movingCheckpoint?.ends = ends.isEmpty ? nil : ends
        }
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
                    tabs[t].panes[p].startedHere()
                    changed = true
                }
                guard var dock = tabs[t].dock else { continue }
                for p in dock.panes.indices where started.contains(dock.panes[p].id) && dock.panes[p].dormant == true {
                    dock.panes[p].startedHere()
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
            let me = Result { try homeDevice ?? hub.me() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let manager = VigilWorkspaces.shared
                    guard case .success(let from) = me else {
                        if case .failure(let error) = me { lifecycleLog.error("move: this Mac's hub did not name it", ["err": error]) }
                        return
                    }
                    let ask = Move.Ask(from: from, workspace: workspace, anchor: anchor, part: part)
                    // The target reads it from what it heard of the source:
                    // asked again whenever the source moves as this Mac hears
                    // it (that Mac hears it too), each ask said in its log.
                    let sources = BringDialogModel.Sources(
                        question: { manager.moveQuestion(home: homeDevice, workspace: workspace, anchor: anchor, part: part) },
                        heard: homeDevice == nil
                            ? NotificationCenter.default.publisher(for: VigilWorkspaces.stateDidChange).map { _ in () }.eraseToAnyPublisher()
                            : VigilRemote.shared.$hosts.map { _ in () }.eraseToAnyPublisher(),
                        read: { _, _ in try hub.bringSheet(device: device, ask) },
                        // The target reads its sheet from its own kept
                        // directory: a read asked of the source from here
                        // would change nothing the target reads.
                        changes: nil,
                        askSource: nil)
                    let model = BringDialogModel(
                        workspace: workspace, anchor: anchor, part: part, mac: sourceHost?.name ?? "this Mac", target: target.name,
                        what: Self.moving(label, part), home: targetHome ?? "/", sources: sources)
                    guard model.open() else {
                        return lifecycleLog.error("move: the workspace is not listed", ["workspace": workspace, "to": target.name])
                    }
                    manager.present(model, source: homeDevice, sourceHome: sourceHome, targetHome: targetHome) { revision in
                        guard let order = Move.order(workspace, home: homeDevice, to: target, me: from, anchor: anchor, part: part, checkoutRevision: revision) else {
                            return lifecycleLog.error("move: no order", ["workspace": workspace, "to": target.name])
                        }
                        manager.ask(RowHome(device: device, workspace: workspace), order.request, failing: "\(label) was not moved to \(target.name)")
                    }
                }
            }
        }
    }

    /// A move's panes as the source says them now (this Mac's registry and
    /// work facts, or another Mac's directory as heard here), and how that
    /// Mac stands; nil when it no longer lists them.
    func moveQuestion(home device: String?, workspace name: String, anchor: String, part: Registry.Workspace.Part?)
        -> (question: Bring.Question, standing: BringDialogModel.Standing)? {
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        guard let device else {
            guard let session = workspaces[name] else { return nil }
            let tabs = part == nil ? session.tabs : session.tabs.filter { $0.members.contains { $0.id == anchor } }
            let members = part == .pane ? tabs.flatMap(\.members).filter { $0.id == anchor } : tabs.flatMap(\.members)
            return (Bring.Question(panes: members.map { pane in
                Bring.Pane(pane: pane.id, agent: nil, conversation: nil, cwd: pane.cwd, name: pane.name, work: paneWork(pane.id))
            }, commit: false), .here)
        }
        guard let host = VigilRemote.shared.host(device), let directory = VigilRemote.shared.sourceDirectory(device),
              let whole = directory.live.first(where: { $0.name == name }),
              let source = part.map({ whole.only($0, of: anchor) }) ?? whole else { return nil }
        let standing: BringDialogModel.Standing = host.error == nil
            ? .live : .away(since: Self.away(host) ?? host.error ?? "out of reach")
        return (Bring.Question(panes: directory.bringing(source, here: here), commit: false), standing)
    }

    /// `state/<pane>.work` of this Mac's pane (`PaneWork`, vigil-agent's);
    /// nil when none is published or it does not read (said).
    func paneWork(_ pane: String) -> PaneWork? {
        guard let file = facts.files["state/\(pane).work"] else { return nil }
        do { return try JSONDecoder().decode(PaneWork.self, from: file.data) } catch {
            lifecycleLog.warn("work facts not read", ["pane": pane, "err": error])
            return nil
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
        guard let host = VigilRemote.shared.host(device), let directory = VigilRemote.shared.sourceDirectory(device),
              let whole = directory.live.first(where: { $0.name == name }),
              let source = part.map({ whole.only($0, of: anchor) }) ?? whole else {
            return lifecycleLog.error("bring: the workspace is not listed", ["workspace": name, "device": device])
        }
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        let hub = Local.Client(socket: VigilPaths.hub)
        // The source's directory as this Mac follows it, this Mac's own
        // facts as vigil-agent watches them, and the source asked once.
        let live = host.error == nil
        let sources = BringDialogModel.Sources(
            question: { VigilWorkspaces.shared.moveQuestion(home: device, workspace: name, anchor: anchor, part: part) },
            heard: VigilRemote.shared.$hosts.map { _ in () }.eraseToAnyPublisher(),
            // Each read takes the source's directory fresh from it while it
            // answers (`moveSource`, what the move itself commits against),
            // else the question as this Mac last heard it.
            read: { question, needs in
                let settle = needs.isEmpty ? nil : needs
                guard live else {
                    var question = question
                    question.settle = settle
                    return try hub.bring(question)
                }
                let snapshot = try JSONDecoder().decode(Directory.self, from: hub.call(device: device, .moveSource(name)))
                guard let entry = snapshot.live.first(where: { $0.name == name }),
                      let selected = part.map({ entry.only($0, of: anchor) }) ?? entry else {
                    throw WireError.refused("The source no longer lists the requested panes.")
                }
                return try hub.bring(.init(panes: snapshot.bringing(selected, here: here), commit: false, settle: settle))
            },
            changes: { hub.bringChanges($0) },
            askSource: { try hub.workRead(device: device, panes: $0) })
        let model = BringDialogModel(
            workspace: name, anchor: anchor, part: part, mac: host.name, target: nil, what: Self.moving(source.label, part),
            home: here, sources: sources)
        guard model.open() else { return lifecycleLog.error("bring: the workspace is not listed", ["workspace": name, "from": host.name]) }
        present(model, source: device, sourceHome: directory.home, targetHome: here) { revision in
            Task { @MainActor in
                let reply = await VigilSessionControl.transact(.bring(name, from: device, anchor: anchor, part: part, checkoutRevision: revision))
                guard !reply.ok || reply.code == "copied" else { return }
                let alert = NSAlert()
                alert.messageText = reply.ok ? "\(source.label) was copied" : "\(source.label) was not brought"
                alert.informativeText = reply.message
                alert.runModal()
            }
        }
    }

    /// A move's dialog on the window it was asked from (so the terminal
    /// behind it stays readable; with none, asked from the menu bar, a
    /// window of its own), and what its buttons do. `source` is the
    /// workspace's Mac (nil: this one), where what is only there is opened
    /// and read.
    private func present(_ model: BringDialogModel, source: String?, sourceHome: String?, targetHome: String?,
                         move: @escaping (String) -> Void) {
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
            case .bring(let revision):
                move(revision)
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
