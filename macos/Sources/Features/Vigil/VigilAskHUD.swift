// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import AskKit
import Ink
import SwiftUI

/// The ask prompt's face: the question, the channels actually listening
/// ("voice · nod" - only the reachable ones), and the verdict
/// crystallizing in place - Ink's `AskPrompt` in the shared HUD chrome.
/// Driven entirely by `Ask.surface` events, so every ask any consumer in
/// this process runs gets the same face for free; the panel lingers just
/// long enough to SHOW the verdict, then leaves.
@MainActor
final class VigilAskHUD {
    static let shared = VigilAskHUD()

    private let model = AskPromptModel()
    private var panel: NSPanel?
    private var generation = 0

    /// Wire once at startup, beside Ask.trace. Nonisolated: callers sit
    /// off-main; the events hop home before touching the panel.
    nonisolated static func arm() {
        Ask.surface = { event in
            Task { @MainActor in shared.handle(event) }
        }
    }

    private func handle(_ event: Ask.SurfaceEvent) {
        switch event {
        case .began(_, let spoken, let channels):
            generation += 1
            model.ask(spoken, channels: channels)
            let panel = self.panel ?? VigilHUDChrome.makePanel { AskPrompt(model: model) }
            self.panel = panel
            VigilHUDChrome.position(panel)
            panel.orderFrontRegardless()
        case .verdict(_, let label, let answered, let source, let confidence):
            model.resolve(
                Self.word(label: label, answered: answered), decided: answered,
                source: source, confidence: confidence)
        case .ended:
            generation += 1
            let gen = generation
            Task { [weak self] in
                // Long enough to SEE the verdict land; a new ask beginning
                // in the window keeps the panel.
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, self.generation == gen else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// The verdict word the human reads: answers in the human's register,
    /// everything undecided stays the ledger label ("timeout",
    /// "superseded" - true and self-explaining).
    private static func word(label: String, answered: Bool) -> String {
        guard answered else { return label }
        switch label {
        case "allow": return "yes"
        case "deny": return "no"
        default:
            if label.hasPrefix("chose-") { return String(label.dropFirst("chose-".count)) }
            return label
        }
    }
}
#endif
