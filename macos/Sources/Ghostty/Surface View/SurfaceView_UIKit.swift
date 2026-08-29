import SwiftUI
import GhosttyKit

extension Ghostty {
    /// The UIView for a terminal surface on the phone: libghostty's Metal
    /// terminal, attached to a vigild pane over the app's transport.
    ///
    /// Four facts about a surface are FOUR properties here, never
    /// inferred from one another (the phone's whole first day of bugs was
    /// one bit standing in for all of them):
    ///  - `presentation`: how the grid is shown (which grid, at what
    ///    content scale, scaled by how much, anchored where);
    ///  - `attended`: the terminal has the user's attention (cursor,
    ///    focus events); set by the screen that shows it;
    ///  - `keyboardWanted`: the software keyboard is up; a tap wants it,
    ///    the strip's hide button and iOS's own dismissal drop it;
    ///  - size ownership: an explicit `claimSize` (the surface is born
    ///    with `vigil_explicit_claim`; focus never claims).
    ///
    /// Layout is ONE authority: `layoutSubviews` computes the framebuffer
    /// from the presentation and reports it to the core only when it
    /// changed. SwiftUI hands this view a frame and nothing else.
    class SurfaceView: OSSurfaceView {
        // MARK: Receipts

        /// Every fact this view learns or decides goes through here; the
        /// app routes it to its receipts (stderr over the cable, os_log,
        /// the in-app list).
        static var trace: (String) -> Void = { FileHandle.standardError.write(Data("vigil: \($0)\n".utf8)) }
        private func receipt(_ line: String) { Self.trace("surface \(paneId): \(line)") }
        /// The pane this surface shows, for receipts.
        private(set) var paneId: String = "?"

        @Published var title: String = "👻"
        @Published var bell: Bool = false
        /// The stream ended (EOF from the daemon or the transport).
        @Published private(set) var ended: (exitCode: Int, runtimeMs: Int)?

        private(set) var _surface: ghostty_surface_t?
        override var surface: ghostty_surface_t? { _surface }

        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            // A non-zero initial frame so the render layer is never 0×0.
            super.init(id: uuid, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            paneId = surface_cfg.vigilAttach ?? "local"
            let surface = surface_cfg.withCValue(view: self) { surface_cfg_c in
                ghostty_surface_new(app, &surface_cfg_c)
            }
            guard let surface else {
                receipt("ghostty_surface_new FAILED")
                return
            }
            _surface = surface
            // Born unfocused and unclaimed: a screen decides both.
            ghostty_surface_set_focus(surface, false)
            proxy.owner = self
            addSubview(proxy)
            installScrollGesture()
            receipt("born (explicit claim \(surface_cfg.vigilExplicitClaim))")
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            guard let surface = _surface else { return }
            ghostty_surface_free(surface)
        }

        /// End the core surface NOW (the attach client closes; the daemon
        /// hands the pty size on if this client owned it), whoever still
        /// holds the view.
        func detach() {
            keyboardWanted = false
            if isFirstResponder { _ = resignFirstResponder() }
            guard let surface = _surface else { return }
            _surface = nil
            ghostty_surface_free(surface)
            receipt("detached")
        }

        // MARK: Presentation

        struct Grid: Equatable {
            let rows: Int
            let cols: Int
        }

        /// How the grid is shown. `grid` nil = the view's own frame is the
        /// terminal (own-size). `contentScale` 0 = the display's scale.
        /// `scale` is a picture scale applied AFTER rendering (a
        /// thumbnail, a fit); `anchorBottom` shows the grid's bottom when
        /// it is taller than the frame (a terminal's action is at the
        /// bottom).
        struct Presentation: Equatable {
            var grid: Grid?
            var contentScale: CGFloat = 0
            var scale: CGFloat = 1
            var anchorBottom = false

            static let own = Presentation()
        }

        private(set) var presentation: Presentation = .own {
            didSet { if presentation != oldValue { setNeedsLayout() } }
        }

        func present(_ p: Presentation) { presentation = p }

        /// The content scale the presentation asks for, resolved.
        private var wantedScale: CGFloat {
            let display = window?.screen.scale ?? traitCollection.displayScale
            return presentation.contentScale > 0 ? presentation.contentScale : display
        }

        /// The content scale the core currently has (the surface config's
        /// screen scale at birth, then whatever `syncScale` applied).
        private var appliedScale: CGFloat = UIScreen.main.scale

