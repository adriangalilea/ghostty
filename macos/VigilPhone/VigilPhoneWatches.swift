import Combine
import Ink
import SwiftUI
import TetherKit
import VigilLink
import VigilWire

/// Every Mac's watches as the person's view on the phone reads them
/// (harness/README.md "Watches, as the person reads them"): each paired
/// Mac's board followed over tether (`VigilLink.watches`: whole at every
/// opening, then each change, reopened the moment the Mac may be back), as
/// the Mac app's `VigilWatchStore` reads them through its hub. The views are
/// the Mac's own (`VigilWatches`, `VigilPaneWatches`, `WatchMark`). A watch
/// is read here and ended where it was armed: no act on one crosses the wire.
@MainActor
final class VigilPhoneWatches: ObservableObject {
    static let shared = VigilPhoneWatches()

    /// Each Mac's records by its tether root.
    @Published private(set) var boards: [String: [String: WatchRecord]] = [:]
    /// What the tree's rows draw of the boards, apart from them: a run's
    /// history moves `boards` and repaints the list, never the tree.
    let marks = Marks()

    @MainActor
    final class Marks: ObservableObject {
        /// The live watches reaching each pane, by root then pane, replaced
        /// only when what a row draws of them differs.
        @Published fileprivate(set) var reaching: [String: [String: [WatchRecord]]] = [:]
        /// Broken watches on every Mac: the home's binoculars wear the count.
        @Published fileprivate(set) var broken = 0

        func watches(root: String, pane: String) -> [WatchRecord] { reaching[root]?[pane] ?? [] }
    }

    private var node: TetherNode?
    /// Each Mac's watches follow, by its tether root.
    private var following: [String: Task<Void, Never>] = [:]
    private var receipts: VigilReceipts { VigilPhone.shared.receipts }

    private init() {}

    // MARK: Following (VigilPhone says when the node is up and which Macs there are)

    func attach(node: TetherNode) {
        guard self.node == nil else { return }
        self.node = node
    }

    /// The paired Macs now: each one's watches followed, a Mac gone taken out.
    func macs(_ roots: Set<String>) {
        for (root, task) in following where !roots.contains(root) {
            task.cancel()
            following[root] = nil
            boards[root] = nil
        }
        for root in roots { follow(root) }
        remark()
    }

    /// Tether keeps the follow open and opens it again when the Mac may be
    /// back; out of reach, what it held is shown as it was. Only the node
    /// closing ends it: the Mac is followed afresh at the next word of the
    /// paired Macs.
    private func follow(_ root: String) {
        guard following[root] == nil, let node else { return }
        let steps = VigilLink.watches(node, device: root)
        following[root] = Task { [weak self] in
            for await step in steps {
                guard let self else { return }
                switch step.step {
                case .open: self.receipts.info("watches", "watches followed", ["mac": self.macName(root)])
                case .changes:
                    guard let changes = step.changes else { continue }
                    self.apply(root, changes)
                case .waiting:
                    self.receipts.warn("watches", "watches out of reach", ["mac": self.macName(root), "why": step.reason ?? ""])
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.receipts.warn("watches", "watches follow ended", ["mac": self.macName(root)])
            self.following[root] = nil
        }
    }

    private func apply(_ root: String, _ changes: WatchRecord.Changes) {
        let before = boards[root] ?? [:]
        let after = changes.applied(to: before)
        // A watch that became broken is said once, where it is read.
        for record in after.values where record.isBroken && before[record.id]?.isBroken != true {
            receipts.warn("watches", "watch broken", ["mac": macName(root), "watch": record.id,
                                                      "why": record.broken.map(\.words).joined(separator: "; ")])
        }
        boards[root] = after
        remark()
    }

    private func remark() {
        let next = VigilWatchList.marks(boards)
        if !VigilWatchList.drawSame(next, marks.reaching) { marks.reaching = next }
        let broken = boards.values.flatMap(\.values).filter(\.isBroken).count
        if broken != marks.broken { marks.broken = broken }
    }

    private func macName(_ root: String) -> String {
        VigilPhone.shared.hosts.first { $0.id == root }?.name ?? "a Mac"
    }

    // MARK: The host the views ask

    /// The phone is no Mac: every watch is another Mac's, said with its
    /// Mac's name. `left`: what shows the list steps aside before a pane
    /// opens (a sheet dismissed).
    func host(left: @escaping @MainActor () -> Void = {}) -> VigilWatchHost {
        VigilWatchHost(
            here: nil,
            mac: { [weak self] root in self?.macName(root) ?? "a Mac" },
            pane: { root, pane in VigilPhoneMessages.pane(root: root, pane: pane).title },
            open: { root, pane in
                left()
                VigilPhoneMessages.open(root: root, pane: pane, from: "watches")
            })
    }
}

/// Every watch of every Mac, from the home's binoculars.
struct PhoneWatchesScreen: View {
    @ObservedObject private var store = VigilPhoneWatches.shared

    var body: some View {
        // The list scrolls itself (Ink's notices), as in the Mac's window.
        VigilWatches(boards: store.boards, host: store.host())
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Watches")
            .toolbarTitleDisplayMode(.inline)
    }
}

/// One pane's watches, from its row's long press or its screen's menu: a
/// sheet over what shows, stepped aside when "go to" opens a pane.
struct PhonePaneWatches: View {
    let ref: PaneRef
    @ObservedObject private var store = VigilPhoneWatches.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VigilPaneWatches(boards: store.boards, root: ref.host.id, pane: ref.pane, host: store.host { dismiss() })
                .padding()
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Watches")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The home's binoculars, in the care tone with the count while any watch
/// is broken.
struct WatchesButtonLabel: View {
    @ObservedObject private var marks = VigilPhoneWatches.shared.marks

    var body: some View {
        if marks.broken > 0 {
            HStack(spacing: 1) {
                Image(systemName: "binoculars.fill")
                Text("\(marks.broken)").monospacedDigit()
            }
            .foregroundStyle(InkTone.warn.color)
        } else {
            Image(systemName: "binoculars")
        }
    }
}

/// A row's binoculars: the watches reaching its pane, or a folded row's panes'.
struct PhoneWatchMark: View {
    let refs: [PaneRef]
    let sizes: PaneMarkSizes
    @ObservedObject private var marks = VigilPhoneWatches.shared.marks

    var body: some View {
        WatchMark(watches: refs.flatMap { marks.watches(root: $0.host.id, pane: $0.pane) }, sizes: sizes)
    }
}
