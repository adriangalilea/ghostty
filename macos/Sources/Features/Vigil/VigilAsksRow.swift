#if os(macOS)
import AppKit
import AskKit
import SwiftUI

/// Asks, from the sidebar: Authz.app owns them, and this row is a view of
/// ITS switches (its defaults domain, the same keys its menu and Settings
/// window use), so the two places can never disagree. Two switches where
/// the work is: Authz asking on this Mac at all, and vigil's own requests
/// asking here (Authz's per-app switch). Everything else is a click away in
/// Authz's Settings.
struct VigilAsksRow: View {
    private static let authz = UserDefaults(suiteName: "space.authz.app")
    /// AuthzAsk's AskLane.quietKey: requesters switched off in Authz.
    private static let quietKey = "authz.quietRequesters"
    @State private var asking = Self.readAsking()
    @State private var vigilAsks = Self.readVigilAsks()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 9))
                .foregroundColor(asking ? .accentColor : .secondary)
            Text("asks").font(.system(size: 10, weight: .medium))
                .foregroundColor(asking ? .primary : .secondary)
            Toggle("", isOn: Binding(get: { asking }, set: { on in
                Self.authz?.set(on, forKey: AskSettings.enabledKey)
                asking = on
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .help("Authz asks on this Mac. Off: nothing opens or speaks here; requests wait in Authz's menu.")
            Spacer(minLength: 4)
            Toggle("vigil", isOn: Binding(get: { vigilAsks }, set: { on in
                var quiet = Set(Self.authz?.stringArray(forKey: Self.quietKey) ?? [])
                if on { quiet.remove(VigilHarnessCoordinator.requester) } else { quiet.insert(VigilHarnessCoordinator.requester) }
                Self.authz?.set(quiet.sorted(), forKey: Self.quietKey)
                vigilAsks = on
            }))
            .toggleStyle(.switch).controlSize(.mini)
            .font(.system(size: 10))
            .disabled(!asking)
            .help("vigil's permission prompts ask here. Off: they wait in Authz's menu and the pane rings its own cue.")
            Button {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Authz.app"),
                    configuration: NSWorkspace.OpenConfiguration())
            } label: {
                Image(systemName: "gearshape").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Authz: voice, nod, devices, apps")
        }
        // Another place may flip them (Authz's own menu): re-read on focus.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            asking = Self.readAsking()
            vigilAsks = Self.readVigilAsks()
        }
    }

    private static func readAsking() -> Bool {
        authz?.object(forKey: AskSettings.enabledKey) as? Bool ?? true
    }
    private static func readVigilAsks() -> Bool {
        !(authz?.stringArray(forKey: quietKey) ?? []).contains(VigilHarnessCoordinator.requester)
    }
}
#endif
