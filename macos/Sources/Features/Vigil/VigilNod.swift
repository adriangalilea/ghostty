// macOS only: the iOS target shares this synchronized source group and has
// no reason to link a head-gesture recognizer for a terminal prompt.
#if os(macOS)
import AppKit
import NodKit
import NodSignal
import os

/// Answer a permission prompt with your head: nod allows, shake denies.
///
/// The ASKING lives in NodKit's `Ask` - narration, cross-ask refractory,
/// route gate, dead-air watchdog, timeout, cancellation, receipts - one
/// implementation for every consumer. This file is pure policy: which pane
/// owns the live ask, the gate's ledger row, and the pump's completion
/// contract. The human still decides; only the input device changes.
enum VigilNod {
    static let key = "vigil.nod.gate"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Whether the toggle should be offered at all.
    ///
    /// Motion-capable headphones must be connected and motion access not
    /// denied. A toggle for a feature that cannot work is worse than no
    /// toggle, so the row hides rather than sits there failing.
    static var available: Bool { MotionTap.ready }

    /// Gate lines land in vigil.log beside the summon's, wired by the
    /// session manager; the kit's receipts flow through it with a "nod "
    /// prefix, so the log reads as one voice.
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    private nonisolated(unsafe) static var activePane: String?
    private nonisolated(unsafe) static var wired = false

    /// Route flips on the log's own timeline, where they HAPPEN, not where
    /// the next ask trips over them - this watcher's flap trace is what
    /// convicted route reclaiming (2026-08-25 09:04).
    private nonisolated(unsafe) static var routeWatched = false
    static func watchRoute() {
        guard !routeWatched else { return }
        routeWatched = true
        AudioRoute.onDefaultOutputChange { name in
            trace?("audio route -> \"\(name)\"")
        }
    }

    /// The prompt was answered by other means (keyboard, another device):
    /// kill the ask NOW. Blips after the decision are noise about it.
    static func cancel(pane: String, reason: String = "superseded") {
        guard activePane == pane else { return }
        Ask.cancel(reason: reason)
    }

    /// One jsonl line per DECISION, alongside cmd-guard's ledger in spirit:
    /// the permission state machine must know WHICH layer answered a prompt
    /// (cmd-guard rule, auto-accept, keyboard, or a head gesture), so every
    /// layer keeps its own truth and `wake prompts` composes them. Blind
    /// and busy asks never reached the wearer - nothing to ledger.
    private static let ledgerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/nod-gate/decisions.jsonl")

    private static func ledger(_ receipt: AskReceipt, pane: String?) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "layer": "nod",
            "verdict": receipt.verdict.label,
            "pane": pane ?? "",
            "spoken": receipt.spoken,
            "ask": receipt.id,
            "latency_ms": receipt.latencyMs,
            "narrated_ms": receipt.narratedMs,
            "route": receipt.route,
        ]
        if let confidence = receipt.confidence {
            entry["confidence"] = (confidence * 100).rounded() / 100
        }
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

    /// completion carries the gesture AND the verdict label, because the
    /// caller's episode bookkeeping keys off HOW the ask ended: an answered
    /// prompt (allow/deny/superseded) closes its episode by EVENT, never by
    /// the pump sampling the unblocked gap between chained prompts.
    static func ask(
        _ spoken: String,
        pane: String? = nil,
        timeout: TimeInterval = 20,
        completion: @escaping (HeadGesture?, String) -> Void
    ) {
        guard enabled, available else { return completion(nil, "unavailable") }
        guard !Ask.isAsking else { return completion(nil, "busy") }
        if !wired {
            wired = true
            Ask.trace = { line in trace?("nod \(line)") }
        }
        activePane = pane
        Ask.begin(spoken, engine: { SignalEngine(tap: $0) }, timeout: timeout) { receipt in
            switch receipt.verdict {
            case .allow, .deny, .timeout, .cancelled:
                ledger(receipt, pane: pane)
            case .blind, .busy:
                break
            }
            DispatchQueue.main.async {
                activePane = nil
                completion(receipt.verdict.gesture, receipt.verdict.label)
            }
        }
    }
}
#endif
