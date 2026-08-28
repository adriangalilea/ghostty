import SwiftUI
import GhosttyKit

/// The phone's screens: ONE home tree (Macs → sessions → tabs → panes,
/// collapsible, the sidebar's rollup dots on every folded row) and a pane,
/// full screen, with a key strip the software keyboard lacks. The pane IS
/// a Ghostty surface (Metal, the Mac's renderer) attached through ssh.
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
                    PanePreview(ref: ref, rows: node.rows, cols: node.cols)
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
                Text("cold").font(.caption2).foregroundStyle(.tertiary)
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

/// A surface laid out at the OWNER's grid (8pt metrics) and scaled to fit
/// the width: the Mac's screen on the phone, no reflow, no repaint. Taller
/// than the screen scrolls natively (the surface's own scroll view sits
/// inside, so a drag inside scrolls the terminal; the outer scroll moves
/// the viewport when the terminal is at its edge).
struct FittedSurface: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let full: CGSize
    let scale: CGFloat

    var body: some View {
        GeometryReader { geo in
            ScrollView(full.width * scale > geo.size.width ? [.vertical, .horizontal] : .vertical, showsIndicators: false) {
                // The view's render layout was set before it got here
                // (PaneScreen.layout); this only sizes the frame it fills.
                Ghostty.SurfaceWrapper(surfaceView: surfaceView)
                    .frame(width: full.width * scale, height: full.height * scale)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

/// A LIVE thumbnail of a pane: a second client on its daemon (a mirror,
/// owning nothing), rendered by a real Ghostty surface laid out at the
/// OWNER's grid and scaled down to the row, so it is the Mac's screen in
/// miniature, updating as it streams. Born when the row scrolls in, ended
/// when it scrolls out; at most `VigilPhone.previewCap` alive at once.
struct PanePreview: View {
    let ref: PaneRef
    let rows: Int
    let cols: Int
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var model: VigilPhone
    @State private var surfaceView: Ghostty.SurfaceView?
    @State private var denied = false
    @State private var generation = 0

    /// The owner's grid at the surface's REAL cell size (ghostty publishes
    /// it once the font is set; until then the render size is held at a
    /// dot so no frame is ever reported), scaled to the row's width, and
    /// clipped to a short window anchored at the BOTTOM of the grid: a
    /// terminal's action is at the bottom.
    private let height: CGFloat = 150
    private func fullSize(_ view: Ghostty.SurfaceView) -> CGSize? {
        let cell = view.liveCell
        guard cell.width > 0, cell.height > 0 else { return nil }
        return CGSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color(ghostty.config.backgroundColor)
                if let surfaceView {
                    // The view IS the thumbnail's size; the grid is rendered
                    // inside it at `renderSize`, scaled and bottom-anchored.
                    // `.id(generation)` re-hosts the UIView after a pane
                    // screen borrowed it (one superview per UIView).
                    Ghostty.SurfaceWrapper(surfaceView: surfaceView)
                        .id(generation)
                        .frame(width: geo.size.width, height: height)
                        .onAppear { configure(surfaceView, width: geo.size.width) }
                        .onChange(of: geo.size.width) { _, w in configure(surfaceView, width: w) }
                        .onChange(of: surfaceView.cellSize) { _, _ in configure(surfaceView, width: geo.size.width) }
                        .onChange(of: model.returnTick) { _, _ in
                            if surfaceView.superview == nil { generation += 1 }
                            configure(surfaceView, width: geo.size.width)
                        }
                } else if denied {
                    Text("preview limit").font(.caption2).foregroundStyle(.tertiary).padding(6)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .bottomLeading)
            .clipped()
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        .task { await attach() }
        .onDisappear { end() }
    }

    /// Readable, never shrunk below 0.8: a wide grid shows its bottom-LEFT
    /// window (content is left-aligned), clipped, rather than the whole
    /// grid at half size (unreadable, 2026-08-28).
    private func configure(_ view: Ghostty.SurfaceView, width: CGFloat) {
        // Unknown metrics yet: the grid is still set (the view reports
        // nothing until the core has metrics), the scale is provisional.
        let scale = fullSize(view).map { min(1, max(0.8, width / $0.width)) } ?? 1
        view.thumbnail = ((rows, cols), scale)
        view.applyThumbnail()
    }

    private func attach() async {
        if let v = surfaceView {
            // Receipt only when something is off: a dead surface or one
            // not hosted (then re-host it).
            if v.surface == nil { model.log("preview: \(ref.pane) appeared with a DEAD surface") }
            if v.superview == nil { generation += 1 }
            return
        }
        guard let app = ghostty.app else { return }
        guard model.previewAllowed(ref.pane) else { denied = true; return }
        do {
            let fd = try await model.attach(ref.host, pane: ref.pane, preview: true)
            var config = Ghostty.SurfaceConfiguration()
            config.vigilAttach = ref.pane
            config.vigilFd = fd
            config.vigilMirror = true
            config.fontSize = 8
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            // A preview is a picture: its UIKit view keeps its full,
            // unscaled frame under the scaleEffect (scale is visual only),
            // reaching over neighbouring rows, and its scroll view ate the
            // taps meant for them (nine taps to open a row, 2026-08-28).
            // UIKit hit-testing is the only switch that reaches it.
            view.isUserInteractionEnabled = false
            surfaceView = view
            model.registerPreview(ref.pane, view: view)
        } catch {
            model.log("preview: \(ref.pane) failed: \(error.localizedDescription)")
        }
    }

    private func end() {
        // A pane screen on top: every preview stays alive (the opened one
        // is borrowed and comes back). Only a real scroll-out ends one.
        if model.presentingPane { return }
        guard let view = surfaceView else { return }
        surfaceView = nil
        view.vigilDetach()
        model.releasePreview(ref.pane)
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

// MARK: - Pane

/// One pane, full screen: the surface attaches on appear (an fd from the
/// ssh bridge), claims the pty size when it takes focus, and lets go on
/// disappear. The key strip supplies what a phone keyboard lacks.
struct PaneScreen: View {
    let ref: PaneRef
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var model: VigilPhone
    @Environment(\.dismiss) private var dismiss
    @State private var surfaceView: Ghostty.SurfaceView?
    @State private var current: PaneRef
    @State private var error: String?
    @State private var ctrl = false
    /// FIT (default): the Mac's grid, scaled to the phone: instant, no
    /// repaint, the Mac's layout untouched. OWN: the phone's grid; the
    /// pane reflows (a TUI repaint, seconds across a VPN) and the Mac
    /// follows the phone while it is open.
    @State private var ownSize = false
    /// FIT zoom is a PICTURE zoom (render scale), never a font change: a
    /// font change alters the cell size, the grid derived from the fixed
    /// render size changes with it, and the phone, as owner, resized the
    /// Mac's real pty (41x51 → 27x32 → 66x70 in the daemon log, 2026-08-28).
    @State private var fitZoom: CGFloat = 1

    init(ref: PaneRef) {
        self.ref = ref
        _current = State(initialValue: ref)
    }

    /// The pane's live row (state) from the last directory read.
    private var node: VigilPhone.Node? {
        model.tree().flatMap { $0.children }.flatMap { $0.children + $0.children.flatMap(\.children) }
            .first { $0.pane == current }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(ghostty.config.backgroundColor)
                if let surfaceView {
                    if ownSize || grid == nil {
                        Ghostty.SurfaceWrapper(surfaceView: surfaceView)
                    } else {
                        FittedSurface(surfaceView: surfaceView, full: fullSize(surfaceView) ?? UIScreen.main.bounds.size, scale: fitScale(surfaceView))
                            .onChange(of: surfaceView.cellSize) { _, _ in layout(surfaceView) }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.orange).padding()
                } else {
                    ProgressView("attaching…")
                }
            }
            KeyStrip(ctrl: $ctrl, send: { keys in surfaceView?.sendKeys(keys) },
                     hideKeyboard: { _ = surfaceView?.resignFirstResponder() })
        }
        // The terminal runs edge to edge; the bar floats over it as glass
        // (iOS 26 renders toolbar items as Liquid Glass once the bar's own
        // background is gone), Telegram's shape: back · name capsule · menu.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
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
                        Text("\(current.host.name) · \(sessionName)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if grid != nil {
                    Button {
                        ownSize.toggle()
                        if let v = surfaceView { layout(v) }
                    } label: {
                        Image(systemName: ownSize ? "rectangle.compress.vertical" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                Button { zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                Menu {
                    ForEach(livePanes.filter { $0.pane != current }, id: \.id) { other in
                        Button {
                            // Swap the viewport in place: same screen, new pane.
                            surfaceView?.vigilDetach()
                            surfaceView = nil
                            current = other.pane!
                            Task { await attach(current) }
                        } label: {
                            Label("\(other.subtitle ?? "") \(other.title)", systemImage: "terminal")
                        }
                    }
                } label: { Image(systemName: "rectangle.stack") }
            }
        }
        .task { model.presentingPane = true; model.log("pane: screen \(current.pane)"); await attach(current) }
        .onDisappear {
            model.presentingPane = false
            guard let view = surfaceView else { return }
            surfaceView = nil
            if model.wasAdopted(view) {
                model.returnPreview(current.pane, view: view)
            } else {
                view.vigilDetach()
            }
        }
    }

    /// The owner's grid for the current pane, if the Mac published one.
    private var grid: (rows: Int, cols: Int)? {
        guard let n = node, n.rows > 0, n.cols > 0 else { return nil }
        return (n.rows, n.cols)
    }

    /// Every live pane on this pane's Mac, labelled by its session.
    private var livePanes: [VigilPhone.Node] {
        guard let host = model.tree().first(where: { $0.children.contains { s in s.leafStates.count >= 0 && s.id.hasPrefix(current.host.id.uuidString) } }) else { return [] }
        var out: [VigilPhone.Node] = []
        for s in host.children {
            func walk(_ n: VigilPhone.Node) {
                if let _ = n.pane { var m = n; m.subtitle = s.title; out.append(m) }
                n.children.forEach(walk)
            }
            s.children.forEach(walk)
        }
        return out
    }

    private var sessionName: String {
        model.tree().flatMap(\.children).first { s in
            s.children.contains { $0.pane == current || $0.children.contains { $0.pane == current } }
        }?.title ?? ""
    }

    private func attach(_ ref: PaneRef) async {
        guard let app = ghostty.app else { error = "ghostty not ready"; return }
        if let view = model.adoptPreview(ref.pane) {
            view.isUserInteractionEnabled = true
            layout(view)
            surfaceView = view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = view.becomeFirstResponder() }
            return
        }
        do {
            let fd = try await model.attach(ref.host, pane: ref.pane)
            var config = Ghostty.SurfaceConfiguration()
            config.vigilAttach = ref.pane
            config.vigilFd = fd
            config.vigilMirror = true
            // A phone reads at 8pt (the Mac's 13 minus five loupe taps,
            // Adrian 2026-08-28); the loupe adjusts from here.
            config.fontSize = 8
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            layout(view)
            surfaceView = view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = view.becomeFirstResponder() }
        } catch {
            self.error = error.localizedDescription
            model.log("attach: \(ref.pane) failed: \(error.localizedDescription)")
        }
    }

    private func zoom(_ direction: Int) {
        if ownSize || grid == nil {
            surfaceView?.zoom(direction)
        } else {
            fitZoom = min(3, max(0.5, fitZoom * (direction > 0 ? 1.2 : 1 / 1.2)))
            if let v = surfaceView { layout(v) }
        }
    }

    /// FIT: the owner's grid at the surface's REAL cell size (published by
    /// ghostty once the font is set; a guessed 4.8×10 resized the Mac's
    /// pty to 95x126), scaled to the width times the picture zoom.
    private func fullSize(_ view: Ghostty.SurfaceView) -> CGSize? {
        let cell = view.liveCell
        guard let grid, cell.width > 0, cell.height > 0 else { return nil }
        return CGSize(width: CGFloat(grid.cols) * cell.width, height: CGFloat(grid.rows) * cell.height)
    }

    private func fitScale(_ view: Ghostty.SurfaceView) -> CGFloat {
        guard let full = fullSize(view) else { return 1 }
        return min(1, UIScreen.main.bounds.width / full.width) * fitZoom
    }

    /// The view's layout is decided BEFORE it enters the view tree: a
    /// wrapper that reports its own small frame first resizes the pty (the
    /// phone owns it once focused) and a TUI re-lays out at a dozen
    /// columns (2026-08-28). FIT = the owner's grid at 8pt metrics scaled
    /// to the screen width; OWN = whatever the screen gives.
    private func layout(_ view: Ghostty.SurfaceView) {
        if !ownSize, let grid {
            // The grid in CELLS: exact pixels come from the core's metrics
            // (nothing is reported until they exist).
            view.renderGrid = grid
            view.renderScale = fitScale(view)
            view.anchorBottom = false
        } else {
            view.renderGrid = nil
            view.renderScale = 1
            view.anchorBottom = false
        }
    }
}

/// esc / tab / ctrl / arrows / ⌃C / paste: the keys a software keyboard
/// hides. `ctrl` is a sticky modifier for the next typed letter.
struct KeyStrip: View {
    @Binding var ctrl: Bool
    let send: (String) -> Void
    let hideKeyboard: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { hideKeyboard() } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                }
                key("esc", "\u{1b}")
                key("tab", "\t")
                Button { ctrl.toggle() } label: {
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
                    if let s = UIPasteboard.general.string { send(s) }
                } label: { Image(systemName: "doc.on.clipboard").padding(.horizontal, 10).padding(.vertical, 6) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func key(_ label: String, _ keys: String) -> some View {
        Button { send(keys) } label: {
            Text(label).font(.caption.monospaced())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.2), in: Capsule())
        }
    }
}
