// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import Face
import Say
import SwiftUI

/// The dictation captions, editable: Face's `LiveTranscript` in Face's
/// `FloatingHUD`. Finals crystallize with an EDIT WINDOW (confident lines
/// leave fast, doubtful ones linger; hover stops the clock), and expiry
/// is the moment a line is injected into the pane - so the human can fix
/// a line in place, or pick one of the recognizer's alternatives, BEFORE
/// it lands. Every correction is ledgered (original vs corrected,
/// locale, confidence, alternatives) to
/// `~/.local/state/senses/corrections.jsonl` - the RLHF corpus for the
/// personal lexicon and the composer's distiller, gathered as a side
/// effect of use. This file owns the pane, the ledger, and the language +
/// threshold persistence; Face owns everything the human sees.
@MainActor
final class VigilDictationHUD: ObservableObject {
    static let shared = VigilDictationHUD()

    static let corrections = JsonlLedger(
        name: "corrections", envKey: "SENSES_CORRECTIONS_LEDGER")
    static let doubtKey = "vigil.voice.doubtBelow"

    let model = LiveTranscriptModel()
    @Published var forcedLocale: String?

    private var hud: FloatingHUD?
    private var pane: String?
    private var closing = false

    private init() {
        model.onExpire = { [weak self] line in
            guard let pane = self?.pane else { return }
            VigilVoice.inject(line.text, into: pane)
        }
        model.onCorrection = { line in
            var row: [String: Any] = [
                "original": line.original,
                "corrected": line.text,
            ]
            row["locale"] = line.locale
            row["confidence"] = line.confidence
            if !line.alternatives.isEmpty { row["alternatives"] = line.alternatives }
            Self.corrections.append(row)
            VigilVoice.trace?(
                "voice: corrected \"\(line.original.prefix(40))\" -> \"\(line.text.prefix(40))\"")
        }
        model.onIdle = { [weak self] in
            guard let self, closing else { return }
            hide()
        }
        let preference = UserDefaults.standard.string(forKey: VigilVoice.localeKey) ?? "auto"
        forcedLocale = preference == "auto" ? nil : preference
        let doubt = UserDefaults.standard.double(forKey: Self.doubtKey)
        if doubt > 0 { model.doubtBelow = doubt }
        model.onDoubtChange = { value in
            UserDefaults.standard.set(value, forKey: Self.doubtKey)
            VigilVoice.trace?("voice: doubt threshold -> \(value)")
        }
    }

    func begin(pane: String) {
        self.pane = pane
        closing = false
        model.reset()
        if hud == nil {
            let hud = FloatingHUD(hoverAware: true) {
                DictationHUDView(hud: VigilDictationHUD.shared)
            }
            hud.onHover = { [weak self] on in
                guard let self else { return }
                model.paused = on || model.editing != nil
            }
            self.hud = hud
        }
        hud?.show()
    }

    func preview(_ text: String, locale: String?) {
        model.preview(text, locale: locale)
    }

    func commit(_ text: String, locale: String?, confidence: Double?, alternatives: [String]) {
        model.commit(text, locale: locale, confidence: confidence, alternatives: alternatives)
    }

    /// The mic closed. Lines still in their edit window stay on screen
    /// until they expire (or are sealed) - the panel leaves when idle.
    func end() {
        closing = true
        if model.committed.isEmpty && model.races.isEmpty { hide() }
    }

    /// The language control: Auto lets the race decide; a forced language
    /// runs ONE recognizer - no race, no flip-flopping. A live dictation
    /// restarts on its pane.
    func select(locale: String?) {
        forcedLocale = locale
        UserDefaults.standard.set(locale ?? "auto", forKey: VigilVoice.localeKey)
        VigilVoice.trace?("voice: language -> \(locale ?? "auto")")
        if let pane, VigilVoice.isActive {
            VigilVoice.stop(reason: "language changed")
            VigilVoice.start(pane: pane)
        }
    }

    private func hide() {
        hud?.hide()
        model.reset()
    }
}

private struct DictationHUDView: View {
    @ObservedObject var hud: VigilDictationHUD

    var body: some View {
        LiveTranscript(
            model: hud.model,
            languages: LanguagePicker(
                options: VigilVoice.candidateLocales.map { $0.identifier(.bcp47) },
                selected: hud.forcedLocale,
                onSelect: { hud.select(locale: $0) }))
    }
}
#endif
