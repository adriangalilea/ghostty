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
        // Self-heal before showing anything: a dead-window session must never
        // become a card. Then scream if any impossible state slipped through.
        manager.reconcile()
        manager.assertInvariants("buildEntries")
        manager.vlog("overview: " + manager.sessions.values
            .map { "\($0.name)[\($0.persistent ? "P" : "e")]" }.sorted().joined(separator: " "))
        // Every rebuild refreshes live thumbnails: p/u/undo change what a
        // card IS mid-showing, and a session touched for the first time
        // (adopt, upgrade) has no frozen snapshot to fall back on.
        manager.refreshThumbnails()
        var entries = manager.sessions.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .map { session -> OverviewEntry in
                OverviewEntry(
                    kind: .window,
                    name: session.name,
                    label: session.label,
                    state: session.state,
                    attention: session.attention,
                    thumbnail: session.thumbnail,
                    persistent: session.persistent,
                    daemonBacked: session.persistent && manager.daemonBacked(session: session),
                    pinned: manager.sessionPinned(session.name),
                    controller: manager.anchorController(of: session.name))
            }
        for controller in manager.ephemeralControllers() {
            let surface = controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
            let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
            let cwd = surface?.pwd ?? "~"
            let label = manager.ephemeralLabel(controller)
                ?? (title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title)
            entries.append(OverviewEntry(
                kind: .window,
                name: "ephemeral-\(UInt(bitPattern: ObjectIdentifier(controller).hashValue))",
                label: label,
                state: .embedded,
                attention: .none,
                thumbnail: VigilSessionManager.windowSnapshot(controller),
                persistent: false,
                daemonBacked: false,
                pinned: manager.isPinned(controller),
                controller: controller))
        }
        // The new-session act is a card too, right where you are looking.
        entries.append(OverviewEntry(
            kind: .create,
            name: "vigil-create-tile",
            label: "new session",
            state: .asleep,
            attention: .none,
            thumbnail: nil,
            persistent: false,
            daemonBacked: false,
            pinned: false,
            controller: nil))
        model.burials = manager.burials()
        return entries
    }

    private func show() {
        let manager = VigilSessionManager.shared
        manager.reconcile()

        model.entries = buildEntries()
        // Start on the window you were just in (the active/front one), not
        // always the first card: the overview opens where you left off.
        let front = (NSApp.keyWindow?.windowController as? TerminalController)
            ?? TerminalController.preferredParent
        model.selection = front.flatMap { f in
            // Any tab of the front window selects its session's card.
            if let name = manager.sessionName(of: f) {
                return model.entries.firstIndex { $0.name == name }
            }
            return model.entries.firstIndex { $0.controller === f }
        } ?? 0
        // Seed the hover anchor at the current cursor so the grid appearing
        // under a stationary mouse doesn't hijack the initial selection.
        model.lastHoverLocation = NSEvent.mouseLocation
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
            onReorder: { [weak self] in self?.persistOrder() },
            onClose: { [weak self] in self?.hide() },
            onActivate: { [weak self] entry in self?.activate(entry) },
            onKill: { [weak self] entry in
                self?.model.selection = self?.model.entries.firstIndex { $0.id == entry.id } ?? 0
                self?.removeSelected()
            },
            onPersist: { [weak self] entry in
                self?.model.selection = self?.model.entries.firstIndex { $0.id == entry.id } ?? 0
                self?.togglePersistSelected()
            },
            onPin: { [weak self] entry in
                self?.model.selection = self?.model.entries.firstIndex { $0.id == entry.id } ?? 0
                self?.togglePinSelected()
            },
            onRename: { [weak self] entry in
                self?.model.selection = self?.model.entries.firstIndex { $0.id == entry.id } ?? 0
                self?.renameSelected()
            },
            onRecover: { [weak self] entry in self?.recover(entry) },
            onRecoverBurial: { [weak self] burial in self?.recoverBurial(burial) },
            onDismissBurial: { [weak self] burial in self?.dismissBurial(burial) })
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
                case 45: self.createSession(); return nil // n
                case 35: self.togglePersistSelected(); return nil // p: persistent
                case 3: self.togglePinSelected(); return nil // f: floating (on top)
                case 15: self.renameSelected(); return nil // r: rename session
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
                    if let entry = self.model.selected { self.activate(entry) }
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

    /// Enter/click on a card: what it does depends on what the card IS.
    private func activate(_ entry: OverviewEntry) {
        switch entry.kind {
        case .window: openAndHide(entry)
        case .create: createSession()
        }
    }

    private func openAndHide(_ entry: OverviewEntry) {
        hide()
        // Embedded already has a window: just focus it. Detached/asleep needs
        // open() to re-embed or resurrect. State decides, not the class.
        if case .embedded = entry.state, let controller = entry.controller {
            VigilSessionManager.shared.vlog("overview: focus '\(entry.name)'")
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            VigilSessionManager.shared.vlog("overview: open '\(entry.name)'")
            VigilSessionManager.shared.open(name: entry.name)
        }
    }

    /// New session always rooted in HOME: a fresh scratch, never silently
    /// inheriting some other session's cwd (Adrian: `n` must not pick a random
    /// path).
    private func createSession() {
        hide()
        VigilSessionManager.shared.create(
            cwd: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Rename the selected session (persistent windows only; the label is
    /// the session's, ephemeral windows have no vigil label). The alert
    /// owns the keyboard while it runs, same modal handling as the kill
    /// confirmation.
    private func renameSelected() {
        guard let entry = model.selected, entry.isWindow else { return }
        let manager = VigilSessionManager.shared

        let alert = NSAlert()
        alert.messageText = "Rename"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = entry.label
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        modalActive = true
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        modalActive = false
        panel?.makeKeyAndOrderFront(nil)
        guard confirmed else { return }

        let label = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        if entry.persistent {
            manager.rename(name: entry.name, label: label)
        } else if let controller = entry.controller {
            manager.renameEphemeral(controller, label)
        }
        let keep = model.selection
        model.entries = buildEntries()
        model.selection = min(keep, max(model.entries.count - 1, 0))
        refit()
    }

    /// Pin/unpin the selected window on top. A persistent session stores
    /// the intent (works detached/asleep too); an ephemeral window is pure
    /// window level.
    private func togglePinSelected() {
        guard let entry = model.selected, entry.isWindow else { return }
        let manager = VigilSessionManager.shared
        if entry.persistent {
            manager.togglePinSession(entry.name)
        } else if let controller = entry.controller {
            manager.togglePin(controller)
        }
        let keep = model.selection
        model.entries = buildEntries()
        model.selection = min(keep, max(model.entries.count - 1, 0))
    }

    /// Pull a killed session back out of its grace period, intact.
    private func recover(_ entry: OverviewEntry) {
        VigilSessionManager.shared.exhume(entry.name)
        model.entries = buildEntries()
        model.selection = min(model.selection, max(model.entries.count - 1, 0))
        refit()
    }

    /// Recover a burial from the tray (back to a live/detached session).
    private func recoverBurial(_ burial: VigilSessionManager.Burial) {
        VigilSessionManager.shared.exhume(burial.name)
        model.entries = buildEntries()
        model.selection = min(model.selection, max(model.entries.count - 1, 0))
        refit()
    }

    /// Dismiss a burial NOW: reap it immediately instead of waiting the grace.
    private func dismissBurial(_ burial: VigilSessionManager.Burial) {
        VigilSessionManager.shared.reapNow(burial.name)
        model.entries = buildEntries()
        model.selection = min(model.selection, max(model.entries.count - 1, 0))
        refit()
    }

    /// p on a live window flips ephemeral <-> persistent in place, and
    /// persistent MEANS survives everything: the panes move into daemons
    /// on the spot. Detached and asleep are persistent by definition
    /// (there is no window to hand back); removing them is backspace's job.
    private func togglePersistSelected() {
        guard let entry = model.selected, entry.isWindow else { return }
        guard case .embedded = entry.state, let controller = entry.controller else { return }
        let manager = VigilSessionManager.shared
        if entry.persistent {
            manager.forget(name: entry.name)
        } else {
            manager.persistFully(controller: controller)
            // The fresh daemon panes are still booting; snapshot again once
            // they have replayed their content.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    guard self.panel != nil, !self.modalActive else { return }
                    let selection = self.model.selection
                    self.model.entries = self.buildEntries()
                    self.model.selection = min(selection, max(self.model.entries.count - 1, 0))
                }
            }
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
        guard let entry = model.selected, entry.isWindow else { return }
        let manager = VigilSessionManager.shared

        let alert = NSAlert()
        alert.messageText = "\(entry.removeVerb.capitalized) \(entry.label)?"
        var info: String
        switch entry.state {
        case .embedded: info = "The window closes and its processes die."
        case .floating: info = "Floating in the quick terminal; this is the kill. Its processes die."
        case .detached: info = "Detached but alive; this is the kill. Its processes die."
        case .asleep: info = "Only the registry entry and its frozen state are dropped."
        }
        if entry.persistent, let session = manager.sessions[entry.name] {
            info = "cwd: \(session.cwd)\ntabs: \(max(session.tabs.count, 1)) panes: \(max(session.paneCount, 1))\n" + info
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

        // Any registered session (persistent OR ephemeral, any state) buries
        // via kill(); killEphemeral is only for an unregistered window
        // (safety net).
        if manager.sessions[entry.name] != nil {
            manager.kill(name: entry.name)
        } else if let controller = entry.controller {
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
    /// What the card IS: a window/session, a killed session resting in its
    /// grace (dimmed, countdown, recoverable), or the new-session tile.
    enum Kind {
        case window
        case create
    }

    let kind: Kind
    let name: String
    let label: String
    let state: VigilSessionManager.State
    let attention: VigilSessionManager.Attention
    let thumbnail: NSImage?
    /// Persistent = vigil session (survives detach/quit/reboot). Ephemeral =
    /// a plain window, dies on close. A toggle, not a boundary.
    let persistent: Bool
    /// Survival class: true = every pane in a daemon (survives the app
    /// dying), false = capture+resume (processes die with the app).
    let daemonBacked: Bool
    /// Pinned on top (Antinote-style); only meaningful for live windows.
    let pinned: Bool

    var id: String { name }

    var isWindow: Bool {
        if case .window = kind { return true }
        return false
    }

    /// The live controller behind this card, if any (embedded window: the
    /// session's selected tab).
    let controller: TerminalController?

    /// Words, not glyphs: the overview must be readable with zero vocabulary.
    /// State-dependent verbs live in the kill CONFIRMATION, never in the
    /// hint bar: the bar is constant so the layout never shifts under the
    /// moving selection.
    var stateWord: String {
        switch state {
        case .embedded: return "live"
        case .floating: return "floating"
        case .detached: return "detached"
        case .asleep: return "asleep"
        }
    }

    var stateColor: Color {
        switch state {
        case .embedded: return .green
        case .floating: return .cyan
        case .detached: return .orange
        case .asleep: return .secondary
        }
    }

    /// State-honest verb for the kill confirmation.
    var removeVerb: String {
        switch state {
        case .embedded: return persistent ? "kill" : "close"
        case .floating, .detached: return "kill"
        case .asleep: return "forget"
        }
    }

}

@MainActor
class OverviewModel: ObservableObject {
    @Published var entries: [OverviewEntry] = []
    @Published var selection: Int = 0
    /// Mouse location at the last hover-driven selection. Hover only steals
    /// the selection when the pointer actually MOVED, not when a card
    /// appears under a stationary cursor (leaving the peek, or the grid
    /// first showing): that was hijacking keyboard focus back to wherever
    /// the mouse happened to sit.
    var lastHoverLocation: NSPoint?

    /// True when the cursor genuinely moved since the last hover selection.
    func mouseMoved() -> Bool {
        let loc = NSEvent.mouseLocation
        defer { lastHoverLocation = loc }
        guard let last = lastHoverLocation else { return true }
        return abs(last.x - loc.x) > 1 || abs(last.y - loc.y) > 1
    }
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
    /// Killed sessions in their grace period, rendered as a compact tray
    /// below the grid (out of the navigable grid, so a kill never reflows
    /// the live cards and each has its own unambiguous recover/dismiss).
    @Published var burials: [VigilSessionManager.Burial] = []

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
    let onClose: () -> Void
    let onActivate: (OverviewEntry) -> Void
    let onKill: (OverviewEntry) -> Void
    let onPersist: (OverviewEntry) -> Void
    let onPin: (OverviewEntry) -> Void
    let onRename: (OverviewEntry) -> Void
    let onRecover: (OverviewEntry) -> Void
    let onRecoverBurial: (VigilSessionManager.Burial) -> Void
    let onDismissBurial: (VigilSessionManager.Burial) -> Void

    var body: some View {
        VStack(spacing: 14) {
            // Close controls top-LEFT, macOS convention: the traffic-light
            // red X with an esc keycap beside it, clear of the content.
            HStack(spacing: 8) {
                Button(action: onClose) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.373, blue: 0.341))
                            .frame(width: 15, height: 15)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.black.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                keycap("esc")
                Spacer()
            }

            if model.zoomed, let selected = model.selected {
                peek(selected)
            } else {
                grid
            }

            // Killed sessions live in a compact tray, NOT the grid: a kill
            // never reflows the live cards, and each has its own recover
            // and a dismiss-now so it need not linger the full grace.
            if !model.burials.isEmpty {
                Divider().padding(.horizontal, 40)
                burialTray
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial))
        .fixedSize()
    }

    private var burialTray: some View {
        VStack(spacing: 6) {
            Text("recently killed")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 10) {
                ForEach(model.burials, id: \.name) { burial in
                    HStack(spacing: 10) {
                        Text(burial.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 130, alignment: .leading)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(burial.deadline.timeIntervalSince(context.date).rounded()))
                            Text("\(left)s")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.orange)
                                .monospacedDigit()
                        }
                        Button(action: { onRecoverBurial(burial) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("recover").font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.orange.opacity(0.9)))
                            .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)
                        Button(action: { onDismissBurial(burial) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.primary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss now: kill immediately instead of waiting out the grace.")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
                }
            }
        }
    }

    /// Quick Look-style peek: the selected session near-fullscreen. For a
    /// LIVE window the image re-captures a few times a second so the peek
    /// tracks the terminal in near real time (a detached/asleep session has
    /// no live window, so it stays its frozen snapshot). Arrows still move
    /// the selection, so triage happens without leaving the peek.
    private func peek(_ entry: OverviewEntry) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.6))
                TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                    let live = entry.controller.flatMap(VigilSessionManager.windowSnapshot)
                    if let image = live ?? entry.thumbnail {
                        Image(nsImage: image)
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
            }
            .frame(width: peekSize.width, height: peekSize.height - 80)

            HStack(spacing: 10) {
                Text(entry.label)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                survivalChip(entry)
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
                card(index: index, entry: entry)
            }
        }
    }

    // MARK: One card

    @ViewBuilder
    private func card(index: Int, entry: OverviewEntry) -> some View {
        let focused = index == model.selection
        let (persistTint, persistIcon): (Color, String) = entry.persistent
            ? (entry.daemonBacked ? .teal : .cyan, "infinity")
            : (.secondary, "hourglass")
        VStack(spacing: 6) {
            // The lane ABOVE the thumbnail holds ONLY the name (+ rename).
            if entry.isWindow {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(entry.label)
                        .font(.system(size: 14, weight: focused ? .bold : .medium))
                        .lineLimit(1)
                    barButton("r", "pencil", tint: .secondary, focused: focused,
                              help: "Rename") { onRename(entry) }
                    Spacer(minLength: 0)
                }
                .frame(width: cardSize.width, height: 24)
            } else {
                Color.clear.frame(height: 24)
            }

            thumbnail(entry, focused: focused)
                .frame(width: cardSize.width, height: cardSize.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            focused ? Color.accentColor : Color.white.opacity(0.15),
                            lineWidth: focused ? 3 : 1))
                // Persist top-LEFT; floating + kill top-RIGHT, on the picture.
                .overlay(alignment: .topLeading) {
                    if entry.isWindow {
                        cornerButton("p", persistIcon, tint: persistTint, focused: focused,
                                     help: entry.persistent
                                        ? "Persistent: survives quit. Click to make ephemeral."
                                        : "Ephemeral: dies on close. Click to make persistent.") { onPersist(entry) }
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if entry.isWindow {
                        HStack(spacing: 6) {
                            cornerButton("f", entry.pinned ? "macwindow.on.rectangle" : "macwindow",
                                         tint: .white, focused: focused,
                                         help: entry.pinned ? "Floating on top. Click to drop." : "Float on top") { onPin(entry) }
                            cornerButton("⌫", "trash", tint: .red, focused: focused,
                                         help: "Kill") { onKill(entry) }
                        }
                        .padding(8)
                    }
                }

            // Peek BELOW the thumbnail; height reserved so focus never shifts.
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                keycap("space")
                Text("peek").font(.system(size: 11))
            }
            .foregroundColor(.secondary)
            .opacity(focused && entry.isWindow ? 1 : 0)
            .frame(height: 16)
        }
        .onTapGesture { onActivate(entry) }
        .onHover { hovering in if hovering && model.mouseMoved() { model.selection = index } }
        .modifier(DragReorder(entry: entry, model: model, onReorder: onReorder))
    }

    /// A small text button (rename): icon then its keycap (space reserved,
    /// shown on focus), no background, dim when the card is not focused.
    private func barButton(
        _ key: String, _ icon: String, tint: Color, focused: Bool,
        help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(tint)
                keycap(key).opacity(focused ? 1 : 0)
            }
            .opacity(focused ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// A control ON the thumbnail corner (persist, floating, kill): icon
    /// then keycap on a dark chip so it reads over the preview; dim when the
    /// card is not focused.
    private func cornerButton(
        _ key: String, _ icon: String, tint: Color, focused: Bool,
        help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(tint)
                keycap(key).opacity(focused ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
            .opacity(focused ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The card's picture: a live thumbnail, the countdown over a dimmed
    /// snapshot for a buried session, or the new-session tile.
    @ViewBuilder
    private func thumbnail(_ entry: OverviewEntry, focused: Bool) -> some View {
        switch entry.kind {
        case .create:
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(focused ? 0.14 : 0.07))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .foregroundColor(.accentColor.opacity(0.6))
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundColor(.accentColor)
                    HStack(spacing: 5) {
                        keycap("n"); Text("new session").font(.system(size: 12))
                    }
                    .foregroundColor(.secondary)
                }
            }

        case .window:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6))
                if let thumb = entry.thumbnail {
                    Image(nsImage: thumb)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: cardSize.width - 8, maxHeight: cardSize.height - 8)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("no preview").font(.system(size: 14)).foregroundColor(.secondary)
                }
                // Attention lives BOTTOM-left; the titlebar strip owns the top.
                if entry.attention != .none {
                    VStack {
                        Spacer()
                        HStack {
                            chip(entry.attention == .input ? "needs you" : "done",
                                 entry.attention == .input ? .red : .green, filled: true)
                                .padding(6)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    /// The survival readout, one chip: teal = survives quit, icy cyan =
    /// resumes on quit, yellow = ephemeral (the class that just dies).
    @ViewBuilder
    private func survivalChip(_ entry: OverviewEntry) -> some View {
        if entry.persistent {
            chip(entry.daemonBacked ? "survives quit" : "resumes on quit",
                 entry.daemonBacked ? .teal : .cyan,
                 icon: "infinity")
        } else {
            chip("ephemeral", .secondary, icon: "hourglass")
        }
    }

    private func keycap(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
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
}

/// Drag-to-reorder, but only for real windows: the create tile and buried
/// cards are not reorderable, so the modifier passes them through untouched.
private struct DragReorder: ViewModifier {
    let entry: OverviewEntry
    let model: OverviewModel
    let onReorder: () -> Void

    func body(content: Content) -> some View {
        if entry.isWindow {
            content
                .onDrag {
                    model.dragging = entry.name
                    return NSItemProvider(object: entry.name as NSString)
                }
                .onDrop(of: [UTType.text], delegate: CardDrop(
                    target: entry.name, model: model, onReorder: onReorder))
        } else {
            content
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
