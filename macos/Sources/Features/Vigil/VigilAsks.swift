#if os(macOS)
import AppKit
import AskKit
import SwiftUI
import VigilWire

/// Where a pane's questions go, said in the sidebar's footer: to Authz, or
/// staying at the pane (with vigil's own chime), and why. A view of Authz's
/// own switches and of the broker's standing with authzd, never a copy:
/// the switches are Authz's to change, so its one act opens Authz.
@MainActor
final class VigilAsks: ObservableObject {
    static let shared = VigilAsks()

    /// The broker's word (`agent/authz`), re-read when that folder changes.
    @Published private(set) var standing: AuthzStanding? = AuthzStanding.read()
    private var watch: DispatchSourceFileSystemObject?

    private init() {
        let folder = open(VigilPaths.agent.path, O_EVTONLY)
        guard folder >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                let now = AuthzStanding.read()
                if now != self?.standing { self?.standing = now }
            }
        }
        source.setCancelHandler { close(folder) }
        source.resume()
        watch = source
    }

    static let bundle = "space.authz.app"
    var authz: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundle) }

    /// The line and whether questions reach Authz. Authz's switches are read
    /// when the sidebar draws (another app's defaults post no event here).
    var said: (text: String, reaches: Bool, why: String) {
        guard authz != nil else {
            return ("Questions stay in the pane", false, "Authz is not installed: questions are answered at the pane.")
        }
        let defaults = UserDefaults(suiteName: Self.bundle)
        if defaults?.object(forKey: AskSettings.enabledKey) as? Bool == false {
            return ("Questions stay in the pane · off in Authz", false, "Asks are switched off in Authz's menu.")
        }
        if (defaults?.stringArray(forKey: "authz.quietRequesters") ?? []).contains(VigilHarnessCoordinator.requester) {
            return ("Questions stay in the pane · vigil off in Authz", false, "vigil is switched off in Authz's Apps.")
        }
        switch standing {
        case .allowed:
            return ("Questions go to Authz", true, "A pane's questions are asked in Authz wherever you are, unless the pane is on screen.")
        case .pending:
            return ("Allow vigil in Authz", false, "Authz is asking whether vigil may ask; until then questions stay in the pane.")
        case .refused:
            return ("Questions stay in the pane · refused in Authz", false, "Authz › Settings › Apps can let vigil ask again.")
        case .unreachable:
            return ("Questions stay in the pane · Authz not running", false, "authzd does not answer; open Authz to start it.")
        case .unsigned:
            return ("Questions stay in the pane · unsigned build", false, "Authz never takes an unsigned vigil-agent.")
        case nil:
            return ("Questions stay in the pane · broker not started", false, "vigil-agent has not reported to Authz yet.")
        }
    }

    func openAuthz() {
        guard let authz else { return }
        NSWorkspace.shared.openApplication(at: authz, configuration: .init())
    }
}

/// The footer's line for `VigilAsks`.
struct VigilAsksRow: View {
    @ObservedObject private var asks = VigilAsks.shared

    var body: some View {
        let said = asks.said
        HStack(spacing: 5) {
            Circle()
                .fill(said.reaches ? Color.accentColor : Color.orange)
                .frame(width: 6, height: 6)
            Text(said.text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if asks.authz != nil {
                Button("Authz") { asks.openAuthz() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .help(said.why)
    }
}
#endif
