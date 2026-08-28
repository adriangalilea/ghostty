import SwiftUI
import GhosttyKit

/// vigil for iPhone: a viewport onto the Macs' sessions. The terminal is
/// Ghostty's own (libghostty, Metal); the transport is ssh (VigilSSH); the
/// facts are the Mac's (`vigild dir` / `vigild proxy`). Nothing lives here.
@main
struct VigilPhoneApp: App {
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
        }
    }
}
