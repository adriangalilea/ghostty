import SwiftUI
import GhosttyKit

/// The phone's screens: ONE home tree (Macs → sessions → tabs → panes,
/// collapsible, the sidebar's rollup dots on every folded row) and a pane,
/// full screen, with a key strip the software keyboard lacks. The pane IS
/// a Ghostty surface (Metal, the Mac's renderer) attached through ssh.
struct VigilPhoneRoot: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @StateObject private var model = VigilPhone.shared

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .environmentObject(model)
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
            NavigationLink(value: ref) { content }.buttonStyle(.plain)
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

    /// 8pt monospace cell, the pane screen's font: the preview is laid out
    /// in the same metrics, scaled to the row's width, and clipped to a
    /// short window anchored at the BOTTOM of the grid: a terminal's
    /// action is at the bottom.
    private let cell = CGSize(width: 4.8, height: 10.0)
    private let height: CGFloat = 150
    private var fullSize: CGSize { CGSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height) }

    var body: some View {
        GeometryReader { geo in
            // Readable, never shrunk below 0.8: a wide grid shows its
            // bottom-LEFT window (content is left-aligned), clipped, rather
            // than the whole grid at half size (unreadable, 2026-08-28).
            let scale = min(1, max(0.8, geo.size.width / fullSize.width))
            ZStack(alignment: .bottomLeading) {
                Color(ghostty.config.backgroundColor)
                if let surfaceView {
                    Ghostty.SurfaceWrapper(surfaceView: surfaceView)
                        .frame(width: fullSize.width, height: fullSize.height)
                        .scaleEffect(scale, anchor: .bottomLeading)
                        .frame(width: fullSize.width * scale, height: fullSize.height * scale, alignment: .bottomLeading)
                        .allowsHitTesting(false)
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

    private func attach() async {
        guard surfaceView == nil, let app = ghostty.app else { return }
        guard model.previewAllowed(ref.pane) else { denied = true; return }
        do {
            let fd = try await model.attach(ref.host, pane: ref.pane, preview: true)
            var config = Ghostty.SurfaceConfiguration()
            config.vigilAttach = ref.pane
            config.vigilFd = fd
            config.vigilMirror = true
            config.fontSize = 8
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            surfaceView = view
            model.registerPreview(ref.pane, view: view)
        } catch {
            model.log("preview: \(ref.pane) failed: \(error.localizedDescription)")
        }
    }

    private func end() {
        guard let view = surfaceView else { return }
        view.vigilDetach()
        surfaceView = nil
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

struct AddHostView: View {
    @EnvironmentObject private var model: VigilPhone
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var user = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Host or IP", text: $hostname).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("User", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .navigationTitle("Add Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.hosts.append(.init(name: name.isEmpty ? hostname : name, hostname: hostname,
                                                 port: Int(port) ?? 22, user: user))
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

    var body: some View {
        NavigationStack {
            List {
                Section("Macs") {
                    ForEach(model.hosts) { host in
                        VStack(alignment: .leading) {
                            Text(host.name).font(.headline)
                            Text("\(host.user)@\(host.hostname):\(host.port)").font(.caption).foregroundStyle(.secondary)
                        }
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
                Section("Receipts") {
                    ForEach(Array(model.trace.suffix(60).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
            ZStack {
                Color(ghostty.config.backgroundColor)
                if let surfaceView {
                    Ghostty.SurfaceWrapper(surfaceView: surfaceView)
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
                Button { surfaceView?.zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { surfaceView?.zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
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
        .task { await attach(current) }
        .onDisappear {
            surfaceView?.vigilDetach()
            surfaceView = nil
        }
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
            surfaceView = view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = view.becomeFirstResponder() }
        } catch {
            self.error = error.localizedDescription
            model.log("attach: \(ref.pane) failed: \(error.localizedDescription)")
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
