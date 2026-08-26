// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import AskKit
import Face
import SwiftUI

/// The ask prompt's face: Face's `AskPrompt` in Face's `FloatingHUD`,
/// driven entirely by `Ask.surface` events - every ask any consumer in
/// this process runs gets the same face for free. The panel lingers just
/// long enough to SHOW the verdict, then leaves.
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

    private func handle(_ event: Ask.SurfaceEvent) {
        model.handle(event)
        switch event {
        case .began:
            generation += 1
            let hud = self.hud ?? FloatingHUD { [model] in AskPrompt(model: model) }
            self.hud = hud
            hud.show()
        case .verdict:
            break
        case .ended:
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
