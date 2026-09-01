import SwiftUI
import GhosttyKit

/// The phone's screens: ONE home tree (Macs → sessions → tabs → panes,
/// collapsible, the sidebar's rollup dots on every folded row) and a pane,
/// full screen. The pane IS a Ghostty surface (Metal, the Mac's renderer)
/// attached through ssh; the model owns every surface, the screens borrow.
///
/// Patterns, named once here and referenced below:
///  - HOSTING: a representable's container `addSubview`s the model's
///    UIView in `updateUIView` and removes it in `dismantleUIView`. A
///    UIView has one superview, so the screen that updates last holds it;
///    the row re-hosts on its next update (it reads `model.presenting`).
///  - LAYOUT AUTHORITY: the container's bounds decide the presentation
///    (fit factor); the surface view's own layout pass reports pixels to
///    the core. SwiftUI hands out frames, nothing else.
///  - KEYBOARD AS A FACT: `KeyboardState` reads iOS's keyboard frame
///    notifications; the terminal area is the window minus that inset.
///    Focus never moves with the keyboard.
///  - ACCESSORY: the key strip is the keyboard's `inputAccessoryView`; it
///    comes and goes with the keyboard by construction.
///  - PICTURE ZOOM: a fit viewport is a UIScrollView zooming its content
///    (pinch, two-finger pan, the loupe sets `zoomScale`); one finger
///    stays the terminal's own scroll.
struct VigilPhoneRoot: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @StateObject private var model = VigilPhone.shared
    @State private var path: [PaneRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
        }
        .environmentObject(model)
        // vigil://<host>/<session>/<pane>: an alert's landing.
        .onOpenURL { url in
            Task { @MainActor in
                if let ref = await model.resolve(url: url) { path = [ref] }
            }
        }
        .onAppear { model.startDiscovery() }
    }
}

// MARK: - Home: the tree

struct HomeView: View {
    @EnvironmentObject private var model: VigilPhone
    @EnvironmentObject private var ghostty: Ghostty.App
    @State private var adding = false
    @State private var settings = false

    var body: some View {
        let tree = model.tree()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if tree.isEmpty {
                    ContentUnavailableView("No Macs yet", systemImage: "desktopcomputer",
                                           description: Text("Add one with +, then enrol this phone's key (⚙︎)."))
                        .padding(.top, 80)
                }
                ForEach(tree) { node in
                    TreeNodeView(node: node, depth: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(ghostty.config.backgroundColor).ignoresSafeArea())
        .navigationTitle("vigil")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: PaneRef.self) { ref in PaneScreen(ref: ref) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "gearshape") }
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $adding) { AddHostView() }
        .sheet(isPresented: $settings) { SettingsView() }
        .refreshable { model.refreshAll() }
        .onAppear { model.refreshAll() }
    }
}

/// One row of the tree and, unfolded, its children. Chevron folds; the
/// row body opens a pane. A folded row wears its cluster.
struct TreeNodeView: View {
    let node: VigilPhone.Node
    let depth: Int
    @EnvironmentObject private var model: VigilPhone

