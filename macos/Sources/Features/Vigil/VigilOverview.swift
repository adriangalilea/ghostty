import AppKit
import SwiftUI

/// The sessions overview: a switcher panel with thumbnails of every session,
/// driven like any tab switcher (arrows to move, enter to open, esc to close,
/// click works too). Thumbnails are live for embedded sessions, captured at
/// detach for detached ones, absent for asleep (their card shows state only).
/// Borderless panels refuse key status by default; the switcher needs it so
/// arrows/enter work end to end, shortcut in, shortcut out.
final class VigilOverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
class VigilOverview: NSObject {
    static let shared = VigilOverview()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let model = OverviewModel()

    func toggle() {
        if panel != nil { hide() } else { show() }
    }

    private func show() {
        let manager = VigilSessionManager.shared
        manager.reconcile()
        manager.refreshThumbnails()

        model.entries = manager.sessions.values
            .sorted { $0.label < $1.label }
            .map { session in
                OverviewEntry(
                    name: session.name,
                    label: session.label,
                    state: session.state,
                    attention: session.attention,
                    thumbnail: session.thumbnail)
            }
        model.selection = 0
        guard !model.entries.isEmpty else { return }

        let view = OverviewView(model: model) { [weak self] name in
            self?.openAndHide(name)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let panel = VigilOverviewPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting

        let size = hosting.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(
            NSRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height),
            display: true)
        // Key + active so the keyboard reaches us even when summoned via the
        // global shortcut with the app in service mode.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // Switcher semantics: while the overview is up, arrows/enter/esc are
        // ours app-wide. The monitor dies with the panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                switch event.keyCode {
                case 123: self.model.move(-1); return nil // left
                case 124: self.model.move(1); return nil // right
                case 53: self.hide(); return nil // esc
                case 36, 76: // return, keypad enter
                    if let entry = self.model.selected { self.openAndHide(entry.name) }
                    return nil
                default:
                    return event
                }
            }
        }
    }

    private func openAndHide(_ name: String) {
        hide()
        VigilSessionManager.shared.open(name: name)
    }

    private func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: Model

struct OverviewEntry: Identifiable {
    let name: String
    let label: String
    let state: VigilSessionManager.State
    let attention: VigilSessionManager.Attention
    let thumbnail: NSImage?

    var id: String { name }

    var stateGlyph: String {
        switch state {
        case .embedded: return "●"
        case .detached: return "◌"
        case .asleep: return "○"
        }
    }
}

@MainActor
class OverviewModel: ObservableObject {
    @Published var entries: [OverviewEntry] = []
    @Published var selection: Int = 0

    var selected: OverviewEntry? {
        entries.indices.contains(selection) ? entries[selection] : nil
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = (selection + delta + entries.count) % entries.count
    }
}

// MARK: View

struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    let onOpen: (String) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.6))
                        if let thumbnail = entry.thumbnail {
                            // The whole window, scaled (Mission Control style):
                            // fill would center-crop away the edges of a wide
                            // terminal, which is exactly what you peek at.
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 252, maxHeight: 162)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text(entry.stateGlyph)
                                .font(.system(size: 42))
                                .foregroundColor(.secondary)
                        }
                        if entry.attention != .none {
                            VStack {
                                HStack {
                                    Spacer()
                                    Text(entry.attention == .input ? "🔔" : "✓")
                                        .font(.system(size: 20))
                                        .padding(6)
                                }
                                Spacer()
                            }
                        }
                    }
                    .frame(width: 260, height: 170)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                index == model.selection ? Color.accentColor : Color.white.opacity(0.15),
                                lineWidth: index == model.selection ? 3 : 1))

                    Text("\(entry.stateGlyph) \(entry.label)")
                        .font(.system(size: 13, weight: index == model.selection ? .bold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                }
                .onTapGesture { onOpen(entry.name) }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial))
        .fixedSize()
    }
}
