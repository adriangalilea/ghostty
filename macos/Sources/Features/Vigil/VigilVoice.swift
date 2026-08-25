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
/// keywords as grounding and its language leaning as the locale.
@MainActor
enum VigilVoice {
    /// Receipts land in vigil.log: "I spoke and nothing happened" vs
    /// "nothing fired" must be distinguishable from the log alone.
    static var trace: ((String) -> Void)?
    /// Fires on start/stop so the status item can show the mic.
    static var onStateChange: (() -> Void)?

    /// Dictation language: "auto" (the session cortex's leaning, else the
    /// system) or an explicit BCP-47 id - the sidebar mic button's context
    /// menu writes it.
    static let localeKey = "vigil.voice.locale"

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

    private static var mic: MicCapture?
    private static var session: TranscriptionSession?
    private static var drain: Task<Void, Never>?
    private static var generation = 0

    /// Dictate into the focused pane; toggling while active stops. The
    /// focused pane is resolved at START and injection sticks to it - a
    /// focus change mid-dictation must not spray text into another pane.
    static func startFocused() {
        guard !isActive else { return }
        guard
            let surface = (NSApp.keyWindow?.windowController as? TerminalController)?
                .focusedSurface,
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
        var locale = Locale.current
        if preference == "auto" {
            if let lang = identity?.lang, lang == "es" || lang == "en" {
                locale = Locale(identifier: lang == "es" ? "es-ES" : "en-US")
            }
        } else {
            locale = Locale(identifier: preference)
        }
        var grounding = GroundingSet()
        if let keywords = identity?.keywords, !keywords.isEmpty {
            grounding[.session] = keywords
        }
        trace?(
            "voice: dictation -> \(pane) locale=\(locale.identifier(.bcp47))"
                + " grounding=\(grounding.totalCount) mic=\"\(MicCapture.inputName)\"")

        Task {
            do {
                var configuration = TranscriptionSession.Configuration(locale: locale)
                configuration.volatileResults = false
                configuration.fastResults = true
                configuration.grounding = grounding
                configuration.sink = VoiceLogSink()
                let session = try await TranscriptionSession(configuration: configuration)
                let mic = MicCapture()
                guard generation == gen, activePane == pane else {
                    await session.finish()
                    return
                }
                Self.session = session
                Self.mic = mic
                try mic.start { buffer in
                    session.feed(buffer)
                    spectrum.ingest(buffer)
                }
                Self.drain = Task {
                    do {
                        for try await segment in session.segments where segment.isFinal {
                            await Self.inject(segment.text, into: pane)
                        }
                    } catch {
                        await MainActor.run {
                            trace?("voice: session error \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                trace?("voice: session failed to start: \(error)")
                activePane = nil
                onStateChange?()
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
        mic?.stop()
        mic = nil
        let session = self.session
        self.session = nil
        drain = nil
        if let session {
            Task { await session.finish() }
        }
        onStateChange?()
    }

    /// One finalized phrase -> raw keystrokes, trailing space so the next
    /// phrase (spoken or typed) lands a word apart. Never a newline.
    private static func inject(_ text: String, into pane: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let vigild = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/vigild").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: vigild)
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
private struct VoiceLogSink: ListenSink {
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
