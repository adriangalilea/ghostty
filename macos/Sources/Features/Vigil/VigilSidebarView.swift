import AppKit
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
    @State private var hovered: String?
    @AppStorage(VigilFollowMode.key) private var followModeRaw = VigilFollowMode.summon.rawValue

    private var followMode: VigilFollowMode { VigilFollowMode(rawValue: followModeRaw) ?? .summon }

    /// The burial tray's per-second countdown; subscribed only while the
    /// tray is on screen (autoconnect follows the subscriber). The old
    /// whole-tree 2s ticker is GONE: tree changes arrive event-driven
    /// (stateDidChange, fed by the state-dir and vigild-dir watchers).
    private let burialCountdown = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum Grid {
        static let chevron: CGFloat = 18
        static let icon: CGFloat = 20
        static let indent: CGFloat = 18
        static let dot: CGFloat = 12
        static let classSlot: CGFloat = 14
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
                                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                    // Remote hosts group under a header:
                                    // another Mac's sessions, viewports
                                    // only (VigilRemote). The header folds
                                    // the whole Mac, keyed by its device.
                                    let device = row.host.flatMap { _ in VigilRemote.split(row.id)?.device }
                                    if let host = row.host, let device,
                                       index == 0 || model.rows[index - 1].host != host {
                                        hostHeader(host, device: device)
                                    }
                                    if let device, collapse.hosts.contains(device) {
                                        EmptyView()
                                    } else {
                                        sessionGroup(row)
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
                    .onChange(of: model.selection) { selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                    .onChange(of: activeLeafId) { id in
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
                Picker("", selection: $followModeRaw) {
                    Text("Do nothing").tag(VigilFollowMode.off.rawValue)
                    Text("Summon it").tag(VigilFollowMode.summon.rawValue)
                    Text("Jump to it").tag(VigilFollowMode.window.rawValue)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
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

    private func hostHeader(_ title: String, device: String) -> some View {
        let collapsed = collapse.hosts.contains(device)
        return HStack(spacing: 4) {
            chevron(collapsed: collapsed) {
                if collapsed { collapse.hosts.remove(device) }
                else { collapse.hosts.insert(device) }
            }
            Image(systemName: "desktopcomputer")
            Text(title)
        }
        .font(.system(size: 11 * scale, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 10)
        .padding(.horizontal, 2)
    }

    // MARK: Session group (one block per session)

    private func sessionGroup(_ row: VigilWorkspaces.SidebarWorkspaceRow) -> some View {
        let collapsed = model.collapsedSessions.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            sessionRow(row, collapsed: collapsed)
                .id(row.id)
            if !collapsed {
                if let tab = row.soleTab {
                    ForEach(tab.panes) { pane in
                        paneRow(pane, session: row.id, tab: tab, level: 1)
                    }
                } else {
                    ForEach(row.tabs) { tab in
                        tabRow(tab, session: row.id)
                        if !model.collapsedTabs.contains(tab.id) {
                            ForEach(tab.panes) { pane in
                                paneRow(pane, session: row.id, tab: tab, level: 2)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
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
        // The chevron NEVER blinks out from under the cursor: any session
        // with content keeps it, however boring the content.
        let hasChildren = !row.tabs.isEmpty
        return HStack(spacing: 4) {
            if hasChildren {
                chevron(collapsed: collapsed) {
                    if collapsed { model.collapsedSessions.remove(id) }
                    else { model.collapsedSessions.insert(id) }
                }
            } else {
                Color.clear.frame(width: (Grid.chevron * scale), height: 1)
            }
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
                }
            ) {
                Text("·").font(.system(size: 13 * scale))
            }
            .opacity(row.stateTag == "windowed" ? 1 : 0.85)
            Spacer(minLength: 4)
            // Folded, who looks from elsewhere rolls up: a peek is never hidden.
            if collapsed { lookerGlyphs(row.tabs.flatMap(\.panes).flatMap(\.lookers)) }
            followKeycap(id)
            // No lifecycle tag on the row: every session is ALIVE by
            // construction (daemons carry it); the only honest distinction
            // is displayed-or-not, and the front tint + filled tab icons
            // already say that. Full state stays in the tooltip.
            // Collapsed, a descendant's antenna rolls up into the class
            // slot (a hidden listener must stay visible).
            Group {
                if collapsed, row.tabs.flatMap(\.panes).contains(where: { watchActive($0) }) {
                    watchRollup(row.tabs.flatMap(\.panes))
                } else {
                    Color.clear.frame(width: Grid.classSlot)
                }
            }
            // Expanded, the children speak for themselves; collapsed, the
            // parent peeks: one dot per distinct state, overlapped.
            Group {
                if collapsed { dotCluster(row.states) } else { dotSlot(nil) }
            }
        }
        .frame(height: 26 * scale)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: id,
            hovered: hovered == id,
            activity: model.isFront(row) ? (collapsed ? .leaf : .chain) : .none,
            state: collapsed ? row.states.first : nil))
        .background(reportHit(id: id, kind: .session(id)))
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag(.session(id))
            return NSItemProvider(object: id as NSString)
        }
        .contextMenu {
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
        .help("\(row.label) (\(row.id)) · \(row.stateTag)")
        .opacity(hintFade(id) * dragSourceFade(.session(id)))
        .overlay {
            if model.dropTarget == id {
                RoundedRectangle(cornerRadius: 5)
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
        return HStack(spacing: 4) {
            chevron(collapsed: collapsed) {
                if collapsed { model.collapsedTabs.remove(tab.id) }
                else { model.collapsedTabs.insert(tab.id) }
            }
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
            if tab.panes.count > 1 {
                Text("\(tab.panes.count)")
                    .font(.system(size: 9 * scale, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer(minLength: 4)
            if collapsed { lookerGlyphs(tab.panes.flatMap(\.lookers)) }
            followKeycap(tab.id)
            // The tab's class slot is free; collapsed, it wears the
            // descendants' antenna so a listener never vanishes.
            Group {
                if collapsed {
                    watchRollup(tab.panes)
                } else {
                    Color.clear.frame(width: Grid.classSlot, height: 1)
                }
            }
            Group {
                if collapsed {
                    dotCluster(AgentState.cluster(tab.panes.compactMap(\.state)))
                } else {
                    dotSlot(nil)
                }
            }
        }
        .frame(height: 22 * scale)
        .padding(.leading, (Grid.indent * scale))
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: tab.id,
            hovered: hovered == tab.id,
            activity: model.isFront(tab) ? (collapsed ? .leaf : .chain) : .none,
            state: collapsed
                ? AgentState.cluster(tab.panes.compactMap(\.state)).first
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
                RoundedRectangle(cornerRadius: 5)
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
                Image(systemName: pane.isDock ? "sidebar.right" : "terminal")
                    .font(.system(size: 8 * scale))
                    .foregroundColor(Color.secondary.opacity(0.8))
            }
            paneIdentity(pane)
            Spacer(minLength: 4)
            paneMarks(pane)
            followKeycap(id)
            watchGlyph(pane)
            dotSlot(pane.state)
        }
        .frame(height: 20 * scale)
        .padding(.leading, (Grid.indent * scale) * CGFloat(level) + (Grid.chevron * scale))
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: id,
            hovered: hovered == id,
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
    static let copied = CopyFeedback()

    /// The ids we speak by, dim beside the name and never louder than it:
    /// the conversation's name when the row's title is not it (you named
    /// the pane), else the pane's id cut in the middle (its end tells panes
    /// apart). Hovering the row shows every id whole; its menu copies them.
    @ViewBuilder
    private func paneIdentity(_ pane: VigilWorkspaces.SidebarPane) -> some View {
        let named = pane.conversationName.flatMap { $0 == pane.title ? nil : $0 }
        if let dim = named ?? pane.identifiers.first?.value {
            MiddleTruncate(dim, tail: named == nil ? "-" : 6)
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
            .padding(.leading, 4 + CGFloat(depth) * 18)
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

    /// A real hitbox (18×20 full shape), not an 8pt glyph.
    private func chevron(collapsed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8 * scale, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: (Grid.chevron * scale), height: 20 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The sentry's antenna is LIT: a declared lease, or survivor
    /// processes under a QUIET pane (hidden while the agent works - tool
    /// churn would blink it; a survivor under a quiet pane is the signal).
    private func watchActive(_ pane: VigilWorkspaces.SidebarPane) -> Bool {
        !pane.watchNotes.isEmpty || (pane.state != .working && !pane.watchProcs.isEmpty)
    }

    /// The sentry's antenna, in the pane row's class slot: something is
    /// alive under this pane beyond its program, LISTENING for the
    /// outside world. NOT an eye - the eye is vigil's own vocabulary
    /// (menu-bar identity, attention badge): eye = vigil watching YOU,
    /// antenna = a process watching the WORLD. Yellow: a live listener
    /// must read at a glance, and yellow is free on this rail (working's
    /// yellow dot never shares a row - the antenna hides while working).
    /// Declared vs derived lives in the tooltip (lease notes first).
    /// What a pane is to the world beyond this window, each only when it
    /// differs from the default: what its agent runs in the background,
    /// who looks from elsewhere (the phone, another Mac), a phone following
    /// it, its priority (high rings through Focus, low never rings).
    private func paneMarks(_ pane: VigilWorkspaces.SidebarPane) -> some View {
        HStack(spacing: 3 * scale) {
            if let background = pane.background { backgroundMark(background) }
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

    @ViewBuilder
    private func lookerGlyphs(_ lookers: [Viewer]) -> some View {
        ForEach(Array(Set(lookers)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { viewer in
            mark(viewer == .phone ? "iphone" : "laptopcomputer", .cyan, "Open on \(viewer.words) right now")
        }
    }

    /// Its background work, counted (agents, shells and the rest together);
    /// hovering says each count and what the first one is for.
    private func backgroundMark(_ background: PaneGlance.Background) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "gearshape.2").font(.system(size: 8 * scale, weight: .semibold))
            Text("\(background.agents + background.shells + background.others)")
                .font(.system(size: 9 * scale, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .help((["In the background: \(background.words)"] + [background.title].compactMap { $0 }).joined(separator: "\n"))
    }

    private func mark(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9 * scale, weight: .bold))
            .foregroundStyle(color)
            .help(help)
    }

    private func watchGlyph(_ pane: VigilWorkspaces.SidebarPane) -> some View {
        Group {
            if watchActive(pane) {
                antennaGlyph(pane.watchNotes + pane.watchProcs)
            }
        }
        .frame(width: Grid.classSlot)
    }

    private func antennaGlyph(_ what: [String]) -> some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 8 * scale, weight: .semibold))
            .foregroundColor(.yellow)
            .help(what.joined(separator: "\n"))
    }

    /// Collapse must not hide a listener: the antenna rolls up to the
    /// collapsed tab/session row (same slot, same yellow), carrying every
    /// descendant's notes in one tooltip.
    private func watchRollup(_ panes: [VigilWorkspaces.SidebarPane]) -> some View {
        let watching = panes.filter { watchActive($0) }
        return Group {
            if !watching.isEmpty {
                antennaGlyph(watching.flatMap { $0.watchNotes + $0.watchProcs })
            }
        }
        .frame(width: Grid.classSlot)
    }

    /// Fixed-width dot column: absent state reserves the slot, so the
    /// right rail never wiggles.
    private func dotSlot(_ state: AgentState?) -> some View {
        VigilStateDot(state: state)
            .frame(width: Grid.dot)
    }

    /// The collapsed rollup: one dot per distinct descendant state,
    /// overlapped (negative gap), blocked leftmost so the most urgent
    /// reads first. Grows inward; the right rail edge never moves.
    private func dotCluster(_ states: [AgentState]) -> some View {
        HStack(spacing: -2) {
            if states.isEmpty {
                Color.clear.frame(width: 7, height: 7)
            } else {
                // Per-PANE dots: duplicates are the point, so identity is
                // positional, not by state. Plain overlap - the ring
                // borders keep overlapping same-colour dots countable (a
                // destinationOut punch-out cannot composite CA-layer dots).
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    VigilStateDot(state: state)
                }
            }
        }
        .frame(minWidth: Grid.dot, alignment: .trailing)
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
                RoundedRectangle(cornerRadius: 5).fill(tint)
            }
            switch activity {
            case .leaf:
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.35))
            case .chain:
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12))
            case .none:
                EmptyView()
            }
            if hovered {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
            }
            if model.keyboardActive, model.selection == id {
                RoundedRectangle(cornerRadius: 5)
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

/// ONE indicator, the dot, and its motion IS the state: a spinning arc =
/// working (something is literally in motion), a pulsing solid = blocked
/// on you (it breathes until you answer), solid teal = done unseen,
/// faint solid = idle. Identical 7pt footprint in every form: state
/// changes never move layout.
///
/// The motion lives in CORE ANIMATION, never SwiftUI: `repeatForever`
/// SwiftUI animations invalidate the hosting view's render loop every
/// frame, and with one working claude visible the sidebar re-renders
/// continuously on the main thread (SwiftUI renderDisplayList dominating
/// main during a pure Metal scroll: the terminal stutters).
/// CABasicAnimation runs in the render server: zero app-side work per
/// frame.
struct VigilStateDot: View {
    let state: AgentState?

    var body: some View {
        VigilDotLayer(state: state)
            .frame(width: 7, height: 7)
    }
}

private struct VigilDotLayer: NSViewRepresentable {
    let state: AgentState?

    func makeNSView(context: Context) -> VigilDotNSView { VigilDotNSView() }
    func updateNSView(_ view: VigilDotNSView, context: Context) {
        view.apply(state)
    }
}

final class VigilDotNSView: NSView {
    private var current: AgentState??

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    func apply(_ state: AgentState?) {
        if current == state { return }
        current = state
        wantsLayer = true
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let rect = CGRect(x: 0, y: 0, width: 7, height: 7)
        switch state {
        case .working:
            // Faint body + bright arc, the arc rotating in the render
            // server forever.
            let body = CAShapeLayer()
            body.frame = rect
            body.path = CGPath(ellipseIn: rect, transform: nil)
            body.fillColor = NSColor.systemYellow.withAlphaComponent(0.3).cgColor
            layer.addSublayer(body)

            let arc = CAShapeLayer()
            arc.frame = rect
            let path = CGMutablePath()
            path.addArc(
                center: CGPoint(x: 3.5, y: 3.5), radius: 3,
                startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
            arc.path = path
            arc.strokeColor = NSColor.systemYellow.cgColor
            arc.fillColor = nil
            arc.lineWidth = 1
            arc.lineCap = .round
            layer.addSublayer(arc)

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.1
            spin.repeatCount = .infinity
            arc.add(spin, forKey: "spin")
        case .blocked:
            let dot = ringLayer(.systemOrange, in: rect)
            layer.addSublayer(dot)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        case .done:
            layer.addSublayer(ringLayer(.systemTeal, in: rect))
        case .idle:
            layer.addSublayer(ringLayer(.secondaryLabelColor.withAlphaComponent(0.6), in: rect))
        case .unknown:
            layer.addSublayer(ringLayer(.systemGray, in: rect))
        case .interrupting:
            layer.addSublayer(ringLayer(.systemYellow, in: rect))
        case nil:
            break
        }
        toolTip = state == .unknown ? "Agent state is unconfirmed" : state == .interrupting ? "Interruption requested; waiting for confirmation" : nil
    }

    /// Ring + translucent body (border at full colour, body ~55%): two
    /// same-colour dots overlapping in a cluster stay countable because
    /// the borders draw the boundary.
    private func ringLayer(_ color: NSColor, in rect: CGRect) -> CAShapeLayer {
        let dot = CAShapeLayer()
        dot.frame = rect
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        dot.path = CGPath(ellipseIn: inset, transform: nil)
        dot.fillColor = color.withAlphaComponent(0.55).cgColor
        dot.strokeColor = color.cgColor
        dot.lineWidth = 1
        return dot
    }
}
