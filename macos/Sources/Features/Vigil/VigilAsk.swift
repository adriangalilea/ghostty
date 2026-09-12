// macOS only: the iOS target shares this synchronized source group and has
// no reason to link answer channels for a terminal prompt.
#if os(macOS)
import AskKit
import AskListen
import AskNod
import AuthzClient
import AuthzProtocol
import Foundation
import Listen
import NodKit
import Say

/// Local speech/nod input for addressed authorization requests and form drafts.
/// authz.space owns decisions and receipts; AskKit owns capture and teardown.
/// Metadata is always instrumented. Content capture is an explicit local debug
/// option; secret-bearing requests never enter the content recorder.
enum VigilAsk {
    static let debugCaptureKey = "vigil.authz.debugCapture"
    private struct InputLog: Encodable {
        let requestID: String
        let revision: Int
        let epoch: String
        let nonce: String
        let pid: Int32
        let capture: Bool
        let input: AskDiagnostic
    }
    // Channel preferences are ask-core (AskSettings, one namespace every
    // host shares); vigil only reads them.
    static var nodEnabled: Bool { AskSettings.nod }
    static var voiceEnabled: Bool { AskSettings.voice }

    /// Whether each toggle should be offered at all. A toggle for a feature
    /// that cannot work is worse than no toggle, so the row hides rather
    /// than sits there failing.
    static var nodAvailable: Bool { MotionTap.ready }
    static var voiceAvailable: Bool { MicCapture.available }

    /// The pump's entry guard: at least one enabled channel could work.
    static var armed: Bool {
        AskSettings.enabled && ((nodEnabled && nodAvailable) || (voiceEnabled && voiceAvailable))
    }

    /// Audio-route diagnostics share the session manager's timeline.
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    private static var activePane: String?
    private static var activeHandle: Ask.Handle?
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
    /// Narration without a race: the request exists and is answered elsewhere
    /// (a manual-only surface). Says so once; never opens a channel that
    /// could not deliver the answer anyway.
    static func announce(_ text: String, pane: String) {
        guard AskSettings.enabled, armed else { return }
        trace?("ask announce \(pane): \(text)")
        Announcer.say(text, recording: false)
    }

    static func cancel(pane: String, reason: String = "superseded") {
        guard activePane == pane, let activeHandle else { return }
        Ask.cancel(activeHandle, reason: reason)
    }

    /// A begun ask that has not COMPLETED yet, teardown included: a
    /// cancelled ask stays in flight until its epilogue lands. The pump's
    /// begin guard - asking through it would land "busy".
    static var inFlight: Bool { Ask.isAsking }

    /// Completion follows channel teardown, so the next presentation can begin
    /// immediately. Request dictation returns a draft to the bound form.
    static func ask(
        _ spoken: String,
        detail: Ask.Detail? = nil,
        options: [String]? = nil,
        textOptions: Set<Int> = [],
        multi: Bool = false,
        request: RequestSnapshot,
        timeout: TimeInterval = 20,
        enterText: Bool = false,
        allowVoice: Bool = true,
        allowNod: Bool = true,
        completion: @escaping (Answer?, String) -> Void
    ) {
        let pane = request.request.context
        let recording = request.request.allowsDebugCapture(enabled: UserDefaults.standard.bool(forKey: debugCaptureKey))
        var sources: [any AnswerSource] = []
        if allowNod, nodEnabled, nodAvailable { sources.append(NodSource()) }
        if allowVoice, voiceEnabled, voiceAvailable {
            sources.append(
                VoiceSource(locales: VigilVoice.chosenLocales, sink: recording ? VoiceLogSink() : nil))
        }
        guard !sources.isEmpty else { return completion(nil, "unavailable") }
        guard !Ask.isAsking else { return completion(nil, "busy") }
        if !wired {
            wired = true
            Ask.trace = { line in trace?("ask \(line)") }
            VigilAskHUD.arm()
        }
        activePane = pane
        Flight.pane = pane
        // Safe wording comes from the requester. Raw inputs stay with it.
        activeHandle = Ask.begin(
            spoken, detail: detail, sources: sources, options: options,
            textOptions: textOptions, multi: multi,
            composition: Composition(input: spoken, tier: options == nil ? "static-gist" : "question-literal"),
            recording: recording,
            recordDictation: recording,
            diagnostics: { event in
                let row = InputLog(requestID: request.id, revision: request.handle.revision,
                    epoch: request.handle.serviceEpoch, nonce: request.handle.nonce,
                    pid: ProcessInfo.processInfo.processIdentifier, capture: recording, input: event)
                if let data = try? JSONEncoder().encode(row), let line = String(bytes: data, encoding: .utf8) {
                    trace?("authz input " + line)
                }
            },
            timeout: timeout,
            completion: { receipt in
            // Ask's completion runs on the main actor in the SAME turn that
            // flips it out of flight: cleanup and the caller's completion
            // are atomic against every other main-queue event. An async
            // re-hop here would open a window where a stale epilogue nulls
            // a successor ask's activePane, making its answered-elsewhere
            // cancel a no-op.
            MainActor.assumeIsolated {
                activePane = nil
                activeHandle = nil
                completion(receipt.verdict.answer, receipt.source ?? "surface")
            }
            })
        if enterText, let activeHandle { Ask.pick(activeHandle, 0, detail: "dictate-request-draft") }
    }
}
#endif
