import Combine
import Foundation
import Log
import VigilWire

/// The Resume menus' steps in the app's record, whichever app draws them.
let resumeLog = Log.log.scope("resume")

/// Each Mac's agent accounts as its router knows them (`AgentAccounts`,
/// `Open.accounts`), for the Resume as panel of a pane there. Read on the
/// pane's Mac by its hub from the document agent-hud keeps; held here only
/// to draw. A row that offers a resume coming under the person's hand
/// reads the document as it is kept, once, so the panel opens on it; the
/// panel opening asks for it brought up to date and draws that when it
/// arrives.
@MainActor
final class VigilAccountFacts: ObservableObject {
    static let shared = VigilAccountFacts()

    struct Key: Hashable, Sendable {
        /// The pane's Mac: nil for this one.
        let mac: String?
        /// `claude`, `codex`.
        let agent: String
    }

    enum Reading: Equatable {
        case facts(AgentAccounts)
        /// Why the Mac gave none (its agent-hud keeps no document, its hub
        /// is out of reach), said in the panel in their place.
        case failed(String)

        var facts: AgentAccounts? { if case .facts(let facts) = self { facts } else { nil } }
    }

    /// The hub's answer bytes for the document, as kept or `current`.
    typealias Ask = @Sendable (_ current: Bool) async throws -> Data

    @Published private(set) var readings: [Key: Reading] = [:]
    /// The asks on their way, and whether each is for the current document.
    private var asking: [Key: Bool] = [:]
    /// A current document wanted while a kept one was on its way.
    private var wanted: [Key: Ask] = [:]

    func reading(_ key: Key) -> Reading? { readings[key] }

    /// Ask the pane's Mac for its accounts. Not `current` (a row under the
    /// hand): only when none are held. `current` (the panel opened): always,
    /// once at a time.
    func want(_ key: Key, current: Bool, ask: @escaping Ask) {
        if !current, readings[key]?.facts != nil { return }
        if let underway = asking[key] {
            if current, !underway { wanted[key] = ask }
            return
        }
        asking[key] = current
        let started = Date()
        Task { @MainActor in
            var reading: Reading
            do {
                reading = .facts(try AgentAccounts.read(try await ask(current)))
            } catch {
                reading = .failed(VigilAccountFacts.words(error))
            }
            asking[key] = nil
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch reading {
            case .facts(let facts):
                // Two asks can answer out of order: the later document stays.
                if let held = readings[key]?.facts, held.supersedes(facts) { reading = .facts(held) }
                resumeLog.info("accounts read", ["mac": key.mac ?? "here", "agent": key.agent, "accounts": facts.accounts.count,
                                                 "generation": facts.generation, "current": current, "ms": ms])
            case .failed(let why):
                resumeLog.warn("accounts not read", ["mac": key.mac ?? "here", "agent": key.agent, "why": why, "ms": ms])
            }
            // A failure never takes the place of facts already drawn.
            if reading.facts != nil || readings[key]?.facts == nil { readings[key] = reading }
            if let next = wanted.removeValue(forKey: key) { want(key, current: true, ask: next) }
        }
    }

    private nonisolated static func words(_ error: Error) -> String {
        if let wire = error as? WireError, case .refused(let why) = wire { return why }
        return String(describing: error)
    }
}
