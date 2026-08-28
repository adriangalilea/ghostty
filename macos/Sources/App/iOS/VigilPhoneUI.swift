import SwiftUI
import GhosttyKit

/// The phone's screens: Macs → a Mac's tree → one pane, full screen, with
/// a key strip the software keyboard lacks. The pane IS a Ghostty surface
/// (Metal, the same renderer as the Mac) attached through the ssh bridge.
struct VigilPhoneRoot: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @StateObject private var model = VigilPhone.shared

    var body: some View {
        NavigationStack {
            HostsView()
        }
        .environmentObject(model)
    }
}

struct HostsView: View {
    @EnvironmentObject private var model: VigilPhone
    @State private var adding = false
    @State private var showKey = false

    var body: some View {
        List {
            Section("Macs") {
                ForEach(model.hosts) { host in
                    NavigationLink(value: host) {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) {
                                Text(host.name).font(.headline)
                                Text("\(host.user)@\(host.hostname):\(host.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let err = model.errors[host.id] {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    .help(err)
                            } else if model.directories[host.id] != nil {
                                Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption2)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Forget host key") { model.forgetHostKey(host) }
                        Button("Refresh") { Task { await model.refresh(host) } }
                    }
                }
                .onDelete { model.hosts.remove(atOffsets: $0) }
            }
            Section {
                Button { showKey = true } label: { Label("This phone's key", systemImage: "key") }
            } footer: {
                Text("Add the key to ~/.ssh/authorized_keys on each Mac. vigild must be on the Mac's PATH for ssh.")
            }
            Section("Receipts") {
                ForEach(Array(model.trace.suffix(30).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("vigil")
        .navigationDestination(for: VigilPhone.Host.self) { host in TreeView(host: host) }
        .toolbar {
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) { AddHostView() }
        .sheet(isPresented: $showKey) { KeyView() }
        .onAppear { model.refreshAll() }
    }
}

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

struct KeyView: View {
    @EnvironmentObject private var model: VigilPhone
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Append this line to ~/.ssh/authorized_keys on the Mac:")
                Text(model.publicKeyLine).font(.caption.monospaced()).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = model.publicKeyLine
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Spacer()
            }
            .padding()
            .navigationTitle("Phone key")
        }
    }
}

struct TreeView: View {
    let host: VigilPhone.Host
    @EnvironmentObject private var model: VigilPhone

    var body: some View {
        let rows = model.rows(for: host)
        List {
            if let err = model.errors[host.id] {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(.caption)
            }
            ForEach(rows) { row in
                if row.kind == .pane, let pane = row.paneId, row.alive {
                    NavigationLink(value: PaneRef(host: host, pane: pane, title: row.title)) {
                        RowView(row: row)
                    }
                } else {
                    RowView(row: row)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.directories[host.id]?.host ?? host.name)
        .navigationDestination(for: PaneRef.self) { ref in PaneScreen(ref: ref) }
        .refreshable { await model.refresh(host) }
        .task { await model.refresh(host) }
    }
}

struct PaneRef: Hashable {
    let host: VigilPhone.Host
    let pane: String
    let title: String
}

struct RowView: View {
    let row: VigilPhone.Row
    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: CGFloat(row.depth) * 16)
            if row.kind == .pane {
                Circle().fill(stateColor).frame(width: 8, height: 8)
            }
            if let e = row.emoji { Text(e) }
            Text(row.title)
                .font(row.kind == .session ? .headline : .body)
                .foregroundStyle(row.alive ? .primary : .secondary)
            if row.kind == .pane && !row.alive {
                Text("cold").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
    private var stateColor: Color {
        guard row.alive else { return .gray.opacity(0.3) }
        switch row.state {
        case "blocked": return .orange
        case "working": return .yellow
        case "done": return .teal
        default: return .gray
        }
    }
}

/// One pane, full screen: the surface attaches on appear (an fd from the
/// ssh bridge), claims the pty size when it takes focus, and lets go on
/// disappear. The key strip supplies what a phone keyboard lacks.
struct PaneScreen: View {
    let ref: PaneRef
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var model: VigilPhone
    @State private var surfaceView: Ghostty.SurfaceView?
    @State private var error: String?
    @State private var ctrl = false

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
        .navigationTitle(ref.title)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.container, edges: .bottom)
        .task { await attach() }
        .onDisappear {
            surfaceView?.vigilDetach()
            surfaceView = nil
        }
    }

    private func attach() async {
        guard let app = ghostty.app else { error = "ghostty not ready"; return }
        do {
            let fd = try await model.attach(ref.host, pane: ref.pane)
            var config = Ghostty.SurfaceConfiguration()
            config.vigilAttach = ref.pane
            config.vigilFd = fd
            config.vigilMirror = true
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