    private var folded: Bool { model.collapsed.contains(node.id) }
    private var foldable: Bool { !node.children.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if let ref = node.pane, node.rows > 0, node.cols > 0 {
                NavigationLink(value: ref) {
                    PanePreview(ref: ref, grid: .init(rows: node.rows, cols: node.cols))
                        .padding(.leading, CGFloat(depth) * 18 + 24)
                        .padding(.trailing, 8)
                        .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { model.log("tap: preview \(node.title) (\(ref.pane))") })
            }
            if foldable && !folded {
                ForEach(node.children) { child in
                    TreeNodeView(node: child, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder private var row: some View {
        let content = HStack(spacing: 8) {
            Spacer().frame(width: CGFloat(depth) * 18)
            if foldable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
            } else {
                Spacer().frame(width: 16)
            }
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let e = node.emoji { Text(e) }
                    Text(node.title)
                        .font(font)
                        .foregroundStyle(node.alive ? .primary : .secondary)
                        .lineLimit(1)
                }
                if let sub = node.subtitle {
                    Text(sub).font(.caption2)
                        .foregroundStyle(sub.hasPrefix("connecting") ? .secondary : Color.orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if node.kind == .pane && !node.alive {
                Text("not running").font(.caption2).foregroundStyle(.tertiary)
            }
            cluster
        }
        .padding(.vertical, node.kind == .host ? 8 : 6)
        .padding(.horizontal, 8)
        .background(node.kind == .host ? Color.secondary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())

        if let ref = node.pane {
            NavigationLink(value: ref) { content.frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { model.log("tap: row \(node.title) (\(ref.pane))") })
        } else {
            content.onTapGesture { if foldable { toggle() } }
        }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) {
            if folded { model.collapsed.remove(node.id) } else { model.collapsed.insert(node.id) }
        }
    }

    private var font: Font {
        switch node.kind {
        case .host: return .headline
        case .session: return .body.weight(.semibold)
        case .tab: return .subheadline
        case .pane: return .body
        }
    }

    @ViewBuilder private var icon: some View {
        switch node.kind {
        case .host: Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
        case .session: EmptyView()
        case .tab: Image(systemName: "rectangle.on.rectangle").font(.caption).foregroundStyle(.secondary)
        case .pane: Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// dot = agent state. A pane shows its own; a folded node its
    /// descendants' cluster; an unfolded node nothing (its children speak).
    @ViewBuilder private var cluster: some View {
        let states: [String] = node.kind == .pane || folded ? node.cluster : []
        HStack(spacing: 4) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                Circle().fill(StateColor.of(s, alive: true)).frame(width: 8, height: 8)
            }
        }
        .frame(minWidth: 8)
    }
}

enum StateColor {
    static func of(_ state: String?, alive: Bool) -> Color {
        guard alive else { return .gray.opacity(0.3) }
        switch state {
        case "blocked": return .orange
        case "working": return .yellow
        case "done": return .teal
        default: return .gray
        }
    }
}

// MARK: - Hosting (pattern: HOSTING + LAYOUT AUTHORITY)

/// The container a surface view lives in while a screen shows it. Its
/// layout pass decides the presentation from ITS bounds (the fit factor
/// is a function of the space given), then the surface's own layout
/// reports pixels to the core.
final class SurfaceHostView: UIView {
    var presentation: ((Ghostty.SurfaceView, CGSize) -> Ghostty.SurfaceView.Presentation)?
    let purpose: String
    init(purpose: String) {
        self.purpose = purpose
        super.init(frame: .zero)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    var hosted: Ghostty.SurfaceView? { subviews.first as? Ghostty.SurfaceView }

    func host(_ view: Ghostty.SurfaceView) {
        guard view.superview !== self else { return }
        addSubview(view)
        view.frame = bounds
        Ghostty.SurfaceView.trace("surface \(view.paneId): hosted by \(purpose)")
    }

    func unhost() {
        guard let view = hosted else { return }
        view.removeFromSuperview()
        Ghostty.SurfaceView.trace("surface \(view.paneId): left \(purpose)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let view = hosted else { return }
        view.frame = bounds
        if let presentation { view.present(presentation(view, bounds.size)) }
    }
}

/// A surface in a SwiftUI frame: a thumbnail row or an own-size screen.
struct SurfaceHost: UIViewRepresentable {
    let view: Ghostty.SurfaceView
    let purpose: String
    let interactive: Bool
    let visible: Bool
    let presentation: (Ghostty.SurfaceView, CGSize) -> Ghostty.SurfaceView.Presentation

    func makeUIView(context: Context) -> SurfaceHostView { SurfaceHostView(purpose: purpose) }

    func updateUIView(_ container: SurfaceHostView, context: Context) {
        // A host that is not the presenter keeps its hands off: a tree
        // refresh re-ran a row's update while the pane screen showed the
        // view and the row stole it back (the gray OWN screen, 2026-08-29).
        guard visible else { return }
        container.host(view)
        container.presentation = presentation
        view.isUserInteractionEnabled = interactive
        view.visible = true
        container.setNeedsLayout()
    }

    static func dismantleUIView(_ container: SurfaceHostView, coordinator: ()) {
        container.unhost()
    }
}

/// A surface's natural picture size for a grid at a content scale
/// (before any fit): the core's pixels, in points.
private func naturalSize(_ view: Ghostty.SurfaceView, grid: Ghostty.SurfaceView.Grid, contentScale: CGFloat) -> CGSize? {
    view.present(.init(grid: grid, contentScale: contentScale, scale: 1))
    return view.presentedSize
}

// MARK: - Preview row

/// A LIVE thumbnail of a pane: the same surface the pane screen shows,
/// laid out at the OWNER's grid and scaled into the row, bottom-anchored
/// (a terminal's action is at the bottom). Rendered at 2× (shown scaled
/// down; the screen's 3× on a full grid was 2.25× the pixels for nothing).
struct PanePreview: View {
    let ref: PaneRef
    let grid: Ghostty.SurfaceView.Grid
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var model: VigilPhone
    @State private var surfaceView: Ghostty.SurfaceView?
    @State private var denied = false

    private let height: CGFloat = 150

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(ghostty.config.backgroundColor)
            if let surfaceView {
                SurfaceHost(view: surfaceView, purpose: "row \(ref.pane)", interactive: false,
                            visible: model.presenting == nil) { view, bounds in
                    // Readable, never shrunk below 0.8: a wide grid shows its
                    // bottom-left window, clipped, rather than the whole grid
                    // at half size (unreadable).
                    let natural = naturalSize(view, grid: grid, contentScale: 2)
                    let scale = natural.map { min(1, max(0.8, bounds.width / $0.width)) } ?? 1
                    return .init(grid: grid, contentScale: 2, scale: scale, anchorBottom: true)
                }
            } else if denied {
                Text("preview limit").font(.caption2).foregroundStyle(.tertiary).padding(6)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        .task { await load() }
        .onChange(of: model.streamGeneration) { _, _ in
            guard surfaceView?.surface == nil else { return }
            surfaceView = nil
            Task { await load() }
        }
        .onAppear { model.rowAppeared(ref) }
        .onDisappear { model.rowDisappeared(ref) }
    }

    private func load() async {
        guard let app = ghostty.app else { return }
        do {
            guard let view = try await model.surface(for: ref, app: app, screen: false) else { denied = true; return }
            surfaceView = view
        } catch {
            model.log("preview: \(ref.pane) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Keyboard (pattern: KEYBOARD AS A FACT)

/// The software keyboard's overlap with the window, from iOS's own
/// notifications. The ONLY source of "is the keyboard up, how tall".
@MainActor
final class KeyboardState: ObservableObject {
    static let shared = KeyboardState()
    @Published private(set) var inset: CGFloat = 0

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.frameChanged(n) }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(0, "hide") }
        }
    }

    private func frameChanged(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let local = window.convert(end, from: nil)
        set(max(0, window.bounds.maxY - local.minY), "frame \(Int(end.height))pt")
    }

    private func set(_ value: CGFloat, _ why: String) {
        guard value != inset else { return }
        inset = value
        Ghostty.SurfaceView.trace("keyboard: inset \(Int(value))pt (\(why))")
    }
}

/// esc / tab / ctrl / arrows / ⌃C / paste: the keys a software keyboard
/// hides. Rides the keyboard as its accessory (pattern: ACCESSORY).
struct KeyStrip: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    @State private var ctrl = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { surface.keyboardWanted = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                }
                key("esc", "\u{1b}")
                key("tab", "\t")
                Button {
                    ctrl.toggle()
                    surface.stickyControl = ctrl
                } label: {
                    Text("ctrl").font(.caption.monospaced())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(ctrl ? Color.accentColor : Color.secondary.opacity(0.2), in: Capsule())
                }
                key("^C", "\u{03}")
                key("^D", "\u{04}")
                key("^Z", "\u{1a}")
                key("←", "\u{1b}[D"); key("↓", "\u{1b}[B"); key("↑", "\u{1b}[A"); key("→", "\u{1b}[C")
                key("⏎", "\r")
                key("/", "/"); key("-", "-"); key("|", "|"); key("~", "~")
                Button {
                    surface.pasteClipboard()
                } label: { Image(systemName: "doc.on.clipboard").padding(.horizontal, 10).padding(.vertical, 6) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
        .onChange(of: surface.keyboardWanted) { _, up in if !up { ctrl = false; surface.stickyControl = false } }
    }

    private func key(_ label: String, _ keys: String) -> some View {
        Button {
            surface.sendKeys(keys)
            if ctrl { ctrl = false; surface.stickyControl = false }
        } label: {
            Text(label).font(.caption.monospaced())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.2), in: Capsule())
        }
    }
}

/// The strip as a UIKit accessory view (one per surface on screen).
private func makeAccessory(for surface: Ghostty.SurfaceView) -> UIView {
    let host = UIHostingController(rootView: KeyStrip(surface: surface))
    host.view.backgroundColor = .clear
    host.safeAreaRegions = []
    host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
    host.view.autoresizingMask = .flexibleWidth
    return host.view
}

// MARK: - Fit viewport (pattern: PICTURE ZOOM)

/// The Mac's grid as a picture: fitted to the space, pinch-zoomable,
/// two-finger pannable, the loupe driving `zoom`. One finger is the
/// terminal's (its own scroll engine sits inside).
struct FitCanvas: UIViewRepresentable {
    let view: Ghostty.SurfaceView
    let grid: Ghostty.SurfaceView.Grid
    @Binding var zoom: CGFloat

    /// The fit is computed in ITS layout pass (the bounds are a fact
    /// there; in `updateUIView` they are 0 on the first pass and nothing
    /// re-runs it, the blank fit screen of 2026-08-29).
    final class ZoomView: UIScrollView {
        let content = SurfaceHostView(purpose: "fit screen")
        var grid: Ghostty.SurfaceView.Grid?
        private var fitted: (bounds: CGSize, natural: CGSize)?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let grid, let view = content.hosted, bounds.width > 0, bounds.height > 0 else { return }
            let contentScale = window?.screen.scale ?? traitCollection.displayScale
            guard let natural = naturalSize(view, grid: grid, contentScale: contentScale), natural.width > 0 else { return }
            if let f = fitted, f.bounds == bounds.size, f.natural == natural { return }
            fitted = (bounds.size, natural)
            let fit = min(bounds.width / natural.width, bounds.height / natural.height, 1)
            let presented = CGSize(width: natural.width * fit, height: natural.height * fit)
            content.presentation = { _, _ in .init(grid: grid, contentScale: contentScale, scale: fit) }
            content.frame = CGRect(origin: .zero, size: presented)
            contentSize = presented
            center()
            Ghostty.SurfaceView.trace("surface \(view.paneId): fit x\(String(format: "%.2f", fit)) -> \(Int(presented.width))x\(Int(presented.height))pt in \(Int(bounds.width))x\(Int(bounds.height))")
        }

        /// Keep the picture centered while it is smaller than the viewport.
        func center() {
            let w = contentSize.width * zoomScale, h = contentSize.height * zoomScale
            let dx = max(0, (bounds.width - w) / 2), dy = max(0, (bounds.height - h) / 2)
            contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }
    }

    func makeUIView(context: Context) -> ZoomView {
        let sv = ZoomView()
        // The margin around the Mac's picture is the transparency
        // CHECKER: inside is the Mac's grid, the checker is the phone
        // accommodating it.
        sv.backgroundColor = UIColor(patternImage: VigilTheme.checker(scale: sv.traitCollection.displayScale))
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 4
        sv.bouncesZoom = true
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.delaysContentTouches = false
        sv.panGestureRecognizer.minimumNumberOfTouches = 2
        sv.delegate = context.coordinator
        sv.addSubview(sv.content)
        return sv
    }

    func updateUIView(_ sv: ZoomView, context: Context) {
        sv.content.host(view)
        view.isUserInteractionEnabled = true
        view.visible = true
        sv.grid = grid
        sv.setNeedsLayout()
        if abs(sv.zoomScale - zoom) > 0.01 { sv.setZoomScale(zoom, animated: true) }
    }

    static func dismantleUIView(_ sv: ZoomView, coordinator: Coordinator) {
        sv.content.unhost()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: FitCanvas
        init(_ parent: FitCanvas) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomView)?.content }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? ZoomView)?.center() }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            Ghostty.SurfaceView.trace("fit: zoom x\(String(format: "%.2f", scale))")
            DispatchQueue.main.async { self.parent.zoom = scale }
        }
    }
}

