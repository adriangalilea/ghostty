import AuthzEndpoint
import AuthzGlance
import AuthzUI
import Ink
import SwiftUI
import GhosttyKit
import VigilActivity
import VigilWire

/// The phone's screens: ONE home tree (Macs → workspaces → tabs → panes,
/// collapsible, the sidebar's rollup dots on every folded row) and a pane,
/// full screen. The pane IS a Ghostty surface (Metal, the Mac's renderer)
/// attached over tether (`vigil/1`); the model owns every surface, the
/// screens borrow.
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
        // vigil://pane/<id> (a request's Go there, a row of the activity).
        .onOpenURL { url in
            Task { @MainActor in
                if let ref = await model.resolve(url: url) { path = [ref] }
            }
        }
        // A tapped question's pane, a pane just created.
        .onChange(of: model.opening) { _, ref in
            guard let ref else { return }
            path = [ref]
            model.opening = nil
        }
        // The new-workspace sheet, from wherever it was asked for; the
        // workspace opens over whatever was on screen.
        .sheet(item: $model.composing) { compose in
            NewWorkspaceSheet(compose: compose) { ref in
                model.typeInto = ref
                model.opening = ref
            }
            .environmentObject(model)
        }
        // A creation in flight, said wherever you are: they take a moment
        // (the Mac spawns, then its directory lists the pane).
        .overlay(alignment: .top) {
            if let birth = model.creating, model.composing == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Creating \(birth.noun)…").font(.callout)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.creating != nil)
        // The sheet says its own failure; anywhere else, this does.
        .alert(model.failure?.title ?? "", isPresented: Binding(
            get: { model.failure != nil && model.composing == nil },
            set: { if !$0 { model.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure?.message ?? "")
        }
        // The Mac's one close question: asked only when something runs,
        // naming it (undo stays in Recently closed either way).
        .alert(closeTitle, isPresented: Binding(
            get: { model.closing != nil },
            set: { if !$0 { model.closing = nil } }
        ), presenting: model.closing) { closing in
            Button("Close", role: .destructive) { model.confirm(closing) }
            Button("Cancel", role: .cancel) {}
        } message: { closing in
            Text("\(closing.busy.joined(separator: ", ")) still running on \(closing.host.name). Closing the \(closing.tab ? "tab" : "pane") kills it; Recently closed can bring it back for a while.")
        }
    }

    private var closeTitle: String { model.closing?.tab == true ? "Close tab?" : "Close pane?" }
}

/// The close items for a pane and its tab: the same on a row's long
/// press and in the pane screen's menu. A workspace is never closed from
/// here (that is a kill, the Mac's own gesture).
struct CloseItems: View {
    let host: VigilPhone.Host
    let anchor: String
    /// Offer closing the pane itself (a tab row offers only its tab).
    var pane = true
    var done: @MainActor () -> Void = {}
    @EnvironmentObject private var model: VigilPhone

    /// Closing the tab's only pane closes the tab: then one item says so.
    private var whole: Bool { model.closesTab(anchor, on: host) }

    var body: some View {
        if pane {
            Button(role: .destructive) { model.bury(anchor, tab: false, on: host, done: done) } label: {
                Label(whole ? "Close tab" : "Close pane", systemImage: "xmark")
            }
        }
        if !whole || !pane {
            Button(role: .destructive) { model.bury(anchor, tab: true, on: host, done: done) } label: {
                Label("Close tab", systemImage: "xmark.rectangle")
            }
        }
    }
}

// MARK: - Home: the tree

struct HomeView: View {
    @EnvironmentObject private var model: VigilPhone
    @EnvironmentObject private var ghostty: Ghostty.App
    @State private var settings = false
    /// The coordinate space preview rows report their frames in: the
    /// scroll view's own, so the visible area is its size at the origin.
    static let treeSpace = "tree"

    var body: some View {
        let tree = model.tree()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let why = model.unlinked {
                    ContentUnavailableView("Not connected", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("vigil could not reach your devices: \(why)"))
                        .padding(.top, 80)
                } else if tree.isEmpty {
                    ContentUnavailableView("No Macs yet", systemImage: "desktopcomputer",
                                           description: Text("A Mac shows up here once it is paired with this iPhone and runs vigil. Pair it in Settings (⚙︎)."))
                        .padding(.top, 80)
                }
                let following = model.followedNodes
                if !following.isEmpty { FollowingList(nodes: following) }
                ForEach(tree) { node in
                    TreeNodeView(node: node, depth: 0)
                }
                if !model.burials.isEmpty { BurialTray() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .coordinateSpace(name: Self.treeSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.treeSize($0) }
        .background(Color(ghostty.config.backgroundColor).ignoresSafeArea())
        // The bar carries the buttons only: the app's name on its own line
        // took the space of three rows.
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(for: PaneRef.self) { ref in PaneScreen(ref: ref) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { settings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            // A new workspace, said in full in the sheet: which Mac (chosen
            // there unless only one can take it), which folder, what runs.
            // A Mac's own row and every row's long press create in context.
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.composing = .init(host: model.onlyReachable, folder: nil) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New workspace")
                // No Mac can be reached: nowhere to create (each Mac's row
                // says why).
                .disabled(model.creating != nil || !model.hosts.contains(where: model.reachable))
            }
        }
        .sheet(isPresented: $settings) { SettingsView() }
    }
}

/// The panes this phone follows (their stalls and ends ring here, they
/// lead their Mac's activity on the Lock Screen), above the tree: each
/// named in full with its Mac, opened by a tap, let go by its pin.
struct FollowingList: View {
    let nodes: [VigilPhone.Node]
    @EnvironmentObject private var model: VigilPhone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Following", systemImage: FollowMark.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(nodes) { node in
                HStack(spacing: 8) {
                    Group {
                        if let ref = node.pane {
                            NavigationLink(value: ref) { label(node) }.buttonStyle(.plain)
                        } else {
                            label(node)
                        }
                    }
                    Button { model.follow(node, false) } label: {
                        Image(systemName: FollowMark.unfollowSymbol)
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Unfollow \(node.path ?? node.title)")
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 6)
    }

    private func label(_ node: VigilPhone.Node) -> some View {
        HStack(spacing: 8) {
            Circle().fill(node.alive ? (node.state ?? .idle).tint : Color.gray.opacity(0.3)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.path ?? node.title).font(.subheadline).lineLimit(1)
                Text([model.host(of: node)?.name, node.words].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// Following, in one symbol on every surface: the pin the Lock Screen
/// wears on a followed row, the tree's mark, the Following list.
enum FollowMark {
    static let symbol = "pin.fill"
    static let unfollowSymbol = "pin.slash"
}

/// What was closed on any Mac and still waits out its grace, as on the
/// Mac's sidebar: tap a row to bring it back where it was, swipe it away
/// to let it die now. The countdown runs on its own (no timer of ours).
struct BurialTray: View {
    @EnvironmentObject private var model: VigilPhone
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Recently closed", systemImage: "trash").font(.caption).foregroundStyle(.secondary)
            if let error = model.burialError {
                Text(error).font(.caption2).foregroundStyle(Hue.care)
            }
            ForEach(model.burials) { burial in
                HStack(spacing: 8) {
                    Text(burial.emoji ?? "").frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(burial.label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Text([burial.from, "on \(burial.host.name)"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(timerInterval: Date()...burial.until, countsDown: true)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                // Swiped away = ended now, the way a notification is cleared.
                .swipeToDismiss { model.settle(burial, undo: false) }
                .onTapGesture { model.settle(burial, undo: true) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Brings it back where it was")
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
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
        VStack(alignment: .leading, spacing: 0) {
            row
            // An agent pane with a glance is drawn by its meaning (`row`):
            // no live terminal, so no surface, no stream, no renderer.
            if let ref = node.pane, node.glance == nil, node.rows > 0, node.cols > 0 {
                NavigationLink(value: ref) {
                    PanePreview(ref: ref, grid: .init(rows: node.rows, cols: node.cols))
                        .padding(.leading, CGFloat(depth) * Self.indent + Self.chevron + 6)
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { model.receipts.info("tap", "preview", ["title": node.title, "pane": ref.pane]) })
            }
            if foldable && !folded {
                ForEach(node.children) { child in
                    TreeNodeView(node: child, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder private var row: some View {
        let content = HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(depth) * Self.indent)
            if foldable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: Self.chevron)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
            } else {
                Spacer().frame(width: Self.chevron)
            }
            icon
            if let glance = node.glance {
                GlanceRow(node: node, glance: glance) { marks }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        if let e = node.emoji { Text(e).font(font) }
                        Text(node.title)
                            .font(font)
                            .foregroundStyle(node.alive ? .primary : .secondary)
                            .lineLimit(1)
                        marks
                    }
                    if let sub = node.subtitle {
                        Text(sub).font(.caption2)
                            .foregroundStyle(sub.hasPrefix("connecting") ? .secondary : Hue.care)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if node.kind == .pane && !node.alive {
                Text("Not running").font(.caption2).foregroundStyle(.tertiary)
            }
            // A glance row wears its state as its glyph.
            if node.glance == nil { cluster }
            // A Mac's own `+`: a workspace there, its Mac obvious.
            if node.kind == .host, let host = model.host(of: node), model.reachable(host) {
                Menu { QuickCreateItems(host: host) } label: {
                    Image(systemName: "plus").font(.body.weight(.medium))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                }
                .disabled(model.creating != nil)
                .accessibilityLabel("New workspace on \(host.name)")
            }
        }
        .padding(.vertical, node.kind == .host ? 5 : 4)
        .padding(.horizontal, 6)
        .frame(minHeight: 32)
        .background(node.kind == .host ? Color.secondary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, node.kind == .host ? 6 : 0)
        .contentShape(Rectangle())

        Group {
            if let ref = node.pane {
                NavigationLink(value: ref) { content.frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { model.receipts.info("tap", "row", ["title": node.title, "pane": ref.pane]) })
            } else {
                content.onTapGesture { if foldable { toggle() } }
            }
        }
        .contextMenu {
            // The ids we communicate by, each where it exists.
            if let pane = node.followPane {
                Section {
                    CopyItem(label: "Copy Pane ID", value: pane)
                    if let name = node.glance?.title { CopyItem(label: "Copy Conversation Name", value: name) }
                    if let id = node.glance?.conversation { CopyItem(label: "Copy Conversation ID", value: id) }
                }
            }
            if node.followPane != nil {
                Button { model.follow(node, !following) } label: {
                    Label(following ? "Unfollow" : "Follow on this iPhone",
                          systemImage: following ? FollowMark.unfollowSymbol : FollowMark.symbol)
                }
            }
            if let host = model.host(of: node), model.reachable(host) {
                if node.kind == .host {
                    QuickCreateItems(host: host)
                } else {
                    Section {
                        CreateItems(host: host, anchor: node.anchor, splits: node.kind == .pane,
                                    folder: node.anchor.flatMap { model.folder(of: $0, on: host) }) { ref in
                            model.typeInto = ref
                            model.opening = ref
                        }
                    }
                }
                switch node.kind {
                case .pane:
                    if let pane = node.followPane { Section { CloseItems(host: host, anchor: pane) } }
                case .tab:
                    if let anchor = node.anchor { Section { CloseItems(host: host, anchor: anchor, pane: false) } }
                case .host, .workspace: EmptyView()
                }
            }
        }
    }

    /// Steps of the tree: each level indents this much, after a chevron
    /// column this wide.
    static let indent: CGFloat = 12
    static let chevron: CGFloat = 14

    /// Followed on this phone (its activity on the Lock Screen).
    private var following: Bool { node.followKey.map(model.followed.contains) == true }

    /// What a pane is beyond this tree, each only when it differs from the
    /// default, as the Mac's sidebar marks it: open on another Mac right
    /// now, followed here, its priority.
    @ViewBuilder private var marks: some View {
        if node.onAnotherMac {
            Image(systemName: "laptopcomputer").font(.caption2.weight(.bold)).foregroundStyle(.cyan)
                .accessibilityLabel("Open on another Mac right now")
        }
        if following {
            Image(systemName: FollowMark.symbol).font(.caption2).foregroundStyle(.primary.opacity(0.75))
                .accessibilityLabel("Followed on this iPhone")
        }
        switch node.priority {
        case .high?:
            Image(systemName: "exclamationmark").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                .accessibilityLabel("High priority: rings through Focus")
        case .low?:
            Image(systemName: "moon.fill").font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel("Low priority: never rings")
        case .normal?, nil: EmptyView()
        }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) {
            if folded { model.collapsed.remove(node.id) } else { model.collapsed.insert(node.id) }
        }
    }

    private var font: Font {
        switch node.kind {
        case .host: return .subheadline.weight(.semibold)
        case .workspace: return .subheadline.weight(.semibold)
        case .tab: return .subheadline
        case .pane: return .subheadline
        }
    }

    /// A Mac and a tab wear a glyph; a workspace is its face and name, a
    /// pane its name and state dot.
    @ViewBuilder private var icon: some View {
        switch node.kind {
        case .host: Image(systemName: "desktopcomputer").font(.footnote).foregroundStyle(.secondary)
        case .tab: Image(systemName: "rectangle.on.rectangle").font(.caption2).foregroundStyle(.secondary)
        case .workspace, .pane: EmptyView()
        }
    }

    /// dot = agent state. A pane shows its own; a folded node its
    /// descendants' cluster; an unfolded node nothing (its children speak).
    @ViewBuilder private var cluster: some View {
        let states: [AgentState] = node.kind == .pane || folded ? node.cluster : []
        HStack(spacing: 3) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                Circle().fill(s.tint).frame(width: 8, height: 8)
            }
        }
        .frame(minWidth: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(states.map(\.words).joined(separator: ", "))
    }
}

// MARK: - Glance row: an agent pane by its meaning

/// An agent pane drawn as what it means (its Mac's `PaneGlance`): its
/// state's glyph, its conversation's name, the mark of a conversation (it
/// opens as one), then one or two lines: the question while it waits for
/// you, the tool call while it works, else its last words with how long ago
/// it said them. Its pane id, dim, under it. Each line only when the glance
/// has it; the state's words otherwise, never a blank row.
struct GlanceRow<Marks: View>: View {
    let node: VigilPhone.Node
    let glance: PaneGlance
    @ViewBuilder let marks: () -> Marks

    private var state: AgentState { node.state ?? .idle }
    /// The row's line is its last words (done or idle, and it has some).
    private var saysLastWords: Bool { (state == .done || state == .idle) && glance.said != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: state.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(state.tint)
                    .frame(width: 16)
                    .accessibilityLabel(state.words(node.flavor))
                if let e = node.emoji { Text(e).font(.subheadline) }
                Text(node.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("A conversation with \(glance.agent)")
                marks()
            }
            line.padding(.leading, 21)
            if let pane = node.followPane {
                HStack(spacing: 6) {
                    MiddleTruncate(pane, tail: "-").font(.caption2.monospaced())
                    // Last words are the past: how long ago, never cut off
                    // by a long message.
                    if saysLastWords, let at = glance.saidAt { Text("said " + Self.ago(at)).font(.caption2) }
                }
                .foregroundStyle(.tertiary)
                .padding(.leading, 21)
            }
        }
    }

    @ViewBuilder private var line: some View {
        switch state {
        case .blocked:
            Text(glance.question ?? state.words(node.flavor))
                .font(.footnote).foregroundStyle(state.tint).lineLimit(2)
        case .working, .interrupting, .unknown:
            if let action = glance.action {
                Text(action.line)
                    .font(action.shell ? .footnote.monospaced() : .footnote)
                    .foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(state.words(node.flavor)).font(.footnote).foregroundStyle(.secondary)
            }
        case .done, .idle:
            if let said = glance.said {
                Text(said).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(state.words(node.flavor)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// How long ago, said plainly: last words are the past, and an hour-old
    /// line must not pass for one said now.
    static func ago(_ time: Double) -> String {
        Date(timeIntervalSince1970: time).formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// One Copy item of a row's menu: Ink's copy action (the pasteboard is the
/// receipt; a menu has no place to show its confirmation), and a receipt.
struct CopyItem: View {
    let label: String
    let value: String

    var body: some View {
        Button {
            CopyFeedback().copy(value)
            VigilPhone.shared.receipts.info("copy", label, ["value": value])
        } label: {
            Label(label, systemImage: "doc.on.doc")
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
        VigilPhone.shared.receipts.info("surface", "hosted", ["pane": view.paneId, "by": "\(purpose)"])
    }

    func unhost() {
        guard let view = hosted else { return }
        view.removeFromSuperview()
        VigilPhone.shared.receipts.info("surface", "unhosted", ["pane": view.paneId, "by": "\(purpose)"])
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
        // refresh re-runs a row's update while the pane screen shows the
        // view, and the row would steal it back (a gray screen).
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

    /// The pane's last lines, where the action is, without one row taking
    /// a third of the screen.
    private let height: CGFloat = 120

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
        // The model hands this row a slot by its place in the viewport;
        // a row dials only while it holds one, and drops its view (the
        // model already ended the surface) when the slot moves on.
        .task(id: wanted) {
            if wanted { await load() } else { surfaceView = nil; denied = false }
        }
        .onChange(of: model.streamGeneration) { _, _ in
            guard wanted, surfaceView?.surface == nil else { return }
            surfaceView = nil
            Task { await load() }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HomeView.treeSpace)) } action: { model.rowFrame(ref, $0) }
        .onDisappear { model.rowDisappeared(ref) }
    }

    private var wanted: Bool { model.previewed.contains(ref.pane) }

    private func load() async {
        guard let app = ghostty.app else { return }
        do {
            guard let view = try await model.surface(for: ref, app: app, screen: false) else { denied = true; return }
            surfaceView = view
        } catch {
            model.receipts.error("surface", "preview failed", ["pane": ref.pane, "err": error])
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
        VigilPhone.shared.receipts.info("keyboard", "inset", ["points": Int(value), "why": why])
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
                // No arrow keys (the floating ArrowStick owns them) and no
                // enter of any kind: the keyboard's return submits, a
                // hardware shift+return line-breaks (CSI-u), and the
                // software keyboard's line break is claude's own \ +
                // return — iOS never reports the on-screen shift, so a
                // combo key here would be a lie (Adrian: no dedicated keys
                // for what a keyboard already has).
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
    /// re-runs it: a blank fit screen).
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
            VigilPhone.shared.receipts.info("surface", "fit", [
                "pane": view.paneId, "scale": Double(fit),
                "width": Int(presented.width), "height": Int(presented.height),
                "bounds_width": Int(bounds.width), "bounds_height": Int(bounds.height),
            ])
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
            VigilPhone.shared.receipts.info("surface", "zoomed", ["scale": Double(scale)])
            DispatchQueue.main.async { self.parent.zoom = scale }
        }
    }
}

// MARK: - Pane screen

/// One pane, full screen. FIT (default): the Mac's grid as a picture,
/// no reflow, the Mac untouched, the phone never owns the pty. OWN: the
/// phone's grid; the surface claims the pty, the pane reflows, the Mac
/// follows while it is open, yielded on leave.
/// Floating 4-way arrow stick (pattern: THUMBSTICK, the arcade virtual
/// stick): drag off center = that arrow, held = game-style repeat
/// (0.30s, then 0.11s), a direction change retargets instantly with its
/// own tick. Hold STILL to pick the whole stick up (haptic, it grows),
/// drag it anywhere, release to pin — the spot persists as fractions of
/// the terminal area, so the keyboard rising keeps it on screen.
/// Replaces the strip's arrow row: arrows deserve a thumb, not four tap
/// targets.
struct ArrowStick: View {
    let surface: Ghostty.SurfaceView
    let area: CGSize
    @AppStorage("vigil.stick.fx") private var fx = 0.86
    @AppStorage("vigil.stick.fy") private var fy = 0.62
    @StateObject private var engine = Engine()

    private var home: CGPoint {
        CGPoint(x: min(max(44, area.width * fx), area.width - 44),
                y: min(max(60, area.height * fy), area.height - 44))
    }

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            ForEach(Direction.allCases, id: \.self) { d in
                Image(systemName: d.chevron)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(engine.active == d ? Color.accentColor : Color.secondary)
                    .offset(d.edge(24))
            }
            Circle().fill(Color.secondary.opacity(engine.mode == .idle ? 0.25 : 0.5))
                .frame(width: 26, height: 26)
                .offset(x: engine.deflection.width, y: engine.deflection.height)
        }
        .frame(width: 68, height: 68)
        .scaleEffect(engine.mode == .moving ? 1.15 : 1)
        .shadow(radius: engine.mode == .moving ? 10 : 2)
        .opacity(engine.mode == .idle ? 0.55 : 0.95)
        .position(engine.mode == .moving ? engine.movingCenter : home)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: engine.mode)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { engine.changed($0, surface: surface, home: home) }
                .onEnded { _ in
                    if engine.mode == .moving, area.width > 0, area.height > 0 {
                        fx = min(max(engine.movingCenter.x / area.width, 0.08), 0.94)
                        fy = min(max(engine.movingCenter.y / area.height, 0.10), 0.94)
                    }
                    engine.ended()
                }
        )
    }

    enum Direction: CaseIterable {
        case up, down, left, right
        var bytes: String {
            switch self {
            case .up: "\u{1b}[A"
            case .down: "\u{1b}[B"
            case .right: "\u{1b}[C"
            case .left: "\u{1b}[D"
            }
        }
        var chevron: String {
            switch self {
            case .up: "chevron.up"
            case .down: "chevron.down"
            case .left: "chevron.left"
            case .right: "chevron.right"
            }
        }
        func edge(_ r: CGFloat) -> CGSize {
            switch self {
            case .up: CGSize(width: 0, height: -r)
            case .down: CGSize(width: 0, height: r)
            case .left: CGSize(width: -r, height: 0)
            case .right: CGSize(width: r, height: 0)
            }
        }
    }

    final class Engine: ObservableObject {
        enum Mode { case idle, stick, moving }
        @Published var mode: Mode = .idle
        @Published var active: Direction?
        @Published var deflection: CGSize = .zero
        @Published var movingCenter: CGPoint = .zero
        private var holdWork: DispatchWorkItem?
        private var timer: Timer?
        private weak var surface: Ghostty.SurfaceView?

        func changed(_ v: DragGesture.Value, surface: Ghostty.SurfaceView, home: CGPoint) {
            self.surface = surface
            let t = v.translation
            switch mode {
            case .idle:
                if holdWork == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.mode == .idle else { return }
                        self.mode = .moving
                        self.movingCenter = home
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    holdWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                }
                if hypot(t.width, t.height) > 14 {
                    holdWork?.cancel()
                    mode = .stick
                    retarget(t)
                }
            case .stick:
                retarget(t)
            case .moving:
                movingCenter = CGPoint(x: home.x + t.width, y: home.y + t.height)
            }
        }

        func ended() {
            holdWork?.cancel()
            holdWork = nil
            timer?.invalidate()
            timer = nil
            active = nil
            deflection = .zero
            mode = .idle
        }

        private func retarget(_ t: CGSize) {
            deflection = CGSize(width: max(-24, min(24, t.width)),
                                height: max(-24, min(24, t.height)))
            let d: Direction = abs(t.width) > abs(t.height)
                ? (t.width > 0 ? .right : .left)
                : (t.height > 0 ? .down : .up)
            guard d != active else { return }
            active = d
            fire(d)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in
                    guard let self, let d = self.active else { return }
                    self.fire(d)
                }
            }
        }

        private func fire(_ d: Direction) {
            surface?.sendKeys(d.bytes)
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
    }
}

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
    @State private var screenVisible = false
    @State private var entryGeneration = UUID()
    /// What the screen shows: an agent pane opens on its conversation, any
    /// other on its terminal; the toggle switches.
    @State private var mode: Mode
    /// The current pane's feed, followed while its conversation can show.
    @State private var conversation: Conversation?

    enum Mode { case conversation, terminal }

    init(ref: PaneRef) {
        self.ref = ref
        _current = State(initialValue: ref)
        _mode = State(initialValue: Self.opens(ref))
    }

    /// How a pane opens: its conversation when an agent runs in it.
    private static func opens(_ ref: PaneRef) -> Mode {
        VigilPhone.shared.node(for: ref)?.agent == true ? .conversation : .terminal
    }

    private var node: VigilPhone.Node? { model.node(for: current) }
    /// The owner's grid for the current pane, if the Mac published one.
    private var grid: Ghostty.SurfaceView.Grid? {
        guard let n = node, n.rows > 0, n.cols > 0 else { return nil }
        return .init(rows: n.rows, cols: n.cols)
    }
    private var fits: Bool { !ownSize && grid != nil }

    var body: some View {
        Group {
            if mode == .conversation {
                if let conversation {
                    ConversationView(conversation: conversation) { setMode(.terminal) }
                } else {
                    ProgressView()
                }
            } else {
                terminal
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbar }
        .task {
            screenVisible = true
            await show(current)
        }
        // Opened by an activity's Reply while this pane already shows.
        .onChange(of: model.typeInto) { _, ref in
            guard let ref, ref == current, let surfaceView else { return }
            model.typeInto = nil
            surfaceView.keyboardWanted = true
        }
        .onChange(of: node?.sizeOwner) { _, owner in
            guard let view = surfaceView, grid != nil else { return }
            view.updateSizeOwner(owner ?? "")
            if !view.sizeClaimRequested { ownSize = false }
        }
        .onChange(of: model.streamGeneration) { _, _ in
            guard screenVisible, phase == .active, mode == .terminal else { return }
            guard surfaceView?.surface == nil else { return }
            model.receipts.warn("pane", "stream died on screen; re-dialing", ["pane": current.pane])
            // A reconnect is no act of yours: the size stays whose it was.
            let held = ownSize
            leave()
            error = nil
            Task { await enter(current, claim: held) }
        }
        .onDisappear {
            screenVisible = false
            leave()
            conversation?.stop()
            conversation = nil
            model.dismissed(current)
        }
        // Leaving the active scene yields (nobody looks at the phone).
        // Bringing the app back on this pane is opening it again: it claims.
        .onChange(of: phase) { _, now in
            switch now {
            case .background, .inactive:
                model.receipts.info("pane", "scene left; yielding", ["pane": current.pane, "phase": "\(now)"])
                entryGeneration = UUID()
                surfaceView?.claimSize(false)
                surfaceView?.keyboardWanted = false
                surfaceView?.attended = false
                ownSize = false
            case .active:
                guard screenVisible, mode == .terminal else { return }
                model.receipts.info("pane", "active again", ["pane": current.pane])
                if let view = surfaceView, view.surface != nil {
                    view.attended = true
                    view.refreshFromDaemon()
                    setOwnSize(true)
                } else {
                    Task { await enter(current, claim: true) }
                }
            @unknown default: break
            }
        }
    }

    /// The pane's terminal: a Ghostty surface over its `proxy` stream.
    private var terminal: some View {
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
                    Text(error).foregroundStyle(Hue.care).padding()
                } else {
                    ProgressView("attaching…")
                }
                if let surfaceView {
                    ArrowStick(
                        surface: surfaceView,
                        area: CGSize(width: geo.size.width, height: max(0, geo.size.height - keyboard.inset)))
                }
            }
            // The terminal area is the window minus the keyboard, applied
            // as a fact (no SwiftUI keyboard avoidance, no animation race).
            .frame(width: geo.size.width, height: max(0, geo.size.height - keyboard.inset), alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .ignoresSafeArea(.keyboard)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
            }
            ToolbarItem(placement: .principal) {
                PaneTitle(title: node?.path ?? current.title,
                          line: [current.host.name, node?.words].compactMap { $0 }.joined(separator: " · "),
                          tint: node?.alive == false ? Color.gray.opacity(0.3) : (node?.state ?? .idle).tint)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Conversation ⇄ terminal, for a pane with a conversation.
                if node?.agent == true || mode == .conversation {
                    Button { setMode(mode == .conversation ? .terminal : .conversation) } label: {
                        Image(systemName: mode == .conversation ? "terminal" : "text.bubble")
                    }
                    .accessibilityLabel(mode == .conversation ? "Show the terminal" : "Show the conversation")
                }
                if let surfaceView { KeyboardButton(surface: surfaceView) }
                if surfaceView != nil {
                    // MIRROR: a picture of the Mac's grid, the Mac untouched.
                    // OWN: the phone is the terminal, the pane reflows to it.
                    // Same footprint either way: a Mac glyph (you are
                    // looking at the Mac's screen) vs a phone glyph (the
                    // phone is the terminal).
                    Button { setOwnSize(!ownSize) } label: {
                        Image(systemName: ownSize ? "iphone" : "desktopcomputer")
                    }
                }
                if mode == .terminal {
                    Button { zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                }
                Menu {
                    // Beside this pane, opened here in its place with the
                    // keyboard up; or a workspace in this pane's folder.
                    Section {
                        CreateItems(host: current.host, anchor: node?.anchor, splits: true,
                                    folder: model.folder(of: current.pane, on: current.host)) { ref in
                            model.typeInto = ref
                            switchTo(ref)
                        }
                    }
                    .disabled(model.creating != nil || !model.reachable(current.host))
                    Section("Switch to") {
                        ForEach(model.livePanes(on: current.host).filter { $0.pane != current }) { other in
                            if let ref = other.pane {
                                // A menu item's second text is its subtitle.
                                Button { switchTo(ref) } label: {
                                    Text(other.path ?? other.title)
                                    Text(other.words)
                                }
                            }
                        }
                    }
                    // Closed on its Mac, which keeps it in Recently closed;
                    // the screen goes back to the list.
                    Section {
                        CloseItems(host: current.host, anchor: current.pane) { dismiss() }
                    }
                    .disabled(!model.reachable(current.host))
                } label: { Image(systemName: "rectangle.stack") }
            }
    }

    /// Brings `ref` on screen in the current mode: its conversation (its
    /// feed followed; the terminal untouched, so the Mac keeps its size),
    /// or its terminal, claimed (you opened it).
    private func show(_ ref: PaneRef) async {
        if mode == .conversation, node?.agent == true {
            model.present(ref)
            if conversation?.ref != ref {
                conversation?.stop()
                let next = Conversation(ref: ref)
                next.start()
                conversation = next
            }
        } else {
            mode = .terminal
            await enter(ref, claim: true)
        }
    }

    /// The toggle: the terminal attaches and claims as an open would; the
    /// conversation lets the terminal go (yielding its size).
    private func setMode(_ next: Mode) {
        guard next != mode else { return }
        mode = next
        model.receipts.info("pane", next == .conversation ? "conversation" : "terminal", ["pane": current.pane])
        switch next {
        case .terminal:
            Task { await enter(current, claim: true) }
        case .conversation:
            leave()
            Task { await show(current) }
        }
    }

    /// Shows `ref`. `claim`: you brought it on screen (opened it from the
    /// list, switched to it, brought the app back on it), so the phone takes
    /// the pane's size. Who owns the size moves only on a person's act: the
    /// phone claims when you open a pane, the Mac takes it back when you work
    /// in that pane there (and the phone then shows the Mac's grid, without
    /// taking it back on its own), the size button switches either way.
    private func enter(_ ref: PaneRef, claim: Bool) async {
        guard screenVisible, phase == .active else { return }
        let generation = UUID()
        entryGeneration = generation
        model.present(ref)
        model.receipts.info("pane", "screen", ["pane": ref.pane])
        guard let app = ghostty.app else { error = "ghostty not ready"; return }
        do {
            guard let view = try await model.surface(for: ref, app: app, screen: true) else { error = "no surface"; return }
            guard !Task.isCancelled, screenVisible, phase == .active,
                  entryGeneration == generation, current == ref else {
                model.receipts.info("pane", "attached after presentation ended; no claim", ["pane": ref.pane])
                return
            }
            view.accessory = makeAccessory(for: view)
            view.attended = true
            surfaceView = view
            if claim { setOwnSize(true) }
            // Opened by an activity's Reply: the terminal's own keyboard comes up.
            if model.typeInto == ref { model.typeInto = nil; view.keyboardWanted = true }
        } catch {
            guard entryGeneration == generation, screenVisible else { return }
            self.error = "\(error)"
            model.receipts.error("pane", "attach failed", ["pane": ref.pane, "err": error])
        }
    }

    private func leave() {
        entryGeneration = UUID()
        ownSize = false
        guard let view = surfaceView else { return }
        view.claimSize(false)
        view.keyboardWanted = false
        view.attended = false
        view.accessory = nil
        surfaceView = nil
    }

    /// Another pane in this screen's place. One just created opens on its
    /// terminal, where a new program starts; any other as it opens.
    private func switchTo(_ other: PaneRef) {
        leave()
        conversation?.stop()
        conversation = nil
        current = other
        fitZoom = 1
        mode = model.typeInto == other ? .terminal : Self.opens(other)
        Task { await show(other) }
    }

    private func setOwnSize(_ own: Bool) {
        guard own != ownSize, let view = surfaceView, screenVisible, phase == .active else { return }
        ownSize = view.claimSize(own)
        fitZoom = 1
        model.receipts.info("pane", ownSize ? "own size: claims the pty" : "fit: mirrors the owner", ["pane": current.pane])
    }

    private func zoom(_ direction: Int) {
        if fits {
            fitZoom = min(4, max(1, fitZoom * (direction > 0 ? 1.25 : 1 / 1.25)))
        } else {
            surfaceView?.zoom(direction)
        }
    }
}

/// The pane screen's name capsule: where the pane is (the one naming
/// rule), then its Mac and state beside its state's dot.
struct PaneTitle: View {
    let title: String
    let line: String
    let tint: Color
    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
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

/// The Macs on your Apple Account, each with what it does for this phone
/// (its workspaces here, its requests answered here), pairing for the ones
/// not paired yet, and the receipts.
struct SettingsView: View {
    @EnvironmentObject private var model: VigilPhone
    @ObservedObject private var authz = VigilAuthz.shared.runtime
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(authz.macs) { mac in
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer").font(.title3).foregroundStyle(.secondary).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mac.name).font(.headline)
                                Text(workspaces(mac)).font(.caption).foregroundStyle(.secondary)
                                Text(requests(mac)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mac.state == .onAccount {
                                Button("Pair") { authz.pair(mac) }.buttonStyle(.borderedProminent)
                            } else if mac.state == .pairing {
                                ProgressView()
                            }
                        }
                    }
                } header: { Text("Macs") } footer: {
                    Text("Pairing is approved on the Mac with Touch ID. A paired Mac running vigil shows its workspaces here.")
                }
                ReceiptsSection(receipts: model.receipts)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func workspaces(_ mac: EndpointRuntime.Mac) -> String {
        if model.hosts.contains(where: { $0.id == mac.id }) { return "Workspaces: shown here" }
        return mac.state == .onAccount || mac.state == .pairing ? "Workspaces: after pairing" : "Workspaces: vigil is not running there"
    }

    private func requests(_ mac: EndpointRuntime.Mac) -> String {
        switch mac.state {
        case .onAccount, .pairing: "Requests: after pairing"
        case .connecting: "Requests: connecting…"
        case .waiting: "Requests: allow vigil on the Mac"
        case .answering: "Requests: answered here"
        case .refused: "Requests: refused on the Mac"
        case .unreachable(let why): "Unreachable: \(why)"
        }
    }
}

struct ReceiptsSection: View {
    @ObservedObject var receipts: VigilReceipts
    var body: some View {
        Section("Receipts") {
            ForEach(receipts.all.suffix(60).reversed()) { receipt in
                Text(receipt.line).font(.caption2.monospaced())
                    .foregroundStyle(receipt.level == .info ? Color.secondary : receipt.level == .warn ? Hue.care : Color.red)
            }
        }
    }
}
