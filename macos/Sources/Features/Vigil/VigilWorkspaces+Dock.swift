import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Dock (the right bar: per-TAB stack of daemon-backed tool panes)

    /// The live dock of a tab, if it has one.
    func dock(for controller: TerminalController) -> VigilDockRuntime? {
        dockMap.object(forKey: controller)
    }

    /// The titlebar toggle: collapse/expand the tab's dock; first use
    /// creates it with one shell tenant in the tab's cwd. Collapse hides
    /// the surface, the daemon keeps running (the detach mechanism).
    func toggleDock(_ controller: TerminalController) {
        if let runtime = dockMap.object(forKey: controller) {
            runtime.collapsed.toggle()
        } else {
            guard addDockTenant(controller) != nil else { return }
        }
        VigilBars.shared.sync(controller)
        persist()
    }

    /// Spawn a new dock tenant: an ordinary daemon-backed pane (own vigild
    /// daemon, VIGIL_WORKSPACE stamped) rooted in the tab's cwd, registered
    /// in the tab's dock the moment it is born.
    @discardableResult
    func addDockTenant(_ controller: TerminalController) -> Ghostty.SurfaceView? {
        guard let name = workspaceName(of: controller),
              let app = controller.ghostty.app else { return nil }
        let cwd = controller.focusedSurface?.pwd
            ?? workspaces[name]?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let id = "vigil-\(name)-\(nextPaneIndex(name: name))"
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.environmentVariables["VIGIL_WORKSPACE"] = name
        config.vigilAttach = id
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let runtime = dockMap.object(forKey: controller) ?? {
            let r = VigilDockRuntime(views: [], active: 0, width: 340, collapsed: false)
            dockMap.setObject(r, forKey: controller)
            return r
        }()
        runtime.views.append(view)
        runtime.active = runtime.views.count - 1
        runtime.collapsed = false
        let tabIds = Set(controller.surfaceTree.compactMap(\.vigilAttachId))
        if let index = workspaces[name]!.tabs.firstIndex(where: { !Set($0.paneIds).isDisjoint(with: tabIds) }) {
            var dock = workspaces[name]!.tabs[index].dock
                ?? Registry.Dock(panes: [], active: 0, width: Double(runtime.width), collapsed: false)
            dock.panes.append(Registry.Pane(id: id, cwd: cwd))
            dock.active = dock.panes.count - 1
            dock.collapsed = false
            workspaces[name]!.tabs[index].dock = dock
        } else {
            dockLog.error("tab not in its registry; tenant unregistered", ["workspace": name, "tab": tabIds, "pane": id])
        }
        VigilBars.shared.sync(controller)
        persist()
        return view
    }

    /// Close one tenant: the view leaves the dock, the pane leaves the
    /// registry for the graveyard (undo keeps it 120s, reap kills it).
    func closeDockTenant(_ controller: TerminalController, index: Int) {
        guard let runtime = dockMap.object(forKey: controller),
              runtime.views.indices.contains(index),
              let name = workspaceName(of: controller) else { return }
        let view = runtime.views.remove(at: index)
        view.removeFromSuperview()
        runtime.active = min(runtime.active, max(runtime.views.count - 1, 0))
        if runtime.views.isEmpty { dockMap.removeObject(forKey: controller) }
        VigilBars.shared.sync(controller)
        if let id = view.vigilAttachId, let taken = takePane(id) {
            buryPane(taken.pane, from: name, origin: taken.origin)
        }
        persist()
    }

    func setDockActive(_ controller: TerminalController, index: Int) {
        guard let runtime = dockMap.object(forKey: controller),
              runtime.views.indices.contains(index) else { return }
        runtime.active = index
        VigilBars.shared.sync(controller)
    }

    func setDockWidth(_ controller: TerminalController, width: CGFloat) {
        guard let runtime = dockMap.object(forKey: controller) else { return }
        runtime.width = min(max(width, 220), 700)
        VigilBars.shared.sync(controller)
    }

}
