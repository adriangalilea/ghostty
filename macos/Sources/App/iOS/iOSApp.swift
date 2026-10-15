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
                // a dark pane and the tree (Adrian 2026-08-28).
                .preferredColorScheme(.dark)
                // The app's tether node (VigilAuthz): the Macs' sessions
                // over `vigil/1`, and an authz endpoint beside Authz for
                // iPhone for the sessions you follow. Back on screen, both
                // pick up where they were.
                .onChange(of: phase, initial: true) { _, phase in
                    if phase == .active { VigilAuthz.shared.start() }
                }
        }
    }
}