// MARK: - Pane screen

/// One pane, full screen. FIT (default): the Mac's grid as a picture,
/// no reflow, the Mac untouched, the phone never owns the pty. OWN: the
/// phone's grid; the surface claims the pty, the pane reflows, the Mac
/// follows while it is open, yielded on leave.
struct PaneScreen: View {
    let ref: PaneRef
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var model: VigilPhone
    @ObservedObject private var keyboard = KeyboardState.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var surfaceView: Ghostty.SurfaceView?
    @State private var current: PaneRef
    @State private var error: String?
    @State private var ownSize = false
    @State private var fitZoom: CGFloat = 1

    init(ref: PaneRef) {
        self.ref = ref
        _current = State(initialValue: ref)
    }

    private var node: VigilPhone.Node? { model.node(for: current) }
    /// The owner's grid for the current pane, if the Mac published one.
    private var grid: Ghostty.SurfaceView.Grid? {
        guard let n = node, n.rows > 0, n.cols > 0 else { return nil }
        return .init(rows: n.rows, cols: n.cols)
    }
    private var fits: Bool { !ownSize && grid != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(ghostty.config.backgroundColor)
                if let surfaceView {
                    if let grid, fits {
                        FitCanvas(view: surfaceView, grid: grid, zoom: $fitZoom)
                    } else {
                        SurfaceHost(view: surfaceView, purpose: "own screen", interactive: true, visible: true) { _, _ in .own }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.orange).padding()
                } else {
                    ProgressView("attaching…")
                }
            }
            // The terminal area is the window minus the keyboard, applied
            // as a fact (no SwiftUI keyboard avoidance, no animation race).
            .frame(width: geo.size.width, height: max(0, geo.size.height - keyboard.inset), alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .ignoresSafeArea(.keyboard)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(current.title).font(.headline)
                    HStack(spacing: 4) {
                        Circle().fill(StateColor.of(node?.state, alive: node?.alive ?? true)).frame(width: 6, height: 6)
                        Text("\(current.host.name) · \(model.sessionTitle(for: current))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let surfaceView { KeyboardButton(surface: surfaceView) }
                if grid != nil {
                    // MIRROR: a picture of the Mac's grid, the Mac untouched.
                    // OWN: the phone is the terminal, the pane reflows to it.
                    // Same footprint either way: a Mac glyph (you are
                    // looking at the Mac's screen) vs a phone glyph (the
                    // phone is the terminal).
                    Button { setOwnSize(!ownSize) } label: {
                        Image(systemName: ownSize ? "iphone" : "desktopcomputer")
                    }
                }
                Button { zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                Menu {
                    ForEach(model.livePanes(on: current.host).filter { $0.ref != current }) { other in
                        Button { switchTo(other.ref) } label: {
                            Label("\(other.session) \(other.ref.title)", systemImage: "terminal")
                        }
                    }
                } label: { Image(systemName: "rectangle.stack") }
            }
        }
        .task { await enter(current) }
        .onChange(of: model.streamGeneration) { _, _ in
            guard surfaceView?.surface == nil else { return }
            model.log("pane: \(current.pane) stream died on screen, re-dialing")
            leave()
            error = nil
            Task { await enter(current) }
        }
        .onDisappear { leave(); model.present(nil) }
        // Phase is a fact, ownership follows it: a backgrounded or locked
        // phone yields the pty (the Mac takes over as survivor); coming
        // back re-claims in OWN and re-requests the screen it missed.
        .onChange(of: phase) { _, now in
            guard let view = surfaceView else { return }
            switch now {
            case .background, .inactive:
                model.log("pane: \(current.pane) phase \(now), yielding")
                view.keyboardWanted = false
                if ownSize || grid == nil { view.claimSize(false) }
            case .active:
                model.log("pane: \(current.pane) active again")
                if ownSize || grid == nil { view.claimSize(true) }
                view.refreshFromDaemon()
            @unknown default: break
            }
        }
    }

    private func enter(_ ref: PaneRef) async {
        model.present(ref)
        model.log("pane: screen \(ref.pane)")
        guard let app = ghostty.app else { error = "ghostty not ready"; return }
        do {
            guard let view = try await model.surface(for: ref, app: app, screen: true) else { error = "no surface"; return }
            view.accessory = makeAccessory(for: view)
            view.attended = true
            if ownSize || grid == nil { view.claimSize(true) }
            surfaceView = view
        } catch {
            self.error = error.localizedDescription
            model.log("attach: \(ref.pane) failed: \(error.localizedDescription)")
        }
    }

    private func leave() {
        guard let view = surfaceView else { return }
        if ownSize || grid == nil { view.claimSize(false) }
        view.keyboardWanted = false
        view.attended = false
        view.accessory = nil
        surfaceView = nil
    }

    private func switchTo(_ other: PaneRef) {
        leave()
        current = other
        fitZoom = 1
        Task { await enter(other) }
    }

    private func setOwnSize(_ own: Bool) {
        guard own != ownSize, let view = surfaceView else { return }
        ownSize = own
        fitZoom = 1
        view.claimSize(own)
        model.log("pane: \(current.pane) \(own ? "own size (claims the pty)" : "fit (mirrors the owner)")")
    }

    private func zoom(_ direction: Int) {
        if fits {
            fitZoom = min(4, max(1, fitZoom * (direction > 0 ? 1.25 : 1 / 1.25)))
        } else {
            surfaceView?.zoom(direction)
        }
    }
}

/// Keyboard up/down, from the surface's own fact.
struct KeyboardButton: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    var body: some View {
        Button { surface.keyboardWanted.toggle() } label: {
            Image(systemName: surface.keyboardWanted ? "keyboard.chevron.compact.down" : "keyboard")
        }
    }
}