        /// Make the core's content scale the wanted one; idempotent.
        @discardableResult
        private func syncScale() -> CGFloat {
            let scale = wantedScale
            guard let surface, scale != appliedScale else { return scale }
            ghostty_surface_set_content_scale(surface, scale, scale)
            appliedScale = scale
            contentScaleFactor = scale
            receipt("content scale \(scale)")
            return scale
        }

        /// Framebuffer pixels for the presentation at the applied scale:
        /// the core's own answer for a grid (`ghostty_surface_size_for_grid`,
        /// cell metrics + explicit padding), the frame for own-size.
        private func framebuffer(scale: CGFloat) -> (w: UInt32, h: UInt32)? {
            guard let surface else { return nil }
            if let g = presentation.grid {
                let s = ghostty_surface_size_for_grid(surface, UInt16(g.rows), UInt16(g.cols))
                guard s.cell_width_px > 0, s.cell_height_px > 0 else { return nil }
                return (s.width_px, s.height_px)
            }
            let w = UInt32(bounds.width * scale), h = UInt32(bounds.height * scale)
            return w > 0 && h > 0 ? (w, h) : nil
        }

        /// The picture's size in points as presented (grid pixels at the
        /// wanted scale, times the picture scale): the ONE number SwiftUI
        /// frames are derived from. nil for own-size or unknown metrics.
        var presentedSize: CGSize? {
            guard presentation.grid != nil else { return nil }
            let scale = syncScale()
            guard let px = framebuffer(scale: scale) else { return nil }
            return CGSize(width: CGFloat(px.w) / scale * presentation.scale,
                          height: CGFloat(px.h) / scale * presentation.scale)
        }

        /// The cell size in POINTS at the applied scale, synchronously from
        /// the core.
        var liveCell: CGSize {
            guard let surface else { return .zero }
            let s = ghostty_surface_size(surface)
            guard s.cell_width_px > 0, s.cell_height_px > 0 else { return .zero }
            return CGSize(width: CGFloat(s.cell_width_px) / appliedScale, height: CGFloat(s.cell_height_px) / appliedScale)
        }

        // MARK: Facts set by the screen

        /// The terminal has the user's attention: cursor, focus events.
        var attended = false {
            didSet {
                guard attended != oldValue, let surface else { return }
                ghostty_surface_set_focus(surface, attended)
                receipt("attended \(attended)")
                syncResponder()
            }
        }

        /// On screen: the renderer runs; off screen it idles (occlusion).
        var visible = true {
            didSet {
                guard visible != oldValue, let surface else { return }
                ghostty_surface_set_occlusion(surface, visible)
                receipt("visible \(visible)")
            }
        }

        /// Claim (true) or yield (false) the daemon's pty size. Only an
        /// own-size viewport claims; a fit viewport mirrors the owner.
        func claimSize(_ claim: Bool) {
            guard let surface else { return }
            ghostty_surface_vigil_claim(surface, claim)
            receipt(claim ? "claimed the pty size" : "yielded the pty size")
        }

        /// The content receipt: FNV-1a of the viewport's plain text, hex,
        /// comparable to the daemon's `screen` in `vigild dir`.
        var screenHash: String {
            guard let surface else { return "" }
            return String(ghostty_surface_vigil_screen_hash(surface), radix: 16)
        }
        var screenSeen = ""
        var screenStrikes = 0
        var screenProven = false
        var screenResyncs = 0

        /// Re-request the screen (the app was suspended and missed the
        /// stream).
        func refreshFromDaemon() {
            guard let surface else { return }
            ghostty_surface_vigil_dump(surface)
            receipt("dump requested")
        }

        // MARK: Keyboard

        /// The software keyboard is up. Raised by a tap, dropped by the
        /// strip's hide button or by iOS dismissing it (the proxy resigns
        /// and reports). The terminal's focus does not move with it.
        @Published var keyboardWanted = false {
            didSet {
                guard keyboardWanted != oldValue else { return }
                receipt("keyboard wanted \(keyboardWanted)")
                syncResponder()
            }
        }

        /// The strip that rides the keyboard (esc, ctrl, arrows…).
        var accessory: UIView? {
            didSet {
                proxy.accessory = accessory
                if proxy.isFirstResponder { proxy.reloadInputViews() }
            }
        }

        /// The keyboard's responder: a UIKeyInput child. The surface
        /// itself is a plain first responder (hardware keys, no software
        /// keyboard) whenever the keyboard is not wanted.
        private let proxy = KeyboardProxy()

