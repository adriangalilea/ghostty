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
    private nonisolated(unsafe) static var lastAskEnded = Date.distantPast

    /// Ask, then hand the verdict back. `nil` means no answer: a timeout NEVER
    /// approves, and the prompt is left exactly as it was.
    /// One jsonl line per decision, alongside cmd-guard's ledger in spirit:
    /// the permission state machine must know WHICH layer answered a prompt
    /// (cmd-guard rule, auto-accept, keyboard, or a head gesture), so every
    /// layer keeps its own truth and `wake prompts` composes them.
    private static let ledgerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/nod-gate/decisions.jsonl")

    private static func ledger(_ verdict: String, pane: String?, spoken: String) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "layer": "nod",
            "verdict": verdict,
            "pane": pane ?? "",
            "spoken": spoken,
        ]
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

    static func ask(
        _ spoken: String,
        pane: String? = nil,
        timeout: TimeInterval = 20,
        completion: @escaping (HeadGesture?) -> Void
    ) {
        guard enabled, available else { return completion(nil) }
        // One ask at a time; ORDERING lives in the session manager's pump,
        // which derives who is next from state files. A queue here would be
        // a second brain disagreeing with it.
        guard !listening else { return completion(nil) }
        listening = true

        let e = SignalEngine(tap: tap)
        engine = e

        let deadline = Date().addingTimeInterval(timeout)
        // The recognizer is LIVE from the first syllable: a wearer who knows
        // the drill nods during the sentence, and the verdict cuts the rest of
        // the speech off. Waiting for the sentence to finish before listening
        // turned a half-second answer into a four-second one.
        // The instruction suffix is for cold starts only; inside a minute of
        // the last ask it is ritual noise.
        let suffix = Date().timeIntervalSince(lastAskEnded) > 60 ? ". nod to allow, shake to deny" : ""
        FeedbackPlayer.announceAsync("\(spoken)\(suffix)", policy: .on)
        Task {
            var answer: HeadGesture?
            do {
                for try await event in e.events() {
                    answer = event.gesture
                    break
                }
            } catch {
                log.error("nod gate: \(error.localizedDescription, privacy: .public)")
            }
            if answer == nil, Date() > deadline { log.info("nod gate: no answer") }
            e.stop()
            engine = nil
            listening = false
            FeedbackPlayer.cutAnnouncement()
            lastAskEnded = Date()
            ledger(answer == .nod ? "allow" : answer == .shake ? "deny" : "timeout",
                   pane: pane, spoken: spoken)
            await MainActor.run { completion(answer) }
        }

        // A gesture that never comes must not hold the gate forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard listening else { return }
            e.stop()
            engine = nil
            listening = false
            lastAskEnded = Date()
            ledger("timeout", pane: pane, spoken: spoken)
            completion(nil)
        }
    }
}
#endif
