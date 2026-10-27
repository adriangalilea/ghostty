import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Floating (the quick terminal hosts one tab of a session)


    func quickController(create: Bool) -> QuickTerminalController? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        if !create && !delegate.quickControllerInitialized { return nil }
        return delegate.quickController
    }

    /// Drop a session into the quick terminal (Quake-style peek). The key
    /// always does something sensible: something floating -> dismiss it;
    /// else the most urgent pending session; else the session of the window
    /// you are in right now, so the key is never dead.
    func nextFloating() {
        if panelWorkspace != nil {
            quickController(create: false)?.animateOut()
            return
        }
        if let head = attentionQueue().first?.candidate {
            float(name: head.name, landOn: head.pane)
            return
        }
        guard let controller = TerminalController.preferredParent,
              let name = mirroredWorkspace(of: controller) ?? workspaceName(of: controller) else { return }
        if let device = controller.focusedSurface?.vigilHost, let pane = controller.focusedSurface?.vigilAttachId {
            float(name: name, landOn: VigilRemote.compositeId(device, pane))
        } else { float(name: name) }
    }

    /// Host a session in the quick terminal. A windowed session is
    /// MIRRORED: the panel shows a second client of one pane's daemon and
    /// the session's windows are never touched (the float is a viewport
    /// onto the session, not a move of it). A background session floats
    /// one of its held tabs; with no warm runtimes it resurrects into a
    /// real window instead (a rebuild belongs in a workspace, not a
    /// peek).
    /// `landOn` makes the landing pane-precise (the summon's contract, the
    /// same rule as follow()): THAT pane mirrors, or the tab CONTAINING it
    /// floats with the pane focused, never merely the first tab.
    func float(name: String, landOn pane: String? = nil) {
        if let remote = VigilRemote.split(name), let pane,
           let target = VigilRemote.split(pane), let quick = quickController(create: true),
           let app = ghosttyApp?.app,
           VigilRemote.shared.host(remote.device)?.directory?.panes[target.name]?.alive == true {
            if mirror?.pane == pane { quick.animateIn(); return }
            if let current = floatingName { reclaim(current, from: quick, restoreStash: false) } else if mirror != nil { endMirror(restoreStash: false) } else if !quick.surfaceTree.isEmpty { stashedQuickTree = quick.surfaceTree }
            var config = Ghostty.SurfaceConfiguration()
            config.vigilAttach = target.name; config.vigilHost = remote.device
            config.vigilMirror = true; config.vigilExplicitClaim = true
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            mirror = Mirror(name: name, pane: pane, view: view)
            quickTreeSwap = true; quick.surfaceTree = SplitTree(view: view); quickTreeSwap = false
            quick.animateIn()
            DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
            viewportLog.info("remote mirror floated", ["pane": pane])
            return
        }
        guard let session = workspaces[name] else { return }
        guard let quick = quickController(create: true) else { return }

        let floated: TabRuntime
        var rest: [TabRuntime] = []
        var floatedIndex = 0
        if windowed(name) {
            guard let target = pane ?? focusedPane(of: name) else {
                viewportLog.warn("float refused: no pane to mirror", ["workspace": name])
                return
            }
            // WINDOWED view or bust: a windowless view would skip the
            // materialize and then fail the windowed guard below, making
            // the summon refusable forever for that pane.
            // materializeCapturedTab adopts such a view.
            if liveView(attachId: target)?.window == nil {
                // A captured tab (registered, daemon alive, no view)
                // becomes a silent native tab of its home window first, so
                // the mirror always has a home to match. The home window
                // is never the panel.
                guard let tabIndex = workspaces[name]!.tabs.firstIndex(where: { $0.panes.contains { $0.id == target } }),
                      let host = anchorController(of: name) else {
                    viewportLog.warn("float refused: pane has no view and no captured tab", ["workspace": name, "pane": target])
                    return
                }
                materializeCapturedTab(name: name, tabIndex: tabIndex, host: host)
            }
            guard let home = liveView(attachId: target), home.window != nil else {
                viewportLog.warn("float refused: pane has no windowed view", ["workspace": name, "pane": target])
                return
            }
            mirror(name: name, pane: target, home: home, quick: quick)
            return
        } else if session.float != nil {
            // Already hosted here. A pane in the floated tab just takes
            // focus; a pane waiting in a REST tab re-floats on its own tab
            // (reclaim to held, keep the quick workspace stashed for the
            // flow's eventual dismissal, float again pane-precise).
            if let pane, !quick.surfaceTree.contains(where: { $0.vigilAttachId == pane }) {
                reclaim(name, from: quick, restoreStash: false)
                float(name: name, landOn: pane)
                return
            }
            // Presence acks once the quick terminal is key (chokepoint).
            quick.animateIn()
            if let pane, let view = quick.surfaceTree.first(where: { $0.vigilAttachId == pane }) {
                DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
            }
            return
        } else if !session.held.isEmpty {
            let held = session.held
            if let pane, !held.contains(where: { $0.tree.contains { $0.vigilAttachId == pane } }) {
                // The ask lives in a CAPTURED tab (no runtime): resurrect
                // just that tab into the panel; the live runtimes wait as
                // rest.
                if let tabIndex = workspaces[name]!.tabs.firstIndex(where: { $0.panes.contains { $0.id == pane } }) {
                    floatCapturedTab(name: name, tabIndex: tabIndex, landOn: pane, quick: quick)
                    return
                }
            }
            floatedIndex = held.firstIndex { tab in
                guard let pane else { return false }
                return tab.tree.contains { $0.vigilAttachId == pane }
            } ?? held.count - 1
            floated = held[floatedIndex]
            rest = held
            rest.remove(at: floatedIndex)
        } else {
            // Pane-precise float of a background session with no warm
            // runtimes = the summon's resurrect-into-the-panel (the
            // post-relaunch fleet must summon); a plain manual float keeps
            // the peek-vs-rebuild doctrine and opens a real window.
            if let pane {
                ensureHostPanes(name)
                if let tabIndex = workspaces[name]!.tabs.firstIndex(where: { $0.panes.contains { $0.id == pane } }) {
                    floatCapturedTab(name: name, tabIndex: tabIndex, landOn: pane, quick: quick)
                    return
                }
            }
            open(name: name)
            return
        }

        // Whoever floats now leaves first; a native quick terminal
        // workspace is stashed, not destroyed. A float replacing a float
        // keeps the stash INTACT (restoreStash: false): restoring it here
        // only to overwrite it a line later dropped the native workspace
        // silently.
        if let current = floatingName {
            reclaim(current, from: quick, restoreStash: false)
        } else if mirror != nil {
            endMirror(restoreStash: false)
        } else if !quick.surfaceTree.isEmpty {
            stashedQuickTree = quick.surfaceTree
        }

        workspaces[name]!.float = FloatRuntime(rest: rest, dock: floated.dock, index: floatedIndex)
        workspaces[name]!.held = []
        floatingName = name
        quickTreeSwap = true
        quick.surfaceTree = floated.tree
        quickTreeSwap = false
        quick.animateIn()
        let landing = pane.flatMap { p in floated.tree.first { $0.vigilAttachId == p } }
            ?? floated.tree.root?.leftmostLeaf()
        if let view = landing {
            DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
        }
        persist()
    }

    /// The floating session leaves the quick terminal: back to background
    /// with whatever its tree is NOW (splits made while floating already
    /// edited the registry through the chokepoint), reinserted among its
    /// waiting held tabs, and the quick terminal gets its own stashed
    /// workspace back.
    /// `restoreStash: false` is the float-replaces-float path: the next
    /// tree overwrites the quick terminal immediately, so the stashed
    /// native workspace must survive for the flow's FINAL dismissal.
    func reclaim(_ name: String, from quick: QuickTerminalController, restoreStash: Bool = true) {
        guard floatingName == name else { return }
        floatingName = nil
        let tree = quick.surfaceTree
        if let session = workspaces[name] {
            var held: [TabRuntime] = []
            var index = 0
            var dock: VigilDockRuntime?
            if let float = session.float {
                held = float.rest
                index = float.index
                dock = float.dock
            }
            if !tree.isEmpty {
                held.insert(TabRuntime(tree: tree, dock: dock), at: min(index, held.count))
            }
            workspaces[name]!.float = nil
            workspaces[name]!.held = held
        }
        if restoreStash {
            quickTreeSwap = true
            quick.surfaceTree = stashedQuickTree ?? SplitTree()
            quickTreeSwap = false
            stashedQuickTree = nil
        }
        persist()
    }

    // MARK: Mirroring (the quick terminal shows a pane that lives in a window)

    /// A second client on one daemon: `view` rides the panel, `home` stays
    /// in its session window. The mirror owns nothing (no registry row,
    /// never persisted, never the pane's live view); it exists exactly
    /// while the panel is up. Part of the panel-occupancy set with
    /// floatingName and stashedQuickTree: at most one of floatingName /
    /// mirror is set.
    struct Mirror {
        let name: String
        let pane: String
        let view: Ghostty.SurfaceView
    }


    func mirroredWorkspace(of controller: TerminalController) -> String? {
        mirrorViewports.object(forKey: controller) as String?
    }

    /// This viewport becomes a mirror of `name`'s anchored tab (else its
    /// first). Its current occupant leaves as any shapeshift's does.
    func mirrorInto(_ controller: TerminalController, name: String, anchor: String?) {
        guard let app = ghosttyApp?.app, let session = workspaces[name], !session.tabs.isEmpty else {
            viewportLog.warn("mirror refused: no tabs to show", ["workspace": name])
            return
        }
        let tab = anchor.flatMap { a in session.tabs.first { $0.paneIds.contains(a) } } ?? session.tabs[0]
        guard !tab.panes.isEmpty else {
            viewportLog.warn("mirror refused: tab has no panes", ["workspace": name])
            return
        }
        if mirroredWorkspace(of: controller) != nil {
            endMirrorViewport(controller)
        } else {
            releaseOccupant(of: controller)
        }
        let configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration = { [self] pane in
            var config = resurrectConfig(name: name, pane: pane)
            config.vigilMirror = true
            return config
        }
        let firstPane = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
        let view = Ghostty.SurfaceView(app, baseConfig: configFor(tab.panes[firstPane]))
        swapTree(controller, SplitTree(view: view))
        mirrorViewports.setObject(name as NSString, forKey: controller)
        remoteLayouts[ObjectIdentifier(controller)] = VigilSessionControl.revision([tab])
        materializeSplits(controller, tab: tab, configFor: configFor)
        land(controller, anchor: anchor, fallback: view)
        viewportLog.info("mirror viewport opened", ["window": workspaceName(of: controller), "workspace": name, "panes": tab.panes.count])
        touchRecent(name)
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// Focus the clicked pane of a freshly mounted tab. The tree is whole
    /// by now (materializeSplits builds it in the mount's turn); a size
    /// claim waits for the pane's layout through `vigilRequestSize`.
    private func land(_ controller: TerminalController, anchor: String?, fallback: Ghostty.SurfaceView, takeSize: Bool = false) {
        let landing: Ghostty.SurfaceView
        if let anchor {
            guard let found = controller.surfaceTree.first(where: { $0.vigilAttachId == anchor }) else {
                handoffLog.warn("landing refused: pane absent from window", ["pane": anchor, "window": controller.window?.windowNumber])
                return
            }
            landing = found
        } else {
            landing = fallback
        }
        // A gesture landed here: this window takes the keyboard back from
        // any floating panel holding key, so focus and title follow it.
        if takeSize, NSApp.isActive, controller.window?.isKeyWindow == false { controller.window?.makeKey() }
        DispatchQueue.main.async { Ghostty.moveFocus(to: landing) }
        if takeSize { landing.vigilRequestSize(reason: "sidebar pane selected") }
        handoffLog.info("landed", ["host": landing.vigilHost, "pane": landing.vigilAttachId, "window": controller.window?.windowNumber])
    }

    /// A REMOTE session (another Mac, VigilRemote) in this viewport: the
    /// same mirror viewport, its surfaces attached through this Mac's hub
    /// (`proxy` over tether, VigilRemote). Nothing is spawned or owned
    /// remotely; the remote's own app keeps every fact.
    @discardableResult
    func openRemotePane(device: String, pane: String) -> TerminalController? {
        guard let directory = VigilRemote.shared.host(device)?.directory,
              let session = directory.workspaces.first(where: { session in (session.tabs ?? []).contains { $0.paneIds.contains(pane) } }) else {
            handoffLog.warn("remote refused: pane absent from directory", ["host": device, "pane": pane])
            return nil
        }
        // A request panel may be key. The main/last-main terminal remains the
        // user's viewport; closed-window undo corpses are never destinations.
        let candidates = [NSApp.keyWindow?.windowController as? TerminalController,
                          NSApp.mainWindow?.windowController as? TerminalController,
                          TerminalController.lastMain]
            + NSApp.orderedWindows.map { $0.windowController as? TerminalController }
        let viewport = candidates.compactMap { $0 }.first {
            !$0.surfaceTree.isEmpty && ($0.window?.isVisible == true || $0.window?.isMiniaturized == true)
        }
        guard let controller = mountRemote(viewport, composite: VigilRemote.compositeId(device, session.name),
                                           anchor: VigilRemote.compositeId(device, pane)) else { return nil }
        handoffLog.info("remote landed", ["host": device, "pane": pane, "workspace": session.name, "window": controller.window?.windowNumber, "reused": viewport != nil])
        if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    func reconnectRemoteViewport(_ view: Ghostty.SurfaceView) {
        if let current = mirror, current.view === view, view.vigilHost != nil {
            let name = current.name, pane = current.pane
            endMirror()
            float(name: name, landOn: pane)
            return
        }
        guard let controller = view.window?.windowController as? TerminalController,
              let composite = mirroredWorkspace(of: controller), let device = view.vigilHost,
              let pane = view.vigilAttachId,
              VigilRemote.shared.session(composite) != nil else { return }
        remoteLog.info("viewport reconnecting", ["workspace": composite, "pane": pane])
        endMirrorViewport(controller)
        mountRemote(controller, composite: composite, anchor: VigilRemote.compositeId(device, pane))
    }

    @discardableResult
    func mountRemote(_ viewport: TerminalController?, composite: String, anchor: String?) -> TerminalController? {
        guard let ghostty = ghosttyApp, let app = ghostty.app,
              let (device, session) = VigilRemote.shared.session(composite) else {
            remoteLog.warn("mount refused: workspace unknown or unreachable", ["workspace": composite])
            return nil
        }
        let rawAnchor = anchor.flatMap { VigilRemote.split($0)?.name }
        let tabs = session.tabs ?? []
        let tab = rawAnchor.flatMap { a in tabs.first { $0.paneIds.contains(a) } } ?? tabs.first
        guard let tab, !tab.panes.isEmpty else { return nil }
        // Already this viewport's mirror and the clicked pane is on screen:
        // a click is a focus move, never a teardown and two fresh proxy
        // streams.
        if let controller = viewport, mirroredWorkspace(of: controller) == composite,
           let shown = controller.surfaceTree.first(where: { $0.vigilAttachId == rawAnchor ?? "" }) ?? (rawAnchor == nil ? controller.surfaceTree.first : nil) {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: shown)
                shown.vigilControlSize(true, reason: "sidebar pane selected")
            }
            return controller
        }
        if let controller = viewport {
            if mirroredWorkspace(of: controller) != nil {
                endMirrorViewport(controller)
            } else {
                releaseOccupant(of: controller)
            }
        }
        let configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration = { pane in
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.cwd
            config.vigilAttach = pane.id
            config.vigilHost = device
            config.vigilMirror = true
            config.vigilExplicitClaim = true
            return config
        }
        let firstPane = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
        let view = Ghostty.SurfaceView(app, baseConfig: configFor(tab.panes[firstPane]))
        // A necessary new viewport is born with its real remote surface. An
        // empty tree schedules a blank window before there is anything to mount.
        let controller = viewport ?? TerminalController.newWindow(ghostty, tree: SplitTree(view: view), confirmUndo: false)
        if viewport != nil { swapTree(controller, SplitTree(view: view)) }
        mirrorViewports.setObject(composite as NSString, forKey: controller)
        remoteLayouts[ObjectIdentifier(controller)] = VigilSessionControl.revision([tab])
        materializeSplits(controller, tab: tab, configFor: configFor)
        land(controller, anchor: rawAnchor, fallback: view, takeSize: rawAnchor != nil)
        remoteLog.info("remote viewport opened", ["workspace": composite, "host": VigilRemote.shared.host(device)?.name ?? device, "panes": tab.panes.count])
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        return controller
    }

    /// The mirrors of this viewport die NOW, explicitly (a mirror view
    /// retained past its viewport must never keep a client alive); the
    /// window itself is the caller's business.
    @discardableResult
    func endMirrorViewport(_ controller: TerminalController) -> Bool {
        guard let name = mirroredWorkspace(of: controller) else { return false }
        mirrorViewports.removeObject(forKey: controller)
        remoteLayouts.removeValue(forKey: ObjectIdentifier(controller))
        remoteLandings.removeValue(forKey: ObjectIdentifier(controller))
        remoteDestinations.removeValue(forKey: ObjectIdentifier(controller))
        for view in controller.surfaceTree where view.vigilMirror { view.vigilDestroySurface() }
        if let dock = dockMap.object(forKey: controller) {
            for view in dock.views where view.vigilMirror { view.vigilDestroySurface() }
        }
        viewportLog.info("mirror viewport ended", ["workspace": name])
        return true
    }

    /// The session the panel shows right now, hosted (floating) or
    /// mirrored. Presence, the summon engine and the kill key read this.
    var panelWorkspace: String? { floatingName ?? mirror?.name }

    /// The pane under the eyes in a session's focus window, else its first
    /// leaf; nil when no member window has a surface.
    private func focusedPane(of name: String) -> String? {
        guard let controller = anchorController(of: name) else { return nil }
        return controller.focusedSurface?.vigilAttachId
            ?? controller.surfaceTree.root?.leftmostLeaf().vigilAttachId
    }

    /// Show `pane` in the native quick terminal as a mirror of `home`: the
    /// panel keeps its own configured position, size and animation; the
    /// mirror is only the surface inside it. The daemon has ONE pty size,
    /// so the home follows the panel's grid while the mirror is up; when
    /// the mirror client leaves, vigild re-applies the home's own size
    /// (jiggled, so the TUI repaints). Mirroring the pane already shown
    /// just brings the panel in.
    private func mirror(
        name: String, pane: String, home: Ghostty.SurfaceView,
        quick: QuickTerminalController
    ) {
        if let current = mirror, current.pane == pane {
            quick.animateIn()
            DispatchQueue.main.async { Ghostty.moveFocus(to: current.view) }
            return
        }
        guard let app = ghosttyApp?.app, let registered = registered(pane) else {
            viewportLog.warn("mirror refused: pane not registered", ["workspace": name, "pane": pane])
            return
        }
        if let current = floatingName {
            reclaim(current, from: quick, restoreStash: false)
        } else if mirror != nil {
            endMirror(restoreStash: false)
        } else if !quick.surfaceTree.isEmpty {
            stashedQuickTree = quick.surfaceTree
        }
        var config = resurrectConfig(name: name, pane: registered)
        config.vigilMirror = true
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        mirror = Mirror(name: name, pane: pane, view: view)
        quickTreeSwap = true
        quick.surfaceTree = SplitTree(view: view)
        quickTreeSwap = false
        quick.animateIn()
        DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
        viewportLog.info("mirror floated", ["workspace": name, "pane": pane])
        touchRecent(name)
    }

    /// The mirror leaves the panel: its client is closed explicitly, and the
    /// daemon restores the surviving client's size. `restoreStash: false`
    /// is the panel-replaces-panel path, same contract as reclaim's.
    func endMirror(restoreStash: Bool = true) {
        guard let current = mirror else { return }
        mirror = nil
        if restoreStash, let quick = quickController(create: false) {
            quickTreeSwap = true
            quick.surfaceTree = stashedQuickTree ?? SplitTree()
            quickTreeSwap = false
            stashedQuickTree = nil
        }
        // The client dies HERE, explicitly: the daemon restores the home's
        // size on this EOF, and a mirror view retained past its panel
        // must never keep a second client alive.
        current.view.vigilDestroySurface()
        viewportLog.info("float mirror ended", ["pane": current.pane])
    }

    /// A registered CAPTURED tab of a windowed session materializes as a
    /// silent native tab of its home window (native reattach, splits and
    /// dock included), unselected: the window keeps showing what it
    /// showed. What the panel then mirrors has a home.
    private func materializeCapturedTab(name: String, tabIndex: Int, host: TerminalController) {
        guard let ghostty = ghosttyApp, let app = ghostty.app else { return }
        let tab = workspaces[name]!.tabs[tabIndex]
        guard !tab.panes.isEmpty else { return }
        let configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration = { [self] in
            resurrectConfig(name: name, pane: $0)
        }
        let firstPane = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
        let first = tab.panes[firstPane]
        // Adopt-or-mint: a warm or released view is REUSED, never twinned
        // onto its daemon's socket.
        let adopted = adoptable(first.id)
        if adopted == nil, let existing = liveView(attachId: first.id), placed(existing) {
            viewportLog.error("materialize aborted: pane already displayed elsewhere", ["pane": first.id])
            return
        }
        let view = adopted ?? Ghostty.SurfaceView(app, baseConfig: configFor(first))
        let controller = TerminalController.vigilNewTab(ghostty, parent: host, tree: SplitTree(view: view))
        registerMember(controller, name: name)
        materializeSplits(controller, tab: tab, configFor: configFor)
        materializeDockCapture(controller, tab.dock, configFor: configFor)
        focusLanding(controller)
        viewportLog.info("captured tab materialized silently", ["workspace": name, "tab": tabIndex])
        persist()
    }

    /// Dock-icon reopen with no live window: the most recent session in the
    /// background comes back; with none in the background, the most recent
    /// one still displayed (riding the quick terminal, or in a window that
    /// is hidden or ordered out) comes to the front. A session is born by
    /// ⌘N alone, never by activating the app (every ghost `born(window)`
    /// session came from this path). False only when no workspace exists.
    func reopen() -> Bool {
        let displayed = recent.first { workspaces[$0] != nil }
            ?? workspaces.values.sorted { ($0.order, $0.label) < ($1.order, $1.label) }.first?.name
        guard let name = successor(excluding: "") ?? displayed else { return false }
        lifecycleLog.info("reopened with no live window", ["workspace": name])
        open(name: name)
        return true
    }

    /// Resurrect ONE captured tab straight into the quick terminal: a
    /// background session's captured tab (warm runtimes or not). Views are
    /// native reattaches (living daemons, VT replay); the rest of the
    /// workspace stays in its capture and mounts later as usual. On
    /// reclaim the tab joins the session's held runtimes — background
    /// with one live tab, exactly the shape a look-away leaves. The known
    /// scope cut: the tab's dock stays in its capture while floating (the
    /// quick terminal shows no docks anywhere).
    private func floatCapturedTab(
        name: String, tabIndex: Int,
        landOn pane: String?, quick: QuickTerminalController
    ) {
        guard let app = ghosttyApp?.app else { return }
        let tab = workspaces[name]!.tabs[tabIndex]
        guard !tab.panes.isEmpty else { return }
        let firstIndex = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
        let anchorPane = tab.panes[firstIndex]
        // Adopt-or-mint, like every other cold materialization: the float
        // must never twin a leaked view's socket.
        let anchor = adoptable(anchorPane.id)
            ?? Ghostty.SurfaceView(app, baseConfig: resurrectConfig(name: name, pane: anchorPane))

        if let current = floatingName {
            reclaim(current, from: quick, restoreStash: false)
        } else if mirror != nil {
            endMirror(restoreStash: false)
        } else if !quick.surfaceTree.isEmpty {
            stashedQuickTree = quick.surfaceTree
        }

        viewportLog.info("captured tab floated", ["workspace": name, "tab": tabIndex])
        // The tab's dock resurrects ALIVE-unshown, exactly like a live
        // float's (the quick terminal shows no docks anywhere): reclaim
        // then hands the runtime on, so a later mount shows the tenants
        // without waiting for a full resurrect.
        var floatedDock: VigilDockRuntime?
        if let capture = tab.dock, !capture.panes.isEmpty {
            floatedDock = VigilDockRuntime(
                views: capture.panes.map { pane in
                    adoptable(pane.id)
                        ?? Ghostty.SurfaceView(app, baseConfig: resurrectConfig(name: name, pane: pane))
                },
                active: min(capture.active, capture.panes.count - 1),
                width: CGFloat(capture.width),
                collapsed: capture.collapsed)
        }
        // The warm tabs as they are NOW: adopting the anchor and the dock
        // above took whatever runtime held them out of the cache, and a
        // snapshot from before would keep those surfaces in the float's
        // rest as well as in the panel.
        let rest = workspaces[name]!.held
        workspaces[name]!.float = FloatRuntime(
            rest: rest, dock: floatedDock, index: min(tabIndex, rest.count))
        workspaces[name]!.held = []
        floatingName = name
        quickTreeSwap = true
        quick.surfaceTree = SplitTree(view: anchor)
        quickTreeSwap = false
        quick.animateIn()
        // Same runloop turn as the anchor: the panel's first layout is the
        // whole tab. Outside the swap flag, so the chokepoint records the
        // materialized panes.
        materializeSplits(quick, tab: tab, configFor: {
            self.resurrectConfig(name: name, pane: $0)
        })
        let landing = pane.flatMap { p in quick.surfaceTree.first { $0.vigilAttachId == p } } ?? anchor
        DispatchQueue.main.async { Ghostty.moveFocus(to: landing) }
        touchRecent(name)
        persist()
    }

    // MARK: Shapeshift (the sidebar's click semantic)

    /// The window is a VIEWPORT: clicking a session in the bar swaps what
    /// this window displays, it never spawns a window. Live targets keep
    /// their home (focus it); background targets mount INTO this
    /// window. The current occupant leaves honestly: background, running,
    /// invisible (a session-less stray is minted a real session first).
    func shapeshift(in controller: TerminalController, to targetName: String, anchor: String? = nil) {
        if VigilRemote.split(targetName) != nil {
            mountRemote(controller, composite: targetName, anchor: anchor)
            return
        }
        guard workspaces[targetName] != nil, let ghostty = ghosttyApp else {
            viewportLog.warn("shapeshift refused: unknown workspace", ["workspace": targetName])
            return
        }
        if place(targetName) != .background {
            // Displayed elsewhere: THIS window becomes a second view of it
            // (a mirror viewport), never a jump to its home window. Its
            // own home window clicking itself is a no-op.
            if members(of: targetName).contains(controller) {
                viewportLog.info("shapeshift skipped: workspace lives in this window", ["workspace": targetName, "place": placeTag(targetName)])
                return
            }
            guard controller.window != nil else { open(name: targetName); return }
            mirrorInto(controller, name: targetName, anchor: anchor)
            return
        }
        guard workspaceName(of: controller) != targetName else {
            viewportLog.info("shapeshift skipped: window already shows it", ["workspace": targetName])
            return
        }
        guard controller.window != nil else { open(name: targetName); return }
        viewportLog.info("shapeshift", ["from": workspaceName(of: controller), "workspace": targetName])

        let t0 = Date()
        releaseOccupant(of: controller)
        let tRelease = Date()

        // No manual acknowledge (see open): the mounted panes are stamped
        // seen by the focus sync that follows the mount.
        mount(targetName, into: controller, ghostty: ghostty, anchor: anchor)
        let tMount = Date()
        // No focus theatre: the user is already IN this window; only pull
        // it forward when it is not key (menu/intent entry points).
        if controller.window?.isKeyWindow != true {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        persist()
        // The click's latency receipt, staged: "not snappy" must be a
        // number with a culprit in the log, never a feeling.
        let now = Date()
        viewportLog.info("shapeshift mounted", [
            "workspace": targetName, "total": Duration.seconds(now.timeIntervalSince(t0)),
            "release": Duration.seconds(tRelease.timeIntervalSince(t0)),
            "mount": Duration.seconds(tMount.timeIntervalSince(tRelease)),
            "persist": Duration.seconds(now.timeIntervalSince(tMount)),
        ])
    }

    /// The current occupant leaves the window WITHOUT the window closing:
    /// every tab is captured, sibling tab-windows close (trees emptied),
    /// and this controller's tree is left alone for mount to REPLACE
    /// (an emptied tree closes the window; a replaced one never does).
    /// Rendering follows VISIBILITY, not liveness. Upstream pauses a
    /// surface's renderer via its WINDOW's occlusion notifications - a
    /// surface released to the held cache has no window, so nothing ever
    /// tells it to stop: every held tree would draw at display refresh
    /// forever (a dozen invisible renderers at 120Hz stutter every
    /// scroll). Detach/bury occlude; mount un-occludes (the window's own
    /// notifications take over from there).
    func setOcclusion(_ visible: Bool, _ runtimes: [TabRuntime]) {
        for runtime in runtimes {
            setOcclusion(visible, views: Array(runtime.tree) + (runtime.dock?.views ?? []))
        }
    }

    func setOcclusion(_ visible: Bool, views: [Ghostty.SurfaceView]) {
        for view in views {
            guard let surface = view.surface, view.isWindowVisible != visible else { continue }
            ghostty_surface_set_occlusion(surface, visible)
            view.isWindowVisible = visible
        }
    }

    /// The occupant of a viewport leaves it ALIVE: the session goes
    /// background with its runtimes held (coming back re-embeds these
    /// exact surfaces: native tabs regroup from live trees, no VT replay,
    /// titles intact); this controller's tree is left for mount to
    /// REPLACE.
    private func releaseOccupant(of controller: TerminalController) {
        if endMirrorViewport(controller) { return }
        if let current = workspaceName(of: controller) {
            // Joins the session's warm tabs; never replaces them.
            let vacated = vacate(current, keeping: controller)
            workspaces[current]!.held += vacated
        } else if !controller.surfaceTree.isEmpty {
            // Safety-net stray: mint it a REAL session (alive, listed,
            // killable) instead of silently burying its tree.
            let tree = controller.surfaceTree
            let surface = controller.focusedSurface ?? tree.root?.leftmostLeaf()
            let title = surface?.title.trimmingCharacters(in: .whitespaces) ?? ""
            let cwd = surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            let runtime = TabRuntime(tree: tree, dock: nil)
            var stray = Workspace(
                name: newWorkspaceId(),
                label: title.isEmpty ? (cwd as NSString).lastPathComponent : title,
                cwd: cwd,
                held: [runtime])
            stray.thumbnail = surface?.asImage
            let (panes, layout) = capture(tree, carrying: [])
            stray.tabs = [Registry.Tab(panes: panes, layout: layout)]
            workspaces[stray.name] = stray
            viewportLog.error("session-less window minted as stray", ["workspace": stray.name])
            setOcclusion(false, [runtime])
        }
    }

    /// Mount a background session INTO an existing window as ONE
    /// synchronous tree swap: its first tab REPLACES the window's tree and
    /// every other tab stays where it is, warm in the held cache or
    /// captured (the sidebar lists them and a click mounts them the same
    /// way). No window is ever created or closed here: a shapeshift must
    /// be instant, not a shuffle. The tree lands BEFORE membership:
    /// registerMember reads the controller's tree, and the old occupant's
    /// tree must never be claimed for the newcomer.
    func mount(
        _ name: String,
        into controller: TerminalController,
        ghostty: Ghostty.App,
        anchor: String? = nil
    ) {
        guard let session = workspaces[name] else { return }
        if place(name) != .background {
            // Refusing is correct (the session is displayed elsewhere)
            // but it must SCREAM: a caller that mounts blind leaves this
            // window stray with the old tree still on screen, and the
            // next release mints that tree as a duplicate session sharing
            // the original's panes. Callers route
            // displayed targets to their home window or pick a background
            // session.
            viewportLog.error("mount refused: workspace not mountable", ["workspace": name, "place": placeTag(name)])
            return
        }
        // A held runtime mounts only when it IS the asked-for tab. An
        // anchor in a captured tab mounts that tab directly: falling back
        // to the held one mounted the wrong tab and swapped it out again
        // a beat later (the double-blink, and focus landing elsewhere).
        let heldServes = anchor.map { a in
            session.held.contains { runtime in runtime.tree.contains { $0.vigilAttachId == a } }
        } ?? !session.held.isEmpty
        if heldServes {
            // Registry order, so native regrouping places every tab where
            // the session lists it (the cache itself is in leaving order).
            let held = registryOrdered(session.held, of: session)
            // The ANCHORED tab (else the one on screen most recently: the
            // cache's last) mounts into THIS window instantly; the rest stay
            // warm (sidebar mode) or regroup as native tab-windows behind it
            // (`vigil.tabs native`).
            let wanted = anchor.flatMap { a in session.held.first { runtime in runtime.tree.contains { $0.vigilAttachId == a } } }
                ?? session.held.last!
            let chosenIndex = held.firstIndex { $0.tree.root?.leftmostLeaf() === wanted.tree.root?.leftmostLeaf() }!
            let chosen = held[chosenIndex]
            swapTree(controller, chosen.tree)
            if let dock = chosen.dock { dockMap.setObject(dock, forKey: controller) }
            registerMember(controller, name: name)
            // Wake the MOUNTED tab's renderers (the window's occlusion
            // notifications take over from the next change); the rest
            // regroup as unselected tab windows and stay occluded until
            // AppKit reports them visible.
            setOcclusion(true, [chosen])
            focusLanding(controller, on: anchor)
            let rest = held.enumerated().filter { $0.offset != chosenIndex }
            if !rest.isEmpty, !nativeTabs {
                // Sidebar mode: sibling tabs stay WARM, held with their
                // surfaces running; a row click adopts them into this
                // viewport. No window is created.
                viewportLog.info("mounted, sibling tabs kept warm", ["workspace": name, "warm": rest.count])
            } else if !rest.isEmpty {
                // This window is PRESENTED (it is the live viewport), so
                // the rest attach in ONE next tick - no stagger, no
                // trickle. The 0.3s beat exists only for freshly created
                // windows (launch resurrect). Each tab lands at its
                // REGISTRY position relative to the anchored viewport
                // (before-anchor insert .below it, after-anchor chain
                // .above), so the native bar never rotates anchored-first.
                regroupsInFlight += 1
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    defer { self.regroupsInFlight -= 1; self.syncWindowMarks() }
                    var lastAfter = controller.window
                    for (index, runtime) in rest {
                        let before = index < chosenIndex
                        let tab = TerminalController.vigilNewTab(
                            ghostty, parent: controller, tree: runtime.tree,
                            relativeTo: before ? controller.window : lastAfter,
                            ordered: before ? .below : .above)
                        if !before { lastAfter = tab.window ?? lastAfter }
                        if let dock = runtime.dock { self.dockMap.setObject(dock, forKey: tab) }
                        self.registerMember(tab, name: name)
                        self.focusLanding(tab)
                    }
                    controller.window?.makeKeyAndOrderFront(nil)
                    self.focusLanding(controller, on: anchor)
                    VigilBars.shared.syncAll()
                }
            }
            // Sidebar mode keeps the siblings warm; native mode just gave
            // each its own tab window.
            workspaces[name]!.held = nativeTabs ? [] : rest.map(\.element)
        } else {
            // The asked-for tab is not warm: it mounts from its capture,
            // adopting whatever surfaces of it are alive; the session's
            // other warm tabs stay held.
            ensureHostPanes(name)
            let tabs = workspaces[name]!.tabs
            guard let app = ghostty.app else { return }
            let configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration = { [unowned self] in
                self.resurrectConfig(name: name, pane: $0)
            }
            let usable = tabs.enumerated().filter { !$0.element.panes.isEmpty }
            let chosen = anchor.flatMap { a in
                usable.first { $0.element.paneIds.contains(a) }
            } ?? usable.first
            guard let chosen else { return }
            let first = chosen.element
            let panes = first.panes
            let firstIndex = min(first.layout?.firstLeaf ?? 0, panes.count - 1)
            let view = adoptable(panes[firstIndex].id) ?? Ghostty.SurfaceView(app, baseConfig: configFor(panes[firstIndex]))
            swapTree(controller, SplitTree(view: view))
            registerMember(controller, name: name)
            materializeSplits(controller, tab: first, configFor: configFor)
            materializeDockCapture(controller, first.dock, configFor: configFor)
            focusLanding(controller, on: anchor)
            // Remaining tabs come back as NATIVE tabs, ALL in one next
            // tick (the window is presented; stagger was pure trickle),
            // each at its CAPTURE position relative to the anchored one
            // (newTab's placement is config-dependent; capture order
            // decides here), focus returning to the anchored one once.
            let rest = usable.filter { $0.offset != chosen.offset }
            // Sidebar mode: the un-anchored tabs simply stay asleep in
            // the registry; each materializes on its first row click.
            if !rest.isEmpty, nativeTabs, let parent = controller.window {
                regroupsInFlight += 1
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    defer { self.regroupsInFlight -= 1; self.syncWindowMarks() }
                    var lastAfter = parent
                    for (offset, tab) in rest {
                        // Silent append (vigilNewTab), NOT newTab: its
                        // per-tab presentation makeKeys every joiner in
                        // sequence - the same festival as the held-tab
                        // regroup. Surfaces come from the resurrect
                        // config directly.
                        let firstPane = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
                        guard let view = self.surface(for: tab.panes[firstPane], configFor: configFor) else { continue }
                        let before = offset < chosen.offset
                        let tabController = TerminalController.vigilNewTab(
                            ghostty, parent: controller, tree: SplitTree(view: view),
                            relativeTo: before ? parent : lastAfter,
                            ordered: before ? .below : .above)
                        if !before { lastAfter = tabController.window ?? lastAfter }
                        self.registerMember(tabController, name: name)
                        self.materializeSplits(tabController, tab: tab, configFor: configFor)
                        self.materializeDockCapture(tabController, tab.dock, configFor: configFor)
                        self.focusLanding(tabController)
                    }
                    controller.window?.makeKeyAndOrderFront(nil)
                    self.focusLanding(controller, on: anchor)
                }
            }
        }
    }


    /// Swap WHICH tab of the CURRENT session this window displays: the
    /// mounted tab releases (its daemons keep its exact state), the captured
    /// tab materializes in place. The viewport rule, one level down.
    /// `anchor` is any pane id of the captured tab (indices shift as tabs go
    /// live/cold; pane ids never lie). A tab with ANY pane live in this
    /// session's windows is already showing.
    func shapeshiftTab(name: String, anchor: String, in controller: TerminalController) {
        guard workspaceName(of: controller) == name, let session = workspaces[name] else { return }
        let t0 = Date()
        defer {
            let elapsed = Duration.seconds(Date().timeIntervalSince(t0))
            if elapsed > .milliseconds(25) { viewportLog.info("tab shapeshift slow", ["tab": anchor, "took": elapsed]) }
        }
        let live = liveAttachIds(of: name)
        guard let target = session.tabs.first(where: { $0.paneIds.contains(anchor) }),
              !target.panes.isEmpty else {
            viewportLog.error("tab shapeshift refused: no registered tab", ["workspace": name, "tab": anchor])
            return
        }
        guard Set(target.paneIds).isDisjoint(with: live) else { return } // already showing
        viewportLog.info("tab shapeshift", ["workspace": name, "tab": anchor])

        // The tab leaving the viewport stays WARM: held by its session with
        // its surfaces running, so coming back adopts them instead of
        // reconnecting and replaying every pane (the held-runtime design;
        // dropping them here made every tab click a full rebuild and left
        // the released views for an unknown retainer to leak).
        // It joins the cache only once the mount has replaced it: a refused
        // mount leaves it on screen, and a surface in a window and in the
        // cache at once has two owners.
        let outgoing = TabRuntime(tree: controller.surfaceTree, dock: dockMap.object(forKey: controller))
        outgoing.dock?.unmount()
        dockMap.removeObject(forKey: controller)
        if mountCapturedTab(target, name: name, in: controller, landOn: anchor), !outgoing.tree.isEmpty {
            setOcclusion(false, [outgoing])
            workspaces[name]!.held += [outgoing]
        } else if let dock = outgoing.dock {
            dockMap.setObject(dock, forKey: controller)
        }
        persist()
    }

    /// After ANY tree mount/swap, focus the pane the gesture asked for (a
    /// clicked pane row, a follow target), else the tree's leftmost leaf,
    /// in its own window: `focusedSurface` drives window AND tab titles,
    /// and a nil/stale one leaves ghostty's literal 👻 default in the tab
    /// bar (per-window first responder; background tabs never steal key).
    /// The tree is whole when this runs (materializeSplits builds it in
    /// the mount's turn), so the requested pane is the FIRST focus: a
    /// leftmost-then-correct hop sent every keystroke and paste typed in
    /// between into the pane nobody clicked.
    func focusLanding(_ controller: TerminalController, on paneId: String? = nil) {
        let requested = paneId.flatMap { id in controller.surfaceTree.first { $0.vigilAttachId == id } }
        guard let leaf = requested ?? controller.surfaceTree.root?.leftmostLeaf() else { return }
        DispatchQueue.main.async { Ghostty.moveFocus(to: leaf) }
    }

    /// Replace the window's tree with a registered tab, in place. The old
    /// tree's views release (whoever holds their registry entries keeps
    /// their daemons).
    /// True when the tab now occupies the viewport.
    @discardableResult
    func mountCapturedTab(_ target: Registry.Tab, name: String, in controller: TerminalController, landOn paneId: String? = nil) -> Bool {
        guard !target.panes.isEmpty, let app = ghosttyApp?.app else { return false }
        let configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration = { [unowned self] in
            self.resurrectConfig(name: name, pane: $0)
        }
        let panes = target.panes
        let firstIndex = min(target.layout?.firstLeaf ?? 0, panes.count - 1)
        let first = panes[firstIndex]
        let adopted = adoptable(first.id)
        if adopted == nil, let existing = liveView(attachId: first.id), placed(existing) {
            viewportLog.error("mount aborted: pane already displayed elsewhere", ["pane": first.id])
            return false
        }
        let view = adopted ?? Ghostty.SurfaceView(app, baseConfig: configFor(first))
        swapTree(controller, SplitTree(view: view))
        materializeSplits(controller, tab: target, configFor: configFor)
        materializeDockCapture(controller, target.dock, configFor: configFor)
        focusLanding(controller, on: paneId)
        return true
    }

    // MARK: Viewport ⌘W (the tab closes; the window NEVER does while a session remains)

    /// ⌘W always closes the TAB, never the window. The mounted tab buries (structural edit, undo grace, confirm when a
    /// process runs) and the session's next tab takes the viewport; the
    /// LAST tab is the session's death (Kill/Cancel when something runs,
    /// then the undo grace) and the last active session takes the
    /// viewport. Only with nothing left anywhere does the window truly
    /// close. Window close stays reachable: red button / ⌘⇧W / ⌘M.
    /// Returns false when this controller is not a lone viewport (native
    /// multi-tab windows keep the old semantics).
    func closeViewportTab(_ controller: TerminalController) -> Bool {
        if confirmRemoteClose(in: controller, operation: "close_tab") { return true }
        guard let name = workspaceName(of: controller),
              members(of: name).count <= 1 else { return false }
        let live = liveAttachIds(of: name)
        let captured = workspaces[name]!.tabs.filter { tab in
            !tab.panes.isEmpty && Set(tab.paneIds).isDisjoint(with: live)
        }

        if let next = captured.first {
            let proceed = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.buryMountedTab(thenMount: next, name: name, in: controller)
            }
            confirmClose("Tab", busy: busyPrograms(in: controller), in: controller, proceed)
            return true
        }

        // The LAST tab: the session dies; the viewport moves on.
        graveyardLog.info("last tab closed: workspace killed, viewport moves on", ["workspace": name])
        confirmKill(name: name) { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.kill(name: name, viewport: controller)
        }
        return true
    }

    private func buryMountedTab(thenMount next: Registry.Tab, name: String, in controller: TerminalController) {
        let tree = controller.surfaceTree
        let dock = dockMap.object(forKey: controller)
        dockMap.removeObject(forKey: controller)
        if !tree.isEmpty { buryTab(tree: tree, dock: dock, from: name) }
        mountCapturedTab(next, name: name, in: controller)
        persist()
    }

    /// ⌘W with the keyboard in a DOCK tenant closes that tenant alone
    /// (it is not in the tree; without this the close request no-ops or
    /// escalates). Native confirm when its process runs.
    func closeDockTenantIfHosted(
        _ view: Ghostty.SurfaceView, in controller: TerminalController, withConfirmation: Bool
    ) -> Bool {
        guard let runtime = dockMap.object(forKey: controller),
              let index = runtime.views.firstIndex(where: { $0 === view }) else { return false }
        let busy = withConfirmation ? busyPrograms(panes: [view.vigilAttachId].compactMap { $0 }) : []
        confirmClose("Dock Pane", busy: busy, in: controller) { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.closeDockTenant(controller, index: index)
        }
        return true
    }

    /// Right-click Close Tab from the sidebar: the native flow for
    /// whatever form the tab is in. Live → its window's close-tab (which
    /// carries the viewport semantics and confirms); COLD → buried from
    /// the registry (daemons alive, exhumable), confirming when the tree
    /// files say something runs.
    func closeTabFromSidebar(name: String, anchor: String?, in host: TerminalController?) {
        guard workspaces[name] != nil, let anchor else { return }
        if let view = liveView(attachId: anchor),
           let controller = view.window?.windowController as? TerminalController {
            controller.closeTab(nil)
            return
        }
        guard let tab = workspaces[name]!.tabs.first(where: { $0.paneIds.contains(anchor) }) else { return }
        confirmClose("Tab", busy: busyPrograms(panes: tab.paneIds), in: host) { [weak self] in
            self?.buryColdTab(tab, from: name)
        }
    }

    private func buryColdTab(_ tab: Registry.Tab, from name: String) {
        let ids = tab.paneIds
        guard let index = workspaces[name]?.tabs.firstIndex(where: { $0.paneIds == ids }) else { return }
        workspaces[name]?.tabs.remove(at: index)
        // A warm tab is buried warm: undo brings back the running surfaces,
        // and the reap destroys exactly them.
        buryTab(tab, held: takeWarm(tab, from: name), thumbnail: nil, from: name, at: index)
        persist()
    }

    /// Right-click Close Pane: live panes ride the native close flow
    /// (dock tenants included: a collapsed dock's tenant has a live view
    /// and NO window, so the owner is resolved by RUNTIME, never by
    /// window); captured panes leave the registry for the graveyard. Confirms
    /// exactly when something runs.
    func closePaneFromSidebar(name: String, paneId: String?, in host: TerminalController?) {
        guard let paneId else { return }
        if VigilRemote.split(name) != nil, let host {
            guard mirroredWorkspace(of: host) == name, let remote = VigilRemote.split(paneId),
                  let view = host.surfaceTree.first(where: { $0.vigilAttachId == remote.name }) else {
                remoteCommandError(host, "Open this remote pane in the viewport before closing it.")
                return
            }
            _ = confirmRemoteClose(in: host, view: view, operation: "close_pane")
            return
        }
        if let view = liveView(attachId: paneId) {
            for case let controller as TerminalController in dockMap.keyEnumerator() {
                if closeDockTenantIfHosted(view, in: controller, withConfirmation: true) { return }
            }
            if let controller = view.window?.windowController as? TerminalController {
                controller.closeSurface(view, withConfirmation: true)
                return
            }
            // A held runtime's tenant (background/floating session): the
            // registry edit is the close, the runtime releases the view.
            if locate(paneId) != nil {
                confirmClose("Dock Pane", busy: busyPrograms(panes: [paneId]), in: host) { [weak self] in
                    self?.removeCapturedPane(name: name, paneId: paneId)
                }
                return
            }
            graveyardLog.error("pane close refused: live view held by nothing", ["pane": paneId])
            return
        }
        guard workspaces[name] != nil else { return }
        confirmClose("Pane", busy: busyPrograms(panes: [paneId]), in: host) { [weak self] in
            self?.removeCapturedPane(name: name, paneId: paneId)
        }
    }

    /// A pane that has no window leaves its registry for the graveyard
    /// (takePane releases any held view; the daemon runs until reap).
    private func removeCapturedPane(name: String, paneId: String) {
        guard let taken = takePane(paneId) else { return }
        buryPane(taken.pane, from: name, origin: taken.origin)
        persist()
    }

}