        override var canBecomeFirstResponder: Bool { true }

        private func syncResponder() {
            guard window != nil else { return }
            if keyboardWanted {
                if !proxy.isFirstResponder { _ = proxy.becomeFirstResponder() }
            } else {
                if proxy.isFirstResponder { _ = proxy.resignFirstResponder() }
                if attended, !isFirstResponder { _ = becomeFirstResponder() }
            }
        }

        /// iOS took the keyboard down (interactive dismissal, a sheet, a
        /// hardware keyboard): the fact follows.
        fileprivate func keyboardProxyResigned() {
            guard keyboardWanted else { return }
            receipt("keyboard dismissed by the system")
            keyboardWanted = false
        }

        final class KeyboardProxy: UIView, UIKeyInput {
            weak var owner: SurfaceView?
            var accessory: UIView?
            override var canBecomeFirstResponder: Bool { true }
            override var inputAccessoryView: UIView? { accessory }
            override func resignFirstResponder() -> Bool {
                let ok = super.resignFirstResponder()
                if ok { DispatchQueue.main.async { [weak self] in self?.owner?.keyboardProxyResigned() } }
                return ok
            }

            var hasText: Bool { true }
            func insertText(_ text: String) { owner?.typed(text) }
            func deleteBackward() { owner?.sendKeys("\u{7f}") }

            var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
            var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
            var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
            var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
            var smartDashesType: UITextSmartDashesType { get { .no } set {} }
            var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
            var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
        }

        // MARK: Input

        /// Text or control bytes to the terminal, as a key event carrying
        /// text (the IME path the Mac uses): escapes, control chars and
        /// arrows all ride this.
        func sendKeys(_ text: String) {
            guard let surface, !text.isEmpty else { return }
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

        /// The strip's ctrl is a sticky modifier for the next typed letter.
        var stickyControl = false

        /// Text from the software keyboard.
        func typed(_ text: String) {
            if stickyControl, let ch = text.lowercased().unicodeScalars.first, ch.value >= 0x61, ch.value <= 0x7a, text.count == 1 {
                stickyControl = false
                sendKeys(String(UnicodeScalar(ch.value - 0x60)!))
                return
            }
            sendKeys(text)
        }

        /// A tap places the pointer and wants the keyboard; a scroll
        /// never does (real estate is the whole game on a phone).
        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            guard let surface else { return }
            let p = g.location(in: self)
            ghostty_surface_mouse_pos(surface, p.x, p.y, GHOSTTY_MODS_NONE)
            receipt("tap at \(Int(p.x)),\(Int(p.y))")
            keyboardWanted = true
        }

        /// Hardware keyboard (reaches here from the proxy through the
        /// responder chain, or directly while no keyboard is up): control
        /// combos and navigation keys become their bytes; everything else
        /// is the key's characters.
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

        /// Zoom = ghostty's own font-size actions (own-size mode; a fit
        /// viewport zooms its picture instead).
        func zoom(_ direction: Int) {
            guard let surface else { return }
            let action = direction > 0 ? "increase_font_size:1" : direction < 0 ? "decrease_font_size:1" : "reset_font_size"
            let ok = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
            receipt("zoom \(action) -> \(ok)")
        }

        // MARK: Scroll: a UIScrollView as the physics engine

        /// Touch scrolling with Apple's physics: an invisible UIScrollView
        /// OWNS the one-finger gesture (deceleration, momentum, rubber
        /// band), and each offset change becomes a precise wheel event in
        /// PIXELS at the finger, re-centered on an endless runway after
        /// every hand-off.
        private var scroller: UIScrollView?
        private var lastOffset: CGPoint = .zero
        private static let runway: CGFloat = 100_000

        private func installScrollGesture() {
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
            sv.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }

        fileprivate func scrollerMoved(_ sv: UIScrollView) {
            guard let surface else { return }
            // Only the finger (or its momentum) is a scroll: a programmatic
            // offset (the re-center, a frame change, a content-size reset)
            // also fires didScroll, and a runway-sized delta sent the
            // terminal to the top on its own (2026-08-29).
            guard sv.isDragging || sv.isDecelerating else { lastOffset = sv.contentOffset; return }
            let dy = lastOffset.y - sv.contentOffset.y
            lastOffset = sv.contentOffset
            guard dy != 0 else { return }
            scrollReceipts += 1
            if scrollReceipts % 20 == 1 { receipt("scroll dy \(Int(dy))pt (finger)") }
            // The core resolves scroll against the pointer: the finger is
            // the pointer, placed before every delta.
            let p = sv.panGestureRecognizer.location(in: self)
            ghostty_surface_mouse_pos(surface, p.x, p.y, GHOSTTY_MODS_NONE)
            // mods bit 0 = precision (Ghostty.Input.ScrollMods' layout).
            ghostty_surface_mouse_scroll(surface, 0, Double(dy * appliedScale), ghostty_input_scroll_mods_t(1))
        }

