import AppKit
import SwiftUI

/// The two custom side bars of every terminal window (NEVER native
/// NSSplitViewController sidebars): LEFT the session tree, visibility
/// PER WINDOW (the session's, persisted; the last toggle is the default
/// for new windows) with one global width; RIGHT the per-tab dock.
/// Both are push splits INSIDE TerminalViewContainer: the bar views are
/// siblings of the terminal hosting view and the terminal is inset to make
/// room, so the titlebar toggle buttons never move when a bar toggles.
@MainActor
final class VigilBars {
    static let shared = VigilBars()

    private var keyMonitor: Any?

    private init() {
        // ONE local monitor (app-internal, no Accessibility) is the modal
        // seam: the terminal owns every key, so stepping out needs an
        // interceptor that fires BEFORE the pty ever sees the event.
        // Mouse-downs ride the same monitor for the auto-follow shield.
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            MainActor.assumeIsolated { VigilBars.shared.route(event) }
        }
        NotificationCenter.default.addObserver(
            forName: VigilSessionManager.stateDidChange,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { VigilBars.shared.scheduleAutoFollow() }
        }
        // Heartbeat: a session that has been SITTING blocked emits no new
        // event (observed 2026-08-03: follow never fired); evaluate on a
        // slow tick too, not only on changes.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VigilBars.shared.scheduleAutoFollow() }
            }
        }
    }

    // MARK: Auto-follow (the viewport chases the attention queue)

    /// Toggle at the sidebar's foot: when a session asks for input, the
    /// key window follows it; answering (the state flips off blocked)
    /// advances to the next in the queue. Never yanks while the CURRENT
    /// session is itself waiting on Adrian, never during control mode.
    private var followWork: DispatchWorkItem?

    func scheduleAutoFollow() {
        guard UserDefaults.standard.bool(forKey: "vigil.autofollow") else { return }
        followWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoFollowNow() }
        followWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func autoFollowNow() {
        guard UserDefaults.standard.bool(forKey: "vigil.autofollow"), !controlMode else { return }
        let manager = VigilSessionManager.shared
        guard let target = manager.followTarget else { return }
        guard NSApp.isActive,
              let window = NSApp.keyWindow,
              let controller = window.windowController as? TerminalController else { return }
        let current = manager.sessionName(of: controller)
        guard current != target else { return }
        // Any raw block in the current session vetoes the yank: it may be
        // an ask Adrian is mid-answering, or an approved tool mid-run.
        if let current, manager.asking(current) { return }
        manager.vlog("auto-follow -> '\(target)'")
        // Pane-precise: the asking claude's TAB mounts and the pane takes
        // focus (a session-level shapeshift mounted the anchored tab; the
        // ask in tab 4 arrived at tab 1's console).
        manager.follow(target, in: controller)
        // The content just changed UNDER the cursor: a click/keystroke in
        // flight milliseconds later was aimed at the OLD content and must
        // not land in the new terminal. Shield the swapped window's
        // terminal briefly; the splash names the arrival and IS the
        // cooldown indicator (a swallowed event re-flashes it).
        followShieldUntil = Date().addingTimeInterval(0.4)
        followShieldWindow = controller.window
        let face: String = {
            guard let session = manager.sessions[target] else { return target }
            let emoji = session.emoji.map { "\($0) " } ?? ""
            return emoji + session.label
        }()
        VigilFollowSplash.show(in: controller.window, text: face)
    }

    // MARK: Auto-follow input shield

    private var followShieldUntil: Date = .distantPast
    private weak var followShieldWindow: NSWindow?

    /// True while the event races a just-fired auto-follow swap AND is
    /// headed into the swapped window's TERMINAL content (sidebar rows,
    /// titlebar and other windows are stable targets; only the terminal
    /// changed under the cursor).
    private func shouldShield(_ event: NSEvent) -> Bool {
        guard Date() < followShieldUntil,
              let window = event.window, window === followShieldWindow else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let content = window.contentView else { return false }
            var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let v = view {
                if v is Ghostty.SurfaceView { return true }
                view = v.superview
            }
            return false
        case .keyDown:
            var responder = window.firstResponder as? NSView
            while let v = responder {
                if v is Ghostty.SurfaceView { return true }
                responder = v.superview
            }
            return false
        default:
            return false
        }
    }

    // MARK: Control mode (step OUT of the terminal, helix-style)

    /// ⇧Esc toggles it from anywhere (plain Esc stays the terminal's).
    /// Entering: the sidebar reveals, wears the yellow ring (input is
    /// grabbed), and the jump labels appear - the labels ARE the mode.
    /// Landing anywhere hands input straight back to the terminal.
    private(set) var controlMode = false
    private weak var controlHost: VigilSidebarHost?

    private func route(_ event: NSEvent) -> NSEvent? {
        if shouldShield(event) {
            VigilFollowSplash.reflash()
            return nil
        }
        guard event.type == .keyDown else { return event }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, mods == [.shift] { // ⇧Esc
            toggleControlMode()
            return nil
        }
        if mods == [.command, .shift], event.keyCode == 11 { // ⌘⇧B
            focusSidebar()
            return nil
        }
        guard controlMode, let host = controlHost else { return event }
        // ⌘ combos keep their meaning even in control mode (close, quit…).
        if mods.contains(.command) { return event }
        host.keyDown(with: event)
        return nil
    }

    func toggleControlMode() {
        controlMode ? exitControlMode() : enterControlMode()
    }

    func enterControlMode() {
        guard let window = NSApp.keyWindow,
              let controller = window.windowController as? TerminalController,
              let container = controller.terminalViewContainer else { return }
        if !sidebarVisible(for: controller) { setSidebarVisible(true, for: controller) }
        guard let host = container.subviews.compactMap({ $0 as? VigilSidebarHost }).first else { return }
        controlHost = host
        controlMode = true
        host.setControlActive(true)
        window.makeFirstResponder(host)
        host.model.ensureSelection()
        host.model.enterHintMode()
        host.model.onLeaveControl = { [weak self] in self?.exitControlMode() }
    }

    func exitControlMode() {
        guard controlMode else { return }
        controlMode = false
        controlHost?.model.onLeaveControl = nil
        controlHost?.model.exitHintMode()
        controlHost?.setControlActive(false)
        controlHost?.model.returnFocus?()
        controlHost = nil
    }

    /// The keyboard door into the left bar (nav without hint labels).
    func focusSidebar() {
        guard let window = NSApp.keyWindow,
              let controller = window.windowController as? TerminalController,
              let container = controller.terminalViewContainer else { return }
        if !sidebarVisible(for: controller) { setSidebarVisible(true, for: controller) }
        guard let host = container.subviews.compactMap({ $0 as? VigilSidebarHost }).first else { return }
        if window.firstResponder === host {
            host.model.returnFocus?()
            return
        }
        window.makeFirstResponder(host)
        host.model.ensureSelection()
    }

    private let visibleKey = "vigil.sidebar.visible"
    private let widthKey = "vigil.sidebar.width"

    /// Session-less strays keep their own flag, keyed by controller.
    private let strayVisible = NSMapTable<TerminalController, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    /// The window's own visibility: the session's stored choice, else the
    /// last toggle anywhere (the default a fresh window is born with).
    func sidebarVisible(for controller: TerminalController) -> Bool {
        let manager = VigilSessionManager.shared
        if let name = manager.sessionName(of: controller), let stored = manager.sessions[name]?.sidebar {
            return stored
        }
        if let stray = strayVisible.object(forKey: controller) { return stray.boolValue }
        return UserDefaults.standard.bool(forKey: visibleKey)
    }

    func setSidebarVisible(_ visible: Bool, for controller: TerminalController) {
        let manager = VigilSessionManager.shared
        UserDefaults.standard.set(visible, forKey: visibleKey)
        if let name = manager.sessionName(of: controller) {
            manager.setSidebar(name: name, visible) // persists + syncs every member
        } else {
            strayVisible.setObject(NSNumber(value: visible), forKey: controller)
            sync(controller)
        }
    }

    var sidebarWidth: CGFloat {
        get {
            let width = CGFloat(UserDefaults.standard.double(forKey: widthKey))
            return width > 0 ? min(max(width, 200), 480) : 280
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 200), 480)), forKey: widthKey)
            syncAll()
        }
    }

    func toggleSidebar(in controller: TerminalController) {
        setSidebarVisible(!sidebarVisible(for: controller), for: controller)
    }

    func syncAll() {
        for controller in TerminalController.all where controller.window != nil {
            sync(controller)
        }
    }

    /// Idempotent per-window install + state sync. Rides the
    /// syncWindowMarks chokepoint, so every window that exists gets its
    /// bars and every state change re-syncs them.
    func sync(_ controller: TerminalController) {
        guard let window = controller.window,
              let container = controller.terminalViewContainer,
              !controller.surfaceTree.isEmpty else { return }

        // Left: the session tree.
        let sidebar = ensureSidebar(container, controller: controller)
        let showSidebar = sidebarVisible(for: controller)
        sidebar.isHidden = !showSidebar
        sidebar.widthConstraint.constant = sidebarWidth
        if showSidebar { sidebar.model.refresh() }

        // Right: the tab's dock.
        let manager = VigilSessionManager.shared
        let runtime = manager.dock(for: controller)
        let showDock = runtime.map { !$0.collapsed && !$0.views.isEmpty } ?? false
        var dockWidth: CGFloat = 0
        if let runtime {
            let dock = ensureDock(container, controller: controller)
            dock.isHidden = !showDock
            dock.widthConstraint.constant = runtime.width
            if showDock {
                dock.present(runtime: runtime, controller: controller)
                dockWidth = runtime.width
            } else {
                dock.unmountActive()
            }
        } else if let dock = existingDock(container) {
            dock.isHidden = true
            dock.unmountActive()
        }

        container.vigilSetInsets(
            leading: showSidebar ? sidebarWidth : 0,
            trailing: dockWidth,
            top: 0)

        ensureToggleAccessory(window, controller: controller)
    }

    // MARK: Install

    private func ensureSidebar(
        _ container: TerminalViewContainer, controller: TerminalController
    ) -> VigilSidebarHost {
        if let existing = container.subviews.compactMap({ $0 as? VigilSidebarHost }).first {
            return existing
        }
        let host = VigilSidebarHost(controller: controller)
        container.addSubview(host)
        host.widthConstraint = host.widthAnchor.constraint(equalToConstant: sidebarWidth)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.widthConstraint,
        ])
        return host
    }

    private func existingDock(_ container: TerminalViewContainer) -> VigilDockHost? {
        container.subviews.compactMap({ $0 as? VigilDockHost }).first
    }

    private func ensureDock(
        _ container: TerminalViewContainer, controller: TerminalController
    ) -> VigilDockHost {
        if let existing = existingDock(container) { return existing }
        let host = VigilDockHost(controller: controller)
        container.addSubview(host)
        host.widthConstraint = host.widthAnchor.constraint(equalToConstant: 340)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.widthConstraint,
        ])
        return host
    }

    /// The LEFT titlebar toggle: fixed at the far left, rides the titlebar,
    /// never moves when the bar toggles (the whole point).
    private func ensureToggleAccessory(_ window: NSWindow, controller: TerminalController) {
        let existing = window.titlebarAccessoryViewControllers
            .compactMap { $0 as? VigilSidebarToggleAccessory }
            .first
        let toggle = VigilSidebarToggle(on: sidebarVisible(for: controller)) { [weak self, weak controller] in
            guard let controller else { return }
            self?.toggleSidebar(in: controller)
        }
        if let hosting = existing?.view as? NSHostingView<VigilSidebarToggle> {
            hosting.rootView = toggle
            hosting.setFrameSize(hosting.fittingSize)
        } else {
            let hosting = NSHostingView(rootView: toggle)
            // A titlebar accessory does not size from SwiftUI intrinsic
            // content; a concrete frame or it collapses to zero width.
            hosting.setFrameSize(hosting.fittingSize)
            let accessory = VigilSidebarToggleAccessory()
            accessory.view = hosting
            accessory.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}

final class VigilSidebarToggleAccessory: NSTitlebarAccessoryViewController {}

struct VigilSidebarToggle: View {
    let on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(on ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(on ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .help(on
            ? "Hide the session sidebar (⌘⇧B focuses it for keyboard navigation)."
            : "Show the session sidebar: every session, its tabs, its panes, what they run. ⌘⇧B summons it with the keyboard; arrows move, enter lands, esc returns.")
        .padding(.leading, 8)
        .frame(height: 28)
    }
}
