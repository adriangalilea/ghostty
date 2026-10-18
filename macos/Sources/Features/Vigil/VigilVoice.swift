// macOS only: dictation binds to the fork's daemon panes.
#if os(macOS)
import AppKit
import Ink
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
    /// Receipts land in the unified log's voice scope: "I spoke and
    /// nothing happened" vs "nothing fired" must be distinguishable from
    /// the log alone.
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
    /// tap-to-latch, the sidebar MicButton's gesture.
    static let talk: PushToTalk = {
        let talk = PushToTalk()
        talk.onChange = { engaged in
            if engaged { startFocused() } else { stop(reason: "released") }
        }
        return talk
    }()

    /// The Mac's one talk key, Caps Lock: Authz.app owns it (swift-utils'
    /// `CapsLockKey`, hold to talk, tap to latch, its light on while
    /// engaged) and posts its state on Listen's `TalkBus`. While it is
    /// engaged and no question or form claims the words, the focused pane
    /// takes dictation; its release, or a question starting to listen,
    /// stops it.
    static let hotkeyHint = "⇪"
    private static var bus: NSObjectProtocol?
    /// The running dictation was started by the key (so the key's release
    /// ends it; one started by the button is the button's).
    private static var byKey = false
    static func followTalkKey() {
        guard bus == nil else { return }
        bus = TalkBus.observe { state in
            let ours = state.engaged && state.claimedBy == nil
            if ours, !isActive {
                voiceLog.info("talk key engaged", ["latched": state.latched])
                byKey = true
                startFocused()
            } else if !ours, byKey {
                byKey = false
                stop(reason: state.engaged ? "the words are \(state.claimedBy ?? "")'s" : "talk key released")
            }
        }
    }

    /// The live spectrum the MicButton renders; flat while idle.
    static let spectrum = AudioSpectrum()

    private(set) static var activePane: String?
    static var isActive: Bool { activePane != nil }
    static var available: Bool { MicCapture.available }

    /// Listen's `Dictation`, the suite's one way to dictate (utter runs the
    /// same): one session per utterance, built ahead; a release flushes
    /// everything said and `.ended` says the utterance is over. Kept while
    /// its recipe holds (the languages, and the words: the pane's cortex
    /// keywords first, then the suite's `Vocabulary`).
    private static var dictation: Dictation?
    private static var builtFor: Recipe?
    private static var events: Task<Void, Never>?
    /// The utterance in flight (`Dictation.listen`'s number): its segments
    /// go to the HUD, its `.ended` closes the HUD's flow.
    private static var utterance: Int?
    private static var generation = 0

    struct Recipe: Equatable {
        let languages: [String]
        let words: [String]
    }

    /// Dictate into the focused pane; toggling while active stops. The
    /// focused pane is resolved at START and injection sticks to it - a
    /// focus change mid-dictation must not spray text into another pane.
    static func startFocused() {
        guard !isActive else { return }
        // The talk key is system-wide: with vigil inactive there is no key
        // window, so the target falls back to the last-main terminal - the
        // surface the human last worked in (the same resolution every other
        // inactive-app action uses).
        guard
            let surface = ((NSApp.keyWindow?.windowController as? TerminalController)
                ?? TerminalController.preferredParent)?.focusedSurface,
            let pane = surface.vigilAttachId
        else {
            voiceLog.warn("no focused pane to dictate into")
            talk.stop()
            return
        }
        start(pane: pane)
    }

    static func start(pane: String) {
        guard !isActive else { return }
        guard available else {
            voiceLog.warn("no microphone")
            return
        }
        activePane = pane
        generation += 1
        let gen = generation
        onStateChange?()

        // The pane's own proper nouns first (the 100-word cap keeps the
        // head of the list), then the suite's words.
        let keywords = VigilWorkspaces.shared.cortexIdentity(ofPane: pane)?.keywords ?? []
        let recipe = Recipe(languages: Languages.active, words: keywords + Vocabulary.words)

        Task {
            do {
                let dictation = try await ready(recipe)
                // Generation-guarded: a stop (or a fresh start) that came
                // while the session was being built wins.
                guard generation == gen, activePane == pane else { return }
                VigilDictationHUD.shared.begin(pane: pane)
                utterance = dictation.listen()
                voiceLog.info("dictation started", [
                    "pane": pane, "locales": dictation.locales.map { $0.identifier(.bcp47) },
                    "model": dictation.module.label, "words": recipe.words.count,
                    "words_applied": dictation.wordsApplied, "mic": MicCapture.inputName,
                ])
            } catch {
                voiceLog.error("dictation failed to start", ["err": "\(error)"])
                guard generation == gen else { return }
                stop(reason: "start failed")
            }
        }
    }

    /// The `Dictation` for `recipe`: the one already built when it holds,
    /// else a new one (the old one's last utterance still finishes).
    private static func ready(_ recipe: Recipe) async throws -> Dictation {
        if let dictation, builtFor == recipe { return dictation }
        if let old = dictation {
            dictation = nil
            builtFor = nil
            Task { await old.stop() }
        }
        let made = try await Dictation.start(
            locales: recipe.languages.map(Locale.init(identifier:)), words: recipe.words,
            spectrum: spectrum, sink: VoiceLogSink())
        for locale in made.skipped {
            voiceLog.warn("language skipped: its model is not installed", [
                "locale": locale.identifier(.bcp47), "model": made.module.label, "fix": "settings > Languages",
            ])
        }
        dictation = made
        builtFor = recipe
        events = Task {
            for await event in made.events { handle(event) }
        }
        return made
    }

    /// The utterance's events: wet ink and finals to the HUD (it holds each
    /// final through its edit window, injection at expiry), and its end
    /// closes the HUD's flow, after every final of the release has landed.
    private static func handle(_ event: Dictation.Event) {
        switch event {
        case .segment(let segment, let number):
            guard number == utterance else { return }
            if segment.isFinal {
                VigilDictationHUD.shared.commit(
                    segment.text, locale: segment.locale, confidence: segment.confidence,
                    alternatives: segment.alternatives)
            } else {
                VigilDictationHUD.shared.preview(segment.text, locale: segment.locale)
            }
        case .ended(let number):
            guard number == utterance else { return }
            utterance = nil
            spectrum.reset()
            VigilDictationHUD.shared.end()
        case .failed(let why, let number):
            voiceLog.error("dictation failed", ["err": why])
            guard number == utterance else { return }
            utterance = nil
            VigilDictationHUD.shared.end()
            stop(reason: "session error")
        }
    }

    /// The mic closes: what was said is finalized and still lands (the
    /// release's finals arrive before `.ended`), nothing said after it.
    static func stop(reason: String) {
        guard isActive else { return }
        voiceLog.info("dictation stopped", ["reason": reason])
        generation += 1
        activePane = nil
        if talk.engaged { talk.stop() }
        if let dictation, utterance != nil {
            Task { await dictation.pause() }
        } else {
            spectrum.reset()
            VigilDictationHUD.shared.end()
        }
        onStateChange?()
    }

    /// One finalized phrase -> raw keystrokes, trailing space so the next
    /// phrase (spoken or typed) lands a word apart. Never a newline.
    static func inject(_ text: String, into pane: String) {
        let clean = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: VigilWorkspaces.vigildBin)
        process.arguments = ["sendraw", pane, clean + " "]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
            voiceLog.info("injected", ["pane": pane, "chars": clean.count, "status": proc.terminationStatus])
        }
        do { try process.run() } catch {
            voiceLog.error("sendraw failed to launch", ["err": error])
        }
    }
}

/// Listen's instrumentation into the voice scope, one event per receipt.
struct VoiceLogSink: ListenSink {
    func emit(_ event: ListenEvent) {
        voiceLog.info("listen", [
            "kind": event.kind, "locale": event.locale, "elapsed": event.ms.map { Duration.milliseconds($0) },
            "confidence": event.confidence, "count": event.count, "note": event.note,
        ])
    }
}
#endif
