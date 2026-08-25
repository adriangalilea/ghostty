// macOS only: the iOS target shares this synchronized source group and has
// no reason to link a head-gesture recognizer for a terminal prompt.
#if os(macOS)
import AppKit
import NodKit
import NodSignal
import os

/// Answer a permission prompt with your head: nod allows, shake denies.
///
/// The recognizer is a Swift library (NodKit + NodSignal), linked in process.
/// No CLI is spawned: the app already owns the pane, the prompt and the audio
/// session, and shelling out would fork a second CoreMotion consumer for a
/// question this process is already asking.
///
/// The human still decides. Only the input device changes.
enum VigilNod {
    static let key = "vigil.nod.gate"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Whether the toggle should be offered at all.
    ///
    /// Motion-capable headphones must be connected and motion access not
    /// denied. A toggle for a feature that cannot work is worse than no
    /// toggle, so the row hides rather than sits there failing.
    static var available: Bool { MotionTap.ready }

    private static let log = Logger(subsystem: "com.mitchellh.ghostty", category: "vigil.nod")
    private static let tap = MotionTap()
    private nonisolated(unsafe) static var engine: SignalEngine?
    private nonisolated(unsafe) static var listening = false
    private nonisolated(unsafe) static var activePane: String?
    private nonisolated(unsafe) static var wasCancelled = false
    private nonisolated(unsafe) static var cancelReason = "superseded"
    private nonisolated(unsafe) static var timedOut = false
    private nonisolated(unsafe) static var lastAskEnded = Date.distantPast

    // ------------------------------------------------------------------
    // Instrumentation. Every ask must be reconstructible from receipts
    // alone: which device the audio went to, whether the narration actually
    // STARTED, how much of it played before it was cut, how long the
    // verdict took, what the recognizer scored, and (in the session
    // manager) whether the keystroke landed. "No narration and my nod did
    // nothing" was undecidable without these (2026-08-25 07:46).
    // ------------------------------------------------------------------

    /// Gate lines land in vigil.log beside the summon's, wired by the
    /// session manager. os_signpost alone proved useless here: signposts
    /// are not persisted to the log store, so the occurrence that matters
    /// is always the one with no record.
    nonisolated(unsafe) static var trace: ((String) -> Void)?

    /// Route flips become visible when they HAPPEN, not when the next ask
    /// trips over them: one line per default-output change, straight from
    /// CoreAudio's own listener.
    static func watchRoute() {
        AudioRoute.onDefaultOutputChange { name in trace?("audio route -> \"\(name)\"") }
    }

    private nonisolated(unsafe) static var askSeq = 0
    /// Milliseconds of THIS ask's narration that actually played, from the
    /// synthesizer's delegate: -1 no report yet, 0 never started.
    private nonisolated(unsafe) static var narratedMs = -1
    private nonisolated(unsafe) static var speechWired = false

    private static func wireSpeechOnce() {
        guard !speechWired else { return }
        speechWired = true
        Announcer.onSpeech = { event in
            switch event {
            case .started(let text):
                trace?("nod ask#\(askSeq): speech STARTED \"\(text.prefix(48))\"")
            case .finished(_, let after):
                narratedMs = Int(after * 1000)
                trace?("nod ask#\(askSeq): speech finished after \(narratedMs)ms")
            case .cut(_, let after):
                narratedMs = Int(after * 1000)
                trace?("nod ask#\(askSeq): speech CUT after \(narratedMs)ms")
            case .droppedBeforeStart:
                narratedMs = 0
                trace?("nod ask#\(askSeq): speech NEVER STARTED (cancelled before the first syllable)")
            }
        }
    }

    /// The prompt was answered by other means (keyboard, another device):
    /// kill the ask NOW. Blips after the decision are noise about it.
    static func cancel(pane: String, reason: String = "superseded") {
        guard listening, activePane == pane else { return }
        wasCancelled = true
        cancelReason = reason
        trace?("nod ask#\(askSeq): cancelled (\(reason))")
        FeedbackPlayer.cutAnnouncement()
        engine?.stop()
    }

    /// One jsonl line per decision, alongside cmd-guard's ledger in spirit:
    /// the permission state machine must know WHICH layer answered a prompt
    /// (cmd-guard rule, auto-accept, keyboard, or a head gesture), so every
    /// layer keeps its own truth and `wake prompts` composes them.
    private static let ledgerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/nod-gate/decisions.jsonl")

