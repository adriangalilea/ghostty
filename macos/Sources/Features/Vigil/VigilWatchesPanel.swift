import AppKit
import Combine
import SwiftUI
import VigilWire

/// Every Mac's watches as the person's view reads them (harness's
/// `WatchBoard`): this Mac's and each paired Mac's, each followed through
/// this Mac's hub (`Local.watchSteps`: whole at every opening, then each
/// change, never polled), as the mailboxes are (`VigilMessageStore`).
@MainActor
final class VigilWatchStore: ObservableObject {
    static let shared = VigilWatchStore()

    /// Each Mac's records by its tether root.
    @Published private(set) var boards: [String: [String: WatchRecord]] = [:]
    /// This Mac's tether root, said by the hub when this Mac's watches open.
    @Published private(set) var here: String?
    /// What the sidebar's rows draw, apart from the records: a run's
    /// history moves `boards` and repaints the window, never the sidebar.
    let marks = Marks()

    @MainActor
    final class Marks: ObservableObject {
        /// The live watches reaching each pane, by root then pane, replaced
        /// only when what a row draws of them differs.
        @Published fileprivate(set) var reaching: [String: [String: [WatchRecord]]] = [:]
        @Published fileprivate(set) var here: String?

        /// The watches a pane row wears: `paneId` for this Mac's, the
        /// composite row id (`device/pane`) for another's.
        func watches(paneId: String?, id: String) -> [WatchRecord] {
            if let paneId { return here.flatMap { reaching[$0]?[paneId] } ?? [] }
            guard let (device, pane) = VigilRemote.split(id) else { return [] }
            return reaching[device]?[pane] ?? []
        }
    }

    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private var following: [String: Task<Void, Never>] = [:]

    var brokenTotal: Int { boards.values.flatMap(\.values).filter(\.isBroken).count }

    // MARK: Following (VigilRemote says when the hub answers and which Macs there are)

    func hubAnswers() { follow(device: nil) }

    func macs(_ devices: Set<String>) {
        for (key, task) in following where !key.isEmpty && !devices.contains(key) {
            task.cancel()
            following[key] = nil
            boards[key] = nil
        }
        for device in devices { follow(device: device) }
        remark()
    }

    func hubGone() {
        for task in following.values { task.cancel() }
        following.removeAll()
    }

    /// A follow that ends while the hub stands is followed again at once
    /// when it had delivered (it fell behind, or a path dropped); one that
    /// never delivered waits for the hub's next word, never dialed in a loop.
    private func follow(device: String?) {
        let key = device ?? ""
        guard following[key] == nil else { return }
        let steps = Self.hub.watchSteps(device: device)
        following[key] = Task { [weak self] in
            var root = device
            var delivered = false
            for await step in steps {
                switch step.step {
                case .open:
                    root = step.root
                    if device == nil {
                        self?.here = step.root
                        self?.marks.here = step.root
                    }
                    watchesLog.info("watches followed", ["device": String((step.root ?? "?").prefix(10)), "here": device == nil])
                case .changes:
                    guard let root, let changes = step.changes else { continue }
                    delivered = true
                    self?.apply(root, changes)
                case .waiting: watchesLog.info("watches out of reach", ["device": String(key.prefix(10)), "why": step.reason ?? ""])
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.following[key] = nil
            watchesLog.warn("watches follow ended", ["device": String(key.prefix(10)), "next": delivered ? "followed again" : "waits for the hub"])
            if delivered { self.follow(device: device) }
        }
    }

    private func apply(_ root: String, _ changes: WatchRecord.Changes) {
        let before = boards[root] ?? [:]
        let after = changes.applied(to: before)
        // A watch that became broken is said once, where it is read.
        for record in after.values where record.isBroken && before[record.id]?.isBroken != true {
            watchesLog.warn("watch broken", ["root": String(root.prefix(10)), "watch": record.id,
                                             "why": record.broken.map(\.words).joined(separator: "; ")])
        }
        boards[root] = after
        remark()
    }

    private func remark() {
        let next = VigilWatchList.marks(boards)
        if !VigilWatchList.drawSame(next, marks.reaching) { marks.reaching = next }
    }

    // MARK: The host the views ask

    var host: VigilWatchHost {
        let here = here
        return VigilWatchHost(
            here: here,
            mac: { root in VigilRemote.shared.hosts.first { $0.device == root }?.name ?? "another Mac" },
            pane: { root, pane in VigilMessageStore.shared.panes["\(root)/\(pane)"]?.pane.said ?? pane },
            open: { root, pane in VigilMessageStore.shared.open(root: root, pane: pane, in: VigilMessageStore.viewport) })
    }
}

/// The Watches window (every watch of every Mac) and a pane's watches in
/// the right bar, shown where Documents, Changes and Messages are.
@MainActor
enum VigilWatchesPanel {
    private static var shown: NSWindow?

    static func window() {
        if let shown {
            shown.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: VigilWatchesWindow().frame(minWidth: 420, minHeight: 360)))
        window.title = "Watches"
        window.setContentSize(NSSize(width: 820, height: 680))
        window.isReleasedWhenClosed = false
        window.center()
        shown = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { shown = nil }
        }
        window.makeKeyAndOrderFront(nil)
        watchesLog.info("watches opened", ["where": "window"])
    }

    /// A pane's watches beside it when it is on screen in `controller`'s
    /// window, else the window. `id`: a local pane id, or `<root>/id`.
    static func show(paneId: String?, id: String, title: String, in controller: TerminalController?) {
        let store = VigilWatchStore.shared
        let target: (root: String, pane: String)?
        if let paneId { target = store.here.map { ($0, paneId) } } else { target = VigilRemote.split(id).map { ($0.device, $0.name) } }
        guard let target else { return watchesLog.warn("watches: this Mac's watches have not answered yet", ["pane": id]) }
        let pane = paneId ?? id
        guard let controller, VigilBars.shared.panesOnScreen(in: controller).contains(pane) else { return window() }
        VigilBars.shared.showAside(
            VigilBars.Aside(
                pane: pane, kind: .watches, title: title,
                view: AnyView(VigilWatchesAside(root: target.root, pane: target.pane)),
                popOut: { window() }))
        watchesLog.info("watches opened", ["pane": pane, "where": "right bar"])
    }
}

private struct VigilWatchesWindow: View {
    @ObservedObject private var store = VigilWatchStore.shared

    var body: some View {
        VigilWatches(boards: store.boards, host: store.host).padding()
    }
}

private struct VigilWatchesAside: View {
    let root: String
    let pane: String
    @ObservedObject private var store = VigilWatchStore.shared

    var body: some View {
        VigilPaneWatches(boards: store.boards, root: root, pane: pane, host: store.host).padding(8)
    }
}
