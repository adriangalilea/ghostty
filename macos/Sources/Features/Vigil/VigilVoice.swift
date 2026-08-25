// macOS only: dictation binds to the fork's daemon panes.
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Ink
import Keymap
import Listen

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

    /// Dictation language: "auto" runs the candidate locales ARBITRATED -
    /// one recognizer each, per-utterance confidence verdict, the Spanglish
    /// answer ("Hola que tal" through the English model alone was
    /// "Oh, like it.") - or an explicit BCP-47 id for one recognizer. The
    /// sidebar mic button's context menu writes it.
    static let localeKey = "vigil.voice.locale"
    /// The arbitrated candidate set (comma-separated BCP-47).
    static let localesKey = "vigil.voice.locales"

    nonisolated static var candidateLocales: [Locale] {
        let stored = UserDefaults.standard.string(forKey: localesKey) ?? "es-ES, en-US"
        let ids = stored.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return ids.isEmpty ? [Locale.current] : ids.map(Locale.init(identifier:))
    }

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
        generation += 1
        let gen = generation
        onStateChange?()

        let preference = UserDefaults.standard.string(forKey: localeKey) ?? "auto"
        let identity = VigilSessionManager.shared.cortexIdentity(ofPane: pane)
        let locales = preference == "auto" ? candidateLocales : [Locale(identifier: preference)]
        var grounding = GroundingSet()
        if let keywords = identity?.keywords, !keywords.isEmpty {
            grounding[.session] = keywords
        }
        trace?(
            "voice: dictation -> \(pane)"
                + " locales=\(locales.map { $0.identifier(.bcp47) }.joined(separator: "+"))"
                + " grounding=\(grounding.totalCount) mic=\"\(MicCapture.inputName)\"")

        Task {
            do {
                // The grant precedes everything: an unauthorized engine
                // "runs" delivering zeros and MicCapture.start throws.
                // Generation-guarded teardown: a stale denial that raced a
                // stop + fresh start must not kill the successor's session.
                guard await MicCapture.requestAccess() else {
                    trace?("voice: microphone DENIED - System Settings > Privacy > Microphone")
                    if generation == gen { stop(reason: "mic denied") }
                    return
                }
                let session: any SpeechSession
                if locales.count > 1 {
                    var configuration = ArbitratedSession.Configuration(locales: locales)
                    configuration.grounding = grounding
                    configuration.sink = VoiceLogSink()
                    session = try await ArbitratedSession(configuration: configuration)
                } else {
                    var configuration = TranscriptionSession.Configuration(locale: locales[0])
                    configuration.fastResults = true
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
                Self.drain = Task {
                    do {
                        for try await segment in session.segments where segment.isFinal {
                            await Self.inject(segment.text, into: pane)
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
    private static func inject(_ text: String, into pane: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        DispatchQueue.main.async {
            VigilVoice.trace?(parts.joined(separator: " "))
        }
    }
}
#endif
