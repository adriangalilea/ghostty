import AppKit
import AskKit
import Listen
import MachineStates
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Sidebar snapshot (the left bar's tree, one immutable read)

    /// Where you ARE in one window: its session, mounted tab row, focused
    /// pane. PER WINDOW: a sidebar asks for its own host, never the key
    /// window (every bar would paint the key window's chain, and focusing a
    /// pane in one window would relight the same rows in every other). Its
    /// own channel, read on every key-window and focus
    /// change without the snapshot's throttle: the chain must repaint the
    /// instant a tab is clicked, never a tick later.
    struct ActiveChain: Equatable {
        let session: String
        let tab: String?
        let pane: String?
    }

    func activeChain(in host: TerminalController? = nil) -> ActiveChain? {
        guard let front = host ?? (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? TerminalController,
              let name = workspaceName(of: front) ?? mirroredWorkspace(of: front) else { return nil }
        let ids = Set(front.surfaceTree.compactMap(\.vigilAttachId)
            + (dockMap.object(forKey: front)?.views.compactMap(\.vigilAttachId) ?? []))
        // A remote viewport: the chain's ids are device-namespaced like the
        // remote rows'.
        if let (device, remote) = VigilRemote.shared.session(name) {
            let tab = (remote.tabs ?? []).first { !Set($0.paneIds).isDisjoint(with: ids) }
            let anchor = tab.flatMap { $0.panes.first?.id ?? $0.dock?.panes.first?.id }
            return ActiveChain(
                session: name,
                tab: anchor.map { Self.tabRowId(name, anchor: VigilRemote.compositeId(device, $0)) },
                pane: front.focusedSurface?.vigilAttachId.map { VigilRemote.compositeId(device, $0) })
        }
        guard let session = workspaces[name] else { return nil }
        let tab = session.tabs.first { !Set($0.paneIds).isDisjoint(with: ids) }
        let anchor = tab.flatMap { $0.panes.first?.id ?? $0.dock?.panes.first?.id }
        return ActiveChain(
            session: name,
            tab: anchor.map { Self.tabRowId(name, anchor: $0) },
            pane: front.focusedSurface?.vigilAttachId)
    }

    /// What the left bar's rows are built from, read in one pass on the main
    /// thread, where the registry, the views and the other Macs' directories
    /// live: values only, copied (the registry, the facts revision and each
    /// directory are copy-on-write). The rows are worked out from them off
    /// the main thread (`VigilSidebarSnapshots`, `SidebarBuilder`).
    func sidebarInputs() -> SidebarInputs {
        let sessions = workspaces.values.map { session -> SidebarInputs.Workspace in
            // Every live view of this session by pane id: member trees and
            // docks when windowed, held runtimes otherwise.
            var live = Set<String>()
            for runtime in runtimes(session) {
                for view in Array(runtime.tree) + (runtime.dock?.views ?? []) {
                    if let id = view.vigilAttachId { live.insert(id) }
                }
            }
            return SidebarInputs.Workspace(
                name: session.name, label: session.label, emoji: session.emoji, order: session.order,
                attention: session.attention, place: place(session.name), tabs: session.tabs, live: live)
        }
        let remote = VigilRemote.shared
        return SidebarInputs(
            workspaces: sessions,
            facts: facts,
            phoneFollows: phoneFollows,
            continuations: offlineContinuations(),
            remotes: remote.sidebarInputs(),
            moveRoot: moveRoot,
            moveDestinations: [(name: Self.thisMac, tickets: Array(moveTickets.values))]
                + remote.hosts.map { (name: $0.name, tickets: $0.moves) },
            home: NSHomeDirectory())
    }

    private static let rowBuilder = SidebarBuilder()

    /// The rows, built here from the inputs just read.
    func sidebarSnapshot() -> [SidebarWorkspaceRow] {
        Self.rowBuilder.build(sidebarInputs())
    }

    // MARK: Pin on top

    /// Apply a pin state to a live window (Antinote-style float-on-top +
    /// follow-across-spaces).
    func applyPin(_ window: NSWindow, _ pin: Bool) {
        window.level = pin ? .floating : .normal
        window.collectionBehavior = pin
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed]
    }

    /// Toggle pin for a session-less window (safety net): pure window level.
    func togglePin(_ controller: TerminalController) {
        guard let window = controller.window else { return }
        applyPin(window, !isPinned(controller))
    }

    func isPinned(_ controller: TerminalController) -> Bool {
        controller.window?.level == .floating
    }

    /// Toggle pin for a SESSION by name, whatever its state. The intent is
    /// stored on the session (persisted) so it survives detach/quit/reboot,
    /// and a background session can be pinned before it has a window;
    /// live windows get it applied immediately.
    func togglePinWorkspace(_ name: String) {
        guard workspaces[name] != nil else { return }
        workspaces[name]!.pinned.toggle()
        let pin = workspaces[name]!.pinned
        for member in members(of: name) {
            if let window = member.window { applyPin(window, pin) }
        }
        persist()
    }

    /// First sync of a session window: freeze the default into the
    /// session (no persist; the next persist carries it).
    func stampSidebar(name: String, _ visible: Bool) {
        guard workspaces[name] != nil, workspaces[name]!.sidebar == nil else { return }
        workspaces[name]!.sidebar = visible
    }

    /// The window's sidebar visibility, stored on the session and synced
    /// to every member window of it.
    func setSidebar(name: String, _ visible: Bool) {
        guard workspaces[name] != nil else { return }
        workspaces[name]!.sidebar = visible
        persist()
    }

    /// A pane's priority (nil = normal), stored on the pane (it moves with
    /// it): read by the broker for every request it files from then on and
    /// by the hub's board for how loudly a followed pane rings.
    func setPriority(pane: String, _ priority: Registry.Priority) {
        guard editPane(pane, { $0.priority = priority == .normal ? nil : priority }) else {
            return sidebarLog.error("priority not stored: nothing owns the pane", ["pane": pane])
        }
        sidebarLog.info("priority set", ["pane": pane, "priority": priority.rawValue])
        persist()
    }

    /// Edit a pane where the registry holds it (a tab's split or its dock),
    /// in any workspace. False when nothing owns it.
    @discardableResult
    func editPane(_ pane: String, _ edit: (inout Registry.Pane) -> Void) -> Bool {
        var landed = false
        for (name, session) in workspaces {
            var tabs = session.tabs
            var hit = false
            for index in tabs.indices {
                for pindex in tabs[index].panes.indices where tabs[index].panes[pindex].id == pane {
                    edit(&tabs[index].panes[pindex])
                    hit = true
                }
                if var dock = tabs[index].dock {
                    for dindex in dock.panes.indices where dock.panes[dindex].id == pane {
                        edit(&dock.panes[dindex])
                        hit = true
                    }
                    tabs[index].dock = dock
                }
            }
            // Evaluate fully, THEN assign (the exclusivity rule).
            if hit {
                workspaces[name]?.tabs = tabs
                landed = true
            }
        }
        return landed
    }

    func priority(ofPane pane: String) -> Registry.Priority {
        for session in workspaces.values {
            for tab in session.tabs {
                if let found = tab.members.first(where: { $0.id == pane }) { return found.priority ?? .normal }
            }
        }
        return .normal
    }

    func watchPhoneFollows() {
        let fd = Darwin.open(VigilPaths.agent.path, O_EVTONLY)
        guard fd >= 0 else { return followLog.error("cannot watch the phones' follows", ["path": VigilPaths.agent.path, "errno": errno]) }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .global(qos: .utility))
        let read: @Sendable () -> Void = {
            struct Phone: Decodable { var follows: [String] }
            let phones = (try? Data(contentsOf: VigilPaths.agent.appendingPathComponent("board-status.json")))
                .flatMap { try? JSONDecoder().decode([Phone].self, from: $0) } ?? []
            let follows = Set(phones.flatMap(\.follows))
            DispatchQueue.main.async {
                VigilWorkspaces.shared.phoneFollows = follows
                VigilWorkspaces.shared.phonesRegistered = !phones.isEmpty
            }
        }
        watch.setEventHandler(handler: read)
        watch.setCancelHandler { close(fd) }
        boardWatch = watch
        watch.resume()
        DispatchQueue.global(qos: .utility).async(execute: read)
    }

    /// Follows (or stops) a pane on every phone registered with this Mac's
    /// hub: it rides the top of the phone's agents activity, and the phone
    /// learns it as its own follow. The hub's board is the record; a
    /// blocking local call, off main.
    nonisolated func followOnPhones(pane: String, _ on: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let phones = try Local.Client(socket: VigilPaths.hub).follow(pane: pane, on)
                followLog.info(on ? "followed" : "no longer followed", ["pane": pane, "phones": phones])
            } catch {
                followLog.error(on ? "follow failed" : "unfollow failed", ["pane": pane, "err": error])
            }
        }
    }

    /// The pin state of a session (its stored intent).
    func workspacePinned(_ name: String) -> Bool {
        workspaces[name]?.pinned ?? false
    }

    /// Pin/unpin the front window (menu + keybind entry point).
    func togglePinFront() {
        guard let controller = TerminalController.preferredParent else { return }
        if let name = workspaceName(of: controller) {
            togglePinWorkspace(name)
        } else {
            togglePin(controller)
        }
        // Refresh the titlebar mark so the float icon reflects the new state
        // now, not on the next focus change.
        syncWindowMarks()
    }

}
