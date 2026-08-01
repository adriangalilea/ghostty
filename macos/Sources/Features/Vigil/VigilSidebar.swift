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
        switch event.keyCode {
        case 126: model.move(-1)          // up
        case 125: model.move(1)           // down
        case 123: model.collapseSelection() // left
        case 124: model.expandSelection()   // right
        case 36: model.activateSelection()  // return
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
    }

    /// Keyboard entry (⌘⇧B lands here): something must be selected.
    func ensureSelection() {
        if selection == nil || !visibleItems.contains(where: { $0.id == selection }) {
            selection = visibleItems.first?.id
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

struct VigilSidebarView: View {
    @ObservedObject var model: VigilSidebarModel
    @State private var hovered: String?

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.rows) { row in
                        sessionRows(row)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .onChange(of: model.selection) { selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
        .onReceive(ticker) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: VigilSessionManager.stateDidChange)
            .receive(on: DispatchQueue.main)) { _ in model.refresh() }
    }

    // MARK: Rows

    @ViewBuilder
    private func sessionRows(_ row: VigilSessionManager.SidebarSessionRow) -> some View {
        let collapsed = model.collapsedSessions.contains(row.id)
        sessionRow(row, collapsed: collapsed)
            .id(row.id)
        if !collapsed {
            if row.tabs.count == 1, let tab = row.tabs.first {
                ForEach(tab.panes) { pane in
                    paneRow(pane, session: row.id, tab: tab, indent: 1)
                }
            } else {
                ForEach(row.tabs) { tab in
                    tabRow(tab, session: row.id)
                    if !model.collapsedTabs.contains(tab.id) {
                        ForEach(tab.panes) { pane in
                            paneRow(pane, session: row.id, tab: tab, indent: 2)
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ row: VigilSessionManager.SidebarSessionRow, collapsed: Bool) -> some View {
        let id = row.id
        return HStack(spacing: 5) {
            chevron(collapsed: collapsed) {
                if collapsed { model.collapsedSessions.remove(id) }
                else { model.collapsedSessions.insert(id) }
            }
            Text(row.emoji ?? "•")
                .font(.system(size: 11))
                .frame(minWidth: 14)
            Text(row.label)
                .font(.system(size: 12, weight: row.isFront ? .semibold : .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            attentionBadge(row.attention)
            if row.stateTag != "live" {
                Text(row.stateTag)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            // Survival class, the titlebar's language: infinity = endures,
            // hourglass = dies on explicit close. Right-click to flip.
            Image(systemName: row.persistent ? "infinity" : "hourglass")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(row.persistent ? .teal : Color.secondary.opacity(0.6))
            stateDot(collapsed ? row.agg : sessionOwnDot(row))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            selected: model.selection == id,
            hovered: hovered == id,
            front: row.isFront))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture {
            model.activate(.init(id: id, kind: .session(id)))
        }
        .onDrag {
            model.beginDrag(id)
            return NSItemProvider(object: id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: VigilSessionDrop(target: id, model: model))
        .contextMenu {
            Button(row.persistent
                ? "Make Ephemeral (dies on explicit close)"
                : "Make Persistent (survives quit and reboot)") {
                VigilSessionManager.shared.setPersistent(name: id, !row.persistent)
            }
            Button("Rename…") { VigilIdentity.editModal(name: id) }
            Divider()
            Button("Kill…", role: .destructive) {
                VigilSessionManager.shared.killWithConfirm(name: id)
            }
        }
        .help("\(row.label) (\(row.id)) · \(row.stateTag) · \(row.persistent ? "persistent" : "ephemeral")")
    }

    /// An EXPANDED session row keeps its rollup dot too: the children show
    /// detail, the parent still answers "does anything in here need me".
    private func sessionOwnDot(_ row: VigilSessionManager.SidebarSessionRow) -> VigilSessionManager.AgentState? {
        row.agg
    }

    private func tabRow(_ tab: VigilSessionManager.SidebarTab, session: String) -> some View {
        let collapsed = model.collapsedTabs.contains(tab.id)
        return HStack(spacing: 5) {
            chevron(collapsed: collapsed) {
                if collapsed { model.collapsedTabs.remove(tab.id) }
                else { model.collapsedTabs.insert(tab.id) }
            }
            Image(systemName: tab.cold ? "moon.zzz" : "rectangle.on.rectangle")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 4)
            if collapsed { stateDot(tab.panes.compactMap(\.state).max()) }
        }
        .opacity(tab.cold ? 0.75 : 1)
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            selected: model.selection == tab.id,
            hovered: hovered == tab.id,
            front: false))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? tab.id : (hovered == tab.id ? nil : hovered) }
        .onTapGesture {
            model.activate(.init(id: tab.id, kind: .tab(name: session, anchor: tab.anchor, id: tab.id)))
        }
        .id(tab.id)
        .help(tab.cold ? "Cold tab: its processes run in their daemons; click to swap it into this window." : tab.title)
    }

    private func paneRow(
        _ pane: VigilSessionManager.SidebarPane,
        session: String,
        tab: VigilSessionManager.SidebarTab,
        indent: Int
    ) -> some View {
        let id = "\(tab.id)#\(pane.id)"
        return HStack(spacing: 5) {
            Image(systemName: pane.isDock ? "sidebar.right" : "terminal")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            Text(pane.title)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
            stateDot(pane.state)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .padding(.leading, CGFloat(14 * indent))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            selected: model.selection == id,
            hovered: hovered == id,
            front: false))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture {
            model.activate(.init(id: id, kind: .pane(name: session, paneId: pane.paneId)))
        }
        .id(id)
    }

    // MARK: Atoms

    /// A real hitbox (20×20, full shape), not an 8pt glyph.
    private func chevron(collapsed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func stateDot(_ state: VigilSessionManager.AgentState?) -> some View {
        if let color = dotColor(state) {
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }

    private func dotColor(_ state: VigilSessionManager.AgentState?) -> Color? {
        switch state {
        case .blocked: return .red
        case .working: return .yellow
        case .done: return .teal
        case .idle: return Color.secondary.opacity(0.45)
        case nil: return nil
        }
    }

    @ViewBuilder
    private func attentionBadge(_ attention: VigilSessionManager.Attention) -> some View {
        switch attention {
        case .input:
            Image(systemName: "bell.fill")
                .font(.system(size: 8))
                .foregroundColor(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8))
                .foregroundColor(.teal)
        case .none:
            EmptyView()
        }
    }

    private func rowBackground(selected: Bool, hovered: Bool, front: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(selected
                ? Color.accentColor.opacity(0.25)
                : hovered ? Color.primary.opacity(0.10)
                : front ? Color.primary.opacity(0.06) : Color.clear)
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
