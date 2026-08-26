// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import AskKit
import Face
import SwiftUI

/// The ask prompt's face: Face's `AskPrompt` in Face's `FloatingHUD`,
/// driven entirely by `Ask.surface` events - every ask any consumer in
/// this process runs gets the same face for free, and the face ANSWERS:
/// hover the glass and the yes/no (or option) buttons click through,
/// y/n/1-9 answer, esc cancels - the `surface` channel racing nod and
/// voice, ledgered like them. The panel lingers just long enough to SHOW
/// the verdict, then leaves.
@MainActor
final class VigilAskHUD {
    static let shared = VigilAskHUD()

    private let model = AskPromptModel()
    private var hud: FloatingHUD?
    private var generation = 0

    /// Wire once at startup, beside Ask.trace. Nonisolated: callers sit
    /// off-main; the events hop home before touching the panel.
    nonisolated static func arm() {
        Ask.surface = { event in
            Task { @MainActor in shared.handle(event) }
        }
    }

    private func makeHUD() -> FloatingHUD {
        let hud = FloatingHUD(hoverAware: true) { [model] in
            AskPrompt(
                model: model,
                languages: LanguagePicker(
                    options: VigilVoice.candidateLocales.map { $0.identifier(.bcp47) },
                    selected: VigilDictationHUD.shared.forcedLocale,
                    onSelect: { VigilDictationHUD.shared.select(locale: $0) }))
        }
        hud.onKey = { [model] event in
            model.key(
                event.charactersIgnoringModifiers ?? "", escape: event.keyCode == 53,
                enter: event.keyCode == 36 || event.keyCode == 76)
        }
        return hud
    }

    private func handle(_ event: Ask.SurfaceEvent) {
        model.handle(event)
        switch event {
        case .began:
            generation += 1
            let hud = self.hud ?? makeHUD()
            self.hud = hud
            hud.show()
        case .stage(_, let stage):
            // The text stage owns the keyboard: the panel takes key focus
            // so the input's caret is live the instant it opens, and gives
            // it back when the options return.
            if case .entering = stage { hud?.focusForTyping() } else { hud?.releaseFocus() }
        case .levels, .heard, .picks, .deadline, .verdict:
            break
        case .ended:
            hud?.releaseFocus()
            generation += 1
            let gen = generation
            Task { [weak self] in
                // Long enough to SEE the verdict land; a new ask beginning
                // in the window keeps the panel.
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, self.generation == gen else { return }
                self.hud?.hide()
            }
        }
    }
}
#endif
