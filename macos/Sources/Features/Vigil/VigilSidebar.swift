import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The left bar: the session tree. Every session (live, detached, asleep)
/// → its tabs → their panes (splits AND dock tenants), each pane wearing
/// its program (argv truth from its daemon's tree file) and its continuous
/// AgentState; collapsed nodes roll state up (max by blocked > working >
/// done > idle). Click a row to land in it; arrows/enter/esc when the bar
/// holds the keyboard (click its background to give it the keyboard).
@MainActor
final class VigilSidebarHost: NSVisualEffectView {
    var widthConstraint: NSLayoutConstraint!
    let model = VigilSidebarModel()
    private weak var controller: TerminalController?

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState

        model.hostController = controller
        model.returnFocus = { [weak self] in
            guard let self, let controller = self.controller,
                  let surface = controller.focusedSurface else { return }
            self.window?.makeFirstResponder(surface)
        }

        let hosting = NSHostingView(rootView: VigilSidebarView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)

        let handle = VigilDragHandle(
            base: { VigilBars.shared.sidebarWidth },
            apply: { VigilBars.shared.sidebarWidth = $0 },
            flip: false)
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if model.hintMode {
            switch event.keyCode {
            case 53: model.exitHintMode()   // esc
            case 36: model.commitHint()     // return: commit ambiguous exact
            case 41: model.jumpAttention()  // ; = attention head
            default:
                if let chars = event.charactersIgnoringModifiers?.lowercased(),
                   chars.count == 1, chars.first!.isLetter {
                    model.hintType(chars)
                } else {
                    NSSound.beep()
                }
            }
            return
        }
        switch event.keyCode {
        case 126: model.move(-1)          // up
        case 125: model.move(1)           // down
        case 123: model.collapseSelection() // left
        case 124: model.expandSelection()   // right
        case 36: model.activateSelection()  // return
        case 3: model.enterHintMode()       // f = jump hints (helix gw)
        case 41: model.jumpAttention()      // ; = attention head
        case 53: model.returnFocus?()       // esc
        default: super.keyDown(with: event)
        }
    }
}

