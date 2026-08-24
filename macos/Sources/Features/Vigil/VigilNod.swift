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

    /// Ask, then hand the verdict back. `nil` means no answer: a timeout NEVER
    /// approves, and the prompt is left exactly as it was.
    ///
    /// One gesture at a time: a second prompt arriving mid-question would race
    /// two recognizers over one head.
    static func ask(
        _ spoken: String,
        timeout: TimeInterval = 20,
        completion: @escaping (HeadGesture?) -> Void
    ) {
        guard enabled, available, !listening else { return completion(nil) }
        listening = true

        let e = SignalEngine(tap: tap)
        engine = e

        let deadline = Date().addingTimeInterval(timeout)
        Task {
            // The engine owns its own feedback: blips per half-cycle teach the
            // gesture, the outcome tone confirms it. announce() blocks until
            // the sentence ends, which is WHY it lives in this task and not on
            // the caller's thread (the event watcher runs on main).
            e.announce("\(spoken). nod to allow, shake to deny.")
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
            await MainActor.run { completion(answer) }
        }

        // A gesture that never comes must not hold the gate forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard listening else { return }
            e.stop()
            engine = nil
            listening = false
            completion(nil)
        }
    }
}
#endif
