// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import AskKit
import Face
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
        case .began:
            generation += 1
            model.handle(event)
            let panel = self.panel ?? VigilHUDChrome.makePanel { AskPrompt(model: model) }
            self.panel = panel
            VigilHUDChrome.position(panel)
            panel.orderFrontRegardless()
        case .verdict:
            model.handle(event)
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
}
#endif
