#if os(iOS)
import AuthzClient
import AuthzUI
import SwiftUI

/// SSH transports opaque signed frames on stdin. The shell cannot forge a
/// device decision, and a response/secret never appears in command arguments.
struct VigilAuthorizationTransport: AuthzTransport {
    let host: VigilPhone.Host
    func call(_ request: RPC) async throws -> RPCResult {
        let fd = try await open()
        return try await Task.detached {
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var yes: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            try Framing.write(request, fd: fd)
            return try Framing.read(RPCResult.self, fd: fd)
        }.value
    }
    @MainActor private func open() async throws -> Int32 {
        let connection = try await VigilPhone.shared.connection(for: host)
        return try await connection.stream("$HOME/.local/bin/authz rpc")
    }
}

struct VigilAuthorizationView: View {
    @EnvironmentObject private var phone: VigilPhone
    @Environment(\.scenePhase) private var phase
    @State private var model: InboxModel?
    @State private var enrollment = ""
    @State private var error = ""
    @State private var host: VigilPhone.Host?
    var body: some View {
        NavigationStack {
            VStack {
                if let model { AuthzInbox(model: model) } else {
                    Text("Choose the Mac hosting your authorization service")
                    ForEach(phone.hosts) { host in Button(host.name) { connect(host) } }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if !enrollment.isEmpty {
                    Text("Trust this device from Authorization settings on your Mac.")
                    ShareLink("Share device enrollment", item: enrollment)
                }
                Button("Create device enrollment") { enroll() }
                if model != nil { Button("Disconnect") { model?.stop(); model = nil } }
            }.padding().navigationTitle("Requests")
        }
        .onDisappear { model?.stop() }
        .onChange(of: phase) { _, phase in
            if phase == .active, let host { connect(host) } else { model?.stop() }
        }
    }
    private func enroll() {
        do {
            // This UUID identifies the physical device for quorum counting.
            // Enrollment is reviewed on the Mac; copied keys cannot manufacture factors.
            let id = UIDevice.current.identifierForVendor?.uuidString ?? "phone"
            let value = try Enrollment.endpoint(name: UIDevice.current.name, deviceID: id)
            enrollment = String(bytes: try Canonical.encode(value), encoding: .utf8) ?? ""
        } catch { self.error = String(describing: error) }
    }
    private func connect(_ host: VigilPhone.Host) {
        do {
            let key = try DeviceIdentity.key()
            model?.stop(); self.host = host
            let model = InboxModel(transport: EndpointTransport(endpointID: Canonical.digest(key.publicKey.rawRepresentation), key: key,
                underlying: VigilAuthorizationTransport(host: host)))
            model.onHandoff = { pane in
                // Handoff opens the native pane; it is never interpreted as an answer.
                if let url = URL(string: "vigil://\(host.hostname)/_/\(pane)") { UIApplication.shared.open(url) }
            }
            self.model = model; model.start(); error = ""
        } catch { self.error = "Create and enroll this device first. \(error)" }
    }
}

#endif