// MARK: - Sheets

/// Add a Mac, or edit one (`editing`): the same form.
struct AddHostView: View {
    var editing: VigilPhone.Host? = nil
    @EnvironmentObject private var model: VigilPhone
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var user = ""

    init(editing: VigilPhone.Host? = nil) {
        self.editing = editing
        if let h = editing {
            _name = State(initialValue: h.name)
            _hostname = State(initialValue: h.hostname)
            _port = State(initialValue: String(h.port))
            _user = State(initialValue: h.user)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !model.discovered.isEmpty {
                    Section("On this network") {
                        ForEach(model.discovered) { mac in
                            Button {
                                name = mac.name
                                hostname = mac.hostname
                            } label: {
                                Label(mac.name, systemImage: "desktopcomputer")
                            }
                        }
                    }
                }
                Section {
                    TextField("Name", text: $name)
                    TextField("Host or IP", text: $hostname).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("User", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("A .local name follows the Mac onto any network you share with it. An IP is for a fixed address (your VPN).")
                }
            }
            .navigationTitle(editing == nil ? "Add Mac" : "Edit Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let host = VigilPhone.Host(id: editing?.id ?? UUID(),
                                                   name: name.isEmpty ? hostname : name, hostname: hostname,
                                                   port: Int(port) ?? 22, user: user)
                        if let i = model.hosts.firstIndex(where: { $0.id == host.id }) {
                            model.hosts[i] = host
                        } else {
                            model.hosts.append(host)
                        }
                        dismiss()
                    }
                    .disabled(hostname.isEmpty || user.isEmpty)
                }
            }
        }
    }
}

