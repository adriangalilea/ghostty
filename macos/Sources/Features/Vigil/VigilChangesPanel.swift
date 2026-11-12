import AppKit
import GitKit
import GitViews
import SwiftUI
import VigilWire

/// A pane's changes on the Mac (harness/GIT-VIEW.md), the phone's view: what
/// its agent edited in the conversation, its repositories, any other
/// repository on its Mac. A pane of this Mac is read by its hub
/// (`Local.here`); another Mac's through the hub over tether, as the phone
/// reads it. Shown in the window's right bar beside its tab's dock panes
/// (`VigilBars.showAside`), where the terminal stays in view; from there it
/// moves to a window of its own. A quote is copied as Markdown (the Mac has
/// no reply box).
@MainActor
enum VigilChangesPanel {
    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private static var windows: [String: NSWindow] = [:]

    /// The view of `pane` as the sidebar knows it: a local pane id, or
    /// `<tether root>/id` for another Mac's. `repository`: the one it opens
    /// on, as a path on the pane's Mac.
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

    /// In the right bar of `controller`'s window; with no window to show it
    /// in (asked from the menu bar), a window of its own.
    static func show(pane: String, title: String, repository: String? = nil, in controller: TerminalController?) {
        guard let controller = controller ?? TerminalController.all.first(where: { $0.window?.isKeyWindow == true }) else {
            window(pane: pane, title: title, repository: repository)
            return
        }
        VigilBars.shared.showAside(
            VigilBars.Aside(
                id: "changes:\(pane):\(repository ?? "")", title: title, symbol: "plusminus",
                view: AnyView(view(pane: pane, repository: repository)),
                popOut: { window(pane: pane, title: title, repository: repository) }),
            in: controller)
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
