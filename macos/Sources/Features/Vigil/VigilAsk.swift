// macOS only: the iOS target shares this synchronized source group and has
// no reason to link answer channels for a terminal prompt.
#if os(macOS)
import AskKit
import AskListen
import AskNod
import Foundation
import Listen
import NodKit
import Say

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
    /// EXPERIMENTAL early-answer window (`defaults write com.mitchellh.ghostty.debug
    /// vigil.voice.eager -bool true`): the gate asks at prompt ARRIVAL
    /// instead of the 1.2s ripeness gate, so a yes spoken at first sight of
    /// the on-screen prompt lands on a live mic. Explicitly accepted risk:
    /// an answer can be accepted before narration says a word - the screen
    /// is the announcement. Off by default; vigil-only, never ask-core.
    static let eagerKey = "vigil.voice.eager"
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
    private static var activePane: String?
    private nonisolated(unsafe) static var wired = false

    /// The pane whose ask is in flight, nil when idle. VigilSummon holds
    /// its chime for this pane: the narration IS the announcement, and a
    /// chime landing in the answer window masks the human's word.
    static var askingPane: String? { activePane }

    /// Route flips on the log's own timeline, where they happen, not where
    /// the next ask trips over them.
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

    /// A begun ask that has not COMPLETED yet, teardown included: a
    /// cancelled ask stays in flight until its epilogue lands. The pump's
    /// begin guard - asking through it would land "busy".
    static var inFlight: Bool { Ask.isAsking }

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
    /// `options` makes it a choice (an AskUserQuestion's labels): the
    /// package narrates them numbered, voice answers by ordinal, the HUD
    /// by click or digit; nod sits a choice out (binary by nature).
    static func ask(
        _ spoken: String,
        options: [String]? = nil,
        textOptions: Set<Int> = [],
        multi: Bool = false,
        pane: String? = nil,
        timeout: TimeInterval = 20,
        completion: @escaping (Answer?, String) -> Void
    ) {
        var sources: [any AnswerSource] = []
        if nodEnabled, nodAvailable { sources.append(NodSource()) }
        if voiceEnabled, voiceAvailable {
            // The sink is the difference between "voice said nothing" and
            // "voice dropped your yes as echo / AEC never engaged".
            sources.append(
                VoiceSource(locales: VigilVoice.chosenLocales, sink: VoiceLogSink()))
        }
        guard !sources.isEmpty else { return completion(nil, "unavailable") }
        guard !Ask.isAsking else { return completion(nil, "busy") }
        if !wired {
            wired = true
            Ask.trace = { line in trace?("ask \(line)") }
            VigilAskHUD.arm()
        }
        activePane = pane
        let offered = sources.map(\.id).joined(separator: "+")
        // The wording is the hook's rule-derived gist (tier 1 of the
        // composer architecture); the raw command is NOT re-shipped here -
        // it stands in cmd-guard's ledger, and the distiller joins the two
        // by timestamp when it mines the compose corpus.
        Ask.begin(
            spoken, sources: sources, options: options, textOptions: textOptions, multi: multi,
            composition: Composition(input: spoken, tier: options == nil ? "static-gist" : "question-literal"),
            timeout: timeout
        ) { receipt in
            switch receipt.verdict {
            case .allow, .deny, .chose, .timeout, .cancelled:
                ledger(receipt, pane: pane, offered: offered)
            case .blind, .busy:
                break
            }
            // Ask's completion runs on the main actor in the SAME turn that
            // flips it out of flight: cleanup and the caller's completion
            // are atomic against every other main-queue event. An async
            // re-hop here would open a window where a stale epilogue nulls
            // a successor ask's activePane, making its answered-elsewhere
            // cancel a no-op.
            MainActor.assumeIsolated {
                activePane = nil
                completion(receipt.verdict.answer, receipt.verdict.label)
            }
        }
    }
}
#endif