/// The sidebar's state: an immutable snapshot of the session tree plus the
/// UI-only bits (selection, collapse sets, both persisted).
@MainActor
final class VigilSidebarModel: ObservableObject {
    @Published private(set) var rows: [VigilSessionManager.SidebarSessionRow] = []
    @Published var selection: String?
    @Published var collapsedSessions: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedSessions), forKey: "vigil.sidebar.collapsed") }
    }
    @Published var collapsedTabs: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedTabs), forKey: "vigil.sidebar.collapsedTabs") }
    }
    var returnFocus: (() -> Void)?
    /// The window this sidebar lives in: the viewport that shapeshifts.
    weak var hostController: TerminalController?

    init() {
        collapsedSessions = Set(UserDefaults.standard.stringArray(forKey: "vigil.sidebar.collapsed") ?? [])
        collapsedTabs = Set(UserDefaults.standard.stringArray(forKey: "vigil.sidebar.collapsedTabs") ?? [])
        refresh()
    }

    private var lastRefresh: Date = .distantPast
    private var refreshQueued = false
    private var refreshCount = 0

    /// Coalesced + throttled: any number of triggers (ticker, state
    /// notifications, bar syncs) collapse into at most ~4 snapshots/s.
    /// The snapshot reads per-pane files; an unthrottled storm once
    /// saturated the main thread and starved the runloop so hard that
    /// launch restore never ran (2026-08-01).
    func refresh() {
        refreshCount += 1
        if refreshCount % 500 == 0 {
            VigilSessionManager.shared.vlog("!! sidebar refresh storm tripwire: count=\(refreshCount)")
        }
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= 0.25 else {
            if !refreshQueued {
                refreshQueued = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.refreshQueued = false
                    self.refresh()
                }
            }
            return
        }
        lastRefresh = now
        // A live drag owns the row order; a snapshot would clobber the
        // preview. Staleness guard: a cancelled drag never blocks forever.
        if draggingSession != nil {
            if Date().timeIntervalSince(dragStarted) > 10 { draggingSession = nil }
            else { return }
        }
        let fresh = VigilSessionManager.shared.sidebarSnapshot()
        if fresh != rows { rows = fresh }
        let freshBurials = VigilSessionManager.shared.sidebarBurials()
        if freshBurials != burials { burials = freshBurials }
    }

    /// The sticky bottom tray: killed sessions living out their grace.
    @Published private(set) var burials: [VigilSessionManager.SidebarBurial] = []

    /// Keyboard entry (⌘⇧B lands here): something must be selected.
    func ensureSelection() {
        if selection == nil || !visibleItems.contains(where: { $0.id == selection }) {
            selection = visibleItems.first?.id
        }
    }

    // MARK: Jump hints (helix gw for the tree)

    /// Positional labels over every visible row: session `a`, its first
    /// tab `aa`, that tab's first split `aaa` (home-row alphabet). Typing
    /// walks the tree; a unique match jumps immediately, an ambiguous
    /// exact match (a IS a prefix of aa by design) commits after a beat
    /// or on return. `;` jumps to the head of the attention FIFO.
    @Published var hintMode = false
    @Published var hintBuffer = ""
    @Published private(set) var hintLabels: [String: String] = [:]
    private var hintCommitWork: DispatchWorkItem?

    private static let hintAlphabet = Array("asdfghjklqwertyuiopzxcvbnm")

    private static func hintLetter(_ index: Int) -> String {
        index < hintAlphabet.count ? String(hintAlphabet[index]) : "z"
    }

    func enterHintMode() {
        var labels: [String: String] = [:]
        for (i, row) in rows.enumerated() {
            let s = Self.hintLetter(i)
            labels[row.id] = s
            guard !collapsedSessions.contains(row.id) else { continue }
            if row.tabs.count == 1, let tab = row.tabs.first {
                for (k, pane) in tab.panes.enumerated() {
                    labels["\(tab.id)#\(pane.id)"] = s + Self.hintLetter(k)
                }
                continue
            }
            for (j, tab) in row.tabs.enumerated() {
                labels[tab.id] = s + Self.hintLetter(j)
                guard !collapsedTabs.contains(tab.id) else { continue }
                for (k, pane) in tab.panes.enumerated() {
                    labels["\(tab.id)#\(pane.id)"] = s + Self.hintLetter(j) + Self.hintLetter(k)
                }
            }
        }
        hintLabels = labels
        hintBuffer = ""
        hintMode = true
    }

    func exitHintMode() {
        hintCommitWork?.cancel()
        hintMode = false
        hintBuffer = ""
        hintLabels = [:]
    }

    func hintType(_ char: String) {
        hintBuffer += char
        hintCommitWork?.cancel()
        let matches = hintLabels.filter { $0.value.hasPrefix(hintBuffer) }
        guard !matches.isEmpty else { exitHintMode(); return }
        guard let exact = matches.first(where: { $0.value == hintBuffer }) else { return }
        if matches.count == 1 {
            activateHint(exact.key)
            return
        }
        // `a` is deliberately a prefix of `aa`: an exact match with live
        // extensions commits after a beat, so a pause means "this one" and
        // fast typing keeps descending.
        let work = DispatchWorkItem { [weak self] in self?.activateHint(exact.key) }
        hintCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func commitHint() {
        if let exact = hintLabels.first(where: { $0.value == hintBuffer }) {
            activateHint(exact.key)
        } else {
            exitHintMode()
        }
    }

    private func activateHint(_ id: String) {
        exitHintMode()
        guard let item = visibleItems.first(where: { $0.id == id }) else { return }
        activate(item)
    }

    /// Direct access to the attention FIFO's head: the most urgent session
    /// shapeshifts into this window.
    func jumpAttention() {
        exitHintMode()
        guard let name = VigilSessionManager.shared.mostUrgentName else { return }
        selection = name
        if let host = hostController {
            VigilSessionManager.shared.shapeshift(in: host, to: name)
        } else {
            VigilSessionManager.shared.open(name: name)
        }
    }

    // MARK: Drag reorder (session rows; order shared with the overview)

    @Published var draggingSession: String?
    private var dragStarted: Date = .distantPast

    func beginDrag(_ name: String) {
        draggingSession = name
        dragStarted = Date()
    }

    /// Live preview: the dragged row follows the cursor through the list.
    func moveSession(_ dragged: String, over target: String) {
        guard dragged != target,
              let from = rows.firstIndex(where: { $0.id == dragged }),
              let to = rows.firstIndex(where: { $0.id == target }) else { return }
        let row = rows.remove(at: from)
        rows.insert(row, at: to)
    }

    /// Drop: the preview order becomes THE order (persisted; the overview
    /// cycles in the same order).
    func commitOrder() {
        let manager = VigilSessionManager.shared
        for (index, row) in rows.enumerated() {
            manager.setOrder(name: row.id, order: index)
        }
        draggingSession = nil
    }

    // MARK: Navigation items (the flattened, currently-visible tree)

    struct NavItem: Equatable {
        enum Kind: Equatable {
            case session(String)
            case tab(name: String, anchor: String?, id: String)
            case pane(name: String, paneId: String?)
        }
        let id: String
        let kind: Kind
    }

    /// Single-tab sessions skip the tab level: their panes hang directly
    /// off the session row (a tab row would be pure noise).
    var visibleItems: [NavItem] {
        var out: [NavItem] = []
        for row in rows {
            out.append(NavItem(id: row.id, kind: .session(row.id)))
            guard !collapsedSessions.contains(row.id) else { continue }
            if row.tabs.count == 1, let tab = row.tabs.first {
                for pane in tab.panes {
                    out.append(NavItem(
                        id: "\(tab.id)#\(pane.id)",
                        kind: .pane(name: row.id, paneId: pane.paneId)))
                }
                continue
            }
            for tab in row.tabs {
                out.append(NavItem(
                    id: tab.id,
                    kind: .tab(name: row.id, anchor: tab.anchor, id: tab.id)))
                guard !collapsedTabs.contains(tab.id) else { continue }
                for pane in tab.panes {
                    out.append(NavItem(
                        id: "\(tab.id)#\(pane.id)",
                        kind: .pane(name: row.id, paneId: pane.paneId)))
                }
            }
        }
        return out
    }

    func move(_ delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? -1
        let next = min(max(current + delta, 0), items.count - 1)
        selection = items[next].id
    }

    func activateSelection() {
        guard let item = visibleItems.first(where: { $0.id == selection }) else { return }
        activate(item)
    }

    /// The click semantic is SHAPESHIFT: this window swaps to show the
    /// chosen session (live sessions keep their home window and get
    /// focused there instead).
    func activate(_ item: NavItem) {
        selection = item.id
        let manager = VigilSessionManager.shared
        switch item.kind {
        case .session(let name):
            if let host = hostController {
                manager.shapeshift(in: host, to: name)
            } else {
                manager.open(name: name)
            }
        case .tab(let name, let anchor, _):
            manager.activateTab(name: name, anchor: anchor, in: hostController)
        case .pane(let name, let paneId):
            manager.activatePane(name: name, paneId: paneId, in: hostController)
        }
    }

    func collapseSelection() {
        guard let item = visibleItems.first(where: { $0.id == selection }) else { return }
        switch item.kind {
        case .session(let name): collapsedSessions.insert(name)
        case .tab(_, _, let id): collapsedTabs.insert(id)
        case .pane: break
        }
    }

    func expandSelection() {
        guard let item = visibleItems.first(where: { $0.id == selection }) else { return }
        switch item.kind {
        case .session(let name): collapsedSessions.remove(name)
        case .tab(_, _, let id): collapsedTabs.remove(id)
        case .pane: break
        }
    }
}

/// Session-row drag reorder: dropEntered previews the move live,
/// performDrop commits it (persisted; the overview shares the order).
struct VigilSessionDrop: DropDelegate {
    let target: String
    let model: VigilSidebarModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging = model.draggingSession else { return }
            model.moveSession(dragging, over: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.commitOrder() }
        return true
    }
}
