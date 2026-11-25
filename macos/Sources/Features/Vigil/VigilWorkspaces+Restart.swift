import Foundation
import VigilWire

extension VigilWorkspaces {
    /// Read the home broker's acknowledgement. The shared panel presents it.
    func restartAgent(pane: String, device: String?, request: Restart) async throws -> Restart.Answer {
        try await Task.detached {
            let client = Local.Client(socket: VigilPaths.hub)
            let open = Open.restart(pane, request: request)
            let data = try device.map { try client.call(device: $0, open) } ?? client.here(open)
            return try JSONDecoder().decode(Restart.Answer.self, from: data)
        }.value
    }

    /// The accounts of the pane's Mac as its router knows them, as the hub
    /// there answers (`Open.accounts`): an `AgentAccounts` document, as
    /// kept or brought up to date first (`current`).
    nonisolated static func accounts(agent: String, device: String?, current: Bool) async throws -> Data {
        try await Task.detached {
            let client = Local.Client(socket: VigilPaths.hub)
            let open = Open.accounts(agent, current: current)
            return try device.map { try client.call(device: $0, open) } ?? client.here(open)
        }.value
    }
}
