// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import Ink
import SwiftUI

/// The floating live-caption readout for dictation: wet-ink volatiles
/// drawn while they form, finals crystallizing solid the instant they
/// land in the pane, then fading like captions (the words already live
/// where they were written - the readout is about the PRESENT). Ink's
/// `LiveTranscript` owns the feel; this file owns the chrome (a
/// nonactivating click-through panel - focus never leaves the pane being
/// dictated into) and the PREVIEW POLICY for arbitrated runs: one
/// recognizer per locale emits interleaved previews, and the one shown is
/// the locale that most recently won a FINAL (the language being spoken),
/// else the longest current preview.
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
        show()
    }

    func preview(_ text: String, locale: String?) {
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

    // MARK: - Chrome

    private func show() {
        let panel = self.panel ?? build()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func build() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 108),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView:
                LiveTranscript(model: model, hint: "listening")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(width: 560, height: 108, alignment: .bottomLeading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        )
        return panel
    }

    /// Bottom-center of the screen the human is working on - the native
    /// dictation position, above the Dock, under the pane's text.
    private func position(_ panel: NSPanel) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 64))
    }
}
#endif
