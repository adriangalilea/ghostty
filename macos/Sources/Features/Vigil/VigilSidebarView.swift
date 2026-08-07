import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The left bar's face. One visual BLOCK per session (the class is the
/// block: persistent wears the faint teal wash + leading accent, the
/// window border's language; ephemeral stays bare with the hourglass),
/// and one rigid column grid so every glyph and dot lands on the same
/// vertical line whatever the row type.
struct VigilSidebarView: View {
    @ObservedObject var model: VigilSidebarModel
    /// The app-wide collapse truth: observing it here is what makes a
    /// chevron toggled in ANY window re-render THIS sidebar (the model
    /// only proxies its values).
    @ObservedObject private var collapse = VigilSidebarCollapse.shared
    @State private var hovered: String?
    @AppStorage("vigil.autofollow") private var autoFollow = false

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
                        // a click activates and what a drop targets. The
                        // per-row tracking-area/gesture/delegate zoo let
                        // those disagree (hover activating outside its
                        // row, dead bands inside rows, drops cancelling in
                        // gaps): one disease, cured structurally
                        // (2026-08-05). Plain VStack on purpose - lazy
                        // row realization is where stale hit geometry
                        // lived, and this list is dozens of rows, not
                        // thousands.
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(model.rows) { row in
                                    sessionGroup(row)
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
                        .onPreferenceChange(VigilHitRowsKey.self) { model.hitRows = $0 }
                        .onContinuousHover(coordinateSpace: .named("vigilTree")) { phase in
                            switch phase {
                            case .active(let p): hovered = model.row(at: p)?.id
                            case .ended: hovered = nil
                            }
                        }
                        .gesture(SpatialTapGesture(coordinateSpace: .named("vigilTree"))
                            .onEnded { value in
                                if let row = model.row(at: value.location) { model.clicked(row) }
                            })
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
        .onReceive(ticker) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: VigilSessionManager.stateDidChange)
            .receive(on: DispatchQueue.main)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: VigilSessionManager.focusDidChange)
            .receive(on: DispatchQueue.main)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .receive(on: DispatchQueue.main)) { _ in model.refresh() }
    }

    /// A row's report into the shared geometry map.
    private func reportHit(id: String, kind: VigilHitRow.Kind) -> some View {
        GeometryReader { g in
            Color.clear.preference(
                key: VigilHitRowsKey.self,
                value: [VigilHitRow(id: id, kind: kind, frame: g.frame(in: .named("vigilTree")))])
        }
    }

    /// The row standing in for "where keystrokes land": the focused pane,
    /// or the deepest visible ancestor when collapse hides it. Drives the
    /// keep-visible scroll.
    private var activeLeafId: String? {
        guard let row = model.rows.first(where: \.isFront) else { return nil }
        if model.collapsedSessions.contains(row.id) { return row.id }
        if row.tabs.count == 1, let tab = row.tabs.first {
            if let pane = tab.panes.first(where: \.focused) { return "\(tab.id)#\(pane.id)" }
            return row.id
        }
        guard let tab = row.tabs.first(where: \.isFront) else { return row.id }
        if model.collapsedTabs.contains(tab.id) { return tab.id }
        if let pane = tab.panes.first(where: \.focused) { return "\(tab.id)#\(pane.id)" }
        return tab.id
    }

    // MARK: Up next (the manual-follow affordance, CO-LOCATED)

    /// The row ⌘⇧J would land on, promoted to the deepest VISIBLE row
    /// when collapse hides the pane - the active-leaf promotion rule
    /// pointed at the future: blue chain = where you are, orange keycap
    /// = where ⌘⇧J goes next. Visiting it re-derives the hint to the
    /// queue's next head; clicking the row is the same jump.
    private var hintRowId: String? {
        guard !autoFollow, let hint = model.followHint,
              let row = model.rows.first(where: { $0.id == hint.name }) else { return nil }
        if model.collapsedSessions.contains(row.id) { return row.id }
        guard let pane = hint.pane else { return row.id }
        if row.tabs.count == 1, let tab = row.tabs.first {
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
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.orange)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
                .help("⌘⇧J (or click) lands here\(model.followHint.map { $0.more > 0 ? "; \($0.more) more waiting" : "" } ?? "").")
        }
    }

    // MARK: Footer (auto-follow)

    /// The viewport chases the attention queue: a session asks for input,
    /// this window follows; answering advances to the next in line.
    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 9))
                .foregroundColor(autoFollow ? .orange : .secondary)
            Text("auto-follow")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(autoFollow ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: $autoFollow)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
        .help("When a session asks for input, this window follows it; answering advances to the next in the queue.")
    }

    // MARK: Burial tray (sticky bottom: killed, still undoable)

    private var burialTray: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Text("recently killed")
                    .font(.system(size: 9, weight: .medium))
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
    }

    private func burialRow(_ burial: VigilSessionManager.SidebarBurial) -> some View {
        let id = "burial-\(burial.id)"
        return HStack(spacing: 4) {
            Text(face(burial.emoji))
                .font(.system(size: 12))
                .frame(width: Grid.icon)
            Text(burial.label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(burial.remaining)s")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundColor(.secondary)
            Button {
                VigilSessionManager.shared.reapNow(burial.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Let it die now (skips the remaining grace).")
        }
        .frame(height: 22)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(id: id, hovered: hovered == id))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture { VigilSessionManager.shared.exhume(burial.id) }
        .help("Killed; dies for real in \(burial.remaining)s. Click to recover it whole (⌘⇧T also exhumes).")
    }

    // MARK: Session group (one block per session)

    private func sessionGroup(_ row: VigilSessionManager.SidebarSessionRow) -> some View {
        let collapsed = model.collapsedSessions.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            sessionRow(row, collapsed: collapsed)
                .id(row.id)
            if !collapsed {
                if row.tabs.count == 1, let tab = row.tabs.first {
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
            if row.persistent {
                RoundedRectangle(cornerRadius: 6).fill(Color.teal.opacity(0.035))
            }
            // The spotlight: the ACTIVE session's whole block lifts off
            // the list (wash + border), cool accent against the warm
            // state tints, so "where am I" is answered by the tree shape,
            // not one row.
            if row.isFront {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.06))
            }
        })
        .overlay {
            if row.isFront {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if row.persistent {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.teal.opacity(0.3))
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: Rows

    private func sessionRow(_ row: VigilSessionManager.SidebarSessionRow, collapsed: Bool) -> some View {
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
                Color.clear.frame(width: Grid.chevron, height: 1)
            }
            Text(face(row.emoji))
                .font(.system(size: 13))
                .frame(width: Grid.icon)
            Text(row.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .opacity(row.stateTag == "live" ? 1 : 0.85)
            Spacer(minLength: 4)
            followKeycap(id)
            // No "asleep/detached" tag: every session is ALIVE by
            // construction (daemons carry it); the only honest distinction
            // is displayed-or-not, and the front tint + filled tab icons
            // already say that. Full state stays in the tooltip.
            // Collapsed, a descendant's antenna outranks the survival
            // glyph in the shared class slot (a hidden listener must stay
            // visible; the hourglass returns on expand).
            Group {
                if collapsed, row.tabs.flatMap(\.panes).contains(where: { watchActive($0) }) {
                    watchRollup(row.tabs.flatMap(\.panes))
                } else {
                    classGlyph(row.persistent)
                }
            }
            // Expanded, the children speak for themselves; collapsed, the
            // parent peeks: one dot per distinct state, overlapped.
            Group {
                if collapsed { dotCluster(row.states) } else { dotSlot(nil) }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: id,
            hovered: hovered == id,
            activity: row.isFront ? (collapsed ? .leaf : .chain) : .none,
            state: collapsed ? row.states.first : nil))
        .background(reportHit(id: id, kind: .session(id)))
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag(.session(id))
            return NSItemProvider(object: id as NSString)
        }
        .contextMenu {
            Button(row.persistent
                ? "Make Ephemeral (dies on explicit close)"
                : "Make Persistent (survives quit and reboot)") {
                VigilSessionManager.shared.setPersistent(name: id, !row.persistent)
            }
            Button("Rename…") { VigilIdentity.editModal(name: id) }
            if model.rows.count > 1 {
                Menu("Merge Into") {
                    ForEach(model.rows.filter { $0.id != id }) { other in
                        Button("\(face(other.emoji)) \(other.label)") {
                            VigilSessionManager.shared.mergeSession(id, into: other.id)
                        }
                    }
                }
            }
            Divider()
            Button("Kill…", role: .destructive) {
                VigilSessionManager.shared.killWithConfirm(name: id)
            }
        }
        .help("\(row.label) (\(row.id)) · \(row.stateTag) · \(row.persistent ? "persistent" : "ephemeral")")
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

    private func tabRow(_ tab: VigilSessionManager.SidebarTab, session: String) -> some View {
        let collapsed = model.collapsedTabs.contains(tab.id)
        return HStack(spacing: 4) {
            chevron(collapsed: collapsed) {
                if collapsed { model.collapsedTabs.remove(tab.id) }
                else { model.collapsedTabs.insert(tab.id) }
            }
            // Same silhouette either way (no layout flash on swap): the
            // FILLED variant marks the tab the window displays right now,
            // the outline is a tab resting cold (daemons running). A
            // custom face takes the column over the glyph.
            Group {
                if let emoji = tab.emoji, let first = emoji.first {
                    Text(String(first)).font(.system(size: 11))
                } else {
                    Image(systemName: tab.cold ? "rectangle.on.rectangle" : "rectangle.inset.filled.on.rectangle")
                        .font(.system(size: 9))
                        .foregroundColor(tab.cold ? .secondary : .primary.opacity(0.8))
                }
            }
            .frame(width: Grid.icon)
            Text(tab.title)
                .font(.system(size: 11, weight: tab.cold ? .regular : .medium))
                .foregroundColor(tab.cold ? .secondary : .primary)
                .lineLimit(1)
            if tab.panes.count > 1 {
                Text("\(tab.panes.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer(minLength: 4)
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
                    dotCluster(VigilSessionManager.clusterStates(tab.panes.compactMap(\.state)))
                } else {
                    dotSlot(nil)
                }
            }
        }
        .frame(height: 22)
        .padding(.leading, Grid.indent)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: tab.id,
            hovered: hovered == tab.id,
            activity: tab.isFront ? (collapsed ? .leaf : .chain) : .none,
            state: collapsed
                ? VigilSessionManager.clusterStates(tab.panes.compactMap(\.state)).first
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
                        context: "a terminal tab in this workspace, cwd basename: \(tab.title), running: \(tab.panes.map(\.title).joined(separator: ", "))"
                    ) { label, emoji in
                        VigilSessionManager.shared.setCustomIdentity(
                            key: "tab:\(anchor)", label: label, emoji: emoji)
                    }
                }
            }
            Button("Close Tab…", role: .destructive) {
                VigilSessionManager.shared.closeTabFromSidebar(
                    name: session, anchor: tab.anchor, in: model.hostController)
            }
        }
        .help(tab.cold
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
        _ pane: VigilSessionManager.SidebarPane,
        session: String,
        tab: VigilSessionManager.SidebarTab,
        level: Int
    ) -> some View {
        let id = "\(tab.id)#\(pane.id)"
        return HStack(spacing: 4) {
            Group {
                if let emoji = pane.emoji, let first = emoji.first {
                    Text(String(first)).font(.system(size: 11))
                } else {
                    Image(systemName: pane.isDock ? "sidebar.right" : "terminal")
                        .font(.system(size: 8))
                        .foregroundColor(Color.secondary.opacity(0.8))
                }
            }
            .frame(width: Grid.icon)
            Text(pane.title)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
            followKeycap(id)
            watchGlyph(pane)
            dotSlot(pane.state)
        }
        .frame(height: 20)
        .padding(.leading, Grid.indent * CGFloat(level) + Grid.chevron)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            id: id,
            hovered: hovered == id,
            activity: pane.focused ? .leaf : .none,
            state: pane.state))
        .background(reportHit(
            id: id,
            kind: .pane(session: session, tabAnchor: tab.anchor, paneId: pane.paneId)))
        .contentShape(Rectangle())
        .id(id)
        .onDrag {
            if let paneId = pane.paneId {
                model.beginDrag(.pane(session: session, paneId: paneId, isDock: pane.isDock))
            }
            return NSItemProvider(object: id as NSString)
        }
        .contextMenu {
            if let paneId = pane.paneId {
                Button("Rename…") {
                    VigilIdentity.editModal(
                        title: "Pane identity",
                        label: pane.title,
                        emoji: pane.emoji,
                        context: "a terminal pane, running: \(pane.program ?? "a shell")"
                    ) { label, emoji in
                        VigilSessionManager.shared.setCustomIdentity(
                            key: paneId, label: label, emoji: emoji)
                    }
                }
            }
            Button("Close Pane…", role: .destructive) {
                VigilSessionManager.shared.closePaneFromSidebar(
                    name: session, paneId: pane.paneId, in: model.hostController)
            }
        }
        .opacity(hintFade(id)
            * (pane.paneId.map { dragSourceFade(.pane(session: session, paneId: $0, isDock: pane.isDock)) } ?? 1))
        .overlay(alignment: .leading) { hintChip(id, depth: level) }
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
            .font(.system(size: 11, weight: .bold, design: .monospaced))
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
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: Grid.chevron, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The sentry's antenna is LIT: a declared lease, or survivor
    /// processes under a QUIET pane (hidden while the agent works - tool
    /// churn would blink it; a survivor under a quiet pane is the signal).
    private func watchActive(_ pane: VigilSessionManager.SidebarPane) -> Bool {
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
    private func watchGlyph(_ pane: VigilSessionManager.SidebarPane) -> some View {
        Group {
            if watchActive(pane) {
                antennaGlyph(pane.watchNotes + pane.watchProcs)
            }
        }
        .frame(width: Grid.classSlot)
    }

    private func antennaGlyph(_ what: [String]) -> some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.yellow)
            .help(what.joined(separator: "\n"))
    }

    /// Collapse must not hide a listener: the antenna rolls up to the
    /// collapsed tab/session row (same slot, same yellow), carrying every
    /// descendant's notes in one tooltip.
    private func watchRollup(_ panes: [VigilSessionManager.SidebarPane]) -> some View {
        let watching = panes.filter { watchActive($0) }
        return Group {
            if !watching.isEmpty {
                antennaGlyph(watching.flatMap { $0.watchNotes + $0.watchProcs })
            }
        }
        .frame(width: Grid.classSlot)
    }

    /// Fixed-width class column: hourglass marks ephemeral, persistence is
    /// the group wash (no glyph needed).
    private func classGlyph(_ persistent: Bool) -> some View {
        Group {
            if !persistent {
                Image(systemName: "hourglass")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color.secondary.opacity(0.7))
            }
        }
        .frame(width: Grid.classSlot)
    }

    /// Fixed-width dot column: absent state reserves the slot, so the
    /// right rail never wiggles.
    private func dotSlot(_ state: VigilSessionManager.AgentState?) -> some View {
        VigilStateDot(state: state)
            .frame(width: Grid.dot)
    }

    /// The collapsed rollup: one dot per distinct descendant state,
    /// overlapped (negative gap), blocked leftmost so the most urgent
    /// reads first. Grows inward; the right rail edge never moves.
    private func dotCluster(_ states: [VigilSessionManager.AgentState]) -> some View {
        HStack(spacing: -2) {
            if states.isEmpty {
                Color.clear.frame(width: 7, height: 7)
            } else {
                // Per-PANE dots: duplicates are the point, so identity is
                // positional, not by state. Plain overlap - the ring
                // borders keep overlapping same-colour dots countable
                // (the old destinationOut punch-out cannot composite the
                // CA-layer dots, and the borders were already doing the
                // work).
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
        state: VigilSessionManager.AgentState? = nil
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

    private func stateTint(_ state: VigilSessionManager.AgentState?) -> Color? {
        switch state {
        case .blocked: return Color.orange.opacity(0.10)
        case .working: return Color.yellow.opacity(0.06)
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
/// SwiftUI animations invalidated the hosting view's render loop every
/// frame, and with one working claude visible the sidebar re-rendered
/// continuously on the main thread - the terminal's scroll stutter,
/// measured by sample 2026-08-06 (SwiftUI renderDisplayList dominating
/// main during a pure Metal scroll). CABasicAnimation runs in the render
/// server: zero app-side work per frame.
struct VigilStateDot: View {
    let state: VigilSessionManager.AgentState?

    var body: some View {
        VigilDotLayer(state: state)
            .frame(width: 7, height: 7)
    }
}

private struct VigilDotLayer: NSViewRepresentable {
    let state: VigilSessionManager.AgentState?

    func makeNSView(context: Context) -> VigilDotNSView { VigilDotNSView() }
    func updateNSView(_ view: VigilDotNSView, context: Context) {
        view.apply(state)
    }
}

final class VigilDotNSView: NSView {
    private var current: VigilSessionManager.AgentState??

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    func apply(_ state: VigilSessionManager.AgentState?) {
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
        case nil:
            break
        }
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
