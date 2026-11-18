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
    func bring(_ request: VigilSessionControl.Request) async -> VigilSessionControl.Reply {
        guard let device = request.from, let host = VigilRemote.shared.host(device), let directory = VigilRemote.shared.sourceDirectory(device),
              let whole = directory.live.first(where: { $0.name == request.session }) else {
            return .failure(request, "not_found", "This Mac has not heard that workspace from that Mac.")
        }
        guard let source = request.part.map({ whole.only($0, of: request.anchor) }) ?? whole else {
            return .failure(request, "not_found", "That workspace has no such pane on that Mac.")
        }
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        let names = directory.conversationNames(of: source)
        let members = Set(source.paneIds)
        let revisions = directory.panes.filter { members.contains($0.key) }.compactMapValues { facts in
            facts.moveRevision.map { Registry.Workspace.moveIdentity($0, glance: facts.glance) }
        }
        guard Set(revisions.keys) == members,
              let digest = try? Registry.Workspace.moveDigest(label: whole.label, emoji: whole.emoji, cwd: whole.cwd, pinned: whole.pinned ?? false, revision: whole.layoutRevision,
                                                               tabs: whole.tabs ?? [], facts: revisions) else {
            return .failure(request, "source_unknown", "The home Mac has not published a complete version of these panes. Refresh it before moving them.")
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
        let receiver = try? await Task.detached(priority: .utility) { try Local.Client(socket: VigilPaths.hub).me() }.value
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
        guard Set(lines.map(\.pane)) == members,
              lines.allSatisfy({ $0.conversation == nil || ($0.folderHere && $0.proof?.files?.isEmpty == false) }) else {
            return .failure(request, "copy_incomplete", "The destination has no usable checkpoint for every conversation. The source is still open.")
        }
        var move = WorkspaceCommand.Request.Moved(panes: source.paneIds, mac: Host.current().localizedName ?? "another Mac", transcripts: proofs)
        move.device = receiver
        move.arrival = name
        move.ticket = request.id
        let release = WorkspaceCommand.Request(id: request.id, session: source.name, revision: digest, operation: "release_move", anchor: "", moved: move)
        let mapping = Dictionary(uniqueKeysWithValues: session.tabs.flatMap(\.members).compactMap { pane in pane.from.map { ($0.pane, pane.id) } })
        let folders = Dictionary(uniqueKeysWithValues: session.tabs.flatMap(\.members).map { ($0.id, $0.cwd) })
        let ticket = IncomingMove(source: device, request: release, panes: mapping, folders: folders)
        do { try ticket.save() } catch { return .failure(request, "commit_failed", "The handoff request could not be saved: \(error)") }
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
        incomingMoves[request.id] = ticket
        resumeMoves(from: device)
        return .init(id: request.id, ok: true, code: "committed", message: "Saved here. An open waits for the source to stop and its last conversation bytes to arrive.", session: name)
    }

    /// The receiver owns delivery. Its request and accepted receipt survive either Mac
    /// restarting and a lost reply. Only the source can release these exact pane ids.
    struct IncomingMove: Codable {
        let source: String
        let request: WorkspaceCommand.Request
        let panes: [String: String]
        let folders: [String: String]
        var requested = false
        var released: [String: Bring.TranscriptProof]?
        var accepted = false
        var refusal: String?
        static var folder: URL { VigilPaths.root.appendingPathComponent("incoming-moves") }
        var file: URL { Self.folder.appendingPathComponent(request.id.uuidString + ".json") }
        func save() throws {
            try Durable.folder(Self.folder)
            try Durable.replace(file, with: JSONEncoder().encode(self))
        }
    }

    func loadIncomingMoves() {
        do {
            try Durable.folder(IncomingMove.folder)
            for file in try FileManager.default.contentsOfDirectory(at: IncomingMove.folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                do {
                    let ticket = try JSONDecoder().decode(IncomingMove.self, from: Data(contentsOf: file))
                    guard ticket.file.lastPathComponent == file.lastPathComponent,
                          ticket.request.operation == "release_move", ticket.request.refusal == nil,
                          ticket.request.moved?.ticket == ticket.request.id else {
                        lifecycleLog.error("invalid incoming move", ["file": file.path, "why": ticket.request.refusal ?? "ticket identity"])
                        continue
                    }
                    incomingMoves[ticket.request.id] = ticket
                } catch { lifecycleLog.error("unreadable incoming move", ["file": file.path, "err": error]) }
            }
        } catch { lifecycleLog.error("incoming moves could not be loaded", ["err": error]) }
        for device in Set(incomingMoves.values.map(\.source)) { resumeMoves(from: device) }
    }

    func resumeMoves(from device: String) {
        for (id, ticket) in incomingMoves where ticket.source == device && ticket.refusal == nil && !activeMoves.contains(id) {
            moveRetry.removeValue(forKey: id)?.cancel()
            activeMoves.insert(id)
            Task { @MainActor in
                defer { activeMoves.remove(id) }
                do {
                    try await advanceIncoming(ticket)
                } catch {
                    let why = String(describing: error)
                    if moveWaiting[id] != why {
                        moveWaiting[id] = why
                        lifecycleLog.warn("handoff waiting", ["move": id, "why": why])
                        for pane in ticket.panes.values where waitingForMove(pane) { showMoveNote(pane) }
                    }
                }
                guard let pending = incomingMoves[id], pending.refusal == nil,
                      pending.requested || matchesArrival(pending) else { return }
                // A disconnected peer wakes this work on its next directory.
                // An unanswered RPC or a replica still catching up while online
                // retries only this outstanding transfer, with a bounded backoff.
                let pause = min((moveDelay[id] ?? 1) * 2, 60)
                moveDelay[id] = pause
                moveRetry[id] = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(pause)) } catch { return }
                    let verifyingHere = pending.released != nil && !pending.accepted
                    guard verifyingHere || VigilRemote.shared.host(device)?.away != true else { return }
                    resumeMoves(from: device)
                }
            }
        }
    }

    private func matchesArrival(_ ticket: IncomingMove) -> Bool {
        guard !ticket.panes.isEmpty, !conflictingOwnership(Set(ticket.panes.values)), Set(ticket.panes.keys) == Set(ticket.request.moved?.panes ?? []),
              Set(ticket.panes.values).count == ticket.panes.count else { return false }
        return ticket.panes.allSatisfy { old, new in
            guard let pane = registered(new) else { return ticket.requested && PaneFence.provesClose(memberMark(new)) }
            guard let from = pane.from else { return false }
            return from.ticket == ticket.request.id && from.device == ticket.source && from.pane == old
        }
    }

    func advanceIncoming(_ saved: IncomingMove) async throws {
        var ticket = saved
        let request = ticket.request
        guard matchesArrival(ticket) else { throw WireError.refused("the local registry cannot account for this transfer") }
        if !ticket.accepted {
            // Establish the receiver's ownership durably before the source may stop.
            if !ticket.requested {
                guard persist(publish: false, durable: true) else { throw WireError.refused("destination registry not saved") }
                ticket.requested = true
                try ticket.save()
                incomingMoves[request.id] = ticket
            }
            if ticket.released == nil {
                let released = try await moveCommand(ticket.source, request)
                if ["source_changed", "unsupported_operation", "invalid_request"].contains(released.code) {
                    var refused = ticket
                    refused.refusal = released.message
                    try refused.save()
                    incomingMoves[request.id] = refused
                    for pane in ticket.panes.values where waitingForMove(pane) { showMoveNote(pane) }
                    reportIncompleteMove(request.session, released.message)
                    return
                }
                guard released.ok, released.id == request.id, released.code == "released", let final = released.released,
                      Set(final.keys) == Set(request.moved?.transcripts?.keys.map { $0 } ?? []),
                      matchesArrival(ticket) else { throw WireError.refused(released.message) }
                ticket.released = final
                try ticket.save()
                incomingMoves[request.id] = ticket
            }
            guard let final = ticket.released else { throw WireError.refused("missing source release") }
            let checks = final.compactMap { old, proof -> Bring.Pane? in
                guard let new = ticket.panes[old], let folder = ticket.folders[new] else { return nil }
                let arriving = registered(new) == nil || PaneFence.provesClose(memberMark(new)) ? "" : new
                return .init(pane: old, arriving: arriving, agent: proof.agent, conversation: proof.start, cwd: folder, name: nil)
            }
            guard checks.count == final.count else { throw WireError.refused("the staged pane changed") }
            if !checks.isEmpty {
                let answer = try await readMove(.init(panes: checks, commit: true, compareTranscripts: true, requireStoppedWriter: true, checkpoints: final))
                guard answer.failed.isEmpty, Set(answer.lines.map(\.pane)) == Set(final.keys),
                      answer.lines.allSatisfy({ $0.folderHere && $0.proof == final[$0.pane] }),
                      matchesArrival(ticket) else { throw WireError.refused("The source has stopped. Waiting for its final transcript. If the histories diverged, resolve the transcript conflict here.") }
            }
            var received = ticket
            received.accepted = true
            try received.save()
            incomingMoves[request.id] = received
        }
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
            if waitingToOpen.remove(pane) != nil, locate(pane)?.buried == false {
                _ = tend(pane, asked: true, why: "the source released the opened pane")
            }
        }
        let ack = WorkspaceCommand.Request(session: request.session, revision: request.revision, operation: "ack_move", anchor: "", moved: request.moved)
        let reply = try await moveCommand(ticket.source, ack)
        guard reply.ok, reply.id == ack.id, reply.code == "acknowledged" else { throw WireError.refused(reply.message) }
        try Durable.remove(ticket.file)
        incomingMoves[request.id] = nil
        moveDelay[request.id] = nil
        moveWaiting[request.id] = nil
    }

    func stopForHandoff(_ name: String) {
        guard !recoveredMoveBurials.contains(name), let session = graveyard[name],
              let ticket = session.moveCheckpoint?.ticket, let requested = session.moveCheckpoint?.panes,
              Set(requested) == ownedPaneIds(session), session.closing != nil,
              !conflictingOwnership(Set(requested)), stoppingMoves.insert(name).inserted else { return }
        let ids = Set(requested)
        if ids.allSatisfy({ memberMark($0) == .clean }) { stoppingMoves.remove(name); return }
        if persist(publish: false, durable: true), fence(ids).isEmpty { deliverClose(ids) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fenceRetry) { [weak self] in
            guard let self else { return }
            self.stoppingMoves.remove(name)
            if self.graveyard[name]?.moveCheckpoint?.ticket == ticket { self.stopForHandoff(name) }
        }
    }

    func handoffCommand(_ request: VigilSessionControl.Request) async -> VigilSessionControl.Reply {
        guard let move = request.moved, let ticket = move.ticket, move.final == nil else {
            return .failure(request, "invalid_request", "A handoff requires a ticket.")
        }
        guard acceptingMove.insert(ticket).inserted else { return .failure(request, "busy", "This handoff is in progress.") }
        defer { acceptingMove.remove(ticket) }
        func record() -> Workspace? {
            graveyard.values.first { $0.moveCheckpoint?.ticket == ticket }
        }
        func same(_ session: Workspace) -> Bool {
            var saved = session.moveCheckpoint
            saved?.final = nil
            return saved == move && ownedPaneIds(session) == Set(move.panes)
        }
        if request.operation == "ack_move" {
            if let record = record() {
                guard same(record), record.moveCheckpoint?.final != nil,
                      !conflictingOwnership(ownedPaneIds(record)), ownedPaneIds(record).allSatisfy({ memberMark($0) == .clean }) else {
                    return .failure(request, "waiting", "The source has not released this transfer.")
                }
                dropBurial(record.name)
            }
            guard persist(publish: false, durable: true) else { return .failure(request, "waiting", "Could not save acknowledgement.") }
            return .init(id: request.id, ok: true, code: "acknowledged", message: "Transfer acknowledged.")
        }
        if record() == nil {
            guard request.id == ticket, let origin = workspaces[request.session], Set(move.panes).isSubset(of: ownedPaneIds(origin)) else {
                return .failure(request, "source_changed", "This workspace no longer owns the requested panes.")
            }
            let proofs = move.transcripts ?? [:]
            var checked: [String: [String: String]] = [:]
            if !proofs.isEmpty {
                let panes = proofs.map { Bring.Pane(pane: $0.key, agent: $0.value.agent, conversation: $0.value.start, cwd: NSHomeDirectory(), name: nil) }
                guard let answer = try? await readMove(.init(panes: panes, commit: false, compareTranscripts: true, checkpoints: proofs)),
                      answer.failed.isEmpty, Set(answer.lines.map(\.pane)) == Set(proofs.keys) else {
                    return .failure(request, "checkpoint_unavailable", "The source could not read the staged conversation checkpoint.")
                }
                for line in answer.lines {
                    guard let proof = line.proof, let original = proofs[line.pane],
                          proof.files == original.files, proof.digest == original.digest, proof.start == original.start,
                          let files = line.checkedFiles else {
                        return .failure(request, "checkpoint_unavailable", "The source could not verify the staged conversation prefix.")
                    }
                    checked[line.pane] = files
                }
            }
            guard workspaces[request.session] != nil,
                  move.panes.allSatisfy({ memberMark($0) == .none && !waitingForMove($0) }) else {
                return .failure(request, "source_changed", "A source pane is already closing or awaiting its own transfer.")
            }
            let began = moved(request, checked: checked)
            guard began.ok else { return began }
        }
        if let session = record(), same(session), move.panes.allSatisfy({ memberMark($0) == .clean }) {
            recoveredMoveBurials.remove(session.name)
        }
        guard let session = record(), same(session), !recoveredMoveBurials.contains(session.name),
              !conflictingOwnership(ownedPaneIds(session)) else { return .failure(request, "waiting", "No matching committed source transfer.") }
        stopForHandoff(session.name)
        guard move.panes.allSatisfy({ memberMark($0) == .clean && !Self.daemonAlive($0) }) else {
            return .failure(request, "waiting", "Waiting for the source processes to stop.")
        }
        if session.moveCheckpoint?.final == nil {
            let proofs = move.transcripts ?? [:]
            var final: [String: Bring.TranscriptProof] = [:]
            if !proofs.isEmpty {
                let panes = proofs.map { Bring.Pane(pane: $0.key, agent: $0.value.agent, conversation: $0.value.start, cwd: NSHomeDirectory(), name: nil) }
                guard let result = try? await readMove(.init(panes: panes, commit: false, compareTranscripts: true, requireStoppedWriter: true)), result.failed.isEmpty else { return .failure(request, "waiting", "The source transcript could not be read.") }
                for line in result.lines {
                    guard let proof = line.proof, let original = proofs[line.pane], proof.agent == original.agent,
                          proof.start == original.start, proof.files?.isEmpty == false else {
                        return .failure(request, "waiting", "The final conversation is unavailable.")
                    }
                    final[line.pane] = proof
                }
            }
            guard Set(final.keys) == Set(proofs.keys), let now = record(), same(now) else { return .failure(request, "waiting", "The source transfer changed.") }
            graveyard[session.name]?.moveCheckpoint?.final = final
        }
        guard persist(publish: false, durable: true) else { return .failure(request, "waiting", "Could not save the final handoff receipt.") }
        return .init(id: request.id, ok: true, code: "released", message: "The source is stopped.", released: graveyard[session.name]?.moveCheckpoint?.final)
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
        movingTo = moved.mac
        movingRevisions = revisions
        movingTranscripts = checked
        movingCheckpoint = moved
        defer { movingTo = nil; movingRevisions = nil; movingTranscripts = nil; movingCheckpoint = nil }
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
        guard let host = VigilRemote.shared.host(device), let directory = VigilRemote.shared.sourceDirectory(device),
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
        present(model, source: device, sourceHome: directory.home, targetHome: here) {
            Task { @MainActor in
                let reply = await VigilSessionControl.transact(.bring(name, from: device, anchor: anchor, part: part))
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
