// macOS only: the iOS target shares this synchronized source group and has
// no reason to link answer channels for a terminal prompt.
#if os(macOS)
import AppKit
import AskKit
import AskListen
import AskNod
import Listen
import NodKit
import os

/// Answer a permission prompt with your head or your voice: nod or "yes"
/// allows, shake or "no" denies - whichever channel delivers first.
///
/// The ASKING lives in the ask package - narration, per-channel
/// reachability, cross-ask refractory, dead-air watchdog, the race,
/// timeout, cancellation, receipts - one implementation for every consumer.
/// This file is pure policy: which channels are enabled, which pane owns
/// the live ask, the gate's ledger row, and the pump's completion contract.
/// The human still decides; only the input device changes.
enum VigilAsk {
    static let nodKey = "vigil.nod.gate"
    static let voiceKey = "vigil.voice.gate"
    static var nodEnabled: Bool { UserDefaults.standard.bool(forKey: nodKey) }
    static var voiceEnabled: Bool { UserDefaults.standard.bool(forKey: voiceKey) }

    /// Whether each toggle should be offered at all. A toggle for a feature
    /// that cannot work is worse than no toggle, so the row hides rather
    /// than sits there failing.
    static var nodAvailable: Bool { MotionTap.ready }
    static var voiceAvailable: Bool { MicCapture.available }

    /// The pump's entry guard: at least one enabled channel could work.
    static var armed: Bool {
        (nodEnabled && nodAvailable) || (voiceEnabled && voiceAvailable)
    }

    /// Gate lines land in vigil.log beside the summon's, wired by the
    /// session manager; the package's receipts flow through it with an
    /// "ask " prefix, so the log reads as one voice.
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
    /// kill the ask NOW. Feedback after the decision is noise about it.
    static func cancel(pane: String, reason: String = "superseded") {
        guard activePane == pane else { return }
        Ask.cancel(reason: reason)
    }

    /// One jsonl line per DECISION, alongside cmd-guard's ledger in spirit:
    /// the permission state machine must know WHICH layer answered a prompt
    /// (cmd-guard rule, auto-accept, keyboard, a head gesture, a spoken
    /// yes/no), so every layer keeps its own truth and `wake prompts`
    /// composes them. `layer` is the winning channel; unanswered asks carry
    /// the channels that were offered. Blind and busy asks never reached
    /// the human - nothing to ledger.
    private static let ledgerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/ask-gate/decisions.jsonl")

    private static func ledger(_ receipt: AskReceipt, pane: String?, offered: String) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "layer": receipt.source ?? offered,
            "verdict": receipt.verdict.label,
            "pane": pane ?? "",
            "spoken": receipt.spoken,
            "ask": receipt.id,
            "latency_ms": receipt.latencyMs,
            "narrated_ms": receipt.narratedMs,
            "route": receipt.route,
        ]
        if let detail = receipt.verdict.event?.detail {
            entry["detail"] = detail
        }
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

    /// completion carries the answer AND the verdict label, because the
    /// caller's episode bookkeeping keys off HOW the ask ended: an answered
    /// prompt (allow/deny/superseded) closes its episode by EVENT, never by
    /// the pump sampling the unblocked gap between chained prompts.
    static func ask(
        _ spoken: String,
        pane: String? = nil,
        timeout: TimeInterval = 20,
        completion: @escaping (Answer?, String) -> Void
    ) {
        var sources: [any AnswerSource] = []
        if nodEnabled, nodAvailable { sources.append(NodSource()) }
        if voiceEnabled, voiceAvailable {
            sources.append(VoiceSource(locales: VigilVoice.candidateLocales))
        }
        guard !sources.isEmpty else { return completion(nil, "unavailable") }
        guard !Ask.isAsking else { return completion(nil, "busy") }
        if !wired {
            wired = true
            Ask.trace = { line in trace?("ask \(line)") }
        }
        activePane = pane
        let offered = sources.map(\.id).joined(separator: "+")
        Ask.begin(spoken, sources: sources, timeout: timeout) { receipt in
            switch receipt.verdict {
            case .allow, .deny, .timeout, .cancelled:
                ledger(receipt, pane: pane, offered: offered)
            case .blind, .busy:
                break
            }
            DispatchQueue.main.async {
                activePane = nil
                completion(receipt.verdict.answer, receipt.verdict.label)
            }
        }
    }
}
#endif
