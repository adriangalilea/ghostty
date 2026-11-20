import AppKit
import Combine
import Face
import Ink
import MachineStateViews
import MachineStates
import SwiftUI
import UniformTypeIdentifiers
import VigilWire

/// The left bar's face. One visual BLOCK per session (the active one
/// spotlit), and one rigid column grid so every glyph and dot lands on
/// the same vertical line whatever the row type.
struct VigilSidebarView: View {
    @ObservedObject var model: VigilSidebarModel
    /// The app-wide collapse truth: observing it here is what makes a
    /// chevron toggled in ANY window re-render THIS sidebar (the model
    /// only proxies its values).
    @ObservedObject private var collapse = VigilSidebarCollapse.shared
    @AppStorage(VigilSidebarSize.key) private var sidebarFontSize = VigilSidebarSize.compact
    private var scale: CGFloat { CGFloat(VigilSidebarSize.bounded(sidebarFontSize) / VigilSidebarSize.compact) }
    /// Every mark on a row's right (the gears, the antenna, the dots, an
    /// ending, a conflict, who looks, a pin, a priority) is sized from the
    /// row's text, by the one rule the phone's rows use (`PaneMarkSizes`).
    private var marks: PaneMarkSizes { PaneMarkSizes(text: 11 * scale) }
    @State private var hovered: String?
    /// The row whose fold control (its thread line open, its count folded)
    /// is under the pointer. While one is, no row wears the hover: a press
    /// there folds or unfolds, it does not open the row behind the pointer,
    /// and the lit control says so.
    @State private var hoveredFold: String?

    private func rowHovered(_ id: String) -> Bool { hovered == id && hoveredFold == nil }
    /// What `hovered` holds while the pointer is on a row that is no row of
    /// the geometry map and says its own hover: a Mac's header, a pane's
    /// aside.
    private static let hostHover = "own:"
    /// The panes whose changes stand in a right bar: each has a row under it.
    @ObservedObject private var asides = VigilBars.shared.asideMarks
    /// What rows draw of every Mac's mailbox (its counts alone): a pane
    /// row's messages mark. A mailbox change that moves no count repaints
    /// nothing here.
    @ObservedObject private var messages = VigilMessageStore.shared.marks
    @ObservedObject private var watches = VigilWatchStore.shared.marks

    /// What a fold control of row `id` tells of the pointer (`ThreadChildren`,
    /// `ThreadFolded`).
    private func foldHover(_ id: String) -> (Bool) -> Void {
        { inside in
            if inside { hoveredFold = id } else if hoveredFold == id { hoveredFold = nil }
        }
    }
    @AppStorage(VigilFollowMode.key) private var followModeRaw = VigilFollowMode.summon.rawValue

    private var followMode: VigilFollowMode { VigilFollowMode(rawValue: followModeRaw) ?? .summon }

    /// The burial tray's per-second countdown; subscribed only while the
    /// tray is on screen (autoconnect follows the subscriber). The old
    /// whole-tree 2s ticker is GONE: tree changes arrive event-driven
    /// (stateDidChange, fed by the state-dir and vigild-dir watchers).
    private let burialCountdown = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The tree's columns and how it folds are the shared thread tree's
    /// (`ThreadTree.swift`, the phone's tree too): a row is its face, its
    /// name and its marks, an open row's line under its face folds it.
    private var tree: ThreadTreeMetrics { .pointer(scale: scale) }

    /// What is the sidebar's own beside the tree's columns. One distance on
    /// every side: a workspace's block holds its rows `inset` inside its
    /// border, and a row its first glyph and its last the tree's `edge`
    /// inside its fill.
    private enum Grid {
        static let icon: CGFloat = 20
        static let gap: CGFloat = 4
        static let inset: CGFloat = 2
    }

    /// The rows of one Mac, in the tree's order: this Mac's (no header), or
    /// another's under its header.
    private struct MacRows: Identifiable {
        let id: String
        let host: VigilWorkspaces.SidebarWorkspaceRow.HostHeader?
        let device: String?
        var rows: [VigilWorkspaces.SidebarWorkspaceRow]
    }

    private var macs: [MacRows] {
        var out: [MacRows] = []
        for row in model.rows {
            let device = row.host.flatMap { _ in VigilRemote.split(row.id)?.device }
            if let last = out.last, last.device == device {
                out[out.count - 1].rows.append(row)
            } else {
                out.append(MacRows(id: "mac:\(device ?? "here")", host: row.host, device: device, rows: [row]))
            }
        }
        return out
    }

    /// Another Mac's header sits at the tree's very edge with a narrow icon,
    /// so its thread line costs its workspaces as little width as a line can:
    /// they start `macIndent` in, just clear of the line's press area.
    private static let macIcon: CGFloat = 14
    private static let macLine = ThreadTreeMetrics(face: macIcon, step: 0, edge: 0, lineHit: 10)
    private static let macIndent: CGFloat = 12

    /// A row's insets: `level` steps in.
    private func rowInsets(level: Int) -> EdgeInsets {
        EdgeInsets(top: 0, leading: tree.leading(level), bottom: 0, trailing: tree.edge)
    }

    /// Messages for you that you have not read, over every Mac: the count
    /// the switch's Messages wears.
    private var unread: Int { messages.pending.values.flatMap(\.values).reduce(0) { $0 + $1.unread } }

