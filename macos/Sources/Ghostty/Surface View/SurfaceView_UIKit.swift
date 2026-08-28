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
            // Born UNFOCUSED: focus follows first responder (tap). A surface
            // defaults to focused, and seven preview surfaces each blinking
            // a cursor and rendering at user-interactive QoS ran the phone
            // hot (2026-08-28).
            ghostty_surface_set_focus(surface, false)
            installScrollGesture()
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

        /// The keyboard comes on a TAP, never on a touch: a scroll must
        /// not raise it (real estate is the whole game on a phone).
        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            guard let surface = self.surface else { return }
            let p = g.location(in: self)
            ghostty_surface_mouse_pos(surface, p.x, p.y, GHOSTTY_MODS_NONE)
            if !isFirstResponder { _ = becomeFirstResponder() }
        }

        /// Touch scrolling with Apple's physics: an invisible UIScrollView
        /// OWNS the gesture (deceleration, momentum, rubber band, the exact
        /// feel of every native list), and each offset change becomes a
        /// precise wheel event in PIXELS (points × screen scale; feeding
        /// points into a 3× surface was the crawl). The offset is re-centered
        /// after every hand-off so the runway never ends.
        private var scroller: UIScrollView?
        private var lastOffset: CGPoint = .zero

        /// Zoom = ghostty's own font-size actions, the Mac's ⌘+/⌘−.
        func zoom(_ direction: Int) {
            guard let surface = self.surface else { return }
            let action = direction > 0 ? "increase_font_size:1" : direction < 0 ? "decrease_font_size:1" : "reset_font_size"
            let ok = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
            FileHandle.standardError.write(Data("vigil: zoom \(action) -> \(ok)\n".utf8))
        }
        private static let runway: CGFloat = 100_000

        func installScrollGesture() {
            let sv = UIScrollView(frame: bounds)
            sv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            sv.backgroundColor = .clear
            sv.showsVerticalScrollIndicator = false
            sv.showsHorizontalScrollIndicator = false
            sv.alwaysBounceVertical = true
            sv.contentInsetAdjustmentBehavior = .never
            sv.decelerationRate = .normal
            sv.delaysContentTouches = false
            sv.contentSize = CGSize(width: bounds.width, height: Self.runway * 2)
            sv.contentOffset = CGPoint(x: 0, y: Self.runway)
            sv.delegate = self
            lastOffset = sv.contentOffset
            addSubview(sv)
            scroller = sv
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            sv.addGestureRecognizer(tap)
        }

        fileprivate func scrollerMoved(_ sv: UIScrollView) {
            guard let surface = self.surface else { return }
            let dy = lastOffset.y - sv.contentOffset.y
            lastOffset = sv.contentOffset
            guard dy != 0 else { return }
            let scale = window?.screen.scale ?? contentScaleFactor
            // The core resolves scroll against the pointer: the finger is
            // the pointer, placed before every delta (without it nothing
            // moved, 2026-08-28).
            let p = sv.panGestureRecognizer.location(in: self)
            ghostty_surface_mouse_pos(surface, p.x, p.y, GHOSTTY_MODS_NONE)
            // mods bit 0 = precision (Ghostty.Input.ScrollMods' layout;
            // that file is macOS-only).
            ghostty_surface_mouse_scroll(surface, 0, Double(dy * scale), ghostty_input_scroll_mods_t(1))
        }

        fileprivate func scrollerSettled(_ sv: UIScrollView) {
            // Re-center silently so the next drag has runway both ways.
            let center = CGPoint(x: 0, y: Self.runway)
            sv.contentOffset = center
            lastOffset = center
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

        /// Vigil: render the terminal at `size / renderScale` and show it
        /// scaled by `renderScale` INSIDE this view's frame (a thumbnail of
        /// the owner's grid). The frame stays the thumbnail's real size, so
        /// the view never overlaps its neighbours (a SwiftUI scaleEffect
        /// only shrank the pixels; the full-size UIKit frame underneath ate
        /// taps on the rows around it, 2026-08-28). `anchorBottom` shows
        /// the bottom of the grid when it is taller than the frame.
        var renderScale: CGFloat = 1 { didSet { setNeedsLayout() } }
        var anchorBottom = false { didSet { setNeedsLayout() } }
        /// The grid the render layer is laid out at, in CELLS: the owner's
        /// grid, so the size reported to the core is exact pixels from its
        /// own cell metrics and the daemon never sees a different grid
        /// (points → cells rounding sent 114 for 118; a 1×1 placeholder
        /// while the metrics were unknown resized three of the Mac's ptys
        /// to 1×1, 2026-08-28). nil = the view's own frame.
        var renderGrid: (rows: Int, cols: Int)? { didSet { setNeedsLayout() } }
        /// The render grid in points, from the live cell size.
        var renderSize: CGSize? {
            guard let g = renderGrid else { return nil }
            let cell = liveCell
            guard cell.width > 0 else { return nil }
            return CGSize(width: CGFloat(g.cols) * cell.width, height: CGFloat(g.rows) * cell.height)
        }

        /// The thumbnail layout a preview row gave this view, kept while a
        /// pane screen borrows the surface full-size, restored on return
        /// (the row re-draws BEFORE the hand-back; without this the
        /// returned surface showed the empty top-left of a full grid: the
        /// gray thumbnails, 2026-08-28).
        var thumbnail: (grid: (rows: Int, cols: Int), scale: CGFloat)?
        func applyThumbnail() {
            guard let t = thumbnail else { return }
            renderGrid = t.grid
            renderScale = t.scale
            anchorBottom = true
        }

        /// Vigil: the cell size in POINTS, synchronously from the core
        /// (`ghostty_surface_size`; the published `cellSize` only arrives
        /// after a first real size, and a fit layout must know the cell
        /// BEFORE reporting any size, or the phone resizes the Mac's pty:
        /// a guessed cell size did, 95x126).
        var liveCell: CGSize {
            guard let surface = self.surface else { return .zero }
            let s = ghostty_surface_size(surface)
            guard s.cell_width_px > 0, s.cell_height_px > 0 else { return .zero }
            return CGSize(width: CGFloat(s.cell_width_px) / appliedScale, height: CGFloat(s.cell_height_px) / appliedScale)
        }
        /// The content scale the core currently has (the surface config's
        /// screen scale at birth, then whatever sizeDidChange applied).
        private var appliedScale: CGFloat = UIScreen.main.scale

        override func sizeDidChange(_ size: CGSize) {
            guard let surface = self.surface else { return }

            // Ghostty wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            // ONE scale for view, surface and the render sublayer: the
            // screen's. `contentScaleFactor` is 1 until the view joins a
            // window, and a size reported then rendered 1× into a 3× layer
            // (small and soft, 2026-08-28).
            // A thumbnail renders at 2× (it is shown scaled down; the
            // screen's 3× on a full grid was 2.25× the pixels for nothing).
            let screen = window?.screen.scale ?? UIScreen.main.scale
            let scale = renderGrid != nil ? min(2, screen) : screen
            contentScaleFactor = scale
            for sub in layer.sublayers ?? [] { sub.contentsScale = scale }
            ghostty_surface_set_content_scale(surface, scale, scale)
            appliedScale = scale
            let px: (w: UInt32, h: UInt32)
            if let g = renderGrid {
                // Exact pixels from the core's cell metrics AT THIS SCALE
                // (set just above): the grid the core derives is g, no
                // rounding. Unknown metrics = report nothing.
                let s = ghostty_surface_size(surface)
                guard s.cell_width_px > 0, s.cell_height_px > 0 else {
                    FileHandle.standardError.write(Data("vigil: size held, no cell metrics yet\n".utf8))
                    return
                }
                px = (UInt32(g.cols) * s.cell_width_px, UInt32(g.rows) * s.cell_height_px)
            } else {
                px = (UInt32(size.width * scale), UInt32(size.height * scale))
            }
            ghostty_surface_set_size(surface, px.w, px.h)
            var s = ghostty_surface_size(surface)
            if let g = renderGrid, Int(s.rows) != g.rows || Int(s.columns) != g.cols {
                // The core reserves its window padding: add the cells it
                // lost and set again, so the derived grid is exactly g.
                let w = px.w + UInt32(max(0, g.cols - Int(s.columns))) * s.cell_width_px
                let h = px.h + UInt32(max(0, g.rows - Int(s.rows))) * s.cell_height_px
                ghostty_surface_set_size(surface, w, h)
                s = ghostty_surface_size(surface)
            }
            FileHandle.standardError.write(Data("vigil: size \(px.w)x\(px.h)px scale \(scale) \(renderGrid.map { "fit \($0.rows)x\($0.cols)" } ?? "own") -> core \(s.rows)x\(s.columns)\n".utf8))
        }

        // MARK: UIView

        override class var layerClass: AnyClass {
            return CAMetalLayer.self
        }

        override func didMoveToWindow() {
            sizeDidChange(bounds.size)
        }

        /// libghostty renders into an IOSurfaceLayer it ADDS AS A SUBLAYER
        /// of this view's layer (iOS views cannot swap their layer). A
        /// sublayer has no frame until someone gives it one; without this,
        /// the renderer's `surfaceSize` read 0×0 bounds and drew nothing
        /// (the blank phone, 2026-08-28). Every layout pass sizes it to the
        /// view and reports the size to the surface.
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Fit: the layer is the grid in points at the applied scale.
            let logical: CGSize = {
                if let g = renderGrid, let surface = self.surface {
                    let s = ghostty_surface_size(surface)
                    if s.cell_width_px > 0 {
                        return CGSize(width: CGFloat(g.cols) * CGFloat(s.cell_width_px) / appliedScale,
                                      height: CGFloat(g.rows) * CGFloat(s.cell_height_px) / appliedScale)
                    }
                }
                return bounds.size
            }()
            for sub in layer.sublayers ?? [] where sub !== scroller?.layer {
                sub.anchorPoint = .zero
                sub.bounds = CGRect(origin: .zero, size: logical)
                sub.setAffineTransform(CGAffineTransform(scaleX: renderScale, y: renderScale))
                let shownHeight = logical.height * renderScale
                let y = anchorBottom ? bounds.height - shownHeight : 0
                sub.position = CGPoint(x: 0, y: y)
            }
            CATransaction.commit()
            scroller?.contentSize = CGSize(width: bounds.width, height: Self.runway * 2)
            sizeDidChange(bounds.size)
        }
    }
}

extension Ghostty.SurfaceView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollerMoved(scrollView) }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollerSettled(scrollView) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollerSettled(scrollView) }
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
