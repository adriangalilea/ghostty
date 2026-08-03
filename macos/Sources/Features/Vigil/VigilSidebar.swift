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

        // The same divider every split wears: the sidebar is a pane too.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Control mode's visible affordance: the ring says "input is grabbed".
    func setControlActive(_ active: Bool) {
        wantsLayer = true
        layer?.borderWidth = active ? 2 : 0
        layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.55).cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if model.hintMode {
            switch event.keyCode {
            case 53: // esc: out of hints, and out of control mode with them
                model.exitHintMode()
                model.onLeaveControl?()
            case 36: // return: commit the typed hint, else the selection
                model.hintBuffer.isEmpty ? model.activateSelection() : model.commitHint()
            case 41: model.jumpAttention()  // ; = attention head
            case 126: model.move(-1)
            case 125: model.move(1)
            case 123: model.collapseSelection()
            case 124: model.expandSelection()
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
        case 53:                            // esc: back to the terminal
            model.returnFocus?()
            model.onLeaveControl?()
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
    /// Set while control mode owns the keyboard: any landing (hint jump,
    /// click, enter, esc) calls it to hand input back to the terminal.
    var onLeaveControl: (() -> Void)?
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
        if draggingItem != nil {
            if Date().timeIntervalSince(dragStarted) > 10 { draggingItem = nil }
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

    /// Positional labels, PLAIN alphabetical in list order (first session
    /// `a`, second `b`), assigned to the actual JUMP TARGETS: leaves.
    /// Non-branching chains collapse (a session with one pane is just
    /// `a`), so the label set is prefix-free by construction and typing
    /// never needs timers: the moment the input matches exactly ONE
    /// candidate, even mid-label, it fires. Nothing auto-selects while
    /// ambiguity remains; an invalid letter beeps and is ignored.
    @Published var hintMode = false
    @Published var hintBuffer = ""
    @Published private(set) var hintLabels: [String: String] = [:]

    private static let hintAlphabet = Array("abcdefghijklmnopqrstuvwxyz")

    private static func hintLetter(_ index: Int) -> String {
        index < hintAlphabet.count ? String(hintAlphabet[index]) : "z"
    }

    func enterHintMode() {
        rebuildHintLabels()
        hintBuffer = ""
        hintMode = true
    }

    /// EVERY row wears its letter, parents included (session `a`, tab
    /// `ab`, pane `abc`, plain alphabetical in list order). Collapsed
    /// parents hide their children's labels until opened.
    private func rebuildHintLabels() {
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
                let t = s + Self.hintLetter(j)
                labels[tab.id] = t
                guard !collapsedTabs.contains(tab.id) else { continue }
                for (k, pane) in tab.panes.enumerated() {
                    labels["\(tab.id)#\(pane.id)"] = t + Self.hintLetter(k)
                }
            }
        }
        hintLabels = labels
    }

    func exitHintMode() {
        hintMode = false
        hintBuffer = ""
        hintLabels = [:]
    }

    func hintType(_ char: String) {
        let candidate = hintBuffer + char
        guard hintLabels.contains(where: { $0.value.hasPrefix(candidate) }) else {
            NSSound.beep() // invalid letter: ignored, buffer stands
            return
        }
        hintBuffer = candidate
        resolveHintBuffer()
    }

    /// The buffer's meaning, in order: a COLLAPSED parent's letter OPENS
    /// it (children get labels, typing continues); an expanded parent
    /// with ONE labeled descendant fires that descendant (a lone claude
    /// is one letter away); with several, their letters disambiguate and
    /// return commits the parent itself; a unique match always fires.
    private func resolveHintBuffer() {
        let matches = hintLabels.filter { $0.value.hasPrefix(hintBuffer) }
        if let exact = matches.first(where: { $0.value == hintBuffer }) {
            let id = exact.key
            if collapsedSessions.contains(id) {
                collapsedSessions.remove(id)
                rebuildHintLabels()
                return
            }
            if collapsedTabs.contains(id) {
                collapsedTabs.remove(id)
                rebuildHintLabels()
                return
            }
            let descendants = matches.filter { $0.value != hintBuffer }
            if descendants.isEmpty {
                activateHint(id)
            } else if descendants.count == 1, let only = descendants.first {
                activateHint(only.key)
            }
            return
        }
        if matches.count == 1, let only = matches.first {
            activateHint(only.key)
        }
    }

    func commitHint() {
        if let exact = hintLabels.first(where: { $0.value == hintBuffer }) {
            activateHint(exact.key)
        } else {
            NSSound.beep()
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
        guard let name = VigilSessionManager.shared.mostUrgentName else {
            NSSound.beep()
            return
        }
        selection = name
        if let host = hostController {
            VigilSessionManager.shared.shapeshift(in: host, to: name)
        } else {
            VigilSessionManager.shared.open(name: name)
        }
        onLeaveControl?()
    }

    // MARK: Drag (sessions reorder; panes/tabs MOVE between sessions)

    enum DragItem: Equatable {
        case session(String)
        case tab(session: String, anchor: String)
        case pane(session: String, paneId: String, isDock: Bool)
    }

    @Published var draggingItem: DragItem?
    /// The row currently under a move-drag: it wears the accent ring.
    @Published var dropTarget: String?
    private var dragStarted: Date = .distantPast

    func beginDrag(_ item: DragItem) {
        draggingItem = item
        dragStarted = Date()
    }

    func endDrag() {
        draggingItem = nil
        dropTarget = nil
        refresh()
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
        draggingItem = nil
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
        onLeaveControl?() // landing hands the keyboard back
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
            switch model.draggingItem {
            case .session(let dragging):
                model.moveSession(dragging, over: target)
                if NSEvent.modifierFlags.contains(.option) { model.dropTarget = target }
            case .tab, .pane:
                model.dropTarget = target
            case nil:
                break
            }
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            if model.dropTarget == target { model.dropTarget = nil }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            if case .session = model.draggingItem {
                if NSEvent.modifierFlags.contains(.option) {
                    model.dropTarget = target
                    return DropProposal(operation: .copy) // the merge badge
                }
                model.dropTarget = nil
                return DropProposal(operation: .move)
            }
            return DropProposal(operation: .move)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            // Mutations DEFER out of the drag callback stack: tearing
            // down/creating windows inside a live NSDraggingSession is
            // asking AppKit for trouble.
            let manager = VigilSessionManager.shared
            let target = self.target
            switch model.draggingItem {
            case .session(let source):
                if NSEvent.modifierFlags.contains(.option), source != target {
                    model.endDrag()
                    DispatchQueue.main.async { manager.mergeSession(source, into: target) }
                } else {
                    model.commitOrder()
                    model.dropTarget = nil
                }
            case .tab(let session, let anchor):
                model.endDrag()
                DispatchQueue.main.async { manager.moveTab(anchor: anchor, from: session, to: target) }
            case .pane(let session, let paneId, let isDock):
                model.endDrag()
                DispatchQueue.main.async {
                    manager.movePane(paneId: paneId, from: session, to: target, isDock: isDock)
                }
            case nil:
                break
            }
        }
        return true
    }
}

/// Tab-row drop: a dragged PANE lands INSIDE this tab (live target splits
/// natively, cold target grows its capture).
struct VigilTabDrop: DropDelegate {
    let session: String
    let anchor: String?
    let model: VigilSidebarModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            if case .pane = model.draggingItem, let anchor {
                model.dropTarget = "tab-\(anchor)"
            }
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            if let anchor, model.dropTarget == "tab-\(anchor)" { model.dropTarget = nil }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            if case .pane = model.draggingItem { return DropProposal(operation: .move) }
            return DropProposal(operation: .forbidden)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard case .pane(let from, let paneId, _) = model.draggingItem,
                  let anchor else { return }
            let session = self.session
            model.endDrag()
            DispatchQueue.main.async {
                VigilSessionManager.shared.movePane(
                    paneId: paneId, from: from, intoTabAnchoredBy: anchor, of: session)
            }
        }
        return true
    }
}
