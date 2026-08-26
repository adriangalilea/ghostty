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
/// is about the PRESENT). Ink's `LiveTranscript` owns the feel; this file
/// owns the PREVIEW POLICY for arbitrated runs: one recognizer per locale
/// emits interleaved previews, and the one shown is the locale that most
/// recently won a FINAL (the language being spoken), else the longest
/// current preview.
@MainActor
final class VigilDictationHUD {
    static let shared = VigilDictationHUD()

    private let model = LiveTranscriptModel()
    private var panel: NSPanel?
    private var previews: [String: String] = [:]
    private var stickyLocale: String?

    func begin() {
        model.reset()
        previews = [:]
        stickyLocale = nil
        let panel = self.panel ?? VigilHUDChrome.makePanel { LiveTranscript(model: model) }
        self.panel = panel
        VigilHUDChrome.position(panel)
        panel.orderFrontRegardless()
    }

    func preview(_ text: String, locale: String?) {
        // Once a final crowned a winner, the losers are SILENCED outright:
        // showing the losing recognizer's garbage because the winner is
        // momentarily quiet cluttered the screen with wrong-language wet
        // ink ("Elo,ó." over an English run, 2026-08-26). Before any
        // final, the longest preview speaks for the race.
        if let sticky = stickyLocale, let locale, locale != sticky { return }
        previews[locale ?? ""] = text
        let shown: (text: String, locale: String?)
        if let sticky = stickyLocale, let held = previews[sticky], !held.isEmpty {
            shown = (held, sticky)
        } else if let longest = previews.max(by: { $0.value.count < $1.value.count }) {
            shown = (longest.value, longest.key.isEmpty ? nil : longest.key)
        } else {
            return
        }
        model.preview(shown.text, locale: shown.locale)
    }

    func commit(_ text: String, locale: String?, confidence: Double?) {
        stickyLocale = locale
        // The final consumed every recognizer's in-progress guess.
        previews = [:]
        model.commit(text, locale: locale, confidence: confidence)
    }

    func end() {
        panel?.orderOut(nil)
    }
}
#endif
