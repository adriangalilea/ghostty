// macOS only: dictation binds to the fork's daemon panes.
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Ink
import Keymap
import Listen
import Say

/// Dictation as co-writing: speech lands in the focused pane's input line
/// exactly as if typed - `vigild sendraw`, NO Enter - so keyboard edits
/// interleave freely and the human submits. (`vigild send` auto-submits;
/// using it for prose is the stray-'1' class of bug.) Finalized phrases
/// only; the live transcription session carries the session cortex's
/// keywords as grounding.
@MainActor
enum VigilVoice {
    /// Receipts land in vigil.log: "I spoke and nothing happened" vs
    /// "nothing fired" must be distinguishable from the log alone.
    static var trace: ((String) -> Void)?
    /// Fires on start/stop so the status item can show the mic.
    static var onStateChange: (() -> Void)?

    /// The languages are the suite's (`Languages` in Say: the human's
    /// chosen set, a pin narrowing it to one). Several run ARBITRATED (one
    /// recognizer each, per-utterance confidence verdict, the Spanglish
    /// answer: one English recognizer alone mangles Spanish); one runs a
    /// single recognizer with no race at all. Vigil holds no language of
    /// its own; the footer's picker and the settings editor write the
    /// suite's keys.

    /// THE interaction state machine (swift-utils Ink): hold-to-talk or
    /// tap-to-latch, shared by the sidebar MicButton's gesture and the
    /// global hotkey below.
    static let talk: PushToTalk = {
        let talk = PushToTalk()
        talk.onChange = { engaged in
            if engaged { startFocused() } else { stop(reason: "released") }
        }
        return talk
    }()

    /// ^⌥M system-wide, with Carbon's release event so a held key IS
    /// push-to-talk. Registration failure (combo owned elsewhere) traces.
    static let hotkeyHint = "⌃⌥M"
    private static var hotkey: PressReleaseHotkey?
    static func armHotkey() {
        guard hotkey == nil else { return }
        hotkey = PressReleaseHotkey(
            keyCode: 46, carbonModifiers: UInt32(controlKey | optionKey),
            onPress: { talk.pressBegan() },
            onRelease: { talk.pressEnded() })
        if hotkey?.registered != true {
            trace?("voice: hotkey \(hotkeyHint) not registered (owned elsewhere)")
        }
    }

    /// The live spectrum the MicButton renders; flat while idle.
    static let spectrum = AudioSpectrum()

    private(set) static var activePane: String?
    static var isActive: Bool { activePane != nil }
    static var available: Bool { MicCapture.available }

    private static var subscription: MicTap.Subscription?
    private static var session: (any SpeechSession)?
    private static var drain: Task<Void, Never>?
    private static var generation = 0

    /// Dictate into the focused pane; toggling while active stops. The
    /// focused pane is resolved at START and injection sticks to it - a
    /// focus change mid-dictation must not spray text into another pane.
    static func startFocused() {
        guard !isActive else { return }
        // ⌃⌥M is system-wide: with Ghostty inactive there is no key window,
        // so the target falls back to the last-main terminal - the surface
        // the human last worked in (the same resolution every other
        // inactive-app action uses).
        guard
            let surface = ((NSApp.keyWindow?.windowController as? TerminalController)
                ?? TerminalController.preferredParent)?.focusedSurface,
            let pane = surface.vigilAttachId
        else {
            trace?("voice: no focused vigil pane to dictate into")
            talk.stop()
            return
        }
        start(pane: pane)
    }

