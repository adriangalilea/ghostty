import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    private var resignObserver: Any?
    /// The kill confirmation owns the keyboard while it runs: the overview
    /// must neither treat losing key status as a dismissal nor keep eating
    /// keystrokes through its local monitor (Enter was firing open-session
    /// under the alert).
    private var modalActive = false
    private let model = OverviewModel()

    func toggle() {
        if panel != nil { hide() } else { show() }
    }

    /// All of ghostty, one grid: persistent sessions (any state) plus every
    /// ephemeral window. Ephemeral vs persistent is a per-card toggle, not a
    /// boundary of what the switcher can see.
    private func buildEntries() -> [OverviewEntry] {
        let manager = VigilSessionManager.shared
        var entries = manager.sessions.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .map { session in
                OverviewEntry(
                    name: session.name,
                    label: session.label,
                    state: session.state,
                    attention: session.attention,
                    thumbnail: session.thumbnail,
                    persistent: true)
            }
        for controller in manager.ephemeralControllers() {
            let surface = controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
            let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
            let cwd = surface?.pwd ?? "~"
            entries.append(OverviewEntry(
                name: "ephemeral-\(UInt(bitPattern: ObjectIdentifier(controller).hashValue))",
                label: title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title,
                state: .embedded(controller),
                attention: .none,
                thumbnail: VigilSessionManager.windowSnapshot(controller),
                persistent: false))
        }
        return entries
    }

    private func show() {
        let manager = VigilSessionManager.shared
        manager.reconcile()
        manager.refreshThumbnails()

        model.entries = buildEntries()
        model.selection = 0
        model.zoomed = false
        model.undoKey = manager.ghosttyApp?.config.keyboardShortcut(for: "undo")
            .map(Self.displayShortcut)
        guard !model.entries.isEmpty else { return }

        // Real estate: the switcher is the moment of visual triage, cards
        // scale to the screen instead of postage stamps. Up to 4 per row,
        // rows wrap; on a big display two sessions get two huge cards.
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let count = model.entries.count
        let columns = min(count, 4)
        let usable = screen.width * 0.88 - CGFloat(columns - 1) * 18 - 48
        let width = min(560, max(300, usable / CGFloat(columns)))
        model.columns = columns
        let cardSize = CGSize(width: width, height: width * 0.625)
        let peekSize = CGSize(width: screen.width * 0.82, height: screen.height * 0.78)

        let view = OverviewView(
            model: model,
            cardSize: cardSize,
            peekSize: peekSize,
            onReorder: { [weak self] in self?.persistOrder() }
        ) { [weak self] entry in
            self?.openAndHide(entry)
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

        // A switcher is a moment, not a window: clicking anywhere else
        // dismisses it exactly like esc.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.modalActive else { return }
                    self.hide()
                }
            }
        }

        // Switcher semantics: while the overview is up, arrows/enter/esc are
        // ours app-wide. The monitor dies with the panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                // The kill confirmation owns the keyboard: pass everything
                // through so Enter/esc hit the alert's buttons, not us.
                if self.modalActive { return event }

                // The toggle shortcut closes from inside: while this panel is
                // key there is no surface to run the keybind, so the monitor
                // is the only one who can honor it. Read from config, never
                // hardcoded.
                if let config = VigilSessionManager.shared.ghosttyApp?.config,
                   let shortcut = config.keyboardShortcut(for: "vigil_overview"),
                   Self.eventMatches(event, shortcut) {
                    self.hide()
                    return nil
                }

                // The configured undo shortcut works from inside the panel
                // (no surface here to run the keybind): exhume the last
                // kill and refresh the grid so it reappears in place.
                if let config = VigilSessionManager.shared.ghosttyApp?.config,
                   let shortcut = config.keyboardShortcut(for: "undo"),
                   Self.eventMatches(event, shortcut) {
                    (NSApp.delegate as? AppDelegate)?.undoManager.undo()
                    self.model.entries = self.buildEntries()
                    self.model.selection = min(self.model.selection, max(self.model.entries.count - 1, 0))
                    self.refit()
                    return nil
                }

                switch event.keyCode {
                case 123: self.model.move(-1); return nil // left
                case 124: self.model.move(1); return nil // right
                case 126: self.model.move(-self.model.columns); return nil // up
                case 125: self.model.move(self.model.columns); return nil // down
                case 45: // n: spawn a new session, rooted where you look
                    let cwd = self.model.selected.flatMap {
                        VigilSessionManager.shared.sessions[$0.name]?.cwd
                    } ?? FileManager.default.homeDirectoryForCurrentUser.path
                    self.hide()
                    VigilSessionManager.shared.create(cwd: cwd)
                    return nil
                case 35: self.togglePersistSelected(); return nil // p
                case 49: self.model.zoomed.toggle(); self.refit(); return nil // space
                case 51: self.removeSelected(); return nil // backspace
                case 53: // esc: leave the peek first, close second
                    if self.model.zoomed {
                        self.model.zoomed = false
                        self.refit()
                    } else {
                        self.hide()
                    }
                    return nil
                case 36, 76: // return, keypad enter
                    if let entry = self.model.selected { self.openAndHide(entry) }
                    return nil
                default:
                    return event
                }
            }
        }
    }

    /// Human form of a config shortcut for the hint bar.
    static func displayShortcut(_ shortcut: KeyboardShortcut) -> String {
        var out = ""
        if shortcut.modifiers.contains(.control) { out += "⌃" }
        if shortcut.modifiers.contains(.option) { out += "⌥" }
        if shortcut.modifiers.contains(.shift) { out += "⇧" }
        if shortcut.modifiers.contains(.command) { out += "⌘" }
        return out + String(shortcut.key.character).uppercased()
    }

    private static func eventMatches(_ event: NSEvent, _ shortcut: KeyboardShortcut) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var want: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { want.insert(.command) }
        if shortcut.modifiers.contains(.shift) { want.insert(.shift) }
        if shortcut.modifiers.contains(.option) { want.insert(.option) }
        if shortcut.modifiers.contains(.control) { want.insert(.control) }
        guard mods == want else { return false }
        return (event.charactersIgnoringModifiers ?? "").lowercased()
            == String(shortcut.key.character).lowercased()
    }

    /// Drag & drop wrote a new entries order; mirror it into the sessions'
    /// order fields so it survives restarts. Ephemeral windows keep their
    /// relative place only for this showing.
    private func persistOrder() {
        let manager = VigilSessionManager.shared
        for (index, entry) in model.entries.enumerated() where entry.persistent {
            manager.setOrder(name: entry.name, order: index)
        }
    }

    private func openAndHide(_ entry: OverviewEntry) {
        hide()
        if entry.persistent {
            VigilSessionManager.shared.open(name: entry.name)
        } else if case .embedded(let controller) = entry.state {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// p on a live window flips ephemeral <-> persistent in place. Detached
    /// and asleep are persistent by definition (there is no window to hand
    /// back); removing them is backspace's job.
    private func togglePersistSelected() {
        guard let entry = model.selected else { return }
        guard case .embedded(let controller) = entry.state else { return }
        let manager = VigilSessionManager.shared
        if entry.persistent {
            manager.forget(name: entry.name)
        } else {
            manager.adopt(controller: controller)
        }
        let keep = model.selection
        model.entries = buildEntries()
        model.selection = min(keep, model.entries.count - 1)
        refit()
    }

    /// Backspace kills for real, whatever the card is: window + processes for
    /// live ones, tree release for detached, registry drop for asleep. The
    /// confirmation shows the thumbnail and the exact consequence, so you
    /// never kill blind.
    private func removeSelected() {
        guard let entry = model.selected else { return }
        let manager = VigilSessionManager.shared

        let alert = NSAlert()
        alert.messageText = "\(entry.removeVerb.capitalized) \(entry.label)?"
        var info: String
        switch entry.state {
        case .embedded: info = "The window closes and its processes die."
        case .detached: info = "Detached but alive; this is the kill. Its processes die."
        case .asleep: info = "Only the registry entry and its frozen state are dropped."
        }
        if entry.persistent, let session = manager.sessions[entry.name] {
            info = "cwd: \(session.cwd)\npanes: \(max(session.panes.count, 1))\n" + info
        }
        alert.informativeText = info
        if let thumb = entry.thumbnail { alert.icon = thumb }
        alert.alertStyle = entry.removeVerb == "forget" ? .warning : .critical
        alert.addButton(withTitle: entry.removeVerb.capitalized)
        alert.addButton(withTitle: "Cancel")

        modalActive = true
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        modalActive = false
        panel?.makeKeyAndOrderFront(nil)
        guard confirmed else { return }

        if entry.persistent {
            manager.kill(name: entry.name)
        } else if case .embedded(let controller) = entry.state {
            manager.killEphemeral(controller)
        }
        model.entries = buildEntries()
        guard !model.entries.isEmpty else { hide(); return }
        model.selection = min(model.selection, model.entries.count - 1)
        refit()
    }

    /// The panel is sized for its content at show(); after a card leaves,
    /// content shrinks and the frame must follow or the survivor floats in
    /// dead space. Columns re-derive from the new count, then the frame
    /// animates to the new fit, recentered.
    private func refit() {
        model.columns = min(model.entries.count, 4)
        guard let panel, let hosting = panel.contentView else { return }
        DispatchQueue.main.async {
            let size = hosting.fittingSize
            let screen = NSScreen.main?.visibleFrame ?? .zero
            panel.setFrame(
                NSRect(
                    x: screen.midX - size.width / 2,
                    y: screen.midY - size.height / 2,
                    width: size.width,
                    height: size.height),
                display: true,
                animate: true)
        }
    }

    private func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
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
    /// Persistent = vigil session (survives detach/quit/reboot). Ephemeral =
    /// a plain window, dies on close. A toggle, not a boundary.
    let persistent: Bool

    var id: String { name }

    /// Words, not glyphs: the overview must be readable with zero vocabulary.
    var stateWord: String {
        switch state {
        case .embedded: return "live"
        case .detached: return "detached"
        case .asleep: return "asleep"
        }
    }

    var stateColor: Color {
        switch state {
        case .embedded: return .green
        case .detached: return .orange
        case .asleep: return .secondary
        }
    }

    /// State-honest verbs for the hint bar and the confirmation.
    var openVerb: String {
        switch state {
        case .embedded: return "focus"
        case .detached: return "open"
        case .asleep: return "resurrect"
        }
    }

    var removeVerb: String {
        switch state {
        case .embedded: return persistent ? "kill" : "close"
        case .detached: return "kill"
        case .asleep: return "forget"
        }
    }

    var persistVerb: String? {
        guard case .embedded = state else { return nil }
        return persistent ? "make ephemeral" : "make persistent"
    }
}

@MainActor
class OverviewModel: ObservableObject {
    @Published var entries: [OverviewEntry] = []
    @Published var selection: Int = 0
    /// Peek-zoom (space): the selected card fills the panel, Quick Look
    /// style. Arrows keep working; space or esc returns to the grid.
    @Published var zoomed: Bool = false
    /// Name of the entry being dragged for reorder, while a drag is live.
    var dragging: String?
    /// Cards per row; up/down arrows jump a whole row.
    var columns: Int = 4
    /// Display form of the configured `undo` shortcut (config-driven, shown
    /// only when one is bound).
    @Published var undoKey: String?

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
    let cardSize: CGSize
    let peekSize: CGSize
    let onReorder: () -> Void
    let onOpen: (OverviewEntry) -> Void

    var body: some View {
        VStack(spacing: 14) {
            if model.zoomed, let selected = model.selected {
                peek(selected)
            } else {
                grid
            }
            // Affordances always on view: the verbs are state-honest for the
            // selected card, so the bar doubles as a state readout.
            if let selected = model.selected {
                HStack(spacing: 18) {
                    hint("←→↑↓", "move")
                    hint("⏎", selected.openVerb)
                    hint("space", model.zoomed ? "grid" : "peek")
                    hint("n", "new session")
                    if let verb = selected.persistVerb {
                        hint("p", verb)
                    }
                    hint("⌫", selected.removeVerb)
                    if let undoKey = model.undoKey {
                        hint(undoKey, "undo kill")
                    }
                    hint("esc", model.zoomed ? "grid" : "close")
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial))
        .fixedSize()
    }

    /// Quick Look-style peek: the selected session near-fullscreen. Arrows
    /// still move the selection, so triage happens without leaving the peek.
    private func peek(_ entry: OverviewEntry) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.6))
                if let thumbnail = entry.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: peekSize.width - 12, maxHeight: peekSize.height - 90)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("no preview")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: peekSize.width, height: peekSize.height - 80)

            HStack(spacing: 10) {
                Text(entry.label)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                chip(entry.stateWord, entry.stateColor)
                if entry.persistent {
                    chip("persistent", .accentColor, icon: "eye.fill")
                } else {
                    chip("ephemeral", .secondary)
                }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(cardSize.width), spacing: 18),
                count: model.columns),
            spacing: 18
        ) {
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
                                .frame(maxWidth: cardSize.width - 8, maxHeight: cardSize.height - 8)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text("no preview")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        if entry.attention != .none {
                            VStack {
                                HStack {
                                    Spacer()
                                    chip(
                                        entry.attention == .input ? "needs you" : "done",
                                        entry.attention == .input ? .red : .green,
                                        filled: true)
                                        .padding(6)
                                }
                                Spacer()
                            }
                        }
                    }
                    .frame(width: cardSize.width, height: cardSize.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                index == model.selection ? Color.accentColor : Color.white.opacity(0.15),
                                lineWidth: index == model.selection ? 3 : 1))

                    Text(entry.label)
                        .font(.system(size: 15, weight: index == model.selection ? .bold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: cardSize.width)

                    HStack(spacing: 6) {
                        chip(entry.stateWord, entry.stateColor)
                        if entry.persistent {
                            chip("persistent", .accentColor, icon: "eye.fill")
                        } else {
                            chip("ephemeral", .secondary)
                        }
                    }
                }
                .onTapGesture { onOpen(entry) }
                .onHover { hovering in
                    if hovering { model.selection = index }
                }
                .onDrag {
                    model.dragging = entry.name
                    return NSItemProvider(object: entry.name as NSString)
                }
                .onDrop(of: [UTType.text], delegate: CardDrop(
                    target: entry.name,
                    model: model,
                    onReorder: onReorder))
            }
        }
    }

    /// Small labeled capsule: state and kind are words anyone can read, color
    /// is reinforcement, never the only carrier.
    private func chip(_ text: String, _ color: Color, icon: String? = nil, filled: Bool = false) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(filled ? .white : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(filled ? color : color.opacity(0.18)))
    }

    /// Key cap + verb, spelled out.
    private func hint(_ key: String, _ verb: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
            Text(verb)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}


/// Live drag & drop reordering: cards shift while hovering (dropEntered)
/// and the final order persists on drop.
struct CardDrop: DropDelegate {
    let target: String
    let model: OverviewModel
    let onReorder: () -> Void

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging = model.dragging, dragging != target,
                  let from = model.entries.firstIndex(where: { $0.name == dragging }),
                  let to = model.entries.firstIndex(where: { $0.name == target })
            else { return }
            withAnimation {
                model.entries.move(
                    fromOffsets: IndexSet(integer: from),
                    toOffset: to > from ? to + 1 : to)
            }
            model.selection = min(model.selection, model.entries.count - 1)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            model.dragging = nil
            onReorder()
        }
        return true
    }
}
