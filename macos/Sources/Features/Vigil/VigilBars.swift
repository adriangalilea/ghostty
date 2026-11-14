import AppKit
import Ink
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
            VigilBars.shared.route(event)
        }
        // A workspace sitting blocked is followed as soon as its vetoes
        // lift (the app active, another key window, control mode left),
        // and each of those is one of these events.
        VigilWorkspaces.onPresenceInputs { VigilBars.shared.scheduleAutoFollow() }
    }

    // MARK: Auto-follow (the viewport chases the attention queue)

    /// Toggle at the sidebar's foot: when a session asks for input, the
    /// key window follows it; answering (the state flips off blocked)
    /// advances to the next in the queue. Never yanks while the CURRENT
    /// session is itself waiting on Adrian, never during control mode.
    private var followWork: DispatchWorkItem?

    func scheduleAutoFollow() {
        guard VigilFollowMode.current == .window else { return }
        followWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoFollowNow() }
        followWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func autoFollowNow() {
        guard VigilFollowMode.current == .window, !controlMode else { return }
        let manager = VigilWorkspaces.shared
        guard let target = manager.followTarget else { return }
        guard NSApp.isActive,
              let window = NSApp.keyWindow,
              let controller = window.windowController as? TerminalController else { return }
        let current = manager.workspaceName(of: controller)
        guard current != target else { return }
        // Any raw block in the current session vetoes the yank: it may be
        // an ask Adrian is mid-answering, or an approved tool mid-run.
        if let current, manager.asking(current) { return }
        followLog.info("auto-follow", ["workspace": target])
        // Pane-precise: the asking claude's TAB mounts and the pane takes
        // focus (a session-level shapeshift mounted the anchored tab; the
        // ask in tab 4 arrived at tab 1's console).
        manager.follow(target, in: controller)
        // The content just changed UNDER the cursor: a click/keystroke in
        // flight milliseconds later was aimed at the OLD content and must
        // not land in the new terminal. Shield the swapped window's
        // terminal briefly; the splash names the arrival and IS the
        // cooldown indicator (a swallowed event re-flashes it).
        shield(window: controller.window)
        let face: String = {
            guard let session = manager.workspaces[target] else { return target }
            let emoji = session.emoji.map { "\($0) " } ?? ""
            return emoji + session.label
        }()
        VigilFollowSplash.show(in: controller.window, text: face)
    }

    // MARK: Auto-follow input shield

    private var followShieldUntil: Date = .distantPast
    private weak var followShieldWindow: NSWindow?

    /// The summon shields the quick terminal the same way auto-follow
    /// shields a swapped viewport: content just changed (or appeared)
    /// under keystrokes possibly in flight, and a stray Enter must never
    /// answer a prompt sight-unseen.
    func shield(window: NSWindow?) {
        followShieldUntil = Date().addingTimeInterval(0.4)
        followShieldWindow = window
    }

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
        if controlMode { exitControlMode() } else { enterControlMode() }
    }

    func enterControlMode() {
        guard let window = NSApp.keyWindow,
              let controller = window.windowController as? TerminalController,
              let container = controller.terminalViewContainer else { return }
        if !sidebarVisible(for: controller) { setSidebarVisible(true, for: controller) }
        guard let host = container.subviews.compactMap({ $0 as? VigilSidebarHost }).first else { return }
        controlHost = host
        controlMode = true
        NotificationCenter.default.post(name: VigilWorkspaces.modeDidChange, object: nil)
        host.setControlActive(true)
        window.makeFirstResponder(host)
        host.model.ensureSelection()
        host.model.enterHintMode()
        host.model.onLeaveControl = { [weak self] in self?.exitControlMode() }
    }

    func exitControlMode() {
        guard controlMode else { return }
        controlMode = false
        NotificationCenter.default.post(name: VigilWorkspaces.modeDidChange, object: nil)
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

    /// The window's own visibility: the session's stored choice. A session
    /// without one is STAMPED with the app-wide default the first time its
    /// window syncs, so a later toggle elsewhere (which moves the default)
    /// can never repaint it: only a toggle on this window changes it.
    func sidebarVisible(for controller: TerminalController) -> Bool {
        let manager = VigilWorkspaces.shared
        let fallback = UserDefaults.standard.bool(forKey: visibleKey)
        if let name = manager.workspaceName(of: controller), manager.workspaces[name] != nil {
            if let stored = manager.workspaces[name]!.sidebar { return stored }
            manager.stampSidebar(name: name, fallback)
            return fallback
        }
        if let stray = strayVisible.object(forKey: controller) { return stray.boolValue }
        strayVisible.setObject(NSNumber(value: fallback), forKey: controller)
        return fallback
    }

    func setSidebarVisible(_ visible: Bool, for controller: TerminalController) {
        let manager = VigilWorkspaces.shared
        UserDefaults.standard.set(visible, forKey: visibleKey)
        if let name = manager.workspaceName(of: controller) {
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

    // MARK: The right bar's aside

    /// What the right bar shows that is no terminal: a pane's changes, its
    /// documents. It is about one pane and is shown only beside that pane:
    /// in the bar of the window whose tab holds it, as one more chip of the
    /// dock's strip, gone from the bar when another tab takes the window and
    /// back when its tab returns. A pane has one of each kind at most. It
    /// lives in memory alone and owns nothing a close could kill.
    final class Aside {
        /// What it shows of its pane: its word on the pane's row.
        enum Kind: String {
            case changes = "Changes"
            case documents = "Documents"

            var symbol: String {
                switch self {
                case .changes: "plusminus"
                case .documents: "doc.text"
                }
            }
        }

        /// The pane it is about (its daemon id).
        let pane: String
        let kind: Kind
        let title: String
        let view: AnyView
        /// To a window of its own, where it has one.
        let popOut: (() -> Void)?
        /// Shown, over the active dock pane.
        var front = true
        var width: CGFloat = 520
        /// When it was last asked for: of a tab's several, the latest shows.
        fileprivate var asked = Date()

        var symbol: String { kind.symbol }
        var id: String { Self.id(pane: pane, kind) }
        static func id(pane: String, _ kind: Kind) -> String { "\(pane)#\(kind.rawValue)" }

        init(pane: String, kind: Kind, title: String, view: AnyView, popOut: (() -> Void)? = nil) {
            self.pane = pane
            self.kind = kind
            self.title = title
            self.view = view
            self.popOut = popOut
        }
    }

    /// Each pane's asides, for whoever draws them (the sidebar's rows).
    final class AsideMarks: ObservableObject {
        @Published fileprivate(set) var kinds: [String: [Aside.Kind]] = [:]
    }
    let asideMarks = AsideMarks()

    /// By `Aside.id`.
    private var asides: [String: Aside] = [:] {
        didSet {
            var kinds: [String: [Aside.Kind]] = [:]
            for aside in asides.values.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) { kinds[aside.pane, default: []].append(aside.kind) }
            if kinds != asideMarks.kinds { asideMarks.kinds = kinds }
        }
    }

    /// The panes a window shows now: its tab's splits and its dock's.
    func panesOnScreen(in controller: TerminalController) -> Set<String> {
        Set(controller.surfaceTree.compactMap(\.vigilAttachId))
            .union(VigilWorkspaces.shared.dock(for: controller)?.views.compactMap(\.vigilAttachId) ?? [])
    }

    /// The aside this window's bar shows: the latest asked for among the
    /// panes on screen in it.
    func aside(in controller: TerminalController) -> Aside? {
        let here = panesOnScreen(in: controller)
        return asides.values.filter { here.contains($0.pane) }.max { $0.asked < $1.asked }
    }

    /// Asked again for a pane that has one of its kind brings it in front as
    /// it is (its scroll and its choices kept).
    func showAside(_ aside: Aside) {
        // One whose pane has ended is forgotten here, where the next is asked.
        let living = Set(VigilWorkspaces.shared.workspaces.values.flatMap { $0.tabs.flatMap(\.paneIds) })
        asides = asides.filter { living.contains($0.value.pane) }
        if let standing = asides[aside.id] {
            standing.front = true
            standing.asked = Date()
        } else {
            asides[aside.id] = aside
        }
        // The marks' sync is the bars' too: the titlebar's right-bar
        // button follows the aside.
        VigilWorkspaces.shared.syncWindowMarks()
    }

    func closeAside(pane: String, _ kind: Aside.Kind) {
        asides[Aside.id(pane: pane, kind)] = nil
        VigilWorkspaces.shared.syncWindowMarks()
    }

    func closeAside(in controller: TerminalController) {
        guard let aside = aside(in: controller) else { return }
        closeAside(pane: aside.pane, aside.kind)
    }

    /// A pane's aside in front again, in whichever window shows the pane.
    func frontAside(pane: String, _ kind: Aside.Kind) {
        guard let aside = asides[Aside.id(pane: pane, kind)] else { return }
        aside.front = true
        aside.asked = Date()
        VigilWorkspaces.shared.syncWindowMarks()
    }

    func setAsideFront(_ front: Bool, in controller: TerminalController) {
        aside(in: controller)?.front = front
        sync(controller)
    }

    /// The right bar's drag handle: the width of whichever is in front.
    func rightBarWidth(of controller: TerminalController) -> CGFloat {
        let runtime = VigilWorkspaces.shared.dock(for: controller)
        let tenants = runtime.map { !$0.collapsed && !$0.views.isEmpty } ?? false
        if let aside = aside(in: controller), aside.front || !tenants { return aside.width }
        return runtime?.width ?? 340
    }

    func setRightBarWidth(_ width: CGFloat, of controller: TerminalController) {
        let runtime = VigilWorkspaces.shared.dock(for: controller)
        let tenants = runtime.map { !$0.collapsed && !$0.views.isEmpty } ?? false
        if let aside = aside(in: controller), aside.front || !tenants {
            aside.width = min(max(width, 320), 1100)
            sync(controller)
        } else {
            VigilWorkspaces.shared.setDockWidth(controller, width: width)
        }
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
        if showSidebar { sidebar.model.refresh(reason: "bars") }

        // Right: the tab's dock panes, and the window's aside beside them.
        let manager = VigilWorkspaces.shared
        let runtime = manager.dock(for: controller)
        let aside = aside(in: controller)
        let tenants = runtime.map { !$0.collapsed && !$0.views.isEmpty } ?? false
        var dockWidth: CGFloat = 0
        if tenants || aside != nil {
            let dock = ensureDock(container, controller: controller)
            // In front: the aside while it is, else the active dock pane.
            let asideFront = aside.map { $0.front || !tenants } ?? false
            dockWidth = asideFront ? aside!.width : runtime?.width ?? 340
            dock.isHidden = false
            dock.widthConstraint.constant = dockWidth
            dock.present(runtime: tenants ? runtime : nil, aside: aside, asideFront: asideFront, controller: controller)
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
    @State private var sizing = false
    @AppStorage(VigilSidebarSize.key) private var fontSize = VigilSidebarSize.compact

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(on ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(on ? 0.18 : 0.08)))
            }
            .buttonStyle(.plain)
            .help(on
                ? "Hide the sidebar (⌘⇧B focuses it for keyboard navigation)."
                : "Show the sidebar: every workspace, its tabs, its panes, what they run. ⌘⇧B summons it with the keyboard; arrows move, enter lands, esc returns.")
            Button { sizing.toggle() } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sidebar size")
            .help("Sidebar size: scale text and rows together")
            .disabled(!on)
            // Reserve its slot so hiding the sidebar never moves the toggle.
            .opacity(on ? 1 : 0)
            .accessibilityHidden(!on)
            .popover(isPresented: $sizing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    // The size said beside its name, as a share of the compact one.
                    InkValue(
                        "Sidebar size", $fontSize, in: VigilSidebarSize.range, step: 1,
                        format: { "\(Int(VigilSidebarSize.bounded($0) / VigilSidebarSize.compact * 100))%" })
                    .inkValueFace(
                        .track(
                            minimum: .symbol("textformat.size.smaller"),
                            maximum: .symbol("textformat.size.larger"), readout: .always))
                    HStack {
                        Button("Reset") { VigilSidebarSize.reset() }
                            .disabled(fontSize == VigilSidebarSize.compact)
                        Spacer()
                        Text("⌘⇧B, then ⌘+ / ⌘−")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(width: 260)
            }
        }
        .padding(.leading, 8)
        .frame(height: 28)
        .onChange(of: on) { _, shown in if !shown { sizing = false } }
    }
}
