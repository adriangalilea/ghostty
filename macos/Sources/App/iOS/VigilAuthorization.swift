#if os(iOS)
import AuthzClient
import AuthzUI
import SwiftUI

/// The phone uses the same pinned, signed protocol as a Mac endpoint. Opening
/// the Requests sheet is presentation intent; leaving it ends that lifetime.
struct VigilAuthorizationView: View {
    @EnvironmentObject private var phone: VigilPhone
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var model: InboxModel?
    @State private var connection: RemoteTransport?
    @State private var homes: [TrustedHome] = []
    @State private var selected: TrustedHome?
    @State private var error = ""
    @State private var visible = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let model { AuthzInbox(model: model) } else {
                    List {
                        Section {
                            ForEach(phone.hosts.filter { pairedHome(for: $0) != nil }) { host in
                                Button {
                                    if let home = pairedHome(for: host) { connect(home) }
                                } label: {
                                    HStack {
                                        Image(systemName: "laptopcomputer")
                                        VStack(alignment: .leading) {
                                            Text(host.name).foregroundStyle(.primary)
                                            Text("Paired · Open requests")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Section {
                            PairingView(destinations: phone.hosts.filter { pairedHome(for: $0) == nil }.map {
                                .init(name: $0.name, route: $0.hostname)
                            }, connect: { route in
                                guard let host = await MainActor.run(body: {
                                    VigilPhone.shared.hosts.first { $0.hostname == route }
                                }) else { throw TransportError.invalidPeer }
                                return PairingTransport {
                                    let fd = try await Self.open(host, command: "pairing")
                                    Framing.configure(fd)
                                    return RemoteStream(input: fd, output: fd) {
                                        _ = Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd)
                                    }
                                }
                            })
                        }
                    }
                    .overlay {
                        if phone.hosts.isEmpty {
                            ContentUnavailableView("No Macs yet", systemImage: "laptopcomputer",
                                                   description: Text("Add a Mac from Vigil’s home screen first."))
                        }
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .disabled(phase != .active)
            .navigationTitle(selected?.name ?? "Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model != nil { Button("Macs", systemImage: "chevron.left") { stop(); selected = nil } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { stop(); dismiss() } }
            }

        }
        .onAppear { visible = true; refresh() }
        .onDisappear { visible = false; stop() }
        .onChange(of: phase) { _, phase in
            if phase == .background { stop() } else if phase == .active, visible, model == nil, let selected { connect(selected) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("authz.peers.changed"))) { _ in refresh() }
    }
    private func pairedHome(for host: VigilPhone.Host) -> TrustedHome? {
        homes.first { $0.route == host.hostname || $0.route == host.name }
    }
    private func refresh() {
        do { homes = try PeerTrust.homes() } catch { self.error = "Saved authorization pairings are unavailable. Unlock this iPhone and try again." }
    }
    private func stop() {
        model?.stop(); model = nil
        if let connection { Task { await connection.close() } }
        connection = nil
    }
    private func connect(_ home: TrustedHome) {
        guard visible, phase == .active else { return }
        guard let host = phone.hosts.first(where: { $0.hostname == home.route || $0.name == home.route }) else {
            error = "This Mac is no longer saved in Vigil. Add it from the home screen to reconnect."
            return
        }
        do {
            let key = try DeviceIdentity.key(), id = Canonical.digest(key.publicKey.rawRepresentation)
            stop(); selected = home
            let connection = RemoteTransport(home: home, endpointID: id, key: key) {
                let fd = try await Self.open(host)
                Framing.configure(fd)
                return RemoteStream(input: fd, output: fd) { _ = Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
            }
            let model = InboxModel(transport: EndpointTransport(endpointID: id, key: key, underlying: connection), expectedHomeID: home.id)
            model.onRequestHandoff = { request in
                if let url = URL(string: "vigil://\(host.hostname)/_/\(request.request.context)") { UIApplication.shared.open(url) }
            }
            self.connection = connection; self.model = model; model.start(); error = ""
        } catch { self.error = "Device identity unavailable. Pair this phone first." }
    }
    @MainActor private static func open(_ host: VigilPhone.Host, command: String = "endpoint") async throws -> Int32 {
        let ssh = try await VigilPhone.shared.connection(for: host)
        return try await ssh.stream("$HOME/.local/bin/authz \(command)")
    }
}
#endif
