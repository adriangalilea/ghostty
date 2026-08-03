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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.rows) { row in
                            sessionGroup(row)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
                .onChange(of: model.selection) { selection in
                    if let selection { proxy.scrollTo(selection) }
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
        .background(rowBackground(selected: false, hovered: hovered == id, front: false))
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
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(row.persistent ? Color.teal.opacity(0.035) : Color.clear))
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
            // No "asleep/detached" tag: every session is ALIVE by
            // construction (daemons carry it); the only honest distinction
            // is displayed-or-not, and the front tint + filled tab icons
            // already say that. Full state stays in the tooltip.
            classGlyph(row.persistent)
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
            selected: model.selection == id,
            hovered: hovered == id,
            front: row.isFront,
            state: collapsed ? row.states.first : nil))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture {
            model.activate(.init(id: id, kind: .session(id)))
        }
        .onDrag {
            model.beginDrag(.session(id))
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
        .opacity(hintFade(id))
        .overlay(alignment: .leading) { hintChip(id, depth: 0) }
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
            // the outline is a tab resting cold (daemons running).
            Image(systemName: tab.cold ? "rectangle.on.rectangle" : "rectangle.inset.filled.on.rectangle")
                .font(.system(size: 9))
                .foregroundColor(tab.cold ? .secondary : .primary.opacity(0.8))
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
            Color.clear.frame(width: Grid.classSlot, height: 1)
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
            selected: model.selection == tab.id,
            hovered: hovered == tab.id,
            front: false,
            state: collapsed
                ? VigilSessionManager.clusterStates(tab.panes.compactMap(\.state)).first
                : nil))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? tab.id : (hovered == tab.id ? nil : hovered) }
        .onTapGesture {
            model.activate(.init(id: tab.id, kind: .tab(name: session, anchor: tab.anchor, id: tab.id)))
        }
        .id(tab.id)
        .onDrag {
            if let anchor = tab.anchor {
                model.beginDrag(.tab(session: session, anchor: anchor))
            }
            return NSItemProvider(object: tab.id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: VigilTabDrop(session: session, anchor: tab.anchor, model: model))
        .contextMenu {
            Button("Close Tab…", role: .destructive) {
                VigilSessionManager.shared.closeTabFromSidebar(
                    name: session, anchor: tab.anchor, in: model.hostController)
            }
        }
        .help(tab.cold
            ? "Cold tab: its processes run in their daemons; click to swap it into this window."
            : tab.title)
        .opacity(hintFade(tab.id))
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
            Image(systemName: pane.isDock ? "sidebar.right" : "terminal")
                .font(.system(size: 8))
                .foregroundColor(Color.secondary.opacity(0.8))
                .frame(width: Grid.icon)
            Text(pane.title)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
            Color.clear.frame(width: Grid.classSlot, height: 1)
            dotSlot(pane.state)
        }
        .frame(height: 20)
        .padding(.leading, Grid.indent * CGFloat(level) + Grid.chevron)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(
            selected: model.selection == id,
            hovered: hovered == id,
            front: false,
            state: pane.state))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture {
            model.activate(.init(id: id, kind: .pane(name: session, paneId: pane.paneId)))
        }
        .id(id)
        .onDrag {
            if let paneId = pane.paneId {
                model.beginDrag(.pane(session: session, paneId: paneId, isDock: pane.isDock))
            }
            return NSItemProvider(object: id as NSString)
        }
        .contextMenu {
            Button("Close Pane…", role: .destructive) {
                VigilSessionManager.shared.closePaneFromSidebar(
                    name: session, paneId: pane.paneId, in: model.hostController)
            }
        }
        .opacity(hintFade(id))
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
                // positional, not by state. Each dot PUNCHES OUT what is
                // beneath it in the cluster (destinationOut inside the
                // compositing group): the front dot fully occludes the one
                // behind - its translucency shows the sidebar, never the
                // neighbour's border - and the oversized punch leaves a
                // hairline gap that makes the count crisp.
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    ZStack {
                        Circle()
                            .fill(Color.black)
                            .frame(width: 8.5, height: 8.5)
                            .blendMode(.destinationOut)
                        VigilStateDot(state: state)
                    }
                }
            }
        }
        .compositingGroup()
        .frame(minWidth: Grid.dot, alignment: .trailing)
    }

    private func rowBackground(
        selected: Bool, hovered: Bool, front: Bool,
        state: VigilSessionManager.AgentState? = nil
    ) -> some View {
        ZStack {
            // The state's whisper, under everything: same collapse logic
            // as the dots (collapsed parent wears the rollup, expanded
            // rows wear their own).
            if let tint = stateTint(state) {
                RoundedRectangle(cornerRadius: 5).fill(tint)
            }
            RoundedRectangle(cornerRadius: 5)
                .fill(selected
                    ? Color.accentColor.opacity(0.25)
                    : hovered ? Color.primary.opacity(0.10)
                    : front ? Color.primary.opacity(0.06) : Color.clear)
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
struct VigilStateDot: View {
    let state: VigilSessionManager.AgentState?
    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        switch state {
        case .working:
            // A FILLED spinner: faint yellow body (so it holds its own
            // next to solid dots in a cluster) with the bright arc
            // spinning on top.
            ZStack {
                Circle().fill(Color.yellow.opacity(0.3))
                Circle()
                    .trim(from: 0.25, to: 1)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .padding(0.5)
                    .rotationEffect(.degrees(spin ? 360 : 0))
            }
            .frame(width: 7, height: 7)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
            .onDisappear { spin = false }
        case .blocked:
            ringDot(.orange)
                .opacity(pulse ? 0.35 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
                .onDisappear { pulse = false }
        case .done:
            ringDot(.teal)
        case .idle:
            ringDot(Color.secondary.opacity(0.6))
        case nil:
            Color.clear.frame(width: 7, height: 7)
        }
    }

    /// Every dot is a RING + translucent body (border at full colour,
    /// body ~55%): two same-colour dots overlapping in a cluster stay
    /// countable because the borders draw the boundary.
    private func ringDot(_ color: Color) -> some View {
        Circle()
            .fill(color.opacity(0.55))
            .overlay(Circle().stroke(color, lineWidth: 1))
            .frame(width: 7, height: 7)
    }
}
