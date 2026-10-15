#if os(macOS)
import AppKit
import Face
import SwiftUI

/// Dictation's one setting: the languages it listens in (Face's editor over
/// the suite's `Languages`; the sidebar rail's picker pins one). Asks and
/// their voice are Authz.app's and are set there.
@MainActor
enum VigilVoiceSettings {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Dictation languages"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Form {
            Section {
                LanguagesEditor()
            } footer: {
                Text("What dictation listens in. Several race per phrase; the rail's picker pins one.")
            }
        }
        .formStyle(.grouped))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}
#endif