        private var scrollReceipts = 0

        fileprivate func scrollerSettled(_ sv: UIScrollView) {
            let center = CGPoint(x: 0, y: Self.runway)
            lastOffset = center
            sv.contentOffset = center
        }

        // MARK: Facts from the core

        override func focusDidChange(_ focused: Bool) {}

        /// The core's cell metrics changed (font set, font size changed):
        /// every fit layout depends on them.
        func cellMetricsDidChange(px: CGSize) {
            cellSize = CGSize(width: px.width / appliedScale, height: px.height / appliedScale)
            receipt("cell \(Int(px.width))x\(Int(px.height))px")
            setNeedsLayout()
        }

        /// The owner's hook: a dead stream is the transport's fact, the
        /// app decides (re-dial, drop).
        var onStreamEnd: (() -> Void)?

        func streamDidEnd(exitCode: Int, runtimeMs: Int) {
            ended = (exitCode, runtimeMs)
            receipt("stream ended exit \(exitCode) after \(runtimeMs)ms")
            onStreamEnd?()
        }

        // MARK: Layout: the ONE authority

        override class var layerClass: AnyClass { CAMetalLayer.self }

        private var lastReport: (w: UInt32, h: UInt32, scale: CGFloat)?
        private var lastMirrorGrid: Grid?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
            syncResponder()
        }

        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            if previous?.displayScale != traitCollection.displayScale { setNeedsLayout() }
        }

        /// libghostty renders into an IOSurfaceLayer it ADDS AS A SUBLAYER
        /// of this view's layer (iOS views cannot swap their layer). Every
        /// layout pass: sync the content scale, compute the framebuffer
        /// from the presentation, report it to the core iff it changed,
        /// and frame the render sublayer as the picture (bounds = the grid
        /// in points, an affine picture scale, anchored top or bottom).
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let surface, window != nil else { return }
            let scale = syncScale()
            guard let px = framebuffer(scale: scale) else {
                receipt("size held: no cell metrics yet")
                return
            }
            let changed = lastReport.map { $0.w != px.w || $0.h != px.h || $0.scale != scale } ?? true
            if changed {
                ghostty_surface_set_size(surface, px.w, px.h)
                lastReport = (px.w, px.h, scale)
                let s = ghostty_surface_size(surface)
                let mode = presentation.grid.map { "fit \($0.rows)x\($0.cols)" } ?? "own"
                receipt("size \(px.w)x\(px.h)px @\(scale) \(mode) x\(presentation.scale) -> core \(s.rows)x\(s.columns)")
                // A mirror that just took a NEW owner grid holds bytes
                // parsed at the old one, reflowed: garbage. Re-sync from
                // the daemon (only a claimant is dumped otherwise).
                if let g = presentation.grid, g != lastMirrorGrid {
                    if lastMirrorGrid != nil { ghostty_surface_vigil_dump(surface); receipt("grid changed, dump requested") }
                    lastMirrorGrid = g
                }
            }
            let logical = CGSize(width: CGFloat(px.w) / scale, height: CGFloat(px.h) / scale)
            let mine = Set(subviews.map { ObjectIdentifier($0.layer) })
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sub in layer.sublayers ?? [] where !mine.contains(ObjectIdentifier(sub)) {
                sub.contentsScale = scale
                sub.anchorPoint = .zero
                sub.bounds = CGRect(origin: .zero, size: logical)
                sub.setAffineTransform(CGAffineTransform(scaleX: presentation.scale, y: presentation.scale))
                let shown = logical.height * presentation.scale
                sub.position = CGPoint(x: 0, y: presentation.anchorBottom ? bounds.height - shown : 0)
            }
            CATransaction.commit()
            scroller?.contentSize = CGSize(width: bounds.width, height: Self.runway * 2)
        }

        override func sizeDidChange(_ size: CGSize) { setNeedsLayout() }
    }
}

extension Ghostty.SurfaceView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollerMoved(scrollView) }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollerSettled(scrollView) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollerSettled(scrollView) }
    }
}
