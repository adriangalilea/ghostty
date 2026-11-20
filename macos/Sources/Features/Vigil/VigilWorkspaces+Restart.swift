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
}
