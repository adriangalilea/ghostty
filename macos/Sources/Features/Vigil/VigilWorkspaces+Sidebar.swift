import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Sidebar snapshot (the left bar's tree, one immutable read)

    struct SidebarPane: Identifiable, Equatable {
        let id: String            // attach id, or a synthetic id for daemon-less panes
        let paneId: String?       // vigild daemon id when daemon-backed
        /// Remote rows navigate by their full identity but have no local
        /// daemon id: local rename, drag and close paths must stay separate.
        var navigationId: String? { paneId ?? (VigilRemote.split(id) != nil ? id : nil) }
        let title: String         // display: the one naming rule (`Directory.titles`)
        let program: String?      // the argv truth alone; nil = just a shell
        let state: AgentState?
        let isDock: Bool
        var emoji: String?        // the pane's custom face
        /// Declared watch leases (notes) on this pane - the sentry's own
        /// words ("vigía de Carlos: awaiting his TG reply").
        var watchNotes: [String] = []
        /// Underived truth: background processes alive under the pane
        /// beyond its program (tree file argv, shortened).
        var watchProcs: [String] = []
        /// Who looks at it from off its Mac (its daemon's `viewers`).
        var lookers: [Viewer] = []
        /// A phone follows it (the hub's board).
        var followed: Bool = false
        var priority: Registry.Priority = .normal
        /// The agent's conversation (its glance), while one runs there: its
        /// id (Claude's session id, what `c -r` and its logs name) and its
        /// name (what the agent's own UI calls it).
        var conversation: String?
        var conversationName: String?
        /// What its agent runs in the background now (its glance): counted,
        /// with the first running task's title.
        var background: PaneGlance.Background?

        /// The ids we communicate by, each only where it exists: the
        /// pane's daemon id, its conversation's name and id.
        var identifiers: [Identifier] {
            [("Pane ID", paneId ?? VigilRemote.split(id)?.name), ("Conversation Name", conversationName),
             ("Conversation ID", conversation)]
                .compactMap { label, value in value.map { Identifier(label: label, value: $0) } }
        }
    }

    struct Identifier: Hashable {
        let label: String
        let value: String
    }

    struct SidebarTab: Identifiable, Equatable {
        let id: String
        let title: String
        let index: Int
        let panes: [SidebarPane]
        /// Any pane id of this tab: the join key row clicks resolve by
        /// (indices shift as tabs mount and release, pane ids never lie).
        var anchor: String?
        /// Exists as its capture only (lazy shapeshift): daemons run, no
        /// views until a viewport mounts it.
        var captured: Bool = false
        /// The tab's custom face.
        var emoji: String?
        /// You gave this tab a name or a face: it carries information of
        /// its own, so the tree never elides its row.
        var named: Bool = false
    }

    struct SidebarWorkspaceRow: Identifiable, Equatable {
        let id: String            // the session name (the identity)
        let emoji: String?
        let label: String
        let stateTag: String      // Place.rawValue, or "remote"
        let attention: Attention
        /// Distinct descendant states, priority-ordered (blocked first),
        /// idle only when it is the only one: the collapsed row's cluster.
        let states: [AgentState]
        let tabs: [SidebarTab]
        /// A remote host's session (VigilRemote): the header text of the
        /// host group it sits under; nil = this Mac. Row ids of remote
        /// workspaces are `device/name`.
        var host: String?

        /// The ONE tab whose row the tree elides: a lone tab that carries
        /// no information of its own (no name, no face). A lone NAMED tab
        /// earns its row like any tab among many.
        var soleTab: SidebarTab? {
            guard tabs.count == 1, let only = tabs.first, !only.named else { return nil }
            return only
        }
    }

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

    /// Row identity FOLLOWS THE TAB (its anchor pane), never its
    /// position: index-based ids made selection, collapse and rename
    /// UI stick to whatever tab happened to sit at that row after a
    /// reorder (the renamed-tab-was-a-different-terminal bug).
    static func tabRowId(_ session: String, anchor: String?, index: Int = 0) -> String {
        anchor.map { "\(session)-tab-\($0)" } ?? "\(session)-t\(index)"
    }

    /// One immutable projection of everything the left bar shows, READ
    /// FROM THE REGISTRY: every session, wherever displayed → its
    /// tabs → their panes (splits AND dock tenants), each pane named and
    /// decorated from its daemon's facts (program from the tree file,
    /// title from `<pane>.title`) and its continuous AgentState, never from
    /// a live view. Every registered row renders whether or not its view
    /// exists yet: nothing flashes while a tab mounts.
    func sidebarSnapshot() -> [SidebarWorkspaceRow] {
        let leases = watchLeases()

        /// A tab's panes (splits, then the dock) named by the one rule every
        /// surface reads (`Directory.titles`: yours, an agent's conversation
        /// from its glance, then its daemon's published title, what runs
        /// there, ...), from this Mac's files in the directory's own shape,
        /// so the phone reads the very same names.
        func paneRows(_ tab: Registry.Tab) -> [SidebarPane] {
            let members = tab.members
            let known = Dictionary(uniqueKeysWithValues: members.map { ($0.id, paneFacts($0.id)) })
            let names = Directory.titles(of: members, facts: known, home: NSHomeDirectory())
            return members.indices.map {
                paneRow(members[$0], title: names[$0], facts: known[members[$0].id]!, isDock: $0 >= tab.panes.count)
            }
        }

        func paneRow(_ pane: Registry.Pane, title: String, facts: Directory.Facts, isDock: Bool) -> SidebarPane {
            let program = facts.program
            let meaning = facts.meaning
            return SidebarPane(
                id: pane.id,
                paneId: pane.id,
                title: title,
                program: program,
                state: paneDisplayState(pane.id),
                isDock: isDock,
                emoji: pane.emoji,
                watchNotes: leases[pane.id]?.map(\.note) ?? [],
                watchProcs: paneWatchers(pane.id),
                lookers: Viewer.parse(paneFileLines(pane.id, "viewers").joined(separator: "\n")),
                followed: phoneFollows.contains(pane.id),
                priority: pane.priority ?? .normal,
                conversation: meaning?.conversation,
                conversationName: meaning?.title,
                background: meaning?.background)
        }

        var rows: [SidebarWorkspaceRow] = []
        let ordered = workspaces.values.sorted { ($0.order, $0.label) < ($1.order, $1.label) }
        for session in ordered {
            let name = session.name
            // Every live view of this session by pane id: member trees and
            // docks when windowed, held runtimes otherwise.
            var live: [String: Ghostty.SurfaceView] = [:]
            for runtime in runtimes(session) {
                for view in Array(runtime.tree) + (runtime.dock?.views ?? []) {
                    if let id = view.vigilAttachId { live[id] = view }
                }
            }
            var tabs: [SidebarTab] = []
            // A tab's skim label: yours, else WHERE it lives (home as `~`),
            // namesakes numbered: the phone's rule, the phone's strings.
            let tabTitles = Directory.titles(ofTabs: session.tabs, home: NSHomeDirectory())
            for (index, tab) in session.tabs.enumerated() {
                let ids = Set(tab.paneIds)
                guard !ids.isEmpty else { continue }
                let panes = paneRows(tab)
                let anchor = tab.panes.first?.id ?? tab.dock?.panes.first?.id
                let title = tabTitles[index]
                tabs.append(SidebarTab(
                    id: Self.tabRowId(name, anchor: anchor, index: index),
                    title: title,
                    index: index,
                    panes: panes,
                    anchor: anchor,
                    captured: !ids.contains { live[$0] != nil },
                    emoji: tab.emoji,
                    named: tab.label?.isEmpty == false || tab.emoji?.isEmpty == false))
            }
            rows.append(SidebarWorkspaceRow(
                id: name,
                emoji: session.emoji,
                label: session.label,
                stateTag: place(name).rawValue,
                attention: session.attention,
                states: AgentState.cluster(tabs.flatMap(\.panes).compactMap(\.state)),
                tabs: tabs))
        }
        return rows + VigilRemote.shared.sidebarRows()
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
        var landed = false
        for (name, session) in workspaces {
            var tabs = session.tabs
            var hit = false
            for index in tabs.indices {
                for pindex in tabs[index].panes.indices where tabs[index].panes[pindex].id == pane {
                    tabs[index].panes[pindex].priority = priority == .normal ? nil : priority
                    hit = true
                }
                if var dock = tabs[index].dock {
                    for dindex in dock.panes.indices where dock.panes[dindex].id == pane {
                        dock.panes[dindex].priority = priority == .normal ? nil : priority
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
        guard landed else { return sidebarLog.error("priority not stored: nothing owns the pane", ["pane": pane]) }
        sidebarLog.info("priority set", ["pane": pane, "priority": priority.rawValue])
        persist()
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
