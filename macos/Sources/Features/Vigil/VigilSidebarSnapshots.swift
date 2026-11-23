import Combine
import Foundation
import VigilWire

/// The left bar's rows, one set for every window's bar: read on the main
/// thread in one pass (`VigilWorkspaces.sidebarInputs`: values only), built
/// on a queue of their own (`SidebarBuilder`), published back on main, where
/// each bar takes them (`VigilSidebarModel.apply`). Built on the main thread
/// by every bar, once per window, they took 25-35 ms of it about 13 times a
/// minute on a Mac with 30 panes in 20 workspaces: 3-4 frames each at 120 Hz.
@MainActor
final class VigilSidebarSnapshots {
    static let shared = VigilSidebarSnapshots()

    /// The rows last built; capture 0 until the first build lands.
    @Published private(set) var built = SidebarBuilt()

    /// Reads taken so far. A bar that changed its rows by hand (a drag's
    /// preview, committed) waits for rows read after the commit.
    private(set) var captures: UInt64 = 0
    private var scheduled = false
    private var building = false
    private var again = false
    private var revision: UInt64 = 0
    private let queue = DispatchQueue(label: "vigil.sidebar.rows", qos: .userInitiated)
    /// Used on `queue` alone.
    private let builder = SidebarBuilder()

    /// Rows read from how things stand once this turn is over: every ask
    /// within a turn (each window's bar hears the same notification) is one
    /// read, and asks while a build runs are one read after it.
    func request() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [self] in
            scheduled = false
            if building {
                again = true
            } else {
                start()
            }
        }
    }

    private func start() {
        let inputs = VigilWorkspaces.shared.sidebarInputs()
        captures += 1
        let capture = captures
        building = true
        let builder = builder
        let last = built.rows
        queue.async {
            let rows = builder.build(inputs)
            let changed = rows != last
            let writers = changed ? ConversationCards.writerProblems(rows.flatMap { row in
                row.tabs.flatMap(\.panes).compactMap { pane in
                    pane.liveConversation.map { ($0, row.host?.name ?? "this Mac", pane.paneId ?? VigilRemote.split(pane.id)?.name ?? pane.id) }
                }
            }) : [:]
            DispatchQueue.main.async { [self] in
                finish(capture: capture, rows: changed ? rows : nil, writers: writers)
            }
        }
    }

    /// `rows`: nil when they are the same as the last built.
    private func finish(capture: UInt64, rows: [VigilWorkspaces.SidebarWorkspaceRow]?, writers: [ConversationRef: ConversationProblem]) {
        building = false
        var next = built
        next.capture = capture
        if let rows {
            revision += 1
            next.revision = revision
            next.rows = rows
            next.writerProblems = writers
            // Messages names its panes from these very rows.
            VigilMessageStore.shared.rows(rows)
        }
        built = next
        if again {
            again = false
            request()
        }
    }
}
