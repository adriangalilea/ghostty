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
        }
        .onReceive(ticker) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: VigilSessionManager.stateDidChange)
            .receive(on: DispatchQueue.main)) { _ in model.refresh() }
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
            attentionBadge(row.attention)
            if row.stateTag != "live" {
                Text(row.stateTag)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            classGlyph(row.persistent)
            dotSlot(row.agg)
        }
        .frame(height: 26)
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
            dotSlot(collapsed ? tab.panes.compactMap(\.state).max() : nil)
        }
        .frame(height: 22)
        .padding(.leading, Grid.indent)
        .padding(.horizontal, 5)
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
        .help(tab.cold
            ? "Cold tab: its processes run in their daemons; click to swap it into this window."
            : tab.title)
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
            front: false))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .onTapGesture {
            model.activate(.init(id: id, kind: .pane(name: session, paneId: pane.paneId)))
        }
        .id(id)
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
        Circle()
            .fill(dotColor(state) ?? Color.clear)
            .frame(width: 7, height: 7)
            .frame(width: Grid.dot)
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
