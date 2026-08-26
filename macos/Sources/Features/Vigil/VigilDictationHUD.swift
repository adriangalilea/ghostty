// macOS only: floats over the fork's windows.
#if os(macOS)
import AppKit
import Ink
import Say
import SwiftUI

/// Shared chrome for vigil's floating HUDs (dictation captions, the ask
/// prompt): a transparent nonactivating panel - focus never leaves the
/// pane - whose VISIBLE shape is Ink's `hudGlass()` (Liquid Glass) hugging
/// the content at bottom-center, the native-dictation position. The panel
/// canvas is fixed; the glass grows and shrinks with the words. Click-
/// through by default; a host that needs clicks (the editable captions)
/// flips `ignoresMouseEvents` while the pointer is over the glass.
@MainActor
enum VigilHUDChrome {
    static let canvas = NSSize(width: 640, height: 220)

    /// `onGlassFrame` reports the glass shape's frame in the canvas's
    /// SwiftUI coordinates (top-left origin) whenever it changes - the
    /// hover gate converts it to screen space.
    static func makePanel<Content: View>(
        onGlassFrame: ((CGRect) -> Void)? = nil, @ViewBuilder content: () -> Content
    ) -> NSPanel {
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
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    onGlassFrame?(frame)
                }
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

    /// A SwiftUI canvas frame (top-left origin) -> screen rect.
    static func screenRect(_ glass: CGRect, in panel: NSPanel) -> NSRect {
        let frame = panel.frame
        return NSRect(
            x: frame.minX + glass.minX, y: frame.minY + (frame.height - glass.maxY),
            width: glass.width, height: glass.height)
    }
}

/// The dictation captions, editable: wet-ink volatiles while they form,
/// finals crystallizing with an EDIT WINDOW (confident lines leave fast,
/// doubtful ones linger; hover stops the clock), and expiry is the moment
/// a line is injected into the pane - so the human can fix a line in
/// place, or pick one of the recognizer's alternatives, BEFORE it lands.
/// Every correction is ledgered (original vs corrected, locale,
/// confidence, alternatives) to `~/.local/state/senses/corrections.jsonl`
/// - the RLHF corpus for the personal lexicon and the composer's
/// distiller, gathered as a side effect of normal use. Ink's
/// `LiveTranscript` owns the feel and the race policy; this file owns the
/// panel, the hover gate, the language control, and the pane.
@MainActor
final class VigilDictationHUD: ObservableObject {
    static let shared = VigilDictationHUD()

    static let corrections = JsonlLedger(
        name: "corrections", envKey: "SENSES_CORRECTIONS_LEDGER")

    let model = LiveTranscriptModel()
    @Published var forcedLocale: String?

    private var panel: NSPanel?
    private var pane: String?
    private var closing = false
    private var hoverMonitors: [Any] = []
    private var hovering = false
    private var glassFrame = CGRect.zero

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
    }

    func begin(pane: String) {
        self.pane = pane
        closing = false
        model.reset()
        let panel =
            self.panel
            ?? VigilHUDChrome.makePanel(onGlassFrame: { [weak self] in self?.glassFrame = $0 }) {
                DictationHUDView(hud: VigilDictationHUD.shared)
            }
        self.panel = panel
        VigilHUDChrome.position(panel)
        panel.orderFrontRegardless()
        armHover()
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
    /// runs ONE recognizer - no race, no flip-flopping. Applies at the next
    /// dictation start; a live one restarts on its pane.
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
        disarmHover()
        panel?.orderOut(nil)
        model.reset()
    }

    // MARK: - Hover gate

    /// The panel is click-through until the pointer is over the glass;
    /// then it takes clicks and the model's clocks stop, so there is
    /// always time to edit. Global + local monitors: the pointer usually
    /// arrives from another app's window.
    private func armHover() {
        guard hoverMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
            hoverMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .mouseMoved,
            handler: { event in
                handler(event)
                return event
            })
        {
            hoverMonitors.append(local)
        }
    }

    private func disarmHover() {
        for monitor in hoverMonitors { NSEvent.removeMonitor(monitor) }
        hoverMonitors = []
        setHovering(false)
    }

    private func pointerMoved() {
        guard let panel, panel.isVisible, glassFrame != .zero else { return }
        let inside = VigilHUDChrome.screenRect(glassFrame, in: panel).insetBy(dx: -8, dy: -8)
            .contains(NSEvent.mouseLocation)
        setHovering(inside)
    }

    private func setHovering(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        panel?.ignoresMouseEvents = !on
        model.paused = on || model.editing != nil
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
