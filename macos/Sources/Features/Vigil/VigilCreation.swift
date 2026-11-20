import AppKit
import SwiftUI
import VigilWire

/// The Mac's facts for the shared creation sheet (`NewWorkspaceSheet`):
/// this Mac and every paired Mac, their folders and programs from their
/// directories, their conversations from their engines. A creation goes to
/// its Mac as the sidebar's own does: this Mac's applied here, another's
/// asked of its home.
@MainActor
final class VigilCreation: ObservableObject, CreationModel {
    static let shared = VigilCreation()

    @Published private(set) var creationBusy = false
    @Published var creationProblem: String?
    private var panel: NSPanel?

    /// The id a creation on this Mac goes to (no device).
    static let here = ""

    var creationMacs: [CreationMac] {
        [CreationMac(id: Self.here, name: "This Mac", reachable: true)]
            + VigilRemote.shared.hosts.map { CreationMac(id: $0.device, name: $0.name, reachable: $0.error == nil) }
    }

    private func directory(_ id: String) -> Directory? {
        id == Self.here ? nil : VigilRemote.shared.host(id)?.directory
    }

    func recentFolders(onMac id: String) -> [String] {
        // Typed in parts: as one expression it outlasts the type checker.
        let panes: [(String, Double)]
        if id == Self.here {
            let members: [Registry.Pane] = VigilWorkspaces.shared.workspaces.values.flatMap { $0.tabs.flatMap(\.members) }
            panes = members.map { ($0.cwd, 0) }
        } else if let dir = directory(id) {
            let members: [Registry.Pane] = dir.live.flatMap { ($0.tabs ?? []).flatMap(\.members) }
            panes = members.map { pane -> (String, Double) in (pane.cwd, dir.panes[pane.id]?.since ?? 0) }
        } else {
            panes = []
        }
        var latest: [String: Double] = [:]
        for (folder, at) in panes { latest[folder] = max(latest[folder] ?? 0, at) }
        return latest.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    func knownCommands(onMac id: String) -> [String] {
        let commands: [String] = id == Self.here
            ? VigilWorkspaces.shared.workspaces.values.flatMap { $0.tabs.flatMap(\.members) }.compactMap(\.command)
            : (directory(id).map { $0.live.flatMap { ($0.tabs ?? []).flatMap(\.members) }.compactMap(\.command) } ?? [])
        let counts = commands.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    func create(_ plan: CreationPlan, onMac id: String, done: @escaping @MainActor () -> Void) {
        let request = plan.request
        creationBusy = true
        Task { @MainActor in
            defer { creationBusy = false }
            let reply: VigilSessionControl.Reply
            if id == Self.here {
                reply = await VigilWorkspaces.shared.applySessionCommand(request, fromThisApp: true)
            } else {
                do { reply = try await VigilRemote.shared.command(id, request: request) } catch {
                    creationProblem = "\(VigilRemote.shared.host(id)?.name ?? "That Mac") did not answer (\(error)). It may have been made: look at its rows before trying again."
                    return
                }
            }
            guard reply.ok else { creationProblem = reply.message; return }
            sidebarLog.info("created from the sheet", ["mac": id.isEmpty ? "here" : id, "session": reply.session ?? "", "pane": reply.pane ?? ""])
            done()
        }
    }

    func conversations(onMac id: String) async throws -> [ConversationRow] {
        let ask = ConversationAsk(op: .list, filter: .init(limit: 200))
        let here = id == Self.here
        let data = try await Task.detached(priority: .userInitiated) {
            let hub = Local.Client(socket: VigilPaths.hub)
            return here ? try hub.conversation(ask) : try hub.call(device: id, .conversation(ask))
        }.value
        return try JSONDecoder().decode(ConversationAnswer<[ConversationRow]>.self, from: data).value
    }

    func startCheck(_ ask: StartCheck.Ask, onMac id: String) async throws -> StartCheck.Answer {
        let here = id == Self.here
        let data = try await Task.detached(priority: .userInitiated) {
            let hub = Local.Client(socket: VigilPaths.hub)
            return here ? try hub.here(.startCheck(ask)) : try hub.call(device: id, .startCheck(ask))
        }.value
        return try JSONDecoder().decode(StartCheck.Answer.self, from: data)
    }

    func move(_ card: ConversationRow, running holding: Holding, toMac id: String) {
        guard let pane = holding.pane else {
            creationProblem = "It runs \(holding.how.words) on \(holding.mac), in no pane: it cannot be moved from here."
            return
        }
        let manager = VigilWorkspaces.shared
        let source = VigilRemote.shared.hosts.first { $0.name == holding.mac }
        let workspace = source.flatMap { $0.directory?.place(of: pane)?.workspace.name } ?? manager.locate(pane)?.owner
        guard let workspace else {
            creationProblem = "Its pane on \(holding.mac) is not listed here."
            return
        }
        dismiss()
        let target = Move.Target(device: id == Self.here ? nil : id, name: id == Self.here ? "This Mac" : VigilRemote.shared.host(id)?.name ?? id)
        manager.moveWithSheet(VigilWorkspaces.RowHome(device: source?.device, workspace: workspace), to: target, anchor: pane, part: .pane)
    }

    /// The sheet, over the key window (a window of its own with none).
    func present(on mac: String? = nil, folder: String? = nil) {
        dismiss()
        creationProblem = nil
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = NSHostingController(rootView:
            NewWorkspaceSheet(model: self, startMac: mac ?? Self.here, startFolder: folder) { [weak self] in self?.dismiss() }
                .frame(width: 520, height: 620))
        self.panel = panel
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow { parent.beginSheet(panel) } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func dismiss() {
        guard let panel else { return }
        self.panel = nil
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
    }
}
