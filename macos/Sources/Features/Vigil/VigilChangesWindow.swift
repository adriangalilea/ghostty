import AppKit
import GitKit
import GitViews
import SwiftUI
import VigilWire

/// A pane's changes in a window of its own (harness/GIT-VIEW.md), the
/// phone's view: what its agent edited in the conversation, its
/// repositories, any other repository on its Mac. A pane of this Mac is
/// read by its hub (`Local.here`); another Mac's through the hub over
/// tether, as the phone reads it. One window per pane, brought forward when
/// asked again; a quote is copied as Markdown (the Mac has no reply box).
@MainActor
enum VigilChangesWindow {
    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private static var open: [String: NSWindow] = [:]

    /// `pane` as the sidebar knows it: a local pane id, or `<tether root>/id`
    /// for another Mac's.
    static func show(pane: String, title: String) {
        if let window = open[pane] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let remote = VigilRemote.split(pane)
        let id = remote?.name ?? pane
        let git: PaneGitCall = { call in
            try await Task.detached {
                do {
                    if let remote {
                        return try hub.call(device: remote.device, .git(id, call))
                    }
                    return try hub.here(.git(id, call))
                } catch {
                    throw PaneGitCallFailed(description: "\(error)")
                }
            }.value
        }
        let view = VigilChanges(git: git, quote: { quote in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(quote.markdown, forType: .string)
        }, show: nil)
        .frame(minWidth: 640, minHeight: 480)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Changes · \(title)"
        window.setContentSize(NSSize(width: 980, height: 720))
        window.isReleasedWhenClosed = false
        window.center()
        open[pane] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = open.removeValue(forKey: pane) }
        }
        window.makeKeyAndOrderFront(nil)
        sidebarLog.info("changes opened", ["pane": pane])
    }
}
