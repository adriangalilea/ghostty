import Foundation
import VigilWire

/// A move's order on its destination (PORTABILITY.md "The design"). Any
/// device asks (this Mac's sidebar, another Mac's, the phone, a command
/// line, an agent); the order always comes here, to the Mac things move to,
/// which takes it at once and publishes its ticket (`moveTickets`, served as
/// `Open.moves`). It then reads its own sheet fresh, and only once every
/// check has answered does it raise the person's card in Authz, whoever
/// asked: every move from one Mac to another is a verified answer. Its Move
/// runs the move (`moveHere`); a refusal, no answer or a sheet that changed ends the
/// ticket with why. The source asks nothing of its own: it releases.
extension VigilWorkspaces {
    /// `move_to`: taken or refused now, decided and done after.
    func orderMove(_ request: VigilSessionControl.Request, fromThisApp: Bool) async -> VigilSessionControl.Reply {
        if let same = moveTickets[request.id] {
            return .init(id: request.id, ok: true, code: "asked", message: same.words(destination: Self.thisMac), session: same.arrival)
        }
        guard let device = request.from, let host = VigilRemote.shared.host(device),
              let held = VigilRemote.shared.sourceDirectory(device),
              let whole = held.live.first(where: { $0.name == request.session }),
              request.part.map({ whole.only($0, of: request.anchor) != nil }) ?? true else {
            return .failure(request, "not_found", "This Mac has not heard that workspace from that Mac.")
        }
        let same = { (ticket: Move.Ticket) in
            ticket.from == device && ticket.workspace == request.session && ticket.anchor == request.anchor
        }
        if let open = moveTickets.values.first(where: { $0.open && same($0) }) {
            return .failure(request, "moving", "That move is already asked here: \(open.words(destination: Self.thisMac)).")
        }
        // Who asked, from facts this Mac holds: its own button, the device
        // its hub says sent the order, else a process of this Mac.
        let asker: Move.Asker
        if fromThisApp {
            asker = Move.Asker(.thisApp, name: Self.thisMac)
        } else {
            let id = request.id
            let relayed = try? await Task.detached(priority: .userInitiated) {
                try Local.Client(socket: VigilPaths.hub).moveAsker(id)
            }.value
            asker = (relayed ?? nil) ?? Move.Asker(.local, name: Self.thisMac)
        }
        guard moveTickets[request.id] == nil, !moveTickets.values.contains(where: { $0.open && same($0) }) else {
            return .failure(request, "moving", "That move is already asked here.")
        }
        for (id, ticket) in moveTickets where same(ticket) { moveTickets[id] = nil }
        let what = Self.moving(whole.label, request.part)
        moveTickets[request.id] = Move.Ticket(
            id: request.id, workspace: request.session, anchor: request.anchor, part: request.part, what: what, from: device,
            fromMac: host.name, asker: asker, stage: .checking, since: Date().timeIntervalSince1970)
        publishMoveTickets()
        lifecycleLog.info("move: asked", ["workspace": request.session, "from": host.name, "by": asker.words, "id": request.id.uuidString])
        Task { @MainActor [weak self] in await self?.decideMove(request, asker: asker, what: what) }
        return .init(id: request.id, ok: true, code: "asked",
                     message: "\(Self.thisMac) reads what it lacks, then asks you in Authz.", session: nil)
    }

    /// This Mac's own read of what it lacks, every check answered, then the
    /// card; its Move runs the move.
    private func decideMove(_ request: VigilSessionControl.Request, asker: Move.Asker, what: String) async {
        let id = request.id
        guard let device = request.from, let host = VigilRemote.shared.host(device),
              let held = VigilRemote.shared.sourceDirectory(device),
              let whole = held.live.first(where: { $0.name == request.session }),
              let selected = request.part.map({ whole.only($0, of: request.anchor) }) ?? whole else {
            return endMove(id, .failed, "\(Self.macName(request.from)) no longer lists it")
        }
        let here = FileManager.default.homeDirectoryForCurrentUser.path
        var question = Move.Question(panes: held.moving(selected, here: here), commit: false)
        question.progressSource = device
        let answer: Move.Answer
        do { answer = try await readMove(question) } catch {
            return endMove(id, .failed, "this Mac could not read what it lacks (\(error))")
        }
        guard answer.failed.isEmpty else { return endMove(id, .failed, answer.failed.values.sorted().joined(separator: "; ")) }
        // What the asker accepted is bound by the checkout revision of the
        // sheet it saw: a lack that came or went since needs a new decision.
        let revision = Move.checkoutRevision(answer.lines)
        if !revision.isEmpty && revision != request.revision {
            return endMove(id, .failed, "what this Mac lacks is not what was accepted. Look at the move again")
        }
        let accepted = Move.standing(answer.lines).map(\.need.text)
        let card = Move.Card(
            what: what, fromMac: host.name, toMac: Self.thisMac, asker: asker,
            stopping: Move.stopping(selected.paneIds, in: held), accepted: accepted,
            away: host.error == nil ? nil : Self.away(host) ?? host.error)
        guard stage(id, .asking) else { return }
        let verdict: Move.Verdict
        do {
            verdict = try await Task.detached(priority: .userInitiated) {
                try Local.Client(socket: VigilPaths.hub).moveConsent(card)
            }.value
        } catch { return endMove(id, .unanswered, "this Mac's vigil-agent did not ask (\(error))") }
        let use: UUID
        switch verdict {
        case .refused: return endMove(id, .refused, nil)
        case .unanswered(let why): return endMove(id, .unanswered, why)
        case .allowed(let allowed): use = allowed
        }
        guard stage(id, .moving) else {
            Self.tellMoveEnded(use, failed: "the move was replaced before it ran")
            return
        }
        let reply = await moveHere(request)
        // What the answer let happen, told to Authz through the hub that holds it.
        Self.tellMoveEnded(use, failed: reply.ok ? nil : reply.message)
        guard reply.ok else { return endMove(id, .failed, reply.message) }
        moveTickets[id]?.stage = .moved
        moveTickets[id]?.arrival = reply.session
        moveTickets[id]?.since = Date().timeIntervalSince1970
        publishMoveTickets()
    }

