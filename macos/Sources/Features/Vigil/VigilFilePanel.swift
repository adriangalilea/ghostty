import AppKit
import SwiftUI
import VigilWire

/// A file a message names, opened on the Mac (`VigilFilePage`): beside the
/// pane of the thread it was pressed in when that pane is on screen in the
/// key window, a page of the right bar of its own (each file its own aside,
/// `VigilBars.Aside.Kind.file`); a window of its own otherwise, as
/// Documents and Changes are shown.
@MainActor
enum VigilFilePanel {
    private static var windows: [String: NSWindow] = [:]

    /// `pane`: the sidebar's id of the thread's pane (a local pane id, or
    /// `<tether root>/id` for another Mac's).
    static func show(_ file: VigilMentionedFile, beside pane: String) {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.lastMain
        guard let controller, VigilBars.shared.panesOnScreen(in: controller).contains(pane) else {
            window(file)
            return
        }
        VigilBars.shared.showAside(
            VigilBars.Aside(
                pane: pane, kind: .file(file), title: file.name,
                view: AnyView(page(file)),
                popOut: { window(file) }))
        messagesLog.info("file opened", ["path": file.path, "where": "right bar"])
    }

    /// One window per file, brought forward when asked again.
    static func window(_ file: VigilMentionedFile) {
        let id = file.root + file.path
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: page(file).frame(minWidth: 420, minHeight: 360)))
        window.title = file.name
        window.subtitle = file.shown
        window.setContentSize(NSSize(width: 900, height: 760))
        window.isReleasedWhenClosed = false
        window.center()
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = windows.removeValue(forKey: id) }
        }
        window.makeKeyAndOrderFront(nil)
        messagesLog.info("file opened", ["path": file.path, "where": "window"])
    }

    private static func page(_ file: VigilMentionedFile) -> some View {
        let here = VigilMessageStore.shared.here
        let path = file.path
        return VigilFilePage(
            file: file,
            read: {
                try JSONDecoder().decode(
                    DocumentText.self, from: await VigilMessageStore.mention(.read(path), root: file.root, here: here))
            },
            reveal: file.root == here ? { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } : nil)
    }
}
