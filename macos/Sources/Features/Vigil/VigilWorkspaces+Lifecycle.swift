import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Lifecycle

    /// Stamp a fresh window's config so it is daemon-backed from birth (a
    /// vigild attach id + VIGIL_WORKSPACE). Returns nil when the config already
    /// carries vigil identity (attach id or VIGIL_WORKSPACE: create,
    /// resurrection and tab paths handled it), so this only augments plain
    /// windows (⌘N, the startup window, dock reopen). Pair with
    /// registerWorkspace once the controller exists.
    func newWindowConfig(
        base: Ghostty.SurfaceConfiguration?
    ) -> (config: Ghostty.SurfaceConfiguration, name: String, cwd: String)? {
        if base?.vigilAttach != nil { return nil }
        if base?.environmentVariables["VIGIL_WORKSPACE"] != nil { return nil }
        let cwd = base?.workingDirectory
            ?? TerminalController.preferredParent?.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let name = newWorkspaceId()
        var config = base ?? Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_WORKSPACE"] = name
        config.vigilAttach = "vigil-\(name)-0"
        return (config, name, cwd)
    }

    /// Register a freshly-created plain window (⌘⇧N, the startup window,
    /// dock reopen) as a session: the window's tree is its first tab.
    func registerWorkspace(controller: TerminalController, name: String, cwd: String) {
        var session = Workspace(name: name, label: name, cwd: cwd)
        session.paneSeq = 1 // index 0 consumed at birth
        workspaces[name] = session
        registerMember(controller, name: name)
        lifecycleLog.info("born from a window", ["workspace": name, "cwd": cwd])
        persist()
    }

    /// Workspace creation is a REGISTRY fact, never a window fact: create
    /// the identity plus one daemon-backed pane. Display is the
    /// viewport's business, entirely orthogonal; the shell/claude lives
    /// in the pane's daemon (not any window's pty).
    func createWorkspace(cwd: String, command: String? = nil) -> String {
        let name = newWorkspaceId()
        var session = Workspace(name: name, label: name, cwd: cwd)
        session.tabs = [Registry.Tab(panes: [Registry.Pane(id: "vigil-\(name)-0", cwd: cwd, command: command)], layout: nil)]
        session.paneSeq = 1 // index 0 consumed at birth
        workspaces[name] = session
        lifecycleLog.info("born", ["workspace": name, "cwd": cwd, "command": command])
        return name
    }

    /// The session API (`vigil new`, AppleScript `new session`): CREATE
    /// means the session exists AND runs — its pane daemon spawns
    /// headless at birth (the shape the whole fleet has after ⌘Q), never
    /// a registry row waiting for a click. No window opens unless asked
    /// (`openWindow`): the session appears in every sidebar and the
    /// viewport under Adrian's hands is never touched. Returns the
    /// minted id.
    @discardableResult
    func apiNewWorkspace(label: String?, cwd: String?, command: String?, openWindow: Bool) -> String {
        let cwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let name = createWorkspace(cwd: cwd, command: command)
        if let label, !label.isEmpty { rename(name: name, label: label, emoji: nil) }
        for pane in workspaces[name]!.tabs.flatMap(\.panes) {
            startDaemon(pane: pane, session: name)
        }
        lifecycleLog.info("born through the api", ["workspace": name, "label": label, "window": openWindow])
        if openWindow { open(name: name) } else { persist() }
        return name
    }

    /// Start a pane's daemon headless (`vigild new <id> [-c cmd]`): the
    /// process half of creation. The app's own environment flows (plus
    /// VIGIL_WORKSPACE), the same contract as the attach backend's spawn;
    /// vigild scrubs agent ancestry itself. Failure screams — a created
    /// session that is not running is the lie this call exists to kill.
    @discardableResult
    func startDaemon(pane: Registry.Pane, session: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.vigildBin)
        // The folder is vigild's to resolve (a missing one falls back to its
        // nearest existing parent), never this process's working directory.
        var args = ["new", pane.id, "--cwd", pane.cwd]
        if let cmd = pane.command {
            if cmd.hasPrefix("direct:") {
                // ghostty's command syntax: `direct:` argv, space-separated.
                args.append("--")
                args += cmd.dropFirst("direct:".count)
                    .split(separator: " ").map(String.init)
            } else {
                args += ["-c", cmd]
            }
        }
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["VIGIL_WORKSPACE"] = session
        proc.environment = env
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                daemonLog.info("daemon up", ["pane": pane.id])
                return true
            } else {
                daemonLog.error("daemon spawn failed", ["pane": pane.id, "status": proc.terminationStatus])
            }
        } catch {
            daemonLog.error("daemon spawn failed", ["pane": pane.id, "err": error])
        }
        return false
    }

    /// New Workspace (⌘N, menu-bar New Workspace, overview `n`): the fresh
    /// session takes the CURRENT viewport (shapeshift; the occupant stays
    /// alive, background — the sidebar-click semantic). A window is created
    /// only when no visible viewport exists: viewport necessity, never a
    /// consequence of session creation.
    func newWorkspace(in controller: TerminalController? = nil, cwd explicitCwd: String? = nil) {
        let viewport: TerminalController? = {
            let c = controller ?? TerminalController.preferredParent
            guard let c, c.window?.isVisible == true else { return nil }
            return c
        }()
        let cwd = explicitCwd
            ?? viewport?.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        if explicitCwd == nil, let viewport, remoteSessionCommand(in: viewport, operation: "new_session") { return }
        let name = createWorkspace(cwd: cwd)
        if let viewport {
            shapeshift(in: viewport, to: name)
        } else {
            open(name: name)
        }
    }

    /// A new tab JOINS its window's session (session scope = the window):
    /// this stamps the config with the parent session's identity and the
    /// next free pane daemon id. Returns nil for configs that already carry
    /// vigil identity (resurrection) or windows with no session.
    func newTabConfig(
        parent: TerminalController,
        base: Ghostty.SurfaceConfiguration?
    ) -> (config: Ghostty.SurfaceConfiguration, name: String)? {
        if base?.vigilAttach != nil { return nil }
        if base?.environmentVariables["VIGIL_WORKSPACE"] != nil { return nil }
        guard let name = workspaceName(of: parent) else { return nil }
        var config = base ?? Ghostty.SurfaceConfiguration()
        if config.workingDirectory == nil {
            config.workingDirectory = parent.focusedSurface?.pwd
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        config.environmentVariables["VIGIL_WORKSPACE"] = name
        config.vigilAttach = "vigil-\(name)-\(nextPaneIndex(name: name))"
        return (config, name)
    }

    /// Splits inside a session are daemon-backed: called by the split path
    /// for EVERY split; passes through untouched unless this controller
    /// belongs to a session. cwd inherits from the split's origin pane so
    /// the daemon shell starts where you were.
    func configForNewSplit(
        in controller: BaseTerminalController,
        from oldView: Ghostty.SurfaceView,
        base: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceConfiguration? {
        guard let terminal = controller as? TerminalController,
              let name = workspaceName(of: terminal) else { return base }
        var config = base ?? Ghostty.SurfaceConfiguration()
        guard config.vigilAttach == nil else { return config }

        config.vigilAttach = "vigil-\(name)-\(nextPaneIndex(name: name))"
        config.environmentVariables["VIGIL_WORKSPACE"] = name
        if config.workingDirectory == nil {
            config.workingDirectory = oldView.pwd
        }
        return config
    }

    /// Mint the next daemon pane index for a session: the persisted
    /// monotonic counter, floored by the owned-id max. NEVER derived from
    /// owned ids alone: an id whose tab left the session (bury, drag-out)
    /// is still a live daemon elsewhere, and re-minting it attaches the
    /// new surface to that daemon's socket - the departed tab replays into
    /// the new pane.
    func nextPaneIndex(name: String) -> Int {
        guard let session = workspaces[name] else { return 0 }
        var maxIndex = 0
        for id in ownedPaneIds(session) {
            if let n = id.split(separator: "-").last.flatMap({ Int($0) }) {
                maxIndex = max(maxIndex, n)
            }
        }
        let minted = max(session.paneSeq, maxIndex + 1)
        workspaces[name]!.paneSeq = minted + 1
        return minted
    }

    /// Detach: every live tab (ptys running) moves from its window to this
    /// manager as a held runtime; the windows close. Our strong reference
    /// keeps every surface alive.
    func detach(name: String) {
        guard workspaces[name] != nil, windowed(name) else { return }
        let vacated = vacate(name, keeping: nil)
        workspaces[name]!.held += vacated
        persist()
    }

    /// Pull every live tab of a windowed session out of its windows, in
    /// REGISTRY order (the native group rotates the anchored tab first;
    /// tab order must never follow it). Sibling windows close; `keeping`'s
    /// tree is left in place for the caller to REPLACE (an emptied tree
    /// closes the window, a replaced one never does). Membership ends
    /// before any tree empties, so the close cascade sees session-less
    /// controllers. Freezes the session's thumbnail and cwd on the way.
    func vacate(_ name: String, keeping viewport: TerminalController?) -> [TabRuntime] {
        let ms = members(of: name)
        let focusController = viewport
            ?? (focusWindow(of: name)?.windowController as? TerminalController)
            ?? ms.first
        if let focusController {
            if let pwd = focusController.focusedSurface?.pwd { workspaces[name]!.cwd = pwd }
            // Freeze the visual: the overview shows what the workspace
            // looked like at the moment it was released. Rate-limited to
            // one capture per 30s per session: windowSnapshot is a render
            // capture worth ~a couple hundred ms, and a release happens on
            // every sidebar session click; the overview's face is
            // ornament, bounded staleness is fine.
            if Date().timeIntervalSince(thumbStamp[name] ?? .distantPast) > 30 {
                // The focused surface's asImage (its Metal layer's own
                // contents), never a windowSnapshot: cacheDisplay is a
                // ~280ms main-thread re-render and this is the CLICK
                // path. The card shows the pane you were in; the whole-
                // window walk stays with the overview's explicit look.
                let thumb =
                    (focusController.focusedSurface ?? focusController.surfaceTree.root?.leftmostLeaf())?.asImage
                if let thumb {
                    workspaces[name]!.thumbnail = thumb
                    persistThumb(name: name, image: thumb)
                    thumbStamp[name] = Date()
                }
            }
        }
        var pool = ms.filter { !$0.surfaceTree.isEmpty }
        var held: [TabRuntime] = []
        for tab in workspaces[name]!.tabs {
            let ids = Set(tab.paneIds)
            guard let index = pool.firstIndex(where: { member in
                member.surfaceTree.contains { $0.vigilAttachId.map(ids.contains) ?? false }
            }) else { continue } // a captured tab lives in the registry alone
            let member = pool.remove(at: index)
            let liveIds = Set(member.surfaceTree.compactMap(\.vigilAttachId))
            let registered = Set(tab.panes.map(\.id))
            guard registered.isSubset(of: liveIds) else {
                // A tree missing some of its tab's panes (its splits were
                // dropped: a layout that did not cover them): held, this
                // runtime would mount verbatim forever with those panes
                // unreachable. Released instead: the tab keeps only its
                // capture and rebuilds whole.
                registryLog.warn("half-live tab released to its capture", ["workspace": name, "panes": registered.sorted(), "live": liveIds.sorted()])
                dockMap.object(forKey: member)?.unmount()
                continue
            }
            held.append(TabRuntime(tree: member.surfaceTree, dock: dockMap.object(forKey: member)))
        }
        for stray in pool {
            registryLog.error("member tree missing from its registry; appended and registered", ["workspace": name, "panes": stray.surfaceTree.compactMap(\.vigilAttachId)])
            // Register the stray's capture too: a pane no registry lists is
            // a daemon collectOrphans kills at the next launch, silently.
            let (strayPanes, strayLayout) = capture(stray.surfaceTree, carrying: [])
            if !strayPanes.isEmpty {
                let tab = Registry.Tab(panes: strayPanes, layout: strayLayout)
                workspaces[name]!.tabs.append(tab)
            }
            held.append(TabRuntime(tree: stray.surfaceTree, dock: dockMap.object(forKey: stray)))
        }
        for runtime in held {
            runtime.dock?.unmount()
            setOcclusion(false, [runtime])
        }
        for member in ms {
            dockMap.removeObject(forKey: member)
            memberships.removeObject(forKey: member)
        }
        for member in ms where member !== viewport { killController(member) }
        return held
    }

    /// The workspace's split shape, pane indices in DFS leaf order (the
    /// same order capturePanes walks).
    static func captureLayout(_ tree: SplitTree<Ghostty.SurfaceView>) -> Registry.Layout? {
        guard let root = tree.root else { return nil }
        var counter = 0
        func walk(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> Registry.Layout {
            switch node {
            case .leaf:
                defer { counter += 1 }
                return .leaf(counter)
            case .split(let split):
                let l = walk(split.left)
                let r = walk(split.right)
                return split.direction == .horizontal
                    ? .h(split.ratio, l, r)
                    : .v(split.ratio, l, r)
            }
        }
        let layout = walk(root)
        if case .leaf = layout { return nil } // single pane: no shape to keep
        return layout
    }

    /// Per-session state directory: VT dumps + frozen thumbnail.
    func dumpsDir(_ name: String) -> URL {
        VigilPaths.dumps.appendingPathComponent(name)
    }

    /// The name to REMEMBER for a live pane: its terminal title, which is
    /// what the program calls itself ("Buscar versión en castellano", not
    /// "adrian"). Ghostty's own default (a bare "👻") and an empty title
    /// are noise, never worth persisting over a real remembered name.
    func capturedTitle(of view: Ghostty.SurfaceView) -> String? {
        Self.name(ofTitle: view.title) ?? view.vigilAttachId.flatMap { capturedTitle(ofPane: $0) }
    }

    /// The name a terminal title gives its pane, nil when it gives none.
    /// Claude prefixes its title with a live STATE marker: a braille
    /// spinner while working, `✳` when idle. That is a status light, not
    /// part of the name: freezing it into stored state would pin a stale
    /// spinner onto a captured pane forever, and a row showing it would
    /// flicker several times a second. Ghostty's default (a bare "👻") and
    /// an empty title name nothing.
    nonisolated static func name(ofTitle raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        while let first = t.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) || first == "✳" || first == "·" {
            t = String(String.UnicodeScalarView(t.unicodeScalars.dropFirst())).trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty || t == "👻" ? nil : t
    }

    /// A pane's remembered name, from its registry entry.
    func capturedTitle(ofPane paneId: String) -> String? {
        registered(paneId)?.title
    }

    func runFireAndForget(_ bin: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Refresh live thumbnails for windowed workspaces (overview open path).
    /// A successful snapshot is also persisted to thumb.png so the card
    /// always has SOMETHING to show, even if a later snapshot fails (a
    /// miniaturized/occluded window, a window mid-layout after re-embed);
    /// on failure we fall back to the last persisted image rather than
    /// blanking the card to "no preview" (the sparse-thumbnail bug).
    func refreshThumbnails() {
        for name in workspaces.keys {
            guard let controller = anchorController(of: name) else { continue }
            if let image = Self.windowSnapshot(controller) {
                workspaces[name]!.thumbnail = image
                persistThumb(name: name, image: image)
            } else if workspaces[name]!.thumbnail == nil {
                workspaces[name]!.thumbnail = NSImage(
                    contentsOfFile: dumpsDir(name).appendingPathComponent("thumb.png").path)
            }
        }
    }

    /// Write a thumbnail to the session's thumb.png (survives relaunch).
    /// The encode and the write leave the main thread: they sat inside
    /// every sidebar click that took a thumbnail (34-81ms of the release).
    private static let thumbQueue = DispatchQueue(label: "vigil.thumbs", qos: .utility)
    private func persistThumb(name: String, image: NSImage) {
        let dir = dumpsDir(name)
        Self.thumbQueue.async {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: dir.appendingPathComponent("thumb.png"), options: .atomic)
        }
    }

    /// The full window content composited (every split), not a single pane.
    /// A full window capture is a ~280ms MAIN-THREAD re-render
    /// (cacheDisplay walks the hierarchy, Metal readback included), and
    /// the cheap alternatives are gone: the window-server
    /// copy (CGWindowListCreateImage) is unavailable in the macOS 26 SDK
    /// and ScreenCaptureKit costs a Screen Recording grant. So this runs
    /// ONLY where the human is deliberately looking (the overview);
    /// the click path (vacate) captures the focused surface's asImage.
    static func windowSnapshot(_ controller: TerminalController) -> NSImage? {
        guard let view = controller.window?.contentView else { return nil }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Open: focus if windowed, re-embed held runtimes if any, else
    /// resurrect from the registry. A background session comes back as
    /// ONE window with all its tabs regrouped (session scope = the
    /// window).
    func open(name: String) {
        guard let session = workspaces[name] else { lifecycleLog.warn("open of an unknown workspace ignored", ["workspace": name]); return }
        guard let ghostty = ghosttyApp else { lifecycleLog.warn("open ignored: no ghostty app", ["workspace": name]); return }
        lifecycleLog.info("open", ["workspace": name, "place": placeTag(name)])

        // No manual acknowledge: presence (ackVisiblePanes at the focus
        // chokepoints) resolves attention once the asking console is
        // actually on screen; a hidden ask survives the visit.
        becomeRegular()

        if session.float != nil {
            quickController(create: false)?.animateIn()
        } else if let window = focusWindow(of: name) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if let first = session.held.last {
            // ONE window, first held tab mounted, the rest kept warm (the
            // sidebar adopts them on click).
            let held = session.held
            lifecycleLog.info("open from held tabs: first mounted, the rest warm", ["workspace": name, "held": held.count])
            let controller = TerminalController.newWindow(ghostty, tree: first.tree, confirmUndo: false)
            registerMember(controller, name: name)
            if let dock = first.dock { dockMap.setObject(dock, forKey: controller) }
            setOcclusion(true, [first])
            workspaces[name]!.held = Array(held.dropLast())
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            resurrect(name: name, ghostty: ghostty)
        }
        touchRecent(name)
        persist()
    }

    /// Every tab needs a host pane to materialize: a session with nothing
    /// registered (every tab emptied by moves and closes) gets one fresh
    /// pane in its cwd, and a dock-only tab (its split panes moved away,
    /// its tenants staying) gets a fresh host pane in front of its dock,
    /// the moment it is shown.
    func ensureHostPanes(_ name: String) {
        var tabs = workspaces[name]!.tabs
        if tabs.isEmpty { tabs = [Registry.Tab(panes: [], layout: nil)] }
        for index in tabs.indices where tabs[index].panes.isEmpty {
            tabs[index].panes = [Registry.Pane(id: "vigil-\(name)-\(nextPaneIndex(name: name))", cwd: workspaces[name]!.cwd)]
            tabs[index].layout = nil
        }
        workspaces[name]!.tabs = tabs
    }

    /// Rebuild the whole workspace from its registry: one window, every
    /// tab regrouped, every pane back in its cwd. Panes reattach natively
    /// (living daemon = living processes, per-pane resume rides the
    /// daemon's own resume pointer); a dead daemon comes back as a fresh
    /// shell.
    private func resurrect(name: String, ghostty: Ghostty.App) {
        ensureHostPanes(name)
        let tabs = workspaces[name]!.tabs

        func configFor(_ pane: Registry.Pane) -> Ghostty.SurfaceConfiguration {
            resurrectConfig(name: name, pane: pane)
        }

        /// Splits and subsequent tabs wait for their window to actually
        /// present (next runloop tick); building against an unpresented
        /// window drops splits and births invisible tabs.
        lifecycleLog.info("resurrected as native tabs", ["workspace": name, "tabs": tabs.count, "panes": tabs.map(\.panes.count)])

        // First tab gets the window; the rest come back as NATIVE tabs
        // behind it (ghostty's regular tab UX, exactly).
        let usable = tabs.filter { !$0.panes.isEmpty }
        guard let first = usable.first else { return }
        let panes = first.panes
        let firstIndex = min(first.layout?.firstLeaf ?? 0, panes.count - 1)
        guard let anchorView = surface(for: panes[firstIndex], configFor: configFor) else { return }
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree(view: anchorView), confirmUndo: false)
        registerMember(controller, name: name)
        materializeSplits(controller, tab: first, configFor: configFor)
        materializeDockCapture(controller, first.dock, configFor: configFor)
        // A FRESH window needs one presentation beat (a tab attached to
        // an unpresented window is born invisible); after it, the rest
        // attach together - one wait, no per-tab trickle. Sidebar mode:
        // the rest simply stay asleep in the registry (this was the
        // "tabs on top at first open" leak once mount was gated —
        // launch restore resurrects through HERE, not mount).
        let rest = Array(usable.dropFirst())
        if !rest.isEmpty, nativeTabs, let parent = controller.window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                var lastAfter = parent
                for tab in rest {
                    let firstPane = min(tab.layout?.firstLeaf ?? 0, tab.panes.count - 1)
                    guard let view = self.surface(for: tab.panes[firstPane], configFor: configFor) else { continue }
                    let tabController = TerminalController.vigilNewTab(
                        ghostty, parent: controller, tree: SplitTree(view: view),
                        relativeTo: lastAfter, ordered: .above)
                    lastAfter = tabController.window ?? lastAfter
                    self.registerMember(tabController, name: name)
                    self.materializeSplits(tabController, tab: tab, configFor: configFor)
                    self.materializeDockCapture(tabController, tab.dock, configFor: configFor)
                    self.focusLanding(tabController)
                }
                controller.window?.makeKeyAndOrderFront(nil)
                self.focusLanding(controller)
            }
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A pane's resurrection config: cwd + session identity + its native
    /// attach id (a live daemon makes the surface a reattach; a dead one
    /// is spawned fresh on first contact).
    func resurrectConfig(name: String, pane: Registry.Pane) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pane.cwd
        config.environmentVariables["VIGIL_WORKSPACE"] = name
        config.vigilAttach = pane.id
        config.command = pane.command
        return config
    }

    /// A captured dock comes back as live tenant surfaces: their daemons
    /// survived (spec files, `vigild restore`), so each SurfaceView is a
    /// native reattach exactly like a split pane's.
    func materializeDockCapture(
        _ controller: TerminalController,
        _ capture: Registry.Dock?,
        configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration
    ) {
        guard let capture, !capture.panes.isEmpty,
              let app = ghosttyApp?.app else { return }
        let views = capture.panes.map { pane in
            // Adopt-or-mint per tenant: a dropped dock runtime can leak
            // its views as live socket clients, and a second mint
            // interleaves the replay into garbage.
            adoptable(pane.id) ?? Ghostty.SurfaceView(app, baseConfig: configFor(pane))
        }
        let runtime = VigilDockRuntime(
            views: views,
            active: min(capture.active, views.count - 1),
            width: CGFloat(capture.width),
            collapsed: capture.collapsed)
        dockMap.setObject(runtime, forKey: controller)
        VigilBars.shared.sync(controller)
    }

    /// Complete one tab's tree in the SAME runloop turn its anchor was
    /// mounted: every pane is adopted or minted, the whole shape is built
    /// as a value with the captured ratios, and the tree is assigned once.
    /// No layout pass ever sees a partial tree, so every pane's first
    /// laid-out size is its final one. Grafting split by split a tick later
    /// laid the anchor out at the full window and each pane out at every
    /// intermediate shape, and each of those sizes reached the pty: a TUI
    /// reflowed its transcript at 153 columns, then at 70, on every mount.
    func materializeSplits(
        _ controller: BaseTerminalController,
        tab: Registry.Tab,
        configFor: (Registry.Pane) -> Ghostty.SurfaceConfiguration
    ) {
        let panes = tab.panes
        guard panes.count > 1 else { return }
        guard let app = ghosttyApp?.app else { viewportLog.error("splits dropped: no ghostty app"); return }
        guard let anchor = controller.surfaceTree.root?.leftmostLeaf() else {
            viewportLog.error("splits dropped: no anchor surface", ["panes": panes.map(\.id)])
            return
        }
        let layout = tab.layout ?? Self.chainLayout(count: panes.count)
        let anchorIndex = layout.firstLeaf
        guard Self.leaves(layout).sorted() == Array(panes.indices) else {
            viewportLog.error("splits dropped: layout does not cover the panes", ["leaves": Self.leaves(layout), "panes": panes.count])
            return
        }
        guard anchor.vigilAttachId == panes[anchorIndex].id else {
            viewportLog.error("splits dropped: anchor is not the layout's first pane", ["anchor": anchor.vigilAttachId, "first": panes[anchorIndex].id])
            return
        }
        func view(_ index: Int) -> Ghostty.SurfaceView {
            if index == anchorIndex { return anchor }
            // A mirror is a second view by definition: it never adopts the
            // pane's own surface (which would then claim size as an owner
            // and outlive the mirror it was taken into).
            let config = configFor(panes[index])
            if !config.vigilMirror, let adopted = adoptable(panes[index].id) { return adopted }
            return Ghostty.SurfaceView(app, baseConfig: config)
        }
        func build(_ node: Registry.Layout) -> SplitTree<Ghostty.SurfaceView>.Node {
            switch node {
            case .leaf(let i):
                return .leaf(view: view(i))
            case .h(let ratio, let l, let r):
                return .split(.init(direction: .horizontal, ratio: ratio, left: build(l), right: build(r)))
            case .v(let ratio, let l, let r):
                return .split(.init(direction: .vertical, ratio: ratio, left: build(l), right: build(r)))
            }
        }
        controller.surfaceTree = SplitTree(root: build(layout), zoomed: nil)
        assertInvariants("materialize")
    }

    static func leaves(_ node: Registry.Layout) -> [Int] {
        switch node {
        case .leaf(let i): return [i]
        case .h(_, let l, let r), .v(_, let l, let r): return leaves(l) + leaves(r)
        }
    }

    /// The shape a tab with panes but no captured layout takes: each pane
    /// split to the right of the previous one.
    static func chainLayout(count: Int, from index: Int = 0) -> Registry.Layout {
        guard index < count - 1 else { return .leaf(index) }
        return .h(0.5, .leaf(index), chainLayout(count: count, from: index + 1))
    }

    // MARK: Close (vigil owns every close; scope decides the meaning)

    /// Closing a session's WINDOW (red button, ⌘⇧W) puts the session away:
    /// it detaches, everything keeps running, no confirm, nothing dies
    /// (the red button and ⌘Q never kill; only ⌘W does). Returns true when
    /// handled (the close must be swallowed by the caller).
    func handleWindowClose(controller: TerminalController) -> Bool {
        guard let name = workspaceName(of: controller) else {
            lifecycleLog.info("window with no workspace closes plain")
            return false
        }
        let empty = members(of: name).allSatisfy { $0.surfaceTree.isEmpty }
        lifecycleLog.info("window close", ["workspace": name, "empty": empty])
        if empty {
            for member in members(of: name) { memberships.removeObject(forKey: member) }
            persist()
            return false
        }
        detach(name: name)
        return true
    }

    /// ⌘W on a SPLIT pane of a session window: confirm with vigil's
    /// process truth (the program holding the tty, never ghostty's
    /// always-running daemon child), then let ghostty remove the node; the
    /// tree-change chokepoint buries the pane. Returns false when the
    /// close needs no confirm (the caller's plain removal proceeds).
    func closePane(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        in controller: TerminalController,
        withConfirmation: Bool
    ) -> Bool {
        if confirmRemoteClose(in: controller, view: node.leftmostLeaf(), operation: "close_pane", confirm: withConfirmation) { return true }
        // A split closed inside a mirror viewport: the mirror client ends
        // here, explicitly, and the split closes plain (nothing buries,
        // the pane lives on in its home).
        if mirroredWorkspace(of: controller) != nil {
            for view in node where view.vigilMirror { view.vigilDestroySurface() }
            return false
        }
        guard withConfirmation, workspaceName(of: controller) != nil else { return false }
        confirmClose("Pane", busy: busyPrograms(panes: node.compactMap(\.vigilAttachId)), in: controller) { [weak controller] in
            controller?.closeSurface(node, withConfirmation: false)
        }
        return true
    }

    /// Confirm-then-kill for surfaces outside the keybind path (sidebar
    /// context menu, overview): same alert, same grace; the viewport the
    /// session showed in moves on to the last active session.
    func killWithConfirm(name: String) {
        guard workspaces[name] != nil else { return }
        confirmKill(name: name) { self.kill(name: name) }
    }

    /// Closing one TAB of a multi-tab session is a structural edit, not a
    /// lifecycle event: the tab leaves the session and becomes its own
    /// buried session (120s grace, ⌘⇧T exhumes it into its own window;
    /// expiry kills its pane daemons). Symmetric with drag-out, which also
    /// makes a tab its own session, just an alive one.
    func closeTabStructurally(_ controller: TerminalController) {
        guard let name = workspaceName(of: controller) else { return }
        let tree = controller.surfaceTree
        let dock = dockMap.object(forKey: controller)
        memberships.removeObject(forKey: controller)
        dockMap.removeObject(forKey: controller)
        swapTree(controller, SplitTree())
        graveyardLog.info("tab closed", ["workspace": name, "panes": tree.compactMap(\.vigilAttachId)])
        guard !tree.isEmpty else { persist(); return }
        buryTab(tree: tree, dock: dock, from: name)
        persist()
    }

    /// A live tab leaves its session for the graveyard: its registry entry
    /// moves into a one-tab burial that HOLDS the runtime (views alive, so
    /// an exhume re-embeds without a VT replay). The tab's dock leaves
    /// with it (the dock is the tab's).
    func buryTab(tree: SplitTree<Ghostty.SurfaceView>, dock: VigilDockRuntime?, from name: String) {
        let ids = Set(tree.compactMap(\.vigilAttachId) + (dock?.views.compactMap(\.vigilAttachId) ?? []))
        var session = workspaces[name]!
        let tab: Registry.Tab
        let index: Int
        if let found = session.tabs.firstIndex(where: { !Set($0.paneIds).isDisjoint(with: ids) }) {
            index = found
            tab = session.tabs.remove(at: found)
        } else {
            graveyardLog.error("buried tab was not in its registry", ["workspace": name, "panes": ids.sorted()])
            let (panes, layout) = capture(tree, carrying: [])
            tab = Registry.Tab(panes: panes, layout: layout, dock: dock.flatMap { captureDock($0, carrying: []) })
            index = session.tabs.count
        }
        workspaces[name] = session
        let surface = tree.root?.leftmostLeaf()
        dock?.unmount()
        buryTab(tab, held: [TabRuntime(tree: tree, dock: dock)], thumbnail: surface?.asImage, from: name, at: index)
    }

    /// One-gesture detach for the front window (⌘⇧U): keep running in the
    /// background, window closes.
    func detachFrontWindow() {
        guard let controller = TerminalController.preferredParent,
              let name = workspaceName(of: controller) else { return }
        detach(name: name)
    }

    // MARK: Drag-out / drag-in (membership follows AppKit's tabGroups)

    /// Make live membership agree with AppKit's tab grouping. Two moves:
    /// a session spanning several tabGroups SPLITS (each stray group mints
    /// a fresh session inheriting the survival class: drag-out); several
    /// workspaces sharing one tabGroup MERGE into the group's first session
    /// (drag-in). Daemons never notice: ownership is reachability, and the
    /// surfaces moved with their tabs.
    func reconcileTabs() {
        guard !reconcilingTabs else { return }
        reconcilingTabs = true
        defer { reconcilingTabs = false }

        // Split: one session, several tabGroups.
        for name in workspaces.keys {
            let session = workspaces[name]!
            let ms = members(of: name)
            guard ms.count > 1 else { continue }
            let groups = Dictionary(grouping: ms) { controller -> ObjectIdentifier in
                if let group = controller.window?.tabGroup { return ObjectIdentifier(group) }
                return ObjectIdentifier(controller)
            }
            guard groups.count > 1 else { continue }
            // The largest group keeps the identity (ties: the group holding
            // the first member, i.e. tab order).
            let keep = groups.max {
                ($0.value.count, $0.value.first === ms.first ? 1 : 0)
                    < ($1.value.count, $1.value.first === ms.first ? 1 : 0)
            }!.key
            for (id, strays) in groups where id != keep {
                createWorkspace(from: strays, inheriting: session)
            }
        }

        // Merge: one tabGroup, several workspaces. Group order decides the
        // absorber: the session of the group's first session tab.
        var byGroup: [ObjectIdentifier: [(window: NSWindow, name: String)]] = [:]
        for controller in TerminalController.all {
            guard let window = controller.window,
                  let name = workspaceName(of: controller),
                  let group = window.tabGroup else { continue }
            byGroup[ObjectIdentifier(group), default: []].append((window, name))
        }
        for (_, entries) in byGroup {
            let ordered = entries.sorted { a, b in
                guard let group = a.window.tabGroup?.windows else { return false }
                return (group.firstIndex(of: a.window) ?? .max) < (group.firstIndex(of: b.window) ?? .max)
            }
            let names = ordered.map(\.name)
            guard let absorber = names.first else { continue }
            for other in Set(names.dropFirst()) where other != absorber {
                absorb(other, into: absorber)
            }
        }
    }

    /// Drag-out: these tabs left their session's window; they become their
    /// own session (registerMember claims their registry entries from the
    /// old one). The ID stays a fresh random handle (identity is NEVER
    /// derived — the adrian-N lesson); lineage lives in the LABEL:
    /// "<parent label> 2", "… 3", renameable.
    func createWorkspace(from controllers: [TerminalController], inheriting old: Workspace) {
        let name = newWorkspaceId()
        let cwd = controllers.first?.focusedSurface?.pwd ?? old.cwd
        var ordinal = 2
        let taken = Set(workspaces.values.map(\.label))
        while taken.contains("\(old.label) \(ordinal)") { ordinal += 1 }
        var session = Workspace(name: name, label: "\(old.label) \(ordinal)", cwd: cwd)
        session.emoji = old.emoji // visual lineage, renameable like the label
        workspaces[name] = session
        for controller in controllers { registerMember(controller, name: name) }
        lifecycleLog.info("minted by a drag-out", ["workspace": name, "label": session.label, "source": old.name, "tabs": controllers.count])
        // No async label refinement here: the lineage label is already
        // meaningful (unlike an id seed), and silently replacing it would
        // erase exactly the breadcrumb the mint just created. Rename wins.
        persist()
    }

    /// Drag-in: a session's tabs joined another session's window; the window
    /// absorbs them, captured tabs included. Attention escalates; nothing dies.
    private func absorb(_ other: String, into absorberName: String) {
        guard workspaces[other] != nil, workspaces[absorberName] != nil else { return }
        for controller in members(of: other) {
            registerMember(controller, name: absorberName)
        }
        let absorbed = workspaces[other]!
        for tab in absorbed.tabs {
            for id in tab.paneIds { chown(id, to: absorberName) }
        }
        workspaces[absorberName]!.tabs += absorbed.tabs
        if absorbed.attention.rawValue > workspaces[absorberName]!.attention.rawValue {
            workspaces[absorberName]!.attention = absorbed.attention
            workspaces[absorberName]!.attentionSince = absorbed.attentionSince
        }
        workspaces[other] = nil
        recent.removeAll { $0 == other }
        try? FileManager.default.removeItem(at: dumpsDir(other))
        lifecycleLog.info("absorbed by a drag-in", ["source": other, "target": absorberName])
        persist()
        onAttentionChange?()
    }

    // MARK: Move (drag: registry re-parenting between workspaces)
    //
    // Moving panes/tabs/workspaces is a REGISTRY operation: a pane's entry
    // leaves one session's tabs and lands in another's. Daemons never
    // notice (the owner mirror is rewritten by chown); live views release
    // first (the daemon holds their exact state) and the target mounts
    // them lazily on click, or splits live when it is on screen.

    /// Take the mounted tab OUT of its window for a move. If the source
    /// still has a tab, the viewport mounts it. If the source is empty, the
    /// controller deliberately stays unclaimed with its moved tree intact;
    /// `settleVacatedController` atomically hands that viewport to the move
    /// target after the target owns the pane. Never an arbitrary session:
    /// one already displayed refuses `mount` and leaves the live tree
    /// sessionless.
    /// Returns the tab's registry entry (dock included).
    private func vacateMountedTab(_ controller: TerminalController, name: String) -> Registry.Tab? {
        let tree = controller.surfaceTree
        guard !tree.isEmpty else { return nil }
        let dock = dockMap.object(forKey: controller)
        dockMap.removeObject(forKey: controller)
        var mountedIds = Set<String>()
        for view in tree { if let id = view.vigilAttachId { mountedIds.insert(id) } }
        for view in dock?.views ?? [] { if let id = view.vigilAttachId { mountedIds.insert(id) } }
        let index = workspaces[name]?.tabs.firstIndex { !Set($0.paneIds).isDisjoint(with: mountedIds) }
        let captured = index.map { workspaces[name]!.tabs.remove(at: $0) }
        dock?.unmount()

        if members(of: name).count > 1 {
            // A native tab window: it just closes.
            memberships.removeObject(forKey: controller)
            killController(controller)
        } else if let next = workspaces[name]?.tabs.first(where: { !$0.panes.isEmpty }) {
            mountCapturedTab(next, name: name, in: controller)
        } else {
            memberships.removeObject(forKey: controller)
        }
        return captured
    }

    /// Finish the empty-source half of a move. The moved tree is still in
    /// `controller`, and the target capture now claims every daemon in it.
    /// A mountable target adopts this exact viewport (no extra window, no
    /// second attach); a target already visible elsewhere keeps its home and
    /// this now-redundant viewport closes empty.
    private func settleVacatedController(
        _ controller: TerminalController,
        movedTo target: String
    ) {
        guard workspaceName(of: controller) == nil,
              !controller.surfaceTree.isEmpty,
              let targetSession = workspaces[target] else { return }

        if place(target) != .background {
            // The target already owns another live viewport. Its capture
            // now owns this pane, so releasing this duplicate viewport is
            // safe.
            killController(controller)
            open(name: target)
            moveLog.info("source viewport closed: target already displayed", ["target": target])
            return
        }
        // The registry is the durable representation of any held tabs.
        // Release them before promoting the moved live tree, otherwise
        // the target would have two runtime owners.
        for runtime in targetSession.held { runtime.dock?.unmount() }
        setOcclusion(false, targetSession.held)
        workspaces[target]!.held = []
        registerMember(controller, name: target)
        setOcclusion(true, views: Array(controller.surfaceTree))
        focusLanding(controller)
        moveLog.info("vacated viewport handed to the target", ["target": target])
    }

    /// A source emptied by moves clears: identity through the tray
    /// (120s, undoable), never a silent delete.
    func clearIfEmpty(_ name: String) {
        guard var session = workspaces[name] else { return }
        session.tabs.removeAll { $0.panes.isEmpty && ($0.dock?.panes.isEmpty ?? true) }
        workspaces[name] = session
        let liveMembers = members(of: name).filter { !$0.surfaceTree.isEmpty }
        guard session.tabs.isEmpty, liveMembers.isEmpty else { return }
        moveLog.info("source emptied by a move; buried", ["workspace": name])
        for member in members(of: name) {
            memberships.removeObject(forKey: member)
            killController(member)
        }
        var buried = workspaces[name]!
        buried.held = []
        buried.float = nil
        workspaces[name] = nil
        recent.removeAll { $0 == name }
        bury(buried)
        onAttentionChange?()
    }

    /// Move a whole TAB (anchored by any of its pane ids) to another
    /// session, where it lands as a captured tab.
    func moveTab(anchor: String, from source: String, to target: String) {
        guard source != target, workspaces[source] != nil, workspaces[target] != nil else {
            moveLog.error("tab move refused: same workspace or unknown here", ["tab": anchor, "source": source, "target": target])
            return
        }
        var moved: Registry.Tab?
        if let view = liveView(attachId: anchor),
           let controller = view.window?.windowController as? TerminalController,
           workspaceName(of: controller) == source {
            moved = vacateMountedTab(controller, name: source)
        } else if let index = workspaces[source]!.tabs.firstIndex(where: { $0.paneIds.contains(anchor) }) {
            moved = workspaces[source]!.tabs.remove(at: index)
        }
        guard let moved else {
            moveLog.error("tab move refused: tab not found", ["tab": anchor, "source": source])
            return
        }
        // A warm tab moves warm: its running surfaces belong to the target now.
        let warm = takeWarm(moved, from: source)
        workspaces[target]!.held += warm
        workspaces[target]!.tabs.append(moved)
        for id in moved.paneIds { chown(id, to: target) }
        if let view = liveView(attachId: anchor),
           let controller = view.window?.windowController as? TerminalController {
            settleVacatedController(controller, movedTo: target)
        }
        moveLog.info("tab moved", ["tab": anchor, "source": source, "target": target])
        clearIfEmpty(source)
        persist()
        assertInvariants("moveTab")
    }

    /// Move ONE pane to another session. A split pane becomes its own
    /// captured tab there; a dock tenant stays a dock tenant (of the target's
    /// first tab, live-appended when the target is mounted).
    func movePane(paneId: String, from source: String, to target: String, isDock: Bool) {
        guard workspaces[source] != nil, workspaces[target] != nil else {
            moveLog.error("pane move refused: workspace unknown here", ["pane": paneId, "source": source, "target": target])
            return
        }
        if source == target {
            isDock ? moveLog.info("dock tenant already in its workspace", ["pane": paneId, "workspace": source])
                : splitOut(paneId: paneId, in: source)
            return
        }
        var vacatedController: TerminalController?
        var vacated: Registry.Tab?

        // A live view leaves its window first (its registry entry follows
        // below, through the one take primitive). Vigil's own tree edit
        // is a swap, never a close.
        if let view = liveView(attachId: paneId),
           let controller = view.window?.windowController as? TerminalController {
            if let runtime = dockMap.object(forKey: controller),
               let index = runtime.views.firstIndex(where: { $0 === view }) {
                let released = runtime.views.remove(at: index)
                released.removeFromSuperview()
                runtime.active = min(runtime.active, max(runtime.views.count - 1, 0))
                if runtime.views.isEmpty { dockMap.removeObject(forKey: controller) }
                VigilBars.shared.sync(controller)
            } else if let node = controller.surfaceTree.root?.node(view: view) {
                if controller.surfaceTree.root == node {
                    // Last pane of the mounted tab: this IS a tab move.
                    vacated = vacateMountedTab(controller, name: source)
                    vacatedController = controller
                } else {
                    swapTree(controller, controller.surfaceTree.removing(node))
                }
            }
        }
        // The registry entry: from the vacated tab (already lifted out of
        // the source), else taken from wherever it lives. An emptied tab's
        // NAME AND FACE travel with its only pane instead of dying with the
        // husk.
        var pane: Registry.Pane?
        var inheritedLabel: String?
        var inheritedEmoji: String?
        if let vacated {
            pane = (vacated.panes + (vacated.dock?.panes ?? [])).first { $0.id == paneId }
            // The tab's captured siblings and its dock tenants stay registered
            // in the source, as a captured tab that keeps the tab's identity;
            // only a tab emptied by this move hands its name to the pane.
            let rest = vacated.panes.filter { $0.id != paneId }
            let restDock = vacated.dock.flatMap { d -> Registry.Dock? in
                let keep = d.panes.filter { $0.id != paneId }
                return keep.isEmpty ? nil
                    : Registry.Dock(panes: keep, active: min(d.active, keep.count - 1), width: d.width, collapsed: d.collapsed)
            }
            if rest.isEmpty, restDock == nil {
                inheritedLabel = vacated.label
                inheritedEmoji = vacated.emoji
            } else {
                workspaces[source]!.tabs.append(Registry.Tab(
                    panes: rest, layout: nil, dock: restDock, label: vacated.label, emoji: vacated.emoji))
            }
        } else if let taken = takePane(paneId) {
            pane = taken.pane
            inheritedLabel = taken.tabLabel
            inheritedEmoji = taken.tabEmoji
        }
        guard let pane else {
            moveLog.error("pane move refused: pane registered nowhere", ["pane": paneId])
            return
        }
        chown(paneId, to: target)

        if isDock {
            // Stays a dock tenant. Mounted target: live append (native
            // reattach); otherwise into the first tab's dock capture.
            if let host = members(of: target).first(where: { !$0.surfaceTree.isEmpty }),
               let app = ghosttyApp?.app {
                let view = adoptable(pane.id) ?? Ghostty.SurfaceView(app, baseConfig: resurrectConfig(name: target, pane: pane))
                let runtime = dockMap.object(forKey: host) ?? {
                    let r = VigilDockRuntime(views: [], active: 0, width: 340, collapsed: false)
                    dockMap.setObject(r, forKey: host)
                    return r
                }()
                runtime.views.append(view)
                runtime.active = runtime.views.count - 1
                VigilBars.shared.sync(host)
                // The registry entry lands in the HOST tab's dock.
                let hostIds = Set(host.surfaceTree.compactMap(\.vigilAttachId))
                let index = workspaces[target]!.tabs.firstIndex { !Set($0.paneIds).isDisjoint(with: hostIds) }
                    ?? {
                        moveLog.error("host tab not in its registry; tenant appended as a new tab", ["workspace": target, "panes": hostIds.sorted()])
                        workspaces[target]!.tabs.append(Registry.Tab(panes: [], layout: nil))
                        return workspaces[target]!.tabs.count - 1
                    }()
                var dock = workspaces[target]!.tabs[index].dock
                    ?? Registry.Dock(panes: [], active: 0, width: Double(runtime.width), collapsed: false)
                dock.panes.append(pane)
                dock.active = dock.panes.count - 1
                workspaces[target]!.tabs[index].dock = dock
            } else {
                if workspaces[target]!.tabs.isEmpty {
                    workspaces[target]!.tabs = [Registry.Tab(panes: [], layout: nil)]
                }
                var dock = workspaces[target]!.tabs[0].dock
                    ?? Registry.Dock(panes: [], active: 0, width: 340, collapsed: false)
                dock.panes.append(pane)
                workspaces[target]!.tabs[0].dock = dock
            }
        } else {
            workspaces[target]!.tabs.append(Registry.Tab(
                panes: [pane], layout: nil,
                label: inheritedLabel, emoji: inheritedEmoji))
        }
        if let vacatedController {
            settleVacatedController(vacatedController, movedTo: target)
        }
        moveLog.info("pane moved", ["pane": paneId, "source": source, "target": target, "dock": isDock])
        clearIfEmpty(source)
        persist()
        assertInvariants("movePane")
    }

    /// Move a pane INTO a specific tab of a session (drop on a tab row):
    /// a mounted target splits live (native reattach); a captured one grows
    /// its capture.
    func movePane(paneId: String, from source: String, intoTabAnchoredBy anchor: String, of target: String) {
        guard workspaces[target] != nil else {
            moveLog.error("pane move into a tab refused: workspace unknown here", ["pane": paneId, "tab": anchor, "target": target])
            return
        }
        if source == target {
            movePaneWithin(target, paneId: paneId, intoTabAnchoredBy: anchor)
            return
        }
        // Lift the pane out exactly as a session-level move does...
        movePane(paneId: paneId, from: source, to: target, isDock: false)
        // ...then fold the fresh single-pane tab into the anchored tab.
        guard var session = workspaces[target] else { return }
        guard let freshIndex = session.tabs.lastIndex(where: {
            $0.panes.count == 1 && $0.panes[0].id == paneId
        }) else { return }
        let fresh = session.tabs.remove(at: freshIndex)
        if liveView(attachId: paneId)?.window != nil {
            // The moved pane became the target's live viewport (its source
            // window was handed over): folding a live pane into a captured tab
            // would list it where it cannot materialize. It stays a tab.
            session.tabs.append(fresh)
            workspaces[target] = session
            persist()
            return
        }
        if let view = liveView(attachId: anchor), view.window != nil,
           let controller = view.window?.windowController as? TerminalController,
           controller.surfaceTree.contains(view),
           let app = ghosttyApp?.app,
           let tabIndex = session.tabs.firstIndex(where: { $0.paneIds.contains(anchor) }) {
            // Live split, right of the anchor. The registry lists the
            // pane in the anchored tab FIRST, so the chokepoint sees a
            // listed pane materialize, never a foreign one to claim.
            session.tabs[tabIndex].panes.append(contentsOf: fresh.panes)
            workspaces[target] = session
            let newView = adoptable(fresh.panes[0].id)
                ?? Ghostty.SurfaceView(app, baseConfig: resurrectConfig(name: target, pane: fresh.panes[0]))
            if let tree = try? controller.surfaceTree.inserting(view: newView, at: view, direction: .right) {
                controller.surfaceTree = tree
            }
        } else if let tabIndex = session.tabs.firstIndex(where: { $0.paneIds.contains(anchor) }) {
            session.tabs[tabIndex].panes.append(contentsOf: fresh.panes)
            session.tabs[tabIndex].layout = nil
            workspaces[target] = session
        } else {
            session.tabs.append(fresh) // anchor gone: stay a new tab
            workspaces[target] = session
        }
        persist()
    }

    // MARK: Moves inside one workspace (registry first, then the views)

    /// A pane into ANOTHER tab of its own workspace. The target tab live in a
    /// window splits right of its anchor there; otherwise the viewport the
    /// pane was in mounts the target tab with the pane in it (you see where
    /// it went), the rest of its old tab staying warm.
    private func movePaneWithin(_ name: String, paneId: String, intoTabAnchoredBy anchor: String) {
        guard let tabs = workspaces[name]?.tabs,
              let from = tabs.firstIndex(where: { $0.panes.contains { $0.id == paneId } }),
              tabs.contains(where: { $0.paneIds.contains(anchor) }) else {
            moveLog.error("pane move into a tab refused: pane or tab not registered there", ["pane": paneId, "tab": anchor, "workspace": name])
            return
        }
        guard !tabs[from].paneIds.contains(anchor) else {
            moveLog.info("pane already in that tab", ["pane": paneId, "tab": anchor, "workspace": name])
            return
        }
        let view = liveView(attachId: paneId)
        let home = view.flatMap(treeHome(of:))
        let anchorView = liveView(attachId: anchor)
        let anchorHome = anchorView.flatMap(treeHome(of:))
        guard let taken = takePane(paneId),
              let into = workspaces[name]!.tabs.firstIndex(where: { $0.paneIds.contains(anchor) }) else {
            moveLog.error("pane move refused: pane could not be taken out", ["pane": paneId, "workspace": name])
            return
        }
        workspaces[name]!.tabs[into].panes.append(taken.pane)

        if let anchorView, let anchorHome, let app = ghosttyApp?.app {
            // The target tab is on screen: lift the view out of its own tree,
            // then split it in right of the anchor.
            if let view, let home, let node = home.surfaceTree.root?.node(view: view) {
                if home.surfaceTree.root == node {
                    memberships.removeObject(forKey: home)
                    killController(home) // a native tab window holding only this pane
                } else {
                    swapTree(home, home.surfaceTree.removing(node))
                }
            }
            let moved = view.flatMap { placed($0) ? nil : $0 } ?? adoptable(paneId)
                ?? Ghostty.SurfaceView(app, baseConfig: resurrectConfig(name: name, pane: taken.pane))
            if let tree = try? anchorHome.surfaceTree.inserting(view: moved, at: anchorView, direction: .right) {
                swapTree(anchorHome, tree)
                focusLanding(anchorHome, on: paneId)
            }
            moveLog.info("pane moved into a tab, split in live", ["pane": paneId, "tab": anchor, "workspace": name])
        } else if let view, let home, let node = home.surfaceTree.root?.node(view: view) {
            // The pane was on screen, its new tab is not: this viewport shows
            // the new tab, the old tab's remaining panes stay warm.
            workspaces[name]!.tabs[into].layout = nil
            let rest = home.surfaceTree.removing(node)
            let outgoing = TabRuntime(tree: rest, dock: dockMap.object(forKey: home))
            outgoing.dock?.unmount()
            dockMap.removeObject(forKey: home)
            if mountCapturedTab(workspaces[name]!.tabs[into], name: name, in: home, landOn: paneId) {
                if !rest.isEmpty {
                    setOcclusion(false, [outgoing])
                    workspaces[name]!.held += [outgoing]
                }
            } else if let dock = outgoing.dock {
                dockMap.setObject(dock, forKey: home)
            }
            moveLog.info("pane moved into a tab the viewport now shows", ["pane": paneId, "tab": anchor, "workspace": name])
        } else {
            // Neither is on screen: the registry is the whole move; the next
            // mount of the tab adopts or mints the pane.
            workspaces[name]!.tabs[into].layout = nil
            moveLog.info("pane moved into a captured tab", ["pane": paneId, "tab": anchor, "workspace": name])
        }
        persist()
        assertInvariants("movePaneWithin")
    }

    /// A pane dropped on its own workspace's row: it leaves its tab and
    /// becomes a tab of its own (the tab it left keeps the rest).
    private func splitOut(paneId: String, in name: String) {
        guard let tab = workspaces[name]?.tabs.first(where: { $0.panes.contains { $0.id == paneId } }) else {
            moveLog.error("split-out refused: not a split pane of the workspace", ["pane": paneId, "workspace": name])
            return
        }
        guard tab.panes.count > 1 else {
            moveLog.info("pane already its own tab", ["pane": paneId, "workspace": name])
            return
        }
        let view = liveView(attachId: paneId)
        let home = view.flatMap(treeHome(of:))
        guard let taken = takePane(paneId) else {
            moveLog.error("pane move refused: pane could not be taken out", ["pane": paneId, "workspace": name])
            return
        }
        workspaces[name]!.tabs.append(Registry.Tab(panes: [taken.pane], layout: nil))
        if let view, let home, let node = home.surfaceTree.root?.node(view: view) {
            swapTree(home, home.surfaceTree.removing(node))
            setOcclusion(false, views: [view])
        }
        moveLog.info("pane split out into its own tab", ["pane": paneId, "workspace": name])
        persist()
        assertInvariants("splitOut")
    }

    /// A tab dropped on a row of its own workspace takes that tab's place
    /// (on the workspace row itself: the first place). Order is the
    /// registry's, so every sidebar and the phone follow.
    func reorderTab(anchor: String, in name: String, onto target: String?) {
        guard var tabs = workspaces[name]?.tabs,
              let from = tabs.firstIndex(where: { $0.paneIds.contains(anchor) }) else {
            moveLog.error("tab reorder refused: tab not registered", ["tab": anchor, "workspace": name])
            return
        }
        let to = target.flatMap { t in tabs.firstIndex { $0.paneIds.contains(t) } } ?? 0
        guard from != to else { return }
        tabs.insert(tabs.remove(at: from), at: to)
        workspaces[name]!.tabs = tabs
        moveLog.info("tab reordered", ["workspace": name, "tab": anchor, "from": from, "to": to])
        persist()
    }

    /// Merge: every tab of `source` becomes a captured tab of `target`; the
    /// source's windows move on (viewport rule) and its emptied identity
    /// clears through the tray.
    func mergeWorkspace(_ source: String, into target: String) {
        guard source != target, workspaces[source] != nil, workspaces[target] != nil else { return }
        let ms = members(of: source)
        let moving = workspaces[source]!.tabs
        workspaces[target]!.tabs.append(contentsOf: moving)
        workspaces[source]!.tabs = []
        for tab in moving {
            for id in tab.paneIds { chown(id, to: target) }
        }
        for member in ms {
            dockMap.object(forKey: member)?.unmount()
            dockMap.removeObject(forKey: member)
            memberships.removeObject(forKey: member)
        }
        // The source's warm tabs are the target's now, still running.
        let warm = workspaces[source]!.held
        workspaces[target]!.held += warm
        if workspaces[target]!.attention.rawValue < workspaces[source]!.attention.rawValue {
            workspaces[target]!.attention = workspaces[source]!.attention
            workspaces[target]!.attentionSince = workspaces[source]!.attentionSince
        }
        var buried = workspaces[source]!
        buried.held = []
        buried.float = nil
        workspaces[source] = nil
        recent.removeAll { $0 == source }
        bury(buried)
        lifecycleLog.info("merged", ["source": source, "target": target, "tabs": workspaces[target]!.tabs.count])
        // The source's windows shapeshift to the merged target (first one)
        // or close (the rest).
        var first = true
        for member in ms {
            if first, let ghostty = ghosttyApp, members(of: target).isEmpty {
                first = false
                mount(target, into: member, ghostty: ghostty)
            } else {
                killController(member)
            }
        }
        persist()
        onAttentionChange?()
        assertInvariants("merge")
    }

    // MARK: Quit

    /// Cmd+Q with workspaces alive: detach every session (everything keeps
    /// running), vanish from the dock. Returns true when the termination
    /// must be cancelled.
    func interceptTermination() -> Bool {
        guard !reallyQuit else { return false }
        // The machine is going down: DIE. prepareForSystemShutdown already
        // froze and persisted the workspace at willPowerOff; anything that
        // cancels here stalls the shutdown (see the observer in init).
        guard !systemPoweringOff else {
            lifecycleLog.info("quit during power-off: terminate now")
            return false
        }
        reconcile()
        // Freeze foreground truth NOW: the detach cascade below closes the
        // windows, and a termination that proceeds to death (vigil-dev
        // pkill, SIGTERM) must record them as OPEN or the next launch
        // restores nothing. Cleared a tick later so service-mode persists go
        // back to live truth.
        var frozen: [String: Bool] = [:]
        for (name, session) in workspaces { frozen[name] = isForeground(session) }
        shutdownForeground = frozen
        lifecycleLog.info("quit intercepted; foreground frozen", ["foreground": frozen.filter(\.value).keys.sorted(), "workspaces": frozen.count])
        defer { DispatchQueue.main.async { self.shutdownForeground = nil } }

        if let name = floatingName, let quick = quickController(create: false) {
            reclaim(name, from: quick)
        }
        endMirror()
        // Every session detaches and keeps running (service mode).
        // Snapshot names first: detach mutates workspaces, which must not
        // happen while iterating it.
        for name in Array(workspaces.keys) where windowed(name) {
            detach(name: name)
        }
        // Nothing to survive: let the app quit for real.
        guard !workspaces.isEmpty else {
            persist()
            return false
        }
        for window in NSApp.windows where window.isVisible {
            window.close()
        }
        // Policy switch deferred a tick: flipping to accessory in the same
        // runloop pass as the window teardown leaves the status item deaf
        // (an AppKit event routing quirk).
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
        return true
    }

    func quitForReal() {
        reallyQuit = true
        // DIE owns its ceremony: freeze foreground truth, persist - for
        // EVERY caller (SIGTERM, the eye menu's explicit Quit). The
        // reallyQuit guard makes interceptTermination skip all
        // bookkeeping, so it must happen here, before terminate.
        prepareForSystemShutdown()
        NSApp.terminate(nil)
    }

    /// System shutdown/restart/logout: the app must DIE (cancelling
    /// termination blocks the shutdown), recording the workspace exactly as
    /// it stands so login rebuilds it: foreground flags frozen while the
    /// windows are still open. Daemons are left for the OS to kill (their
    /// specs survive; `vigild restore` respawns them at login).
    func prepareForSystemShutdown() {
        // Both signals may land (willPowerOff, then the terminate): the
        // first one owns the truth, while the windows still show.
        guard shutdownForeground == nil else { return }
        var frozen: [String: Bool] = [:]
        for (name, session) in workspaces { frozen[name] = isForeground(session) }
        shutdownForeground = frozen
        lifecycleLog.info("shutdown; foreground frozen", ["foreground": frozen.filter(\.value).keys.sorted(), "workspaces": frozen.count])
        persist()
    }

    /// Launch restoration: reopen every session that had a window when the
    /// app last died (crash or shutdown), in overview order. Detached and
    /// Background workspaces stay exactly as they were. Returns true
    /// when anything was restored (the caller then skips the virgin
    /// initial window).
    func restoreForegroundWorkspaces() -> Bool {
        let names = workspaces.values
            .filter { $0.foreground && place($0.name) == .background }
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .map(\.name)
        for name in names {
            workspaces[name]!.foreground = false
            lifecycleLog.info("restored to a window at launch", ["workspace": name])
            open(name: name)
        }
        return !names.isEmpty
    }

    /// Returning from service mode: any opened window brings back the dock
    /// presence.
    func becomeRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

}
