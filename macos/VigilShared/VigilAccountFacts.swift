import Combine
import Foundation
import Log
import VigilWire

/// The Resume menus' steps in the app's record, whichever app draws them.
let resumeLog = Log.log.scope("resume")

/// Each Mac's agent accounts as its router sees them (`AgentAccounts`,
/// `Open.accounts`), for the Resume as menu of a pane there. Read on the
/// pane's Mac by its hub; held here only to draw, and asked again when a
/// row that offers a resume comes under the person's hand and the last
/// reading is older than `fresh` (agent-hud's own cache is 60 s, so asking
/// more often reads the same numbers).
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
        case facts(AgentAccounts, at: Date)
        /// Why the Mac gave none (its agent-hud predates `--json`, its hub
        /// is out of reach), said in the menu in their place.
        case failed(String, at: Date)

        var at: Date {
            switch self {
            case .facts(_, let at), .failed(_, let at): at
            }
        }
        var facts: AgentAccounts? { if case .facts(let facts, _) = self { facts } else { nil } }
    }

    static let fresh: TimeInterval = 30

    @Published private(set) var readings: [Key: Reading] = [:]
    private var asking: Set<Key> = []

    func reading(_ key: Key) -> Reading? { readings[key] }

    /// Ask the pane's Mac for its accounts unless a reading is fresh or one
    /// is on its way. `ask` returns the hub's answer bytes.
    func want(_ key: Key, ask: @escaping @Sendable () async throws -> Data) {
        guard !asking.contains(key) else { return }
        if let at = readings[key]?.at, Date().timeIntervalSince(at) < Self.fresh { return }
        asking.insert(key)
        let started = Date()
        Task { @MainActor in
            let reading: Reading
            do {
                reading = .facts(try AgentAccounts.read(try await ask()), at: Date())
            } catch {
                reading = .failed(VigilAccountFacts.words(error), at: Date())
            }
            asking.remove(key)
            readings[key] = reading
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch reading {
            case .facts(let facts, _):
                resumeLog.info("accounts read", ["mac": key.mac ?? "here", "agent": key.agent, "accounts": facts.accounts.count,
                                                 "pick": facts.pick ?? "", "ms": ms])
            case .failed(let why, _):
                resumeLog.warn("accounts not read", ["mac": key.mac ?? "here", "agent": key.agent, "why": why, "ms": ms])
            }
        }
    }

    private nonisolated static func words(_ error: Error) -> String {
        if let wire = error as? WireError, case .refused(let why) = wire { return why }
        return String(describing: error)
    }
}
