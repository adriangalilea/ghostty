import AppKit
import AskKit
import Earcon
import VigilWire

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
    private var current: VigilWorkspaces.SummonCandidate?

    /// Dismissing the panel with an ask still open is a SNOOZE: only a
    /// block FRESHER than this re-opens the flow (and re-admits everything
    /// older behind it). Time arbitrates, no flag can go stale - the acks
    /// doctrine.
    private var snoozeDate: Date = .distantPast

    private var work: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    /// Pending empty-queue dismissal; cancelled when a fresh ask retargets.
    private var lingerWork: DispatchWorkItem?
    /// Consumed by the visibility observer: this dismissal is the engine
    /// draining its queue, not Adrian waving the panel away.
    private var engineDismiss = false
    /// Adrian moved INTO the panel this episode: a click inside it, or real
    /// typing (printable text beyond an answer key). An answer that never
    /// touched the glass - a nod, a bare enter/arrow/1/esc - leaves nothing
    /// to preserve, and the panel dismisses the moment its queue drains
    /// instead of lingering over the video he was watching.
    private var engaged = false

    private init() {
        // A pane sitting blocked needs no re-check by itself: only what
        // vetoes its summon changes, and every such change is one of these.
        VigilWorkspaces.onPresenceInputs { VigilSummon.shared.schedule() }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                let summon = VigilSummon.shared
                guard summon.current != nil,
                      let quick = VigilWorkspaces.shared.quickTerminalWindow,
                      event.window === quick else { return }
                if event.type == .leftMouseDown {
                    summon.engaged = true
                    return
                }
                guard let chars = event.charactersIgnoringModifiers,
                      let first = chars.first, let scalar = chars.unicodeScalars.first else { return }
                let answerKeys: Set<Character> = ["\r", "\u{1b}", "\t", "1", "2"]
                let isFunctionKey = (0xF700...0xF8FF).contains(scalar.value)
                if !isFunctionKey, scalar.value >= 0x20, !answerKeys.contains(first) {
                    summon.engaged = true
                }
            }
            return event
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
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.evaluate() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Everything after the snooze gate and the current summon.
    private func queue() -> [VigilWorkspaces.SummonCandidate] {
        // Every drop is LOGGED with its reason: "no float appeared" must be
        // answerable from the log alone.
        let manager = VigilWorkspaces.shared
        return manager.summonQueue().filter { c in
            if c.since <= snoozeDate {
                summonLog.info("dropped: snoozed", ["pane": c.pane])
                return false
            }
            if c.pane == current?.pane { return false }
            if manager.paneOnAnyScreen(c.pane) {
                // The full visibility breakdown rides the log line: "it said
                // in-place but I could not see it" must be decidable from
                // this receipt alone.
                summonLog.info("in place: on screen", ["pane": c.pane, "visibility": manager.paneOnScreenReceipt(c.pane)])
                return false
            }
            return true
        }
    }

    /// What was rung for: each pane's state revision, the one its own Mac
    /// gave that state. A cue is for an event, and the event is that
    /// revision: rung once, whatever happens to the way this Mac hears of
    /// it. Kept on disk and never dropped because a pane stopped being
    /// listed: a Mac out of reach and back, or this app restarted, rings
    /// nothing again, and a turn that ended while its Mac was away rings
    /// once when it is heard (its revision is new). Held as memory keyed by
    /// pane and dropped when the pane left the list, every old ending on an
    /// M5 in and out of reach rang at each return (2026-11-11).
    private struct Rung: Codable, Equatable {
        var revision: String
        var at: Double
    }
    private var rung: [String: Rung] = VigilSummon.readRung() {
        didSet { if rung != oldValue { Self.writeRung(rung) } }
    }
    private static let rungFile = VigilPaths.root.appendingPathComponent("rung.json")
    private static let rungKept = 2000

    private static func readRung() -> [String: Rung] {
        guard let data = try? Data(contentsOf: rungFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Rung].self, from: data)) ?? [:]
    }

    private static func writeRung(_ rung: [String: Rung]) {
        // The oldest go first, far past any number of panes that exist.
        var kept = rung
        if kept.count > rungKept {
            kept = Dictionary(uniqueKeysWithValues: kept.sorted { $0.value.at > $1.value.at }.prefix(rungKept).map { ($0.key, $0.value) })
        }
        do { try JSONEncoder().encode(kept).write(to: rungFile, options: .atomic) } catch {
            summonLog.error("what was rung for not saved", ["err": error])
        }
    }

    /// Whether this state of the pane is news: not rung for yet. Marks it.
    private func news(_ candidate: VigilWorkspaces.SummonCandidate) -> Bool {
        guard rung[candidate.pane]?.revision != candidate.revision else { return false }
        rung[candidate.pane] = Rung(revision: candidate.revision, at: Date().timeIntervalSince1970)
        return true
    }

    /// The waiting cue, the earcon family's own (two notes rising): only
    /// for a blocker nothing narrates. No system sound: the machine's own
    /// voice is the earcon family.
    static func chime() { cue(.waiting) }

    /// The attention pair's falling half: an agent finished on a pane you
    /// cannot see (a visible ending is seen; news is what you cannot see).
    static func doneChime() { cue(.ended) }

    /// Every cue vigil plays, through the player's own queue (`Earcon.cue`:
    /// never on main, where an idle output device froze the app ~650 ms per
    /// chime); a cue that could not sound is said.
    nonisolated static func cue(_ earcon: Earcon) {
        earcon.cue { summonLog.error("\(earcon.rawValue) cue silent: output player refused") }
    }

    private func announce() {
        let manager = VigilWorkspaces.shared
        // ONE chime per tick however many asks landed together — three
        // overlapping dings are noise about noise. The log names every
        // pane a cue was for: "I heard nothing" vs "nothing fired", and
        // "what was that for", are answered from the log alone.
        var waiting: [String] = []
        for ask in manager.midTurnAsks() {
            // ONE cue per moment, owned by the layer that owns it. A blocker
            // the ask lane carries (narrated now, or queued in the inbox to
            // be narrated next) gets the ask's own cues - narration, the
            // ears-open earcon, accepted/unheard - and a chime on top would
            // be a second sound for the same permission on every command.
            // Not marked rung: an ask that times out unanswered leaves the
            // pane blocked with nothing carrying it, and THEN the chime
            // does its job.
            if VigilHarnessCoordinator.shared.carries(pane: ask.pane) { continue }
            if news(ask) { waiting.append(ask.pane) }
        }
        if !waiting.isEmpty {
            summonLog.info("waiting cue", ["panes": waiting])
            Self.chime()
        }
        // Ended turns ring softer — news, not interruption — and news is
        // what you cannot see: a turn ending on screen is seen, and a cue
        // for every visible message would be a sound per message. One
        // already seen anywhere (this Mac, another, the phone) is no news.
        var ended: [String] = []
        for end in manager.turnEnds() where news(end) {
            if manager.paneOnAnyScreen(end.pane) || manager.paneDisplayState(end.pane) == .idle { continue }
            ended.append(end.pane)
        }
        if !ended.isEmpty {
            summonLog.info("ended cue", ["panes": ended])
            Self.doneChime()
        }
    }

    private func evaluate() {
        // The chimes are the noise contract and ring in every follow mode;
        // only the glass moving is the summon's own business (a follow
        // mode of `off` must never silence every blocker).
        announce()
        guard VigilFollowMode.current == .summon else { return }
        let manager = VigilWorkspaces.shared

        if let cur = current {
            // Adrian moved the flow himself (manual float of another
            // session, a mount): the summon is over, his gesture wins.
            guard manager.panelWorkspace == cur.name else {
                current = nil
                settleWork?.cancel()
                Hush.release("summon")
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
            // Veto only an answer IN PROGRESS: the FOCUSED pane is
            // blocked — typing there IS answering. Anything wider mutes
            // the summon: session-level (any raw block) mutes hidden-tab
            // asks, visible-level (any on-screen block) lets one lingering
            // unanswered prompt mute the whole fleet.
            // Queue discipline falls out: answer the prompt under your
            // fingers, THEN the next one summons.
            if let controller = key.windowController as? TerminalController,
               let pane = controller.focusedSurface?.vigilAttachId,
               manager.paneAgentState(pane)?.state == .blocked { return }
            if key is NSPanel, !(key.windowController is QuickTerminalController) { return }
        }
        let q = queue()
        let all = manager.summonQueue()
        if q.isEmpty, !all.isEmpty {
            summonLog.info("asks standing, none float-eligible", ["asks": all.count])
            return
        }
        guard let head = q.first else { return }
        summon(head)
    }

    private func summon(_ candidate: VigilWorkspaces.SummonCandidate) {
        lingerWork?.cancel()
        lingerWork = nil
        let manager = VigilWorkspaces.shared
        let appearing = !manager.quickTerminalVisible
        manager.float(name: candidate.name, landOn: candidate.pane)
        guard manager.panelWorkspace == candidate.name else {
            summonLog.warn("float refused", ["workspace": candidate.name])
            return
        }
        // One claim for the whole summon flow: chained asks inside it each
        // claim too (ask-core), but the panel's own claim keeps media down
        // across the gaps between them.
        if appearing { Hush.claim("summon") }
        // A summon re-opens the whole flow: everything snoozed queues
        // behind the fresh ask again.
        snoozeDate = .distantPast
        current = candidate
        engaged = false
        summonLog.info("summoned", ["workspace": candidate.name, "pane": candidate.pane])
        // The content under the cursor just changed (or appeared): shield
        // the panel's terminal briefly, and the pill names the arrival.
        VigilBars.shared.shield(window: manager.quickTerminalWindow)
        let text: String = {
            guard let session = manager.workspaces[candidate.name] else { return candidate.name }
            let emoji = session.emoji.map { "\($0) " } ?? ""
            let waiting = queue().count
            return emoji + session.label + (waiting > 0 ? "  ·  +\(waiting) waiting" : "")
        }()
        VigilFollowSplash.show(in: manager.quickTerminalWindow, text: text)
    }

    private func advance() {
        guard VigilFollowMode.current == .summon, let cur = current else { return }
        let manager = VigilWorkspaces.shared
        // Re-blocked during the settle: stay put, it is asking again.
        if manager.paneAgentState(cur.pane)?.state == .blocked { return }
        if let next = queue().first {
            current = nil
            summon(next)
        } else if manager.quickTerminalVisible {
            if !engaged {
                summonLog.info("drained unengaged; dismissed")
                engineDismiss = true
                manager.dismissQuickTerminal()
                return
            }
            // LINGER before dismissing: chained prompts in one turn land a
            // few seconds apart, and out-then-in is the slowest possible
            // rendering of "next question". Hold the panel; an ask arriving
            // inside the window retargets the viewport in place, and only a
            // quiet linger actually dismisses.
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lingerWork = nil
                if let next = self.queue().first {
                    self.current = nil
                    self.summon(next)
                } else if VigilWorkspaces.shared.quickTerminalVisible {
                    self.engineDismiss = true
                    VigilWorkspaces.shared.dismissQuickTerminal()
                } else {
                    self.current = nil
                    Hush.release("summon")
                }
            }
            lingerWork?.cancel()
            lingerWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: w)
        } else {
            current = nil
            Hush.release("summon")
        }
    }

    /// Any dismissal (engine drain, ⌥`, esc, autohide) ends the flow; a
    /// MANUAL one with the ask still open also snoozes it.
    private func panelDidHide() {
        let wasEngine = engineDismiss
        engineDismiss = false
        engaged = false
        guard let cur = current else { return }
        current = nil
        settleWork?.cancel()
        settleWork = nil
        lingerWork?.cancel()
        lingerWork = nil
        if !wasEngine,
           VigilWorkspaces.shared.paneAgentState(cur.pane)?.state == .blocked {
            snoozeDate = Date()
            summonLog.info("snoozed: dismissed mid-ask")
        }
        Hush.release("summon")
    }
}
