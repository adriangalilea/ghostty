import AuthzClient
import AuthzGlance
import SwiftUI
import GhosttyKit

/// vigil for iPhone: a viewport onto the Macs' sessions. The terminal is
/// Ghostty's own (libghostty, Metal); the transport is tether (`vigil/1`,
/// to each Mac's vigil-agent); the facts are the Mac's. Nothing lives here.
@main
struct VigilPhoneApp: App {
    @UIApplicationDelegateAdaptor private var delegate: VigilAppDelegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var ghostty: Ghostty.App

    init() {
        // First: every event from here on is kept in its record.
        Record.keep(service: "vigil-phone")
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            preconditionFailure("Initialize ghostty backend failed")
        }
        _ghostty = StateObject(wrappedValue: Ghostty.App())
    }

    var body: some Scene {
        WindowGroup {
            VigilPhoneRoot()
                .environmentObject(ghostty)
                // A terminal app is dark; never flash light chrome between
                // a dark pane and the tree.
                .preferredColorScheme(.dark)
                // The app's tether node (VigilAuthz): the Macs' sessions
                // over `vigil/1`, and an authz endpoint beside Authz for
                // iPhone for the sessions you follow. Back on screen, both
                // pick up where they were.
                .onChange(of: phase, initial: true) { _, phase in
                    switch phase {
                    case .active: VigilAuthz.shared.start()
                    case .background: VigilAuthz.shared.leave()
                    default: break
                    }
                    VigilPhone.shared.scene(active: phase == .active)
                }
        }
    }
}
