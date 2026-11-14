import AppKit
import GitKit
import GitViews
import Ink
import SwiftUI
import VigilWire

/// A pane's changes on the Mac (harness/GIT-VIEW.md), the phone's view: what
/// its agent edited in the conversation, its repositories, any other
/// repository on its Mac. A pane of this Mac is read by its hub
/// (`Local.here`); another Mac's through the hub over tether, as the phone
/// reads it. Where it is shown is `show`'s rule. A quote is copied as
/// Markdown (the Mac has no reply box).
@MainActor
enum VigilChangesPanel {
    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private static var windows: [String: NSWindow] = [:]

    /// The view of `pane` as the sidebar knows it: a local pane id, or
    /// `<tether root>/id` for another Mac's. `repository`: that one alone,
    /// as a path on the pane's Mac (a Bring Here's dialog asks about one).
    static func view(pane: String, repository: String? = nil) -> some View {
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
        let watch: PaneGitWatch = { root in hub.gitChanges(device: remote?.device, pane: id, repo: root) }
        return VigilChanges(git: git, watch: watch, quote: { quote in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(quote.markdown, forType: .string)
        }, show: nil, opening: repository)
    }

    /// Changes appear where their subject is. A pane on screen in
    /// `controller`'s window: that window's right bar, beside the terminal
    /// they describe. Any other pane (another tab, another workspace,
    /// another Mac): a window of its own, since no terminal here is theirs
    /// to sit beside. (A Bring Here's dialog shows a repository's inside
    /// itself, `BringDialog`.)
    static func show(pane: String, title: String, in controller: TerminalController?) {
        guard let controller, VigilBars.shared.panesOnScreen(in: controller).contains(pane) else {
            window(pane: pane, title: title)
            return
        }
        VigilBars.shared.showAside(
            VigilBars.Aside(
                pane: pane, kind: .changes, title: title,
                view: AnyView(view(pane: pane).inkEmbedded()),
                popOut: { window(pane: pane, title: title) }))
        sidebarLog.info("changes opened", ["pane": pane, "where": "right bar"])
    }

    /// One window per pane, brought forward when asked again.
    static func window(pane: String, title: String, repository: String? = nil) {
        if let window = windows[pane] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: view(pane: pane, repository: repository).frame(minWidth: 640, minHeight: 480)))
        window.title = "Changes · \(title)"
        window.setContentSize(NSSize(width: 980, height: 720))
        window.isReleasedWhenClosed = false
        window.center()
        windows[pane] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = windows.removeValue(forKey: pane) }
        }
        window.makeKeyAndOrderFront(nil)
        sidebarLog.info("changes opened", ["pane": pane, "where": "window"])
    }
}
