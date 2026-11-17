import AppKit
import SwiftUI
import VigilWire

/// A pane's documents on the Mac (harness/DOCUMENTS.md), the phone's view:
/// the files its agent works from, read and edited as pages. A pane of this
/// Mac is asked of its hub (`Local.here`); another Mac's through the hub
/// over tether, as the phone asks. Where it is shown is `show`'s rule, the
/// one `VigilChangesPanel` has.
@MainActor
enum VigilDocumentsPanel {
    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private static var windows: [String: NSWindow] = [:]

    private struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    /// The view of `pane` as the sidebar knows it: a local pane id, or
    /// `<tether root>/id` for another Mac's.
    static func view(pane: String) -> some View {
        let remote = VigilRemote.split(pane)
        let id = remote?.name ?? pane
        let call: PaneDocumentCall = { ask in
            try await Task.detached {
                do {
                    if let remote { return try hub.call(device: remote.device, .documents(id, ask)) }
                    return try hub.here(.documents(id, ask))
                } catch {
                    throw Failed(description: "\(error)")
                }
            }.value
        }
        let watch: PaneDocumentWatch = { hub.documentChanges(device: remote?.device, pane: id) }
        // The person's words for the pane's agent (`Open.say`): its Mac
        // posts them to its mailbox where its agent's carrier is on, types
        // them otherwise; this Mac's pane asked of its own hub, another
        // Mac's through it.
        let tell: PaneTell = { line in
            let said: Said = try await Task.detached {
                do {
                    let answer = try remote.map { try hub.call(device: $0.device, .say(id, text: line)) } ?? hub.here(.say(id, text: line))
                    return try JSONDecoder().decode(Said.self, from: answer)
                } catch {
                    throw Failed(description: "\(error)")
                }
            }.value
            sidebarLog.info("documents: agent told", ["pane": pane, "how": said.words])
        }
        return VigilDocuments(call: call, watch: watch, tell: tell, local: remote == nil)
    }

    /// Documents appear where their subject is: a pane on screen in
    /// `controller`'s window gets that window's right bar, beside the
    /// terminal whose agent reads them; any other pane a window of its own.
    static func show(pane: String, title: String, in controller: TerminalController?) {
        guard let controller, VigilBars.shared.panesOnScreen(in: controller).contains(pane) else {
            window(pane: pane, title: title)
            return
        }
        VigilBars.shared.showAside(
            VigilBars.Aside(
                pane: pane, kind: .documents, title: title,
                view: AnyView(view(pane: pane)),
                popOut: { window(pane: pane, title: title) }))
        sidebarLog.info("documents opened", ["pane": pane, "where": "right bar"])
    }

    /// One window per pane, brought forward when asked again.
    static func window(pane: String, title: String) {
        if let window = windows[pane] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: view(pane: pane).frame(minWidth: 420, minHeight: 360)))
        window.title = "Documents · \(title)"
        window.setContentSize(NSSize(width: 1100, height: 780))
        window.isReleasedWhenClosed = false
        window.center()
        windows[pane] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = windows.removeValue(forKey: pane) }
        }
        window.makeKeyAndOrderFront(nil)
        sidebarLog.info("documents opened", ["pane": pane, "where": "window"])
    }
}
