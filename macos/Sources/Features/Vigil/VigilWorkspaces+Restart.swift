import AppKit
import VigilWire

/// The person's restart of a pane's agent (`Open.restart`), from the pane's
/// problems, the menu bar and a Mac's header: asked of the pane's own Mac,
/// whose broker ends the agent and resumes its conversation in the pane,
/// never while its turn, a question or background work runs. Asked to wait
/// (`whenIdle`), it restarts at the pane's next idle moment, and the pane's
/// row says what became of it (`Restart.Note`).
extension VigilWorkspaces {
    /// Where a row's restart is asked: this Mac's pane id (`device` nil),
    /// or another Mac's with that Mac.
    func restartTarget(_ pane: SidebarPane) -> (pane: String, device: String?)? {
        if let local = pane.paneId { return (local, nil) }
        return VigilRemote.split(pane.id).map { ($0.name, $0.device) }
    }

    /// Whether a window on screen shows this row's pane.
    func isOnScreen(_ row: String) -> Bool {
        TerminalController.all.contains { controller in
            controller.window?.isVisible == true && VigilBars.shared.panesOnScreen(in: controller).contains(row)
        }
    }

    /// The panes of the sidebar whose agent a new start would settle and
    /// that have none kept for them yet: every Mac's, or another Mac's
    /// alone (`device`, its tether root).
    func restartable(on device: String? = nil) -> [SidebarPane] {
        sidebarSnapshot().flatMap(\.tabs).flatMap(\.panes)
            .filter { pane in device.map { pane.paneId == nil && VigilRemote.split(pane.id)?.device == $0 } ?? true }
            .filter { pane in pane.problems.contains(where: \.restarts) && pane.restart?.state != .armed }
    }

    /// `whenIdle`: restart at its next idle moment (now when it is idle).
    /// `cancel`: let a kept one go. A kept or let-go restart is said on the
    /// row; only what did not happen, or a refusal, is said here as well.
    func restartAgent(pane: String, device: String?, whenIdle: Bool = false, cancel: Bool = false) {
        Task { @MainActor in
            let answer: Restart.Answer
            do {
                answer = try await Self.askRestart(pane: pane, device: device, whenIdle: whenIdle, cancel: cancel)
            } catch {
                lifecycleLog.error("restart not asked", ["pane": pane, "device": device ?? "here", "err": error])
                let failed = NSAlert()
                failed.messageText = "The agent was not restarted"
                failed.informativeText = "\(error)"
                failed.runModal()
                return
            }
            lifecycleLog.info("restart answered", ["pane": pane, "device": device ?? "here", "whenIdle": whenIdle,
                                                   "cancel": cancel, "outcome": answer.outcome.rawValue])
            if cancel || answer.outcome == .armed { return }
            let alert = NSAlert()
            alert.informativeText = answer.said
            switch answer.outcome {
            case .restarting: alert.messageText = "Restarting the agent"
            case .armed: return
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

    /// Every pane `restartable(on:)` names, asked to restart at its next
    /// idle moment; one answer for all, each pane's row saying its own.
    func restartAllWhenIdle(on device: String? = nil) {
        let targets = restartable(on: device).compactMap(restartTarget)
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            var outcomes: [Restart.Answer.Outcome: Int] = [:]
            var refused: [String] = []
            for target in targets {
                do {
                    let answer = try await Self.askRestart(pane: target.pane, device: target.device, whenIdle: true, cancel: false)
                    outcomes[answer.outcome, default: 0] += 1
                    if answer.outcome == .refused { refused.append("\(target.pane): \(answer.said)") }
                } catch {
                    outcomes[.refused, default: 0] += 1
                    refused.append("\(target.pane): \(error)")
                }
            }
            lifecycleLog.info("restart all when idle", ["panes": targets.count, "restarting": outcomes[.restarting] ?? 0,
                                                       "kept": outcomes[.armed] ?? 0, "refused": refused.count])
            let alert = NSAlert()
            alert.messageText = "Restarting \(targets.count) agent\(targets.count == 1 ? "" : "s") when idle"
            alert.informativeText = "\(outcomes[.restarting] ?? 0) restarting now, \(outcomes[.armed] ?? 0) when their turn ends. "
                + (refused.isEmpty ? "Each row says when it has." : "Not restarted:\n" + refused.joined(separator: "\n"))
            alert.runModal()
        }
    }

    private nonisolated static func askRestart(pane: String, device: String?, whenIdle: Bool, cancel: Bool) async throws -> Restart.Answer {
        try await Task.detached {
            let client = Local.Client(socket: VigilPaths.hub)
            let open = Open.restart(pane, whenIdle: whenIdle, cancel: cancel)
            let data = try device.map { try client.call(device: $0, open) } ?? client.here(open)
            return try JSONDecoder().decode(Restart.Answer.self, from: data)
        }.value
    }
}