/// Macs (edit, forget host key, remove), this phone's key, receipts.
struct SettingsView: View {
    @EnvironmentObject private var model: VigilPhone
    @Environment(\.dismiss) private var dismiss
    @State private var editing: VigilPhone.Host?

    var body: some View {
        NavigationStack {
            List {
                Section("Macs") {
                    ForEach(model.hosts) { host in
                        Button { editing = host } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(host.name).font(.headline)
                                    Text("\(host.user)@\(host.hostname):\(host.port)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { model.hosts.removeAll { $0.id == host.id } } label: { Label("Remove", systemImage: "trash") }
                            Button { model.forgetHostKey(host) } label: { Label("Forget key", systemImage: "key.slash") }
                        }
                    }
                }
                Section {
                    Text(model.publicKeyLine).font(.caption2.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = model.publicKeyLine } label: { Label("Copy", systemImage: "doc.on.doc") }
                } header: { Text("This phone's key") } footer: {
                    Text("Append it to ~/.ssh/authorized_keys on each Mac. vigild must be on the Mac's PATH for ssh.")
                }
                ReceiptsSection(receipts: model.receipts)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { host in AddHostView(editing: host) }
        }
    }
}

struct ReceiptsSection: View {
    @ObservedObject var receipts: VigilReceipts
    var body: some View {
        Section("Receipts") {
            ForEach(Array(receipts.lines.suffix(60).reversed().enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
