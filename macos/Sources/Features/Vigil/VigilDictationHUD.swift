// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import Ink
import SwiftUI

/// Shared chrome for vigil's floating HUDs (dictation captions, the ask
/// prompt): a transparent click-through nonactivating panel - focus never
/// leaves the pane - whose VISIBLE shape is Ink's `hudGlass()` (Liquid
/// Glass) hugging the content at bottom-center, the native-dictation
/// position. The panel canvas is fixed; the glass grows and shrinks with
/// the words.
@MainActor
enum VigilHUDChrome {
    static let canvas = NSSize(width: 640, height: 220)

    static func makePanel<Content: View>(@ViewBuilder content: () -> Content) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView:
                content()
                .frame(maxWidth: 520, alignment: .leading)
                .hudGlass()
                .frame(
                    width: canvas.width, height: canvas.height, alignment: .bottom)
        )
        return panel
    }

    /// Bottom-center of the screen the human is working on, above the Dock.
    static func position(_ panel: NSPanel) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 56))
    }
}

/// The dictation captions: wet-ink volatiles drawn while they form, finals
/// crystallizing solid the instant they land in the pane, then fading like
/// captions (the words already live where they were written - the readout
/// is about the PRESENT). Ink's `LiveTranscript` owns the feel AND the
/// race policy (every candidate shown divided until a final crowns a
/// winner, losers silenced after, stale ink evaporating); this file only
/// forwards segments and owns the panel.
@MainActor
final class VigilDictationHUD {
    static let shared = VigilDictationHUD()

    private let model = LiveTranscriptModel()
    private var panel: NSPanel?

    func begin() {
        model.reset()
        let panel = self.panel ?? VigilHUDChrome.makePanel { LiveTranscript(model: model) }
        self.panel = panel
        VigilHUDChrome.position(panel)
        panel.orderFrontRegardless()
    }

    func preview(_ text: String, locale: String?) {
        model.preview(text, locale: locale)
    }

    func commit(_ text: String, locale: String?, confidence: Double?) {
        model.commit(text, locale: locale, confidence: confidence)
    }

    func end() {
        panel?.orderOut(nil)
    }
}
#endif