    /// The bar's two sections, one switch at its top.
    private var sections: some View {
        InkTabs(
            Binding(get: { model.section.rawValue }, set: { model.section = VigilSidebarModel.Section(rawValue: $0) ?? .workspaces }),
            [
                InkTab("Workspaces", VigilSidebarModel.Section.workspaces.rawValue, symbol: "square.grid.2x2"),
                InkTab("Messages", VigilSidebarModel.Section.messages.rawValue, symbol: "envelope", count: unread > 0 ? unread : nil),
            ]
        )
        .controlSize(.small)
        .accessibilityLabel("Sidebar section")
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            sections
            if model.section == .messages {
                VigilSidebarThreads(model: model)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                workspaces
            }
            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: VigilWorkspaces.titleDidChange)
            .receive(on: DispatchQueue.main)) { _ in model.refresh(reason: "titles") }
        .onReceive(NotificationCenter.default.publisher(for: VigilWorkspaces.stateDidChange)
            .receive(on: DispatchQueue.main)) { _ in model.refresh(reason: "facts") }
        .onReceive(NotificationCenter.default.publisher(for: VigilWorkspaces.focusDidChange)
            .receive(on: DispatchQueue.main)) { _ in model.refresh(immediate: true, reason: "focus") }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .receive(on: DispatchQueue.main)) { _ in model.refresh(immediate: true, reason: "key window") }
    }

    /// The Workspaces section: the tree, and the burial tray under it.
    @ViewBuilder private var workspaces: some View {
            ScrollViewReader { proxy in
                GeometryReader { geo in
                    ScrollView {
                        // ONE geometry map drives hover, click and drop:
                        // every row reports its frame into the "vigilTree"
                        // space, one resolver answers "what is under this
                        // point" for all three, so what highlights IS what
                        // a click activates and what a drop targets. Per-row
                        // tracking areas, gestures and delegates would let
                        // those disagree (hover activating outside its row,
                        // dead bands inside rows, drops cancelling in
                        // gaps). Plain VStack on purpose - lazy row
                        // realization is where stale hit geometry lives,
                        // and this list is dozens of rows, not thousands.
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(macs) { mac in
                                    if let host = mac.host, let device = mac.device {
                                        // Another Mac: its header, and its
                                        // workspaces as the header's
                                        // children, under its thread line
                                        // (the phone's tree draws a Mac the
                                        // same way).
                                        let folded = collapse.hosts.contains(device)
                                        hostHeader(host, device: device, count: mac.rows.count, folded: folded)
                                        if !folded {
                                            ThreadChildren(
                                                level: 0, metrics: Self.macLine, spacing: 5,
                                                hovering: foldHover(mac.id),
                                                fold: { collapse.hosts.insert(device) }
                                            ) {
                                                ForEach(mac.rows) { row in
                                                    // An away Mac's rows are
                                                    // what it last was, not
                                                    // what it is: dimmed.
                                                    sessionGroup(row)
                                                        .opacity(row.stateTag == "away" ? 0.55 : 1)
                                                        .padding(.leading, Self.macIndent)
                                                }
                                            }
                                        }
                                    } else {
                                        ForEach(mac.rows) { row in sessionGroup(row) }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            // The tail below the last row: plain space to
                            // the eye, resolved as "drop last" by the one
                            // drop delegate (past-end = append).
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .frame(minHeight: 40)
                        }
                        .frame(minHeight: geo.size.height, alignment: .top)
                        .coordinateSpace(name: "vigilTree")
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .named("vigilTree")) { phase in
                            switch phase {
                            // A Mac's header is no row of the map: it says
                            // itself when the pointer is on it and when it left.
                            case .active(let p):
                                if let row = model.row(at: p)?.id {
                                    hovered = row
                                } else if hovered?.hasPrefix(Self.hostHover) != true {
                                    hovered = nil
                                }
                            case .ended: hovered = nil
                            }
                        }
                        .gesture(SpatialTapGesture(coordinateSpace: .named("vigilTree"))
                            .onEnded { value in model.tapped(at: value.location) })
                        .onDrop(of: [UTType.text], delegate: VigilTreeDrop(model: model))
                    }
                    .onChange(of: model.selection) { _, selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                    .onChange(of: activeLeafId) { _, id in
                        // The viewport moved (auto-follow, ⌘⇧J, a click):
                        // the lit chain must be on screen, or the
                        // spotlight lies.
                        if let id { withAnimation { proxy.scrollTo(id) } }
                    }
                }
            }
            if !model.burials.isEmpty {
                burialTray
            }
    }

    /// A row's report into the shared geometry map: a DIRECT write on
    /// layout change, never a PreferenceKey. A preference reduce runs
    /// across the whole tree inside every SwiftUI render pass (half-second
    /// main-thread stalls in updatePreferences); a plain callback into
    /// non-observed model storage costs the render graph nothing. onDisappear is the prune:
    /// a collapsed or removed row withdraws its frame, so a ghost row can
    /// never swallow a click.
    private func reportHit(id: String, kind: VigilHitRow.Kind) -> some View {
        HitReport(model: model, id: id, kind: kind)
    }

    /// One row's place in the map, owned by this view instance (its `owner`
    /// lives as long as the view does), so its withdrawal can never take a
    /// same-id successor's frame with it.
    private struct HitReport: View {
        let model: VigilSidebarModel
        let id: String
        let kind: VigilHitRow.Kind
        @State private var owner = UUID()

        var body: some View {
            Color.clear
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("vigilTree"))
                } action: { frame in
                    model.reportHit(VigilHitRow(id: id, kind: kind, frame: frame, owner: owner))
                }
                .onDisappear { model.dropHit(id, owner: owner) }
        }
    }

    /// The row standing in for "where keystrokes land": the focused pane,
    /// or the deepest visible ancestor when collapse hides it. Drives the
    /// keep-visible scroll.
    private var activeLeafId: String? {
        guard let row = model.rows.first(where: { model.isFront($0) }) else { return nil }
        if model.collapsedSessions.contains(row.id) { return row.id }
        if let tab = row.soleTab {
            if let pane = tab.panes.first(where: { model.isFocused($0) }) { return "\(tab.id)#\(pane.id)" }
            return row.id
        }
        guard let tab = row.tabs.first(where: { model.isFront($0) }) else { return row.id }
        if model.collapsedTabs.contains(tab.id) { return tab.id }
        if let pane = tab.panes.first(where: { model.isFocused($0) }) { return "\(tab.id)#\(pane.id)" }
        return tab.id
    }

    // MARK: Up next (the manual-follow affordance, CO-LOCATED)

    /// The row ⌘⇧J would land on, promoted to the deepest VISIBLE row
    /// when collapse hides the pane - the active-leaf promotion rule
    /// pointed at the future: blue chain = where you are, orange keycap
    /// = where ⌘⇧J goes next. Visiting it re-derives the hint to the
    /// queue's next head; clicking the row is the same jump.
    private var hintRowId: String? {
        guard followMode != .window, let hint = model.followHint,
              let row = model.rows.first(where: { $0.id == hint.name }) else { return nil }
        if model.collapsedSessions.contains(row.id) { return row.id }
        guard let pane = hint.pane else { return row.id }
        if let tab = row.soleTab {
            guard tab.panes.contains(where: { $0.paneId == pane }) else { return row.id }
            return "\(tab.id)#\(pane)"
        }
        guard let tab = row.tabs.first(where: { t in t.panes.contains { $0.paneId == pane } })
        else { return row.id }
        if model.collapsedTabs.contains(tab.id) { return tab.id }
        return "\(tab.id)#\(pane)"
    }

    /// The keycap itself: attention-orange so it reads with the dots.
    @ViewBuilder
    private func followKeycap(_ id: String) -> some View {
        if hintRowId == id {
            Text("⌘⇧J")
                .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
                .foregroundColor(.orange)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
                .help("⌘⇧J (or click) lands here\(model.followHint.map { $0.more > 0 ? "; \($0.more) more waiting" : "" } ?? "").")
        }
    }

    // MARK: Footer (follow mode)

    /// ONE control, three mutually-exclusive modes (two toggles that both
    /// move focus would fight): off / summon (mid-turn blockers pull the
    /// quick terminal in) / window (the key window shapeshifts to any
    /// unseen ask). Summon carries its hush sub-toggle.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: followMode == .summon
                          ? "bolt.horizontal.circle" : "arrow.right.circle")
                        .font(.system(size: 9))
                        .foregroundColor(followMode == .off ? .secondary : .orange)
                    Text("When something needs you")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(followMode == .off ? .secondary : .primary)
                }
                InkTabs($followModeRaw, [
                    InkTab("Do nothing", VigilFollowMode.off.rawValue),
                    InkTab("Summon it", VigilFollowMode.summon.rawValue),
                    InkTab("Jump to it", VigilFollowMode.window.rawValue),
                ])
                .controlSize(.mini)
                .accessibilityLabel("When something needs you")
                .onChange(of: followModeRaw) { _, _ in
                    NotificationCenter.default.post(name: VigilWorkspaces.modeDidChange, object: nil)
                }
            }
            .help("Do nothing: it waits in the queue (the orange keycap, the badge, ⌘⇧J). Summon it: a permission prompt or a question mid-turn brings the floating terminal in on that pane; answering moves to the next. Jump to it: this window switches to anything waiting that you haven't seen.")
            ForEach(model.moveHistories) { history in
                HStack {
                    Button("Show preserved history for " + history.workspace) { VigilWorkspaces.shared.inspectMoveHistory(history) }
                        .help("Show the preserved files in Finder. An interrupted transfer can contain a partial transcript.")
                    Button("Dismiss") { VigilWorkspaces.shared.dismissMoveHistory(history) }
                        .help("Dismiss this notice. The saved files remain on disk.")
                }
            }
            ForEach(model.moveWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            VigilAsksRow()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
    }

    // MARK: Burial tray (sticky bottom: killed, still undoable)

    private var burialTray: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 8 * scale))
                    .foregroundColor(.secondary)
                Text("recently closed")
                    .font(.system(size: 9 * scale, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 5)
            ForEach(model.burials) { burial in
                burialRow(burial)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
        .onReceive(burialCountdown) { _ in model.refreshBurials() }
    }

    private func burialRow(_ burial: VigilWorkspaces.SidebarBurial) -> some View {
        let id = "burial-\(burial.id)"
        return HStack(spacing: 4) {
            Text(face(burial.emoji))
                .font(.system(size: 12 * scale))
                .frame(width: Grid.icon)
            VStack(alignment: .leading, spacing: 0) {
                Text(burial.label)
                    .font(.system(size: 11 * scale))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                // Where it goes back to, and on which Mac it waits.
                if burial.from != nil || burial.mac != nil {
                    Text([burial.from, burial.mac.map { "on \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9 * scale))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if burial.recoverableMove && !burial.conflict {
                Button("Take back here…") {
                    let app = VigilWorkspaces.shared
                    guard let entry = app.graveyard[burial.name], app.canTakeBack(entry),
                          let device = entry.moveCheckpoint?.device else { return }
                    let surrendered = app.peerClosedFork(entry)
                    let since = surrendered ? nil : app.moveOffline[device]
                    let alert = NSAlert()
                    alert.messageText = "Take this move back here?"
                    alert.informativeText = "The other Mac may still be working. This Mac will resume its saved history. When the other Mac returns its moved panes will stop and its later history will be kept separately."
                    alert.addButton(withTitle: "Cancel")
                    if app.unpairedMoves.contains(device) {
                        alert.informativeText = "Contact failed before this Mac lost its pairing. The destination may still be writing. Both copies may run until you pair the Macs again and their histories are reconciled."
                    }
                    if surrendered {
                        alert.informativeText = "The other Mac confirmed that its fork closed. Open this Mac's saved conversation here?"
                    }
                    alert.addButton(withTitle: "Take back here")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                    Task { @MainActor in
                        do { try await VigilWorkspaces.shared.recoverStoppedMove(burial.name, since: since) }
                        catch { VigilWorkspaces.shared.reportIncompleteMove(burial.name, String(describing: error)) }
                    }
                }
            }
            // A close begun has no grace left to count: it is closing.
            Text(burial.conflict ? "ownership conflict" : burial.closing ? "closing" : burial.waiting ? "recovered" : "\(burial.remaining)s")
                .font(.system(size: 9 * scale))
                .monospacedDigit()
                .foregroundColor(.secondary)
            Button {
                VigilWorkspaces.shared.endBurial(burial)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7 * scale, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(burial.conflict)
            .help("Let it die now (skips the remaining grace).")
        }
        .frame(height: (burial.from != nil || burial.mac != nil ? 30 : 22) * scale)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(id: id, hovered: hovered == id))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture { VigilWorkspaces.shared.undoBurial(burial) }
        .help(burial.conflict ? "Two registry entries own the same pane. Resolve ownership on its Mac to continue." : burial.closing
            ? "Its close began and is not finished\(burial.mac.map { " on \($0)" } ?? ""): it cannot be brought back. The ✕ tries to finish it now."
            : burial.waiting ? "Recovered from a backup. Bring it back or end it now." : "Closed; dies for real in \(burial.remaining)s. Click to bring it back where it was\(burial.mac.map { " on \($0)" } ?? " (⌘⇧T too)").")
    }

    // MARK: Remote host header (one per other Mac)

    /// Another Mac's header. It folds as every row that holds others does:
    /// a press anywhere on it folds it when open and opens it when folded
    /// (`VigilSidebarModel.holderClicked`'s rule), as the thread line under
    /// its icon does.
    private func hostHeader(
        _ host: VigilWorkspaces.SidebarWorkspaceRow.HostHeader, device: String, count: Int, folded collapsed: Bool
    ) -> some View {
        let title = host.name
        let hoverId = Self.hostHover + device
        return Button {
            if collapse.hosts.contains(device) { collapse.hosts.remove(device) } else { collapse.hosts.insert(device) }
        } label: {
            HStack(spacing: Grid.gap) {
                // A laptop is a Mac with a battery, as its own power says.
                Image(systemName: host.machine?.power.battery == nil ? "desktopcomputer" : "laptopcomputer")
                    .frame(width: Self.macIcon)
                Text(title).lineLimit(1)
                if collapsed { ThreadFoldedCount(count: count, size: 9 * scale) }
                Spacer(minLength: Grid.gap)
                // How it stands, apart from its name: at the row's far
                // end, smaller and plain, where a row's marks sit.
                if let standing = host.standing {
                    Text(standing)
                        .font(.system(size: 9.5 * scale).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                // What waits on your yes on that Mac, each message once.
                WaitingMark(messages: messages.awaiting(root: device), sizes: marks)
                // Its power on the rail, in the header's own size; away, what
                // it last sent, dimmed with the rest of it.
                if let machine = host.machine {
                    MachineState.PowerMark(machine.power)
                        .inkControlMetrics(InkControlMetrics(font: 11 * scale, height: 22 * scale, inset: 0))
                        .opacity(host.standing == nil ? 1 : 0.55)
                }
            }
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22 * scale)
            // Under the pointer as every row is; drawn past its text on both
            // sides so the name keeps its place on the Macs' edge.
            .background(rowBackground(id: hoverId, hovered: hovered == hoverId).padding(.horizontal, -4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? hoverId : (hovered == hoverId ? nil : hovered) }
        // A Mac's menu, as a workspace's offers a tab: a workspace born on
        // it, then how it stands (the whole reading, `MachineState.facts`).
        .contextMenu {
            menu {
                Button {
                    VigilWorkspaces.shared.newWorkspace(on: device)
                } label: { Label("New Workspace", systemImage: "plus.square.on.square") }
                if let machine = host.machine {
                    Divider()
                    ForEach(Array(machine.facts.enumerated()), id: \.offset) { _, fact in
                        Text("\(fact.label): \(fact.value)")
                    }
                }
            }
        }
        .padding(.top, 6)
        .padding(.trailing, tree.edge + Grid.inset)
    }

    /// A row's move (VigilWire's `Move`), the same rule wherever the row
    /// lives: one Mac it may go to is one item ("Bring Here…" when that is
    /// this Mac, else "Move to <Mac>…"); more are one "Move To" submenu,
    /// this Mac first when it is one of them. A Mac out of reach is listed,
    /// disabled, with why. When the move would leave something behind on
    /// the workspace's Mac (uncommitted, unpushed, a stash, from what this
    /// Mac already holds of its directory) the items are orange, title and
    /// icon: there is something to settle, and the dialog says what.
    @ViewBuilder private func moveItem(
        _ home: VigilWorkspaces.RowHome, anchor: String = "", part: Registry.Workspace.Part? = nil
    ) -> some View {
        let manager = VigilWorkspaces.shared
        let leaves = manager.leavesBehind(home)
        switch Move.menu(manager.moveTargets(home: home.device)) {
        case .none:
            EmptyView()
        case .one(let target):
            moveButton(target, target.action, home, anchor: anchor, part: part, leaves: leaves,
                       symbol: target.device == nil ? Self.bringSymbol : Self.moveSymbol)
        case .submenu(let targets):
            Menu {
                menu {
                    ForEach(targets) { target in
                        moveButton(target, target.title, home, anchor: anchor, part: part, leaves: leaves,
                                   symbol: target.device == nil ? Self.bringSymbol : "desktopcomputer")
                    }
                }
            } label: {
                moveLabel("Move To", symbol: Self.moveSymbol, leaves: leaves)
            }
        }
    }

    private func moveButton(
        _ target: Move.Target, _ title: String, _ home: VigilWorkspaces.RowHome, anchor: String,
        part: Registry.Workspace.Part?, leaves: Bool, symbol: String
    ) -> some View {
        Button {
            VigilWorkspaces.shared.moveWithSheet(home, to: target, anchor: anchor, part: part)
        } label: {
            moveLabel(target.unreachable.map { "\(title) (\($0))" } ?? title, symbol: symbol, leaves: leaves && target.unreachable == nil)
        }
        .disabled(target.unreachable != nil)
    }

    @ViewBuilder private func moveLabel(_ title: String, symbol: String, leaves: Bool) -> some View {
        if leaves {
            Label {
                Text(title).foregroundStyle(.orange)
            } icon: {
                Image(nsImage: Self.orange(symbol))
            }
        } else {
            Label(title, systemImage: symbol)
        }
    }

    /// A menu's items with their icons shown. macOS 27 hides a menu item's
    /// image unless its label asks for both (measured: an item's
    /// `preferredImageVisibility` is hidden for a plain `Label`, visible
    /// under this style), and a submenu's items do not inherit it: every
    /// menu and submenu of the sidebar is built through here.
    private func menu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        Group(content: items).labelStyle(.titleAndIcon)
    }

    private static func symbol(ofIdentifier label: String) -> String {
        switch label {
        case "Pane ID": "number"
        case "Conversation Name": "text.bubble"
        case "Conversation ID": "bubble.left.and.text.bubble.right"
        case "Handle": "at"
        default: "doc.on.doc"
        }
    }

    private static let bringSymbol = "arrow.down.to.line"
    private static let moveSymbol = "arrow.right.to.line"
    /// A menu draws a symbol as a template, in the menu's own ink: the
    /// orange one is drawn into an image that is not one, once per symbol.
    @MainActor private static var orangeIcons: [String: NSImage] = [:]
    @MainActor private static func orange(_ name: String) -> NSImage {
        if let image = orangeIcons[name] { return image }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Work would stay behind")!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.systemOrange.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        orangeIcons[name] = image
        return image
    }

    private static func symbol(of priority: Registry.Priority) -> String {
        switch priority {
        case .high: "exclamationmark"
        case .normal: "bell"
        case .low: "moon"
        }
    }

    /// A folded row's count, the button that opens it.
    private func unfold(_ id: String, _ count: Int, _ open: @escaping () -> Void) -> some View {
        ThreadFolded(count: count, size: 9 * scale, hovering: foldHover(id), open: open)
    }

    /// An open row's children with its thread line.
    private func foldable<Children: View>(
        _ id: String, level: Int, fold: @escaping () -> Void, @ViewBuilder children: @escaping () -> Children
    ) -> some View {
        ThreadChildren(level: level, metrics: tree, hovering: foldHover(id), fold: fold, content: children)
    }

    // MARK: Session group (one block per session)

    private func sessionGroup(_ row: VigilWorkspaces.SidebarWorkspaceRow) -> some View {
        let collapsed = model.collapsedSessions.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            sessionRow(row, collapsed: collapsed)
                .id(row.id)
            if !collapsed, !row.tabs.isEmpty {
                foldable(row.id, level: 0, fold: { model.collapsedSessions.insert(row.id) }) {
                    if let tab = row.soleTab {
                        ForEach(tab.panes) { pane in
                            paneRow(pane, session: row.id, tab: tab, level: 1)
                            subagentRows(pane, level: 1)
                            asideRow(pane, session: row.id, tab: tab, level: 1)
                        }
                    } else {
                        ForEach(row.tabs) { tab in
                            tabRow(tab, session: row.id)
                            if !model.collapsedTabs.contains(tab.id) {
                                foldable(tab.id, level: 1, fold: { model.collapsedTabs.insert(tab.id) }) {
                                    ForEach(tab.panes) { pane in
                                        paneRow(pane, session: row.id, tab: tab, level: 2)
                                        subagentRows(pane, level: 2)
                                        asideRow(pane, session: row.id, tab: tab, level: 2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Every row's fill sits the same distance inside the block's
        // border, on all four sides.
        .padding(Grid.inset)
        .background(ZStack {
            // The spotlight: the ACTIVE session's whole block lifts off
            // the list (wash + border), cool accent against the warm
            // state tints, so "where am I" is answered by the tree shape,
            // not one row.
            if model.isFront(row) {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.06))
            }
        })
        .overlay {
            if model.isFront(row) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
    }

    // MARK: Rows

    private func sessionRow(_ row: VigilWorkspaces.SidebarWorkspaceRow, collapsed: Bool) -> some View {
        let id = row.id
        return HStack(spacing: Grid.gap) {
            VigilNameCell(
                emoji: row.emoji,
                title: row.label,
                scale: scale,
                font: .system(size: 12 * scale, weight: .semibold),
                color: .primary,
                onRename: { label in
                    let manager = VigilWorkspaces.shared
                    guard let session = manager.workspaces[id] else { return }
                    manager.rename(name: id, label: label ?? session.label, emoji: session.emoji)
                },
                onPickEmoji: { emoji in
                    let manager = VigilWorkspaces.shared
                    guard let session = manager.workspaces[id] else { return }
                    manager.rename(name: id, label: session.label, emoji: emoji)
                },
                fallback: {
                    Text("·").font(.system(size: 13 * scale))
                }
            )
            .opacity(row.stateTag == "windowed" ? 1 : 0.85)
            if collapsed, !row.tabs.isEmpty {
                unfold(id, row.soleTab?.panes.count ?? row.tabs.count) { model.collapsedSessions.remove(id) }
            }
            Spacer(minLength: 4)
            // The row's marks, one gap between any two, the dots last on
            // the rail. No lifecycle tag: every session is ALIVE by
            // construction (daemons carry it); displayed-or-not is said by
            // the front tint and the filled tab icons, the rest by the
            // tooltip.
            HStack(spacing: marks.gap) {
                // Where it came from, folded or not, until its panes are opened.
                arrivedMark(row.tabs.flatMap(\.panes).compactMap(\.arrived))
                if collapsed { foldedMarks(row.tabs.flatMap(\.panes)) }
                followKeycap(id)
                if collapsed { AntennaMark(what: row.tabs.flatMap(\.panes).flatMap(\.sentries), sizes: marks) }
                // Expanded, the children speak for themselves; collapsed,
                // the parent peeks: one dot per distinct state, overlapped.
                PaneDots(dots: collapsed ? row.states : [], sizes: marks)
            }
        }
        .frame(height: 26 * scale)
        .padding(rowInsets(level: 0))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: id,
            hovered: rowHovered(id),
            activity: model.isFront(row) ? (collapsed ? .leaf : .chain) : .none,
            state: collapsed ? row.states.first?.state : nil))
        .background(reportHit(id: id, kind: .session(id)))
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag(.session(id))
            return NSItemProvider(object: id as NSString)
        }
        .contextMenu {
            // The same menu wherever the workspace lives: each action goes
            // to its home (`RowHome`, VigilWorkspaces+RowActions).
            let home = VigilWorkspaces.RowHome(row: id)
            menu {
                Button {
                    VigilWorkspaces.shared.renameRow(
                        home, title: "Workspace identity", label: row.label, emoji: row.emoji,
                        context: home.device == nil
                            ? VigilWorkspaces.shared.identityContext(name: id)
                            : "a workspace of terminal panes: \(row.tabs.flatMap(\.panes).map(\.title).joined(separator: ", "))")
                } label: { Label("Rename…", systemImage: "pencil") }
                if let anchor = row.tabs.last?.anchor {
                    Button {
                        VigilWorkspaces.shared.newTab(home, after: anchor, in: model.hostController)
                    } label: { Label("New Tab", systemImage: "plus.rectangle.on.rectangle") }
                }
                moveItem(home)
                // Merging moves panes between two workspaces of one Mac:
                // offered among this Mac's.
                if home.device == nil, model.rows.contains(where: { $0.id != id && $0.host == nil }) {
                    Menu {
                        ForEach(model.rows.filter { $0.id != id && $0.host == nil }) { other in
                            Button("\(face(other.emoji)) \(other.label)") {
                                VigilWorkspaces.shared.mergeWorkspace(id, into: other.id)
                            }
                        }
                    } label: { Label("Merge Into", systemImage: "arrow.triangle.merge") }
                }
                Divider()
                Button(role: .destructive) {
                    VigilWorkspaces.shared.killRow(home, label: row.label)
                } label: { Label("Kill…", systemImage: "xmark.circle") }
            }
        }
        .help("\(row.label) (\(row.id)) · \(row.stateTag)")
        .opacity(hintFade(id) * dragSourceFade(.session(id)))
        .overlay {
            if model.dropTarget == id {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .leading) { hintChip(id, depth: 0) }
    }

    /// Drag affordances: the source dims while it travels, the row under
    /// the cursor wears the accent ring (dropTarget).
    private func dragSourceFade(_ item: VigilSidebarModel.DragItem) -> Double {
        model.draggingItem == item ? 0.45 : 1
    }

    private func tabRow(_ tab: VigilWorkspaces.SidebarTab, session: String) -> some View {
        let collapsed = model.collapsedTabs.contains(tab.id)
        return HStack(spacing: Grid.gap) {
            // Same silhouette either way (no layout flash on swap): the
            // FILLED variant marks the tab the window displays right now,
            // the outline is a tab resting in its capture (daemons running). A
            // custom face takes the column over the glyph.
            VigilNameCell(
                emoji: tab.emoji,
                title: tab.title,
                scale: scale,
                font: .system(size: 11 * scale, weight: tab.captured ? .regular : .medium),
                color: tab.captured ? .secondary : .primary,
                onRename: tab.anchor.map { anchor in
                    { label in
                        VigilWorkspaces.shared.setCustomIdentity(
                            key: "tab:\(anchor)", label: label,
                            emoji: VigilWorkspaces.shared.customIdentity("tab:\(anchor)")?.emoji)
                    }
                },
                onPickEmoji: tab.anchor.map { anchor in
                    { emoji in
                        VigilWorkspaces.shared.setCustomIdentity(
                            key: "tab:\(anchor)",
                            label: VigilWorkspaces.shared.customIdentity("tab:\(anchor)")?.label,
                            emoji: emoji)
                    }
                }
            ) {
                Image(systemName: tab.captured ? "rectangle.on.rectangle" : "rectangle.inset.filled.on.rectangle")
                    .font(.system(size: 9 * scale))
                    .foregroundColor(tab.captured ? .secondary : .primary.opacity(0.8))
            }
            if collapsed { unfold(tab.id, tab.panes.count) { model.collapsedTabs.remove(tab.id) } }
            Spacer(minLength: 4)
            HStack(spacing: marks.gap) {
                if collapsed { foldedMarks(tab.panes) }
                followKeycap(tab.id)
                if collapsed { AntennaMark(what: tab.panes.flatMap(\.sentries), sizes: marks) }
                PaneDots(dots: collapsed ? PaneDot.cluster(tab.panes.flatMap(\.dots)) : [], sizes: marks)
            }
        }
        .frame(height: 22 * scale)
        .padding(rowInsets(level: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: tab.id,
            hovered: rowHovered(tab.id),
            activity: model.isFront(tab) ? (collapsed ? .leaf : .chain) : .none,
            state: collapsed
                ? PaneDot.cluster(tab.panes.flatMap(\.dots)).first?.state
                : nil))
        .background(reportHit(id: tab.id, kind: .tab(session: session, anchor: tab.anchor)))
        .contentShape(Rectangle())
        .id(tab.id)
        .onDrag {
            if let anchor = tab.anchor {
                model.beginDrag(.tab(session: session, anchor: anchor))
            }
            return NSItemProvider(object: tab.id as NSString)
        }
        .contextMenu {
            let home = VigilWorkspaces.RowHome(row: session)
            menu {
                if let anchor = tab.anchor.map(home.there) {
                    Button {
                        VigilWorkspaces.shared.renameRow(
                            home, anchor: anchor, part: .tab, title: "Tab identity", label: tab.title, emoji: tab.emoji,
                            context: "a terminal tab. running: \(tab.panes.map(\.title).joined(separator: ", "))\n"
                                + VigilWorkspaces.shared.workContext(panes: tab.panes.compactMap(\.paneId)))
                    } label: { Label("Rename…", systemImage: "pencil") }
                    // A tab can move alone, from any Mac.
                    moveItem(home, anchor: anchor, part: .tab)
                }
                Divider()
                Button(role: .destructive) {
                    VigilWorkspaces.shared.closeTabFromSidebar(
                        name: session, anchor: tab.anchor, in: model.hostController)
                } label: { Label("Close Tab…", systemImage: "xmark") }
            }
        }
        .help(tab.captured
            ? "Cold tab: its processes run in their daemons; click to swap it into this window."
            : tab.title)
        .opacity(hintFade(tab.id)
            * (tab.anchor.map { dragSourceFade(.tab(session: session, anchor: $0)) } ?? 1))
        .overlay {
            if let anchor = tab.anchor, model.dropTarget == "tab-\(anchor)" {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .leading) { hintChip(tab.id, depth: 1) }
    }

    /// What stands in a right bar about a pane (its changes, its documents),
    /// each as a row under the pane: what the bar holds is in the tree as a
    /// dock pane is. It sits at its pane's own level, its mark under the
    /// pane's face: one step further in with no thread line of its own, it
    /// read as a row out of place. A press goes to the pane and brings it
    /// in front; its menu moves it to a window or closes it (which ends
    /// nothing).
    /// Its agent's running subagents under its row, as its Mac's
    /// `#subagent` tuples fold them (the glance's `member`): each by the
    /// best fact there is (`MemberGlance.Line.title`: what it is doing now,
    /// else its call's description, else its type), deeper ones further
    /// in. Finished ones are the member
    /// card's to list (a long conversation spawns dozens). A press opens
    /// the card.
    @ViewBuilder private func subagentRows(_ pane: VigilWorkspaces.SidebarPane, level: Int) -> some View {
        if let member = pane.member {
            ForEach(member.subagents.filter(\.running), id: \.key) { sub in
                let hoverId = Self.hostHover + "subagent:" + sub.key
                Button {
                    VigilMemberCard.show(pane)
                } label: {
                    HStack(spacing: 4 * scale) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 8 * scale, weight: .semibold))
                            .frame(width: VigilNameCell<EmptyView>.face * scale)
                        Text(sub.title).font(.system(size: 11 * scale)).lineLimit(1)
                        if let caption = sub.caption {
                            Text(caption).font(.system(size: 9 * scale)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Circle().fill(sub.running ? Color.green.opacity(0.8) : Color.secondary.opacity(0.35))
                            .frame(width: 5 * scale, height: 5 * scale)
                    }
                    .foregroundStyle(sub.running ? .secondary : .tertiary)
                    .frame(height: 18 * scale)
                    .padding(rowInsets(level: level + sub.depth))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBackground(id: hoverId, hovered: hovered == hoverId))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? hoverId : (hovered == hoverId ? nil : hovered) }
                .help(sub.said + (sub.running ? " · running" : " · finished") + "\nvigil send @\(sub.handle) reaches it through its parent")
            }
        }
    }

    @ViewBuilder private func asideRow(
        _ pane: VigilWorkspaces.SidebarPane, session: String, tab: VigilWorkspaces.SidebarTab, level: Int
    ) -> some View {
        // Keyed as the bars key it: another Mac's pane by its row id.
        let paneId = pane.paneId ?? pane.id
        ForEach(asides.kinds[paneId] ?? [], id: \.key) { kind in
            asideRow(kind, paneId: paneId, pane, session: session, tab: tab, level: level)
        }
    }

    private func asideRow(
        _ kind: VigilBars.Aside.Kind, paneId: String, _ pane: VigilWorkspaces.SidebarPane, session: String,
        tab: VigilWorkspaces.SidebarTab, level: Int
    ) -> some View {
        let hoverId = Self.hostHover + "aside:" + VigilBars.Aside.id(pane: paneId, kind)
        return Button {
            model.activate(.init(id: "\(tab.id)#\(pane.id)", kind: .pane(name: session, paneId: pane.navigationId)))
            VigilBars.shared.frontAside(pane: paneId, kind)
        } label: {
            // The name cell's own columns (`VigilNameCell`): its mark sits
            // in the face's column, its word where a pane's name starts.
            HStack(spacing: 4 * scale) {
                Image(systemName: kind.symbol).font(.system(size: 9 * scale, weight: .semibold))
                    .frame(width: VigilNameCell<EmptyView>.face * scale)
                Text(kind.word).font(.system(size: 11 * scale)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "sidebar.right").font(.system(size: 9 * scale)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .frame(height: 20 * scale)
            .padding(rowInsets(level: level))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(id: hoverId, hovered: hovered == hoverId))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? hoverId : (hovered == hoverId ? nil : hovered) }
        .contextMenu {
            menu {
                Button {
                    VigilBars.shared.closeAside(pane: paneId, kind)
                    switch kind {
                    case .changes: VigilChangesPanel.window(pane: paneId, title: pane.title)
                    case .documents: VigilDocumentsPanel.window(pane: paneId, title: pane.title)
                    case .messages:
                        VigilMessagesPanel.window(thread: VigilMessageStore.shared.key(paneId: pane.paneId, id: pane.id, conversation: pane.conversation)
                            .flatMap(VigilMessagesPanel.thread(of:))?.id)
                    case .watches: VigilWatchesPanel.window()
                    case .file(let file): VigilFilePanel.window(file)
                    }
                } label: { Label("Move to Window", systemImage: "macwindow") }
                Divider()
                Button { VigilBars.shared.closeAside(pane: paneId, kind) } label: { Label("Close \(kind.word)", systemImage: "xmark") }
            }
        }
        .help(asideHelp(kind, pane: pane))
    }

    private func asideHelp(_ kind: VigilBars.Aside.Kind, pane: VigilWorkspaces.SidebarPane) -> String {
        if case .file(let file) = kind { return "\(file.shown), from \(pane.title)'s messages, in the right bar" }
        return "\(pane.title)'s \(kind.word.lowercased()), in the right bar"
    }

    private func paneRow(
        _ pane: VigilWorkspaces.SidebarPane,
        session: String,
        tab: VigilWorkspaces.SidebarTab,
        level: Int
    ) -> some View {
        let id = "\(tab.id)#\(pane.id)"
        return HStack(spacing: 4) {
            VigilNameCell(
                emoji: pane.emoji,
                title: pane.title,
                scale: scale,
                font: .system(size: 11 * scale),
                color: .primary.opacity(0.85),
                onRename: pane.paneId.map { id in
                    { label in
                        VigilWorkspaces.shared.setCustomIdentity(
                            key: id, label: label,
                            emoji: VigilWorkspaces.shared.customIdentity(id)?.emoji)
                    }
                },
                onPickEmoji: pane.paneId.map { id in
                    { emoji in
                        VigilWorkspaces.shared.setCustomIdentity(
                            key: id,
                            label: VigilWorkspaces.shared.customIdentity(id)?.label,
                            emoji: emoji)
                    }
                }
            ) {
                // No emoji of its own: its agent's mark when one runs in it
                // (VigilWire's `PaneFace`, the phone's rule too), else the
                // glyph of where it sits.
                if case .agent(let agent) = PaneFace.of(emoji: nil, program: pane.program), AgentMark.knows(agent) {
                    AgentMark(agent: agent, size: 11 * scale, tint: pane.member?.tint)
                } else {
                    Image(systemName: pane.isDock ? "sidebar.right" : "terminal")
                        .font(.system(size: 8 * scale))
                        .foregroundColor(Color.secondary.opacity(0.8))
                }
            }
            forkMark(pane)
            paneIdentity(pane)
            Spacer(minLength: 4)
            HStack(spacing: marks.gap) {
                paneMarks(pane)
                followKeycap(id)
                // Its antenna takes room only when lit (`AntennaMark` draws
                // nothing for an empty list).
                AntennaMark(what: pane.sentries, sizes: marks)
                // A dot per agent, drawn as a folded row's cluster is: each
                // background agent not finished, then the pane's own on the
                // rail. They grow inward; the rail's edge never moves.
                PaneDots(dots: pane.dots, sizes: marks)
            }
        }
        .frame(height: 20 * scale)
        .padding(rowInsets(level: level))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: id,
            hovered: rowHovered(id),
            activity: model.isFocused(pane) ? .leaf : .none,
            state: pane.state))
        .background(reportHit(
            id: id,
            kind: .pane(session: session, tabAnchor: tab.anchor, paneId: pane.navigationId)))
        .contentShape(Rectangle())
        .id(id)
        .onDrag {
            if let paneId = pane.paneId {
                model.beginDrag(.pane(session: session, paneId: paneId, isDock: pane.isDock))
            }
            return NSItemProvider(object: id as NSString)
        }
        .contextMenu {
            // One order on every row: what it is called, what it holds,
            // where it is heard, what to copy of it, and its end last.
            // The same menu wherever the pane lives (`RowHome`).
            let home = VigilWorkspaces.RowHome(row: session)
            // The pane as its home names it; nil for a row with no daemon.
            let there = pane.paneId ?? (home.device != nil ? VigilRemote.split(pane.id)?.name : nil)
            menu {
                if let there {
                    Button {
                        VigilWorkspaces.shared.renameRow(
                            home, anchor: there, part: .pane, title: "Pane identity", label: pane.title, emoji: pane.emoji,
                            context: "a terminal pane, running: \(pane.program ?? "a shell")\n"
                                + (pane.paneId.map { VigilWorkspaces.shared.workContext(panes: [$0]) } ?? ""))
                    } label: { Label("Rename…", systemImage: "pencil") }
                    // A pane can move alone, from any Mac.
                    moveItem(home, anchor: there, part: .pane)
                }
                Divider()
                // What its agent edited, its repositories, any other on its
                // Mac: another Mac's pane too, read from that Mac.
                Button {
                    VigilChangesPanel.show(pane: pane.paneId ?? pane.id, title: pane.title, in: model.hostController)
                } label: { Label("Changes", systemImage: "plusminus") }
                // The files its agent works from (its instructions, plan and
                // skills), read and edited as pages: another Mac's pane too.
                // Only where an agent holds a conversation.
                if pane.conversation != nil {
                    Button {
                        VigilDocumentsPanel.show(pane: pane.paneId ?? pane.id, title: pane.title, in: model.hostController)
                    } label: { Label("Documents", systemImage: "doc.text") }
                }
                // Its thread: what agents and you said to its agent and what
                // it said back, beside it (another Mac's pane too). Where an
                // agent holds a conversation, or messages already wait.
                if pane.conversation != nil || messages.pending(paneId: pane.paneId, id: pane.id) != nil {
                    Button {
                        VigilMessagesPanel.show(paneId: pane.paneId, id: pane.id, conversation: pane.conversation, in: model.hostController)
                    } label: { Label("Messages", systemImage: "envelope") }
                }
                // The watches whose verdict reaches it, live and ended.
                if !watches.watches(paneId: pane.paneId, id: pane.id).isEmpty {
                    Button {
                        VigilWatchesPanel.show(paneId: pane.paneId, id: pane.id, title: pane.title, in: model.hostController)
                    } label: { Label("Watches", systemImage: "binoculars") }
                }
                // Who its conversation is, as its Mac's tuples say:
                // handle, lineage, subagents, the runs that speak for it.
                if pane.conversationRef != nil || pane.member != nil {
                    Button { VigilMemberCard.show(pane) } label: { Label("Conversation Details…", systemImage: "info.circle") }
                }
                // Its agent's conversation, forked: a second pane starts
                // from the same state under a new id and this one goes on.
                // Only where an agent holds a conversation (never a shell).
                if let there, pane.conversation != nil, !pane.isDock {
                    Menu {
                        menu {
                            Button {
                                VigilWorkspaces.shared.fork(home, pane: there, beside: true, in: model.hostController)
                            } label: { Label("Beside", systemImage: "rectangle.split.2x1") }
                            Button {
                                VigilWorkspaces.shared.fork(home, pane: there, beside: false, in: model.hostController)
                            } label: { Label("In New Tab", systemImage: "plus.rectangle.on.rectangle") }
                        }
                    } label: { Label("Fork", systemImage: "arrow.branch") }
                }
                // Its conversation was written on two Macs: both copies, and
                // which goes on.
                if let paneId = pane.paneId, pane.conflict != nil {
                    Button { VigilWorkspaces.shared.conflictSheet(pane: paneId) } label: {
                        Label("Conflict…", systemImage: "arrow.triangle.branch")
                    }
                }

                // Any pane, whatever runs in it: an agent's stall or a
                // command's end rings on the phone, as loud as its priority.
                // Only with a phone registered here: following and priority
                // are what the phone shows and how loudly it rings.
                if let there, VigilWorkspaces.shared.phonesRegistered {
                    Divider()
                    // What a phone follows is each Mac's own board's to
                    // hold, and this Mac holds its own: offered on its panes.
                    if let paneId = pane.paneId {
                        let following = VigilWorkspaces.shared.phoneFollows.contains(paneId)
                        Button {
                            VigilWorkspaces.shared.followOnPhones(pane: paneId, !following)
                        } label: {
                            Label(following ? "Stop Following on iPhone" : "Follow on iPhone",
                                  systemImage: following ? "pin.slash" : "pin")
                        }
                    }
                    Menu {
                        menu {
                            ForEach(Registry.Priority.allCases, id: \.self) { priority in
                                Toggle(isOn: Binding(
                                    get: { VigilWorkspaces.shared.priority(home, pane: there) == priority },
                                    set: { if $0 { VigilWorkspaces.shared.setPriority(home, pane: there, priority) } })) {
                                    Label(priority.rawValue.capitalized, systemImage: Self.symbol(of: priority))
                                }
                            }
                        }
                    } label: { Label("Priority", systemImage: "bell") }
                }
                // The ids we communicate by, each where it exists.
                if !pane.identifiers.isEmpty {
                    Divider()
                    Menu {
                        menu {
                            ForEach(pane.identifiers, id: \.label) { id in
                                Button {
                                    VigilSidebarView.copied.copy(id.value)
                                    sidebarLog.info("copied", ["what": id.label, "pane": pane.id])
                                } label: { Label(id.label, systemImage: Self.symbol(ofIdentifier: id.label)) }
                            }
                        }
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Divider()
                Button(role: .destructive) {
                    VigilWorkspaces.shared.closePaneFromSidebar(
                        name: session, paneId: pane.navigationId, in: model.hostController)
                } label: { Label("Close Pane…", systemImage: "xmark") }
            }
        }
        .opacity(hintFade(id)
            * (pane.paneId.map { dragSourceFade(.pane(session: session, paneId: $0, isDock: pane.isDock)) } ?? 1))
        .overlay(alignment: .leading) { hintChip(id, depth: level) }
        // Its thread is open in a right bar: the row says so, as the
        // thread's head names the row.
        .overlay {
            if asides.kinds[pane.paneId ?? pane.id]?.contains(.messages) == true {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Ink's one copy action, for the rows' Copy items (a menu has no
    /// place to show its confirmation; the pasteboard is the receipt).
    static let copied = InkCopyFeedback()

    /// A fork wears a branch beside its name: its conversation was forked
    /// from another (its glance's `forkedFrom`, `Fork`). Hovering says from
    /// which, by the name of the pane that holds it now, on any Mac listed.
    @ViewBuilder
    private func forkMark(_ pane: VigilWorkspaces.SidebarPane) -> some View {
        if let parent = pane.forkedFrom {
            let holder = model.rows.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.conversation == parent }
            Image(systemName: "arrow.branch")
                .font(.system(size: 8 * scale, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.8))
                .help(holder.map { "A fork of \($0.title)" }
                    ?? "A fork of a conversation no pane holds now (\(parent.prefix(8)))")
        }
    }

    /// The ids we speak by, dim beside the name and never louder than it:
    /// the conversation's name when the row's title is not it (you named
    /// the pane), else the pane's id cut in the middle (its end tells panes
    /// apart). Hovering the row shows every id whole; its menu copies them.
    @ViewBuilder
    private func paneIdentity(_ pane: VigilWorkspaces.SidebarPane) -> some View {
        let named = pane.conversationName.flatMap { $0 == pane.title ? nil : $0 }
        if let dim = named ?? pane.identifiers.first?.value {
            InkMiddleTruncate(dim, tail: named == nil ? "-" : 6)
                .font(.system(size: 9 * scale, design: named == nil ? .monospaced : .default))
                .foregroundStyle(.secondary.opacity(0.7))
                .layoutPriority(-1)
                .help(pane.identifiers.map { "\($0.label): \($0.value)" }.joined(separator: "\n"))
        }
    }

    // MARK: Jump hints (helix gw: f in the bar, labels appear, type to land)

    @ViewBuilder
    private func hintChip(_ id: String, depth: Int) -> some View {
        if model.hintMode, let label = model.hintLabels[id],
           label.hasPrefix(model.hintBuffer) {
            HStack(spacing: 0) {
                Text(model.hintBuffer)
                    .foregroundColor(.black.opacity(0.45))
                Text(label.dropFirst(model.hintBuffer.count))
                    .foregroundColor(.black)
            }
            .font(.system(size: 11 * scale, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.yellow))
            .padding(.leading, rowInsets(level: depth).leading)
            .allowsHitTesting(false)
        }
    }

    private func hintFade(_ id: String) -> Double {
        guard model.hintMode else { return 1 }
        // Containers carry no label (leaves are the targets): never dim
        // them. A labeled row dims once it stops matching the buffer.
        guard let label = model.hintLabels[id] else { return 1 }
        return label.hasPrefix(model.hintBuffer) ? 1 : 0.35
    }

    // MARK: Atoms

    /// The face column never breaks the label grid: one emoji cluster,
    /// full face on hover via the row help.
    private func face(_ emoji: String?) -> String {
        guard let emoji, let first = emoji.first else { return "·" }
        return String(first)
    }

    /// What a pane is to the world beyond this window, each only when it
    /// differs from the default: what its agent runs in the background,
    /// who looks from elsewhere (the phone, another Mac), a phone following
    /// it, its priority (high rings through Focus, low never rings). Its
    /// antenna follows them on the row (`AntennaMark`): a declared lease,
    /// or something alive here that no agent accounts for
    /// (`SidebarPane.sentries`), which is which in its tooltip. NOT an eye:
    /// the eye is vigil watching YOU, the antenna a process watching the
    /// WORLD.
    private func paneMarks(_ pane: VigilWorkspaces.SidebarPane) -> some View {
        HStack(spacing: marks.gap) {

            // Messages waiting on your yes, to it or from it: a press opens
            // its thread, where each is answered on its message.
            WaitingMark(messages: messages.awaiting(paneId: pane.paneId, id: pane.id), sizes: marks) {
                VigilMessagesPanel.show(paneId: pane.paneId, id: pane.id, conversation: pane.conversation, in: model.hostController)
            }
            // Messages for it that wait on its agent, or that you have not
            // read: a press opens its thread in the bar's Messages.
            if let pending = messages.pending(paneId: pane.paneId, id: pane.id) {
                MessagesMark(pending: [pending], sizes: marks) {
                    VigilMessagesPanel.show(paneId: pane.paneId, id: pane.id, conversation: pane.conversation, in: model.hostController)
                }
            }
            // Watches whose verdict will reach it, in the care tone when
            // one is broken: a press opens them beside it.
            WatchMark(watches: watches.watches(paneId: pane.paneId, id: pane.id), sizes: marks) {
                VigilWatchesPanel.show(paneId: pane.paneId, id: pane.id, title: pane.title, in: model.hostController)
            }
            if let arrived = pane.arrived { arrivedMark([arrived]) }
            PaneProblemsMark(items: problemItems(pane), sizes: marks)
            // The shells its agent runs in the background, counted
            // (`PaneGlance.Background.jobs`); its agents are dots of their
            // own, what a turn left running the antenna's.
            if let background = pane.background { GearsMark(backgrounds: [background], sizes: marks) }
            lookerGlyphs(pane.lookers)
            if pane.followed {
                mark("pin.fill", .primary.opacity(0.75), "Followed on iPhone: its stalls and ends ring there")
            }
            switch pane.priority {
            case .high: mark("exclamationmark", .orange, "High priority: rings through Focus")
            case .low: mark("moon.fill", .secondary, "Low priority: never rings")
            case .normal: EmptyView()
            }
        }
    }

    /// Brought from another Mac and not opened here: that Mac's name (one
    /// pane's, or a workspace's panes rolled up). It leaves a pane's row
    /// when the pane is opened, since from then it runs here.
    @ViewBuilder
    private func arrivedMark(_ arrivals: [Registry.Arrival]) -> some View {
        if let first = arrivals.first {
            HStack(spacing: 1) {
                Image(systemName: "arrow.down.to.line").font(marks.symbol)
                Text(first.mac).font(marks.word).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .help("Brought from \(first.mac), \(Self.endTime.string(from: Date(timeIntervalSince1970: first.at))). "
                + (arrivals.count == 1 ? "Not opened here yet: opening it starts it." : "\(arrivals.count) panes not opened here yet: opening one starts it."))
        }
    }

    /// What a folded row wears for the panes it hides, so a fold never hides
    /// a background shell, an ending, a conflict or someone looking: each
    /// mark's own rollup (a count, or the first with the rest in its
    /// tooltip). Their antenna and their dots follow on the row.
    @ViewBuilder
    private func foldedMarks(_ panes: [VigilWorkspaces.SidebarPane]) -> some View {
        GearsMark(backgrounds: panes.compactMap(\.background), sizes: marks)

        WaitingMark(
            messages: panes.reduce(into: Set<String>()) { $0.formUnion(messages.awaiting(paneId: $1.paneId, id: $1.id)) }, sizes: marks)
        MessagesMark(pending: panes.compactMap { messages.pending(paneId: $0.paneId, id: $0.id) }, sizes: marks)
        WatchMark(watches: panes.flatMap { watches.watches(paneId: $0.paneId, id: $0.id) }, sizes: marks)
        PaneProblemsMark(items: panes.flatMap(problemItems), sizes: marks)
        lookerGlyphs(panes.flatMap(\.lookers))
    }

    private func problemItems(_ pane: VigilWorkspaces.SidebarPane) -> [PaneProblemItem] {
        func visit() {
            for row in model.rows {
                for tab in row.tabs where tab.panes.contains(where: { $0.id == pane.id }) {
                    model.go(to: .pane, of: .init(row: row, tab: tab, pane: pane))
                    return
                }
            }
        }
        let writers = pane.liveConversation.flatMap { model.writerProblems[$0] }
        var items = (pane.problems + [writers].compactMap { $0 }).map { issue in
            PaneProblemItem(pane: pane.id, problem: issue, button: "Open pane", act: visit)
        }
        if let ended = pane.ended, !ended.clean {
            items.append(PaneProblemItem(pane: pane.id, problem: ended.problem, button: "Open pane", act: visit, ended: ended))
        }
        if let conflict = pane.conflict, conflict.worn {
            items.append(PaneProblemItem(pane: pane.id, problem: conflict.problem, button: "Review copies", act: {
                if let local = pane.paneId { VigilWorkspaces.shared.conflictSheet(pane: local) }
                else if let host = VigilRemote.split(pane.id)?.device {
                    _ = VigilWorkspaces.shared.conflictSheet(conflict, pane: nil, device: host)
                }
            }, writers: conflict.writers))
        }
        return items
    }

    private static let endTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    @ViewBuilder
    private func lookerGlyphs(_ lookers: [Viewer]) -> some View {
        ForEach(Array(Set(lookers)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { viewer in
            mark(viewer == .phone ? "iphone" : "laptopcomputer", .cyan, "Open on \(viewer.words) right now")
        }
    }

    private func mark(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(marks.symbol)
            .foregroundStyle(color)
            .help(help)
    }

    /// A row's place in the DERIVED active chain: `leaf` = where keystrokes
    /// land right now (or a collapsed row standing in for it), `chain` =
    /// an ancestor of the leaf.
    private enum RowActivity { case none, chain, leaf }

    /// Two separate visual languages, never confused: the active chain is
    /// FILL (accent wash, strong on the leaf — where you ARE, derived from
    /// the key window, so auto-follow/⌘⇧J/clicks all move it for free);
    /// the keyboard cursor is a RING (outline only, visible only while the
    /// bar owns the keyboard — what enter/rename would hit).
    private func rowBackground(
        id: String, hovered: Bool,
        activity: RowActivity = .none,
        state: AgentState? = nil
    ) -> some View {
        ZStack {
            // The state's whisper, under everything: same collapse logic
            // as the dots (collapsed parent wears the rollup, expanded
            // rows wear their own).
            if let tint = stateTint(state) {
                RoundedRectangle(cornerRadius: 4).fill(tint)
            }
            switch activity {
            case .leaf:
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.35))
            case .chain:
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12))
            case .none:
                EmptyView()
            }
            if hovered {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
            }
            if model.keyboardActive, model.selection == id {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
    }

    private func stateTint(_ state: AgentState?) -> Color? {
        switch state {
        case .blocked: return Color.orange.opacity(0.10)
        case .working: return Color.yellow.opacity(0.06)
        case .interrupting: return Color.yellow.opacity(0.06)
        case .unknown: return Color.gray.opacity(0.06)
        case .done: return Color.teal.opacity(0.06)
        case .idle, nil: return nil
        }
    }
}