    private static func ledger(
        _ verdict: String, pane: String?, spoken: String,
        ask: Int, askedAt: Date, confidence: Double?, route: String
    ) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "layer": "nod",
            "verdict": verdict,
            "pane": pane ?? "",
            "spoken": spoken,
            "ask": ask,
            "latency_ms": Int(Date().timeIntervalSince(askedAt) * 1000),
            "narrated_ms": narratedMs,
            "route": route,
        ]
        if let confidence { entry["confidence"] = (confidence * 100).rounded() / 100 }
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        let dir = ledgerURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: ledgerURL.path) {
            FileManager.default.createFile(atPath: ledgerURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: ledgerURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data("\n".utf8))
            try? handle.close()
        }
    }

    /// completion carries the gesture AND the ledger verdict, because the
    /// caller's episode bookkeeping keys off HOW the ask ended: an answered
    /// prompt (allow/deny/superseded) closes its episode by EVENT, never by
    /// the pump happening to sample the unblocked gap between two chained
    /// prompts — sampling missed that gap on every chained run all night.
    ///
    /// Ask, then hand the verdict back. `nil` means no answer: a timeout NEVER
    /// approves, and the prompt is left exactly as it was.
    static func ask(
        _ spoken: String,
        pane: String? = nil,
        timeout: TimeInterval = 20,
        completion: @escaping (HeadGesture?, String) -> Void
    ) {
        guard enabled, available else { return completion(nil, "unavailable") }
        // One ask at a time; ORDERING lives in the session manager's pump,
        // which derives who is next from state files. A queue here would be
        // a second brain disagreeing with it.
        guard !listening else { return completion(nil, "busy") }
        wireSpeechOnce()
        listening = true
        activePane = pane
        wasCancelled = false
        timedOut = false
        narratedMs = -1
        askSeq += 1
        let id = askSeq
        let askedAt = Date()
        let route = AudioRoute.outputName
        trace?("nod ask#\(id): pane \(pane ?? "?") route=\"\(route)\" spoken=\"\(spoken.prefix(48))\"")

        let e = SignalEngine(tap: tap)
        engine = e

        // The recognizer is LIVE from the first syllable: a wearer who knows
        // the drill nods during the sentence, and the verdict cuts the rest of
        // the speech off. Waiting for the sentence to finish before listening
        // turned a half-second answer into a four-second one.
        // The instruction suffix is for cold starts only; inside a minute of
        // the last ask it is ritual noise.
        let suffix = Date().timeIntervalSince(lastAskEnded) > 60 ? ". nod to allow, shake to deny" : ""
        // Clean channel before speaking: any stale narration from a resolved
        // ask dies here even when its cancel lost the race.
        FeedbackPlayer.cutAnnouncement()
        // A hijacked route (another device grabbed the A2DP stream, or macOS
        // fell back to speakers) makes narration inaudible while this gate
        // believes it asked. Reclaim the default output FIRST, bounded by
        // AudioRoute.reclaim's budget, then speak - never half a question on
        // the speakers and a silent swap mid-sentence. The already-target
        // path is microseconds, so the common ask pays one task hop.
        Task.detached {
            let reclaim = AudioRoute.reclaim()
            if reclaim.outcome != .alreadyTarget { trace?("nod ask#\(id): \(reclaim.line)") }
            // A cancel that landed during the reclaim already resolved this
            // ask; narrating now would be stale speech about a decision made.
            guard !wasCancelled, askSeq == id else { return }
            FeedbackPlayer.announceAsync("\(spoken)\(suffix)", policy: .on)
        }
        // Cross-ask refractory: a fresh detector starting inside the tail of
        // the PREVIOUS ask's nod would consume that residual motion as an
        // instant (unintended) answer. Speech starts the moment the route is
        // settled (microseconds unless a reclaim runs); listening waits out
        // the tail.
        let coolOff = max(0, 0.8 - Date().timeIntervalSince(lastAskEnded))
        Task {
            if coolOff > 0 { try? await Task.sleep(for: .seconds(coolOff)) }
            var answer: HeadGesture?
            var confidence: Double?
            do {
                // A cancel during the cool-off arrives before the engine has a
                // task to stop; honoring the flag here is what makes that
                // cancel stick instead of racing a subscription that hasn't
                // happened yet.
                if !wasCancelled {
                    for try await event in e.events() {
                        answer = event.gesture
                        confidence = event.confidence
                        trace?(
                            "nod ask#\(id): recognized \(event.gesture.rawValue)"
                                + " conf=\(String(format: "%.2f", event.confidence))"
                                + " +\(Int(Date().timeIntervalSince(askedAt) * 1000))ms")
                        break
                    }
                }
            } catch is CancellationError {
                // engine.stop() (cancel/timeout): the silence IS the answer.
            } catch {
                trace?("nod ask#\(id): engine error \(error.localizedDescription)")
                log.error("nod gate: \(error.localizedDescription, privacy: .public)")
            }
            e.stop()
            engine = nil
            FeedbackPlayer.cutAnnouncement()
            // The cut reports through the synthesizer's delegate a beat
            // later; the pause lets narrated_ms be truth instead of a race.
            try? await Task.sleep(for: .milliseconds(80))
            listening = false
            lastAskEnded = Date()
            let verdict = answer == .nod ? "allow"
                : answer == .shake ? "deny"
                : wasCancelled ? cancelReason : "timeout"
            ledger(verdict, pane: pane, spoken: spoken,
                   ask: id, askedAt: askedAt, confidence: confidence, route: route)
            trace?(
                "nod ask#\(id): verdict \(verdict)"
                    + " latency=\(Int(Date().timeIntervalSince(askedAt) * 1000))ms"
                    + " narrated=\(narratedMs)ms")
            await MainActor.run { completion(answer, verdict) }
        }

        // A gesture that never comes must not hold the gate forever. The
        // timeout only STOPS the engine: the consumer task above is the one
        // and only completion path. (Two independent paths once raced when
        // the stream finished while the timeout closure ran: double ledger
        // rows, double completions.)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard listening, askSeq == id, !wasCancelled else { return }
            timedOut = true
            trace?("nod ask#\(id): timeout after \(Int(timeout))s -> stopping engine")
            e.stop()
        }
    }
}
#endif
