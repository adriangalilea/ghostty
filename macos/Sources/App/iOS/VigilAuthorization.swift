#if os(iOS)
import AuthzClient
import AuthzUI
import SwiftUI

/// The phone uses the same pinned, signed protocol as a Mac endpoint. Opening
/// the Requests sheet is presentation intent; leaving it ends that lifetime.
struct VigilAuthorizationView: View {
    @EnvironmentObject private var phone: VigilPhone
    @Environment(\.scenePhase) private var phase
    @State private var model: InboxModel?
    @State private var connection: RemoteTransport?
    @State private var homes: [TrustedHome] = []
    @State private var selected: TrustedHome?
    @State private var error = ""
    @State private var visible = false
    @State private var pairing = false
    var body: some View {
        NavigationStack {
            VStack {
                if let model { AuthzInbox(model: model) } else {
                    Text("Choose the home Mac")
                    ForEach(homes) { home in Button(home.name) { connect(home) } }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Button("Pair a home Mac") { pairing = true }
                if model != nil { Button("Disconnect") { stop(); selected = nil } }
            }.padding().disabled(phase != .active).navigationTitle("Requests")
        }
        .sheet(isPresented: $pairing, onDismiss: refresh) { ScrollView { PairingView().padding() } }
        .onAppear { visible = true; refresh() }
        .onDisappear { visible = false; stop() }
        .onChange(of: phase) { _, phase in
            if phase == .background { stop() } else if phase == .active, visible, !pairing, model == nil, let selected { connect(selected) }
        }
        .onChange(of: pairing) { _, pairing in if pairing { stop() } }
    }
    private func refresh() { homes = (try? PeerTrust.homes()) ?? [] }
    private func stop() {
        model?.stop(); model = nil
        if let connection { Task { await connection.close() } }
        connection = nil
    }
    private func connect(_ home: TrustedHome) {
        guard visible, phase == .active, !pairing else { return }
        guard let host = phone.hosts.first(where: { $0.hostname == home.route || $0.name == home.route }) else {
            error = "Add this home to the phone’s Macs, using its address or name as the pairing route."
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
    @MainActor private static func open(_ host: VigilPhone.Host) async throws -> Int32 {
        let ssh = try await VigilPhone.shared.connection(for: host)
        return try await ssh.stream("$HOME/.local/bin/authz endpoint")
    }
}
#endif
