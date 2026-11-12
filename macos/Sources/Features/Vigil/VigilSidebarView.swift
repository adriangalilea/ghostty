import AppKit
import Combine
import Face
import Ink
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

    var body: some View {
        VStack(spacing: 0) {
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
                            case .active(let p): hovered = model.row(at: p)?.id
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

    /// A row's report into the shared geometry map: a DIRECT write on
    /// layout change, never a PreferenceKey. A preference reduce runs
    /// across the whole tree inside every SwiftUI render pass (half-second
    /// main-thread stalls in updatePreferences); a plain callback into
    /// non-observed model storage costs the render graph nothing. onDisappear is the prune:
    /// a collapsed or removed row withdraws its frame, so a ghost row can
    /// never swallow a click.
    private func reportHit(id: String, kind: VigilHitRow.Kind) -> some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("vigilTree"))
            } action: { frame in
                model.reportHit(VigilHitRow(id: id, kind: kind, frame: frame))
            }
            .onDisappear { model.dropHit(id) }
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
            Text("\(burial.remaining)s")
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
            .help("Let it die now (skips the remaining grace).")
        }
        .frame(height: (burial.from != nil || burial.mac != nil ? 30 : 22) * scale)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(id: id, hovered: hovered == id))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture { VigilWorkspaces.shared.undoBurial(burial) }
        .help("Closed; dies for real in \(burial.remaining)s. Click to bring it back where it was\(burial.mac.map { " on \($0)" } ?? " (⌘⇧T too)").")
    }

    // MARK: Remote host header (one per other Mac)

    /// Another Mac's header. It folds as every row that holds others does:
    /// by the thread line under its icon while open, and a press anywhere on
    /// it opens it when folded (a press on an open header does nothing: it
    /// leads nowhere).
    private func hostHeader(
        _ host: VigilWorkspaces.SidebarWorkspaceRow.HostHeader, device: String, count: Int, folded collapsed: Bool
    ) -> some View {
        let title = host.name
        return Button {
            collapse.hosts.remove(device)
        } label: {
            HStack(spacing: Grid.gap) {
                Image(systemName: "desktopcomputer").frame(width: Self.macIcon)
                Text(title).lineLimit(1)
                if collapsed { ThreadFoldedCount(count: count, size: 9 * scale) }
                // How it stands, apart from its name: at the row's far
                // end, smaller and plain, where a row's marks sit.
                if let standing = host.standing {
                    Spacer(minLength: Grid.gap)
                    Text(standing)
                        .font(.system(size: 9.5 * scale).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .padding(.trailing, tree.edge + Grid.inset)
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
                        }
                    } else {
                        ForEach(row.tabs) { tab in
                            tabRow(tab, session: row.id)
                            if !model.collapsedTabs.contains(tab.id) {
                                foldable(tab.id, level: 1, fold: { model.collapsedTabs.insert(tab.id) }) {
                                    ForEach(tab.panes) { pane in
                                        paneRow(pane, session: row.id, tab: tab, level: 2)
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
            // A workspace of another Mac is that Mac's to rename, merge or
            // kill; from here it can be brought.
            if row.host != nil, let remote = VigilRemote.split(id) {
                Button("Bring Here…") { VigilWorkspaces.shared.bringWithSheet(device: remote.device, workspace: remote.name) }
            } else {
            Button("Rename…") { VigilIdentity.editModal(name: id) }
            if model.rows.count > 1 {
                Menu("Merge Into") {
                    ForEach(model.rows.filter { $0.id != id }) { other in
                        Button("\(face(other.emoji)) \(other.label)") {
                            VigilWorkspaces.shared.mergeWorkspace(id, into: other.id)
                        }
                    }
                }
            }
            Divider()
            Button("Kill…", role: .destructive) {
                VigilWorkspaces.shared.killWithConfirm(name: id)
            }
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
            if let anchor = tab.anchor {
                Button("Rename…") {
                    VigilIdentity.editModal(
                        title: "Tab identity",
                        label: tab.title,
                        emoji: tab.emoji,
                        context: "a terminal tab. running: \(tab.panes.map(\.title).joined(separator: ", "))\n"
                            + VigilWorkspaces.shared.workContext(
                                panes: tab.panes.compactMap(\.paneId))
                    ) { label, emoji in
                        VigilWorkspaces.shared.setCustomIdentity(
                            key: "tab:\(anchor)", label: label, emoji: emoji)
                    }
                }
            }
            // A tab of another Mac's workspace can come alone.
            if let remote = VigilRemote.split(session), let pane = tab.anchor.flatMap(VigilRemote.split)?.name {
                Button("Bring Here…") {
                    VigilWorkspaces.shared.bringWithSheet(device: remote.device, workspace: remote.name, anchor: pane, part: .tab)
                }
            }
            Button("Close Tab…", role: .destructive) {
                VigilWorkspaces.shared.closeTabFromSidebar(
                    name: session, anchor: tab.anchor, in: model.hostController)
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
                    AgentMark(agent: agent, size: 11 * scale)
                } else {
                    Image(systemName: pane.isDock ? "sidebar.right" : "terminal")
                        .font(.system(size: 8 * scale))
                        .foregroundColor(Color.secondary.opacity(0.8))
                }
            }
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
            // The ids we communicate by, each where it exists.
            Section {
                ForEach(pane.identifiers, id: \.label) { id in
                    Button("Copy \(id.label)") {
                        VigilSidebarView.copied.copy(id.value)
                        sidebarLog.info("copied", ["what": id.label, "pane": pane.id])
                    }
                }
            }
            // Its conversation was written on two Macs: both copies, and
            // which goes on.
            if let paneId = pane.paneId, pane.conflict != nil {
                Button("Conflict…") { VigilWorkspaces.shared.conflictSheet(pane: paneId) }
            }
            // A pane of another Mac's workspace can come alone.
            if pane.paneId == nil, let remote = VigilRemote.split(session), let there = VigilRemote.split(id)?.name {
                Button("Bring Here…") {
                    VigilWorkspaces.shared.bringWithSheet(device: remote.device, workspace: remote.name, anchor: there, part: .pane)
                }
            }
            if let paneId = pane.paneId {
                // What its agent edited, its repositories, any other on its Mac.
                Button("Changes…") {
                    VigilChangesWindow.show(pane: paneId, title: pane.title)
                }
                Button("Rename…") {
                    VigilIdentity.editModal(
                        title: "Pane identity",
                        label: pane.title,
                        emoji: pane.emoji,
                        context: "a terminal pane, running: \(pane.program ?? "a shell")\n"
                            + VigilWorkspaces.shared.workContext(panes: [paneId])
                    ) { label, emoji in
                        VigilWorkspaces.shared.setCustomIdentity(
                            key: paneId, label: label, emoji: emoji)
                    }
                }
                // Any pane, whatever runs in it: an agent's stall or a
                // command's end rings on the phone, as loud as its priority.
                // Only with a phone registered here: following and priority
                // are what the phone shows and how loudly it rings.
                if VigilWorkspaces.shared.phonesRegistered {
                    let following = VigilWorkspaces.shared.phoneFollows.contains(paneId)
                    Button(following ? "Stop Following on iPhone" : "Follow on iPhone") {
                        VigilWorkspaces.shared.followOnPhones(pane: paneId, !following)
                    }
                    Menu("Priority") {
                        ForEach(Registry.Priority.allCases, id: \.self) { priority in
                            Toggle(priority.rawValue.capitalized, isOn: Binding(
                                get: { VigilWorkspaces.shared.priority(ofPane: paneId) == priority },
                                set: { if $0 { VigilWorkspaces.shared.setPriority(pane: paneId, priority) } }))
                        }
                    }
                }
            }
            Button("Close Pane…", role: .destructive) {
                VigilWorkspaces.shared.closePaneFromSidebar(
                    name: session, paneId: pane.navigationId, in: model.hostController)
            }
        }
        .opacity(hintFade(id)
            * (pane.paneId.map { dragSourceFade(.pane(session: session, paneId: $0, isDock: pane.isDock)) } ?? 1))
        .overlay(alignment: .leading) { hintChip(id, depth: level) }
    }

    /// Ink's one copy action, for the rows' Copy items (a menu has no
    /// place to show its confirmation; the pasteboard is the receipt).
    static let copied = InkCopyFeedback()

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
            if let ended = pane.ended { EndedMark(ends: [ended], sizes: marks) }
            if let arrived = pane.arrived { arrivedMark([arrived]) }
            // On a pane of this Mac a press opens the sheet that settles it;
            // another Mac's conflict is that Mac's to settle.
            if let conflict = pane.conflict {
                ConflictMark(
                    conflicts: [conflict], sizes: marks,
                    press: pane.paneId.map { id in { _ in VigilWorkspaces.shared.conflictSheet(pane: id) } })
            }
            if let refused = pane.refused {
                mark("person.2.slash.fill", .orange,
                     "Another agent process reports under this pane and is refused, since \(Self.endTime.string(from: Date(timeIntervalSince1970: refused))): this row is not following its work. It is likely this conversation moved to the background; close that one, or resume it here.")
            }
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
        EndedMark(ends: panes.compactMap(\.ended), sizes: marks)
        ConflictMark(conflicts: panes.compactMap(\.conflict), sizes: marks)
        lookerGlyphs(panes.flatMap(\.lookers))
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