    static func start(pane: String) {
        guard !isActive else { return }
        guard available else {
            trace?("voice: no microphone")
            return
        }
        activePane = pane
        // Recognition is shared; submission is not. Terminal dictation must
        // not simultaneously answer the authorization prompt it interrupted.
        VigilHarnessCoordinator.shared.pauseForTerminalDictation()
        generation += 1
        let gen = generation
        onStateChange?()

        let identity = VigilSessionManager.shared.cortexIdentity(ofPane: pane)
        let wanted = Languages.activeLocales
        var grounding = GroundingSet()
        if let keywords = identity?.keywords, !keywords.isEmpty {
            grounding[.session] = keywords
        }

        Task {
            do {
                while VigilAsk.inFlight {
                    try await Task.sleep(for: .milliseconds(50))
                    guard generation == gen, activePane == pane else { return }
                }
                // The grant precedes everything: an unauthorized engine
                // "runs" delivering zeros and MicCapture.start throws.
                // Generation-guarded teardown: a stale denial that raced a
                // stop + fresh start must not kill the successor's session.
                guard await MicCapture.requestAccess() else {
                    trace?("voice: microphone DENIED - System Settings > Privacy > Microphone")
                    if generation == gen { stop(reason: "mic denied") }
                    return
                }
                // Only a language whose model is on disk can listen: a
                // chosen one without its model is skipped with a receipt,
                // never handed to a session that would fail at its first
                // word (a recipient's dictation "initiated then stopped"
                // on a Spanish model his Mac never had, 2026-09-15).
                var locales: [Locale] = []
                for locale in wanted {
                    if let ready = try? await AssetStore.resolveInstalled(locale) {
                        locales.append(ready)
                    } else {
                        trace?("voice: \(locale.identifier(.bcp47)) has no speech model installed, skipped (ask settings > Languages)")
                    }
                }
                guard !locales.isEmpty else {
                    trace?("voice: no installed model for \(wanted.map { $0.identifier(.bcp47) }.joined(separator: "+")) - download one in ask settings > Languages")
                    if generation == gen { stop(reason: "no language model") }
                    return
                }
                trace?(
                    "voice: dictation -> \(pane)"
                        + " locales=\(locales.map { $0.identifier(.bcp47) }.joined(separator: "+"))"
                        + " grounding=\(grounding.totalCount) mic=\"\(MicCapture.inputName)\"")
                // Volatiles feed the floating HUD (wet-ink preview); only
                // FINALS ever reach the pane.
                let session: any SpeechSession
                if locales.count > 1 {
                    var configuration = ArbitratedSession.Configuration(locales: locales)
                    configuration.grounding = grounding
                    configuration.volatileResults = true
                    configuration.reportAlternatives = true
                    configuration.sink = VoiceLogSink()
                    session = try await ArbitratedSession(configuration: configuration)
                } else {
                    var configuration = TranscriptionSession.Configuration(locale: locales[0])
                    configuration.fastResults = true
                    configuration.volatileResults = true
                    configuration.reportAlternatives = true
                    configuration.grounding = grounding
                    configuration.sink = VoiceLogSink()
                    session = try await TranscriptionSession(configuration: configuration)
                }
                guard generation == gen, activePane == pane else {
                    await session.finish()
                    return
                }
                Self.session = session
                // The shared warm tap: consecutive dictations (and the ask
                // gate) reuse one hot voice-processed engine instead of
                // paying VPIO construction per start. Its receipts sink has
                // ONE owner, wired at startup with the traces - never here.
                Self.subscription = try MicTap.shared.subscribe { buffer in
                    session.feed(buffer)
                    spectrum.ingest(buffer)
                }
                trace?(
                    "voice: capture voiceProcessed=\(MicTap.shared.voiceProcessed)"
                        + " (OS AEC \(MicTap.shared.voiceProcessed ? "on - self-audio subtracted" : "OFF"))"
                )
                VigilDictationHUD.shared.begin(pane: pane)
                Self.drain = Task {
                    do {
                        for try await segment in session.segments {
                            if segment.isFinal {
                                // The HUD holds the line through its edit
                                // window; injection happens at expiry (or
                                // when the human seals a correction).
                                await MainActor.run {
                                    VigilDictationHUD.shared.commit(
                                        segment.text, locale: segment.locale,
                                        confidence: segment.confidence,
                                        alternatives: segment.alternatives)
                                }
                            } else {
                                await MainActor.run {
                                    VigilDictationHUD.shared.preview(
                                        segment.text, locale: segment.locale)
                                }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            // A mid-stream failure tears down through the ONE
                            // path: a mic left hot with a claimed floor and a
                            // lit glyph is a lying UI. Generation-guarded - a
                            // deliberate stop that raced this error already
                            // tore down a successor's session.
                            guard generation == gen else { return }
                            stop(reason: "session error: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                trace?("voice: session failed to start: \(error)")
                // Generation-guarded like the drain's error path: a stale
                // failure must not null a successor's activePane. stop() is
                // the ONE teardown - it finishes a session a subscribe
                // failure left behind, unlatches push-to-talk, and re-pumps
                // the deferred ask gate.
                guard generation == gen else { return }
                stop(reason: "start failed")
            }
        }
    }

    static func stop(reason: String) {
        guard isActive else { return }
        trace?("voice: dictation stopped (\(reason))")
        generation += 1
        activePane = nil
        VigilDictationHUD.shared.end()
        spectrum.reset()
        if talk.engaged { talk.stop() }
        subscription?.cancel()
        subscription = nil
        let session = self.session
        self.session = nil
        drain = nil
        if let session {
            Task { await session.finish() }
        }
        onStateChange?()
        // The ask gate defers while dictation owns the voice channel;
        // stopping IS its re-arm event (the gate polls nothing).
        VigilSessionManager.shared.pumpAskGate()
    }

    /// One finalized phrase -> raw keystrokes, trailing space so the next
    /// phrase (spoken or typed) lands a word apart. Never a newline.
    static func inject(_ text: String, into pane: String) {
        let clean = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: VigilSessionManager.vigildBin)
        process.arguments = ["sendraw", pane, clean + " "]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                trace?(
                    "voice: injected \(clean.count) chars -> \(pane)"
                        + " exit=\(proc.terminationStatus)")
            }
        }
        do { try process.run() } catch {
            trace?("voice: sendraw failed to launch: \(error.localizedDescription)")
        }
    }
}

/// Listen instrumentation into vigil.log with a stable prefix.
struct VoiceLogSink: ListenSink {
    func emit(_ event: ListenEvent) {
        var parts = ["voice:", event.kind]
        if let ms = event.ms { parts.append(String(format: "%.0fms", ms)) }
        if let confidence = event.confidence {
            parts.append(String(format: "conf=%.2f", confidence))
        }
        if let count = event.count { parts.append("n=\(count)") }
        if let note = event.note { parts.append(note) }
        DispatchQueue.main.async {
            VigilVoice.trace?(parts.joined(separator: " "))
        }
    }
}
#endif
