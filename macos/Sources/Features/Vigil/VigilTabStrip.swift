import AppKit
import SwiftUI

/// The session's tabs, visible IN the window: a slim strip under the
/// titlebar that appears the moment a session has more than one tab, so
/// tabs stay on screen with the sidebar closed. Chips carry the tab's
/// face/title and its state dot; the filled chip is the mounted tab,
/// clicking swaps in place (the viewport rule), + makes a new session tab
/// (⌘T's semantics). Native tab-windows never appear again.
@MainActor
final class VigilTabStripHost: NSView {
    private var hosting: NSHostingView<VigilTabStrip>?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(model: VigilSidebarModel, session: String, controller: TerminalController) {
        let strip = VigilTabStrip(model: model, session: session, controller: controller)
        if let hosting {
            hosting.rootView = strip
        } else {
            let view = NSHostingView(rootView: strip)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosting = view
        }
    }
}

struct VigilTabStrip: View {
    @ObservedObject var model: VigilSidebarModel
    let session: String
    weak var controller: TerminalController?

    var body: some View {
        HStack(spacing: 4) {
            if let row = model.rows.first(where: { $0.id == session }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(row.tabs) { tab in
                            chip(tab)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    guard let controller else { return }
                    _ = VigilSessionManager.shared.newViewportTab(controller)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New tab in this session (⌘T).")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
    }

    private func chip(_ tab: VigilSessionManager.SidebarTab) -> some View {
        let mounted = !tab.cold
        return HStack(spacing: 4) {
            if let emoji = tab.emoji, let first = emoji.first {
                Text(String(first)).font(.system(size: 11))
            }
            Text(tab.title)
                .font(.system(size: 11, weight: mounted ? .medium : .regular))
                .foregroundColor(mounted ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 160)
                .fixedSize(horizontal: true, vertical: false)
            VigilStateDot(state: tab.panes.compactMap(\.state).max())
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(mounted ? Color.primary.opacity(0.14) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !mounted, let controller else { return }
            VigilSessionManager.shared.activateTab(name: session, anchor: tab.anchor, in: controller)
        }
        .contextMenu {
            if let anchor = tab.anchor {
                Button("Rename…") {
                    VigilIdentity.editModal(
                        title: "Tab identity",
                        label: tab.title,
                        emoji: tab.emoji,
                        context: "a terminal tab, running: \(tab.panes.map(\.title).joined(separator: ", "))"
                    ) { label, emoji in
                        VigilSessionManager.shared.setCustomIdentity(
                            key: "tab:\(anchor)", label: label, emoji: emoji)
                    }
                }
            }
            Button("Close Tab…", role: .destructive) {
                VigilSessionManager.shared.closeTabFromSidebar(
                    name: session, anchor: tab.anchor, in: controller)
            }
        }
        .help(tab.title)
    }
}
