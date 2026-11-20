import AppKit
import VigilWire

/// The person's restart of a pane's agent (`Open.restart`), from the pane's
/// problems: asked of the pane's own Mac, whose broker ends the agent and
/// resumes its conversation in the pane, never while its turn or background
/// work runs. Then it says why and offers to restart when the turn ends.
extension VigilWorkspaces {
    /// `pane`: this Mac's pane id, or `device` with that Mac's.
    func restartAgent(pane: String, device: String?, whenIdle: Bool = false) {
        Task { @MainActor in
            let answer: Restart.Answer
            do {
                answer = try await Task.detached {
                    let client = Local.Client(socket: VigilPaths.hub)
                    let open = Open.restart(pane, whenIdle: whenIdle)
                    let data = try device.map { try client.call(device: $0, open) } ?? client.here(open)
                    return try JSONDecoder().decode(Restart.Answer.self, from: data)
                }.value
            } catch {
                lifecycleLog.error("restart not asked", ["pane": pane, "device": device ?? "here", "err": error])
                let failed = NSAlert()
                failed.messageText = "The agent was not restarted"
                failed.informativeText = "\(error)"
                failed.runModal()
                return
            }
            lifecycleLog.info("restart answered", ["pane": pane, "device": device ?? "here", "outcome": answer.outcome.rawValue])
            let alert = NSAlert()
            alert.informativeText = answer.said
            switch answer.outcome {
            case .restarting: alert.messageText = "Restarting the agent"
            case .armed: alert.messageText = "Restarts when its turn ends"
            case .refused: alert.messageText = "The agent was not restarted"
            case .busy:
                alert.messageText = "The agent is still working"
                alert.addButton(withTitle: "Restart When Its Turn Ends")
                alert.addButton(withTitle: "Not Now")
                if alert.runModal() == .alertFirstButtonReturn { restartAgent(pane: pane, device: device, whenIdle: true) }
                return
            }
            alert.runModal()
        }
    }
}