    /// How a move an answer allowed ended, told to this Mac's hub off the
    /// main thread; a hub that cannot be told leaves the use unknown, logged.
    private static func tellMoveEnded(_ use: UUID, failed: String?) {
        Task.detached(priority: .utility) {
            do { try Local.Client(socket: VigilPaths.hub).moveEnded(Move.Ended(use: use, failed: failed)) } catch {
                lifecycleLog.warn("move: its end not told to Authz", ["err": error])
            }
        }
    }

    private static func macName(_ device: String?) -> String {
        device.flatMap { VigilRemote.shared.host($0)?.name } ?? "its Mac"
    }

    /// A ticket to its next stage; false when it is gone (replaced).
    private func stage(_ id: UUID, _ stage: Move.Ticket.Stage) -> Bool {
        guard moveTickets[id] != nil else { return false }
        moveTickets[id]?.stage = stage
        moveTickets[id]?.since = Date().timeIntervalSince1970
        publishMoveTickets()
        return true
    }

    private func endMove(_ id: UUID, _ stage: Move.Ticket.Stage, _ why: String?) {
        guard let ticket = moveTickets[id] else { return }
        lifecycleLog.info("move: not moved", ["workspace": ticket.workspace, "from": ticket.fromMac, "stage": stage.rawValue, "why": why ?? ""])
        moveTickets[id]?.stage = stage
        moveTickets[id]?.why = why
        moveTickets[id]?.since = Date().timeIntervalSince1970
        publishMoveTickets()
    }

    /// This Mac as a card and a ticket name it.
    static var thisMac: String { Host.current().localizedName ?? "this Mac" }

    /// The tickets, whole, where the hub serves them (tmp + rename: its
    /// folder watch hears every document and never half of one).
    func publishMoveTickets() {
        // Ended tickets retire by one rule, every device's (`Move.retired`).
        let kept = Set(Move.retired(Array(moveTickets.values)).map(\.id))
        moveTickets = moveTickets.filter { kept.contains($0.key) }
        let tickets = moveTickets.values.sorted { $0.since < $1.since }
        do {
            try FileManager.default.createDirectory(at: VigilPaths.movesFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(tickets).write(to: VigilPaths.moves, options: .atomic)
        } catch {
            lifecycleLog.error("moves not published: other devices see what they last had", ["err": error])
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// At launch, after the handoffs (`loadIncomingMoves`): the tickets last
    /// published. One still being decided was lost with the app that decided
    /// it (its card's answer has no one to run it), and one whose Move came
    /// moved only if its handoff was saved: each said as it stands, never
    /// resumed unasked.
    func loadMoveTickets() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { self.moveRoot = try await self.moveDevice() } catch {
                lifecycleLog.warn("this Mac's root not known: its workspaces' moves are not marked on their rows", ["err": error])
            }
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
        guard let data = try? Data(contentsOf: VigilPaths.moves) else { return }
        do {
            for var ticket in try JSONDecoder().decode([Move.Ticket].self, from: data) {
                switch ticket.stage {
                case .checking, .asking:
                    ticket.stage = .failed
                    ticket.why = "Vigil restarted on \(Self.thisMac) before it was decided. Ask again"
                case .moving:
                    if let handoff = incomingMoves[ticket.id] {
                        ticket.stage = .moved
                        ticket.arrival = handoff.request.moved?.arrival
                    } else {
                        ticket.stage = .failed
                        ticket.why = "Vigil restarted on \(Self.thisMac) before the move was saved. Ask again"
                    }
                case .moved, .refused, .unanswered, .failed: break
                }
                moveTickets[ticket.id] = ticket
            }
        } catch {
            lifecycleLog.error("moves not read at launch", ["err": error])
        }
        publishMoveTickets()
    }
}
