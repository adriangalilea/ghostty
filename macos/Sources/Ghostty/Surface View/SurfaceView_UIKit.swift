import SwiftUI
import GhosttyKit

extension Ghostty {
    /// The UIView implementation for a terminal surface.
    class SurfaceView: OSSurfaceView {
        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published private(set) var title: String = "👻"

        /// True when the bell is active. This is set inactive on focus or event.
        @Published var bell: Bool = false

        private(set) var _surface: ghostty_surface_t?

        override var surface: ghostty_surface_t? {
            _surface
        }

        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(id: uuid, frame: CGRect(x: 0, y: 0, width: 800, height: 600))

            // Setup our surface. This will also initialize all the terminal IO.
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            let surface = surface_cfg.withCValue(view: self) { surface_cfg_c in
                ghostty_surface_new(app, &surface_cfg_c)
            }
            guard let surface = surface else {
                // TODO
                return
            }
            self._surface = surface
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            guard let surface = self.surface else { return }
            ghostty_surface_free(surface)
        }

        /// Vigil: end the core surface NOW (the attach client closes, the
        /// daemon hands the pty size back), whoever still holds the view.
        func vigilDetach() {
            resignFirstResponder()
            guard let surface = _surface else { return }
            _surface = nil
            ghostty_surface_free(surface)
        }

        // MARK: Input

        /// Text or control bytes to the terminal, as a key event carrying
        /// text (the IME path the Mac uses): escapes, control chars and
        /// arrows all ride this.
        func sendKeys(_ text: String) {
            guard let surface = self.surface, !text.isEmpty else { return }
            var ev = ghostty_input_key_s()
            ev.action = GHOSTTY_ACTION_PRESS
            ev.mods = GHOSTTY_MODS_NONE
            ev.consumed_mods = GHOSTTY_MODS_NONE
            ev.keycode = 0
            ev.unshifted_codepoint = 0
            ev.composing = false
            text.withCString { ptr in
                ev.text = ptr
                _ = ghostty_surface_key(surface, ev)
            }
        }

        override var canBecomeFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { focusDidChange(true) }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { focusDidChange(false) }
            return ok
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            if !isFirstResponder { _ = becomeFirstResponder() }
        }

        /// Hardware keyboard: control combos and navigation keys become
        /// their bytes; everything else is the key's characters.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let key = press.key else { continue }
                if let bytes = Self.bytes(for: key) {
                    sendKeys(bytes)
                    handled = true
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }

        private static func bytes(for key: UIKey) -> String? {
            let mods = key.modifierFlags
            switch key.keyCode {
            case .keyboardEscape: return "\u{1b}"
            case .keyboardTab: return "\t"
            case .keyboardReturnOrEnter: return "\r"
            case .keyboardDeleteOrBackspace: return "\u{7f}"
            case .keyboardUpArrow: return "\u{1b}[A"
            case .keyboardDownArrow: return "\u{1b}[B"
            case .keyboardRightArrow: return "\u{1b}[C"
            case .keyboardLeftArrow: return "\u{1b}[D"
            default: break
            }
            if mods.contains(.control), let ch = key.charactersIgnoringModifiers.lowercased().unicodeScalars.first,
               ch.value >= 0x61, ch.value <= 0x7a {
                return String(UnicodeScalar(ch.value - 0x60)!)
            }
            if mods.contains(.command) { return nil }
            let text = key.characters
            return text.isEmpty ? nil : text
        }

        override func focusDidChange(_ focused: Bool) {
            guard let surface = self.surface else { return }
            ghostty_surface_set_focus(surface, focused)

            // On macOS 13+ we can store our continuous clock...
            if focused {
                focusInstant = ContinuousClock.now
            }
        }

        override func sizeDidChange(_ size: CGSize) {
            guard let surface = self.surface else { return }

            // Ghostty wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scale = self.contentScaleFactor
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(
                surface,
                UInt32(size.width * scale),
                UInt32(size.height * scale)
            )
        }

        // MARK: UIView

        override class var layerClass: AnyClass {
            return CAMetalLayer.self
        }

        override func didMoveToWindow() {
            sizeDidChange(frame.size)
        }
    }
}

/// The software keyboard types into the surface as text; delete is DEL.
/// Traits keep autocorrect and smart punctuation out of a terminal.
extension Ghostty.SurfaceView: UIKeyInput {
    var hasText: Bool { true }
    func insertText(_ text: String) { sendKeys(text) }
    func deleteBackward() { sendKeys("\u{7f}") }

    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}
