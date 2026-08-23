import AppKit

/// Follow has three modes, one control (two toggles that both move focus
/// would fight; a mode selector cannot):
///   off     - the queue stays discoverable (keycap, badge, ⌘⇧J), nothing moves.
///   summon  - mid-turn blockers (permission prompts, AskUserQuestion) pull
///             the quick terminal in over whatever Adrian is doing; turn-end
///             questions never do. The default: it is the one kind of ask
///             that cannot wait.
///   window  - the original auto-follow: the key window shapeshifts to any
///             unseen ask.
enum VigilFollowMode: String {
    case off, summon, window

    static let key = "vigil.follow.mode"

    static var current: VigilFollowMode {
        UserDefaults.standard.string(forKey: key).flatMap(VigilFollowMode.init) ?? .summon
    }

    /// One-time migration from the retired `vigil.autofollow` bool: true
    /// was the window behavior; false/absent falls to the default above.
    static func migrate() {
        guard UserDefaults.standard.string(forKey: key) == nil,
              UserDefaults.standard.bool(forKey: "vigil.autofollow") else { return }
        UserDefaults.standard.set(VigilFollowMode.window.rawValue, forKey: key)
    }
}

/// The summon engine: an agent stalls mid-turn somewhere in the unseen
/// fleet and the quick terminal slides in already focused on the asking
/// pane; answering advances to the next stalled pane IN PLACE (the panel
/// is a viewport, the queue drives its shapeshift - no dismiss/re-summon
/// flashing); the queue draining slides it away. Policy lives here, every
/// mechanic (float, reclaim, the queue derivation) is the manager's.
@MainActor
final class VigilSummon {
    static let shared = VigilSummon()

    /// The pane currently summoned. While set, the engine watches for its
    /// answer, never for new targets (a chained prompt in the same pane
    /// keeps the panel in place).
    private var current: VigilSessionManager.SummonCandidate?

    /// Dismissing the panel with an ask still open is a SNOOZE: only a
    /// block FRESHER than this re-opens the flow (and re-admits everything
    /// older behind it). Time arbitrates, no flag can go stale - the acks
    /// doctrine.
    private var snoozeDate: Date = .distantPast

    private var work: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    /// Consumed by the visibility observer: this dismissal is the engine
    /// draining its queue, not Adrian waving the panel away.
    private var engineDismiss = false

    private init() {
        VigilFollowMode.migrate()
        NotificationCenter.default.addObserver(
            forName: VigilSessionManager.stateDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { VigilSummon.shared.schedule() }
        }
        // Heartbeat, same reason as auto-follow's: a pane SITTING blocked
        // emits no new event.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VigilSummon.shared.schedule() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .quickTerminalDidChangeVisibility, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let quick = notification.object as? QuickTerminalController,
                      !quick.visible else { return }
                VigilSummon.shared.panelDidHide()
            }
        }
    }

    private func schedule() {
        guard VigilFollowMode.current == .summon else { return }
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.evaluate() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Everything after the snooze gate and the current summon.
    private func queue() -> [VigilSessionManager.SummonCandidate] {
        VigilSessionManager.shared.summonQueue()
            .filter { $0.since > snoozeDate && $0.pane != current?.pane }
    }

    private func evaluate() {
        guard VigilFollowMode.current == .summon else { return }
        let manager = VigilSessionManager.shared

        if let cur = current {
            // Adrian moved the flow himself (manual float of another
            // session, a mount): the summon is over, his gesture wins.
            guard manager.floatingName == cur.name else {
                current = nil
                settleWork?.cancel()
                VigilHush.resume()
                schedule()
                return
            }
            // Answered? Settle briefly so the approval visibly lands
            // before the panel moves on; a re-block during the settle
            // (chained prompts in one pane) cancels the advance.
            if manager.paneAgentState(cur.pane)?.state != .blocked, settleWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    self?.settleWork = nil
                    self?.advance()
                }
                settleWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
            }
            return
        }

        // Firing vetoes, auto-follow's family: never under control mode,
        // never while Adrian is mid-answer in the key window, never while
        // another panel (overview, identity editor) owns the keys. NSApp
        // inactive is NOT a veto - summoning over other apps is the point
        // (the fleet asks while Adrian reads elsewhere).
        guard !VigilBars.shared.controlMode else { return }
        if NSApp.isActive, let key = NSApp.keyWindow {
            if let controller = key.windowController as? TerminalController,
               let name = VigilSessionManager.shared.sessionName(of: controller),
               manager.asking(name) { return }
            if key is NSPanel, !(key.windowController is QuickTerminalController) { return }
        }
        guard let head = queue().first else { return }
        summon(head)
    }

    private func summon(_ candidate: VigilSessionManager.SummonCandidate) {
        let manager = VigilSessionManager.shared
        let appearing = !manager.quickTerminalVisible
        manager.float(name: candidate.name, landOn: candidate.pane)
        guard manager.floatingName == candidate.name else {
            manager.vlog("summon: float REFUSED for '\(candidate.name)'")
            return
        }
        if appearing { VigilHush.pause() }
        // A summon re-opens the whole flow: everything snoozed queues
        // behind the fresh ask again.
        snoozeDate = .distantPast
        current = candidate
        manager.vlog("summon: '\(candidate.name)' pane \(candidate.pane)")
        // The content under the cursor just changed (or appeared): shield
        // the panel's terminal briefly, and the pill names the arrival.
        VigilBars.shared.shield(window: manager.quickTerminalWindow)
        let text: String = {
            guard let session = manager.sessions[candidate.name] else { return candidate.name }
            let emoji = session.emoji.map { "\($0) " } ?? ""
            let waiting = queue().count
            return emoji + session.label + (waiting > 0 ? "  ·  +\(waiting) waiting" : "")
        }()
        VigilFollowSplash.show(in: manager.quickTerminalWindow, text: text)
    }

    private func advance() {
        guard VigilFollowMode.current == .summon, let cur = current else { return }
        let manager = VigilSessionManager.shared
        // Re-blocked during the settle: stay put, it is asking again.
        if manager.paneAgentState(cur.pane)?.state == .blocked { return }
        if let next = queue().first {
            current = nil
            summon(next)
        } else if manager.quickTerminalVisible {
            engineDismiss = true
            manager.dismissQuickTerminal()
        } else {
            current = nil
            VigilHush.resume()
        }
    }

    /// Any dismissal (engine drain, ⌥`, esc, autohide) ends the flow; a
    /// MANUAL one with the ask still open also snoozes it.
    private func panelDidHide() {
        let wasEngine = engineDismiss
        engineDismiss = false
        guard let cur = current else { return }
        current = nil
        settleWork?.cancel()
        settleWork = nil
        if !wasEngine,
           VigilSessionManager.shared.paneAgentState(cur.pane)?.state == .blocked {
            snoozeDate = Date()
            VigilSessionManager.shared.vlog("summon: snoozed (manual dismissal mid-ask)")
        }
        VigilHush.resume()
    }
}
