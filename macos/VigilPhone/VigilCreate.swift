import AuthzGlance
import Ink
import SwiftUI
import VigilLink
import VigilWire

/// Creating from the phone: a workspace on a Mac (the shared sheet,
/// `NewWorkspaceSheet`: its folder, its program or a conversation it
/// resumes, its label), a tab or a split beside a pane. Every creation is a
/// `WorkspaceCommand` to the pane's home Mac (`VigilPhone.create`), and the
/// new pane opens full screen with the keyboard up, at the phone's size.
///
/// Where it is offered, the Mac always obvious or chosen, never assumed:
///  - the home's `+`: the sheet, its Mac chosen there (preset only when one
///    Mac alone can take it),
///  - each Mac's row (its own `+`): a shell or a Claude in its home folder,
///    or the sheet for that Mac,
///  - a workspace's or tab's long press (a tab in it, or a workspace in its
///    folder), a pane's (a tab or split beside it, the same workspace),
///  - the pane screen's stack menu (the same, beside the pane you are in).

/// The items that create beside a pane (a tab, a split) or in its folder
/// (a workspace): one list for a tree row's long press and the pane
/// screen's menu. `landed` opens the new pane.
struct CreateItems: View {
    let host: VigilPhone.Host
    /// The pane a tab or split stands beside (nil: a dock tenant, which
    /// anchors neither; only a workspace is offered).
    let anchor: String?
    /// Offer splitting the anchor (a pane's own row or screen; a workspace
    /// or tab row offers a new tab only).
    let splits: Bool
    /// The anchor's agent holds a conversation (its glance names one): a
    /// fork of it is offered, on the pane's own row or screen.
    var forks = false
    /// The folder a new workspace starts in.
    let folder: String?
    let landed: @MainActor (PaneRef) -> Void
    @EnvironmentObject private var model: VigilPhone

    var body: some View {
        if let anchor, forks {
            // The same state under a new id, in a pane of its own; this
            // one goes on.
            Button { model.begin(.fork(of: anchor, direction: nil), on: host, landed: landed) } label: {
                Label("Fork in new tab", systemImage: "arrow.branch")
            }
            if splits {
                Button { model.begin(.fork(of: anchor, direction: "right"), on: host, landed: landed) } label: {
                    Label("Fork beside", systemImage: "arrow.branch")
                }
            }
        }
        if let anchor {
            Button { model.begin(.tab(beside: anchor, command: nil), on: host, landed: landed) } label: {
                Label("New tab", systemImage: "plus.rectangle.on.rectangle")
            }
            ForEach(Create.presets, id: \.command) { preset in
                Button { model.begin(.tab(beside: anchor, command: preset.command), on: host, landed: landed) } label: {
                    Label("New \(preset.name) tab", systemImage: "sparkle")
                }
            }
            if splits {
                Button { model.begin(.split(beside: anchor, direction: "right", command: nil), on: host, landed: landed) } label: {
                    Label("Split right", systemImage: "rectangle.split.2x1")
                }
                Button { model.begin(.split(beside: anchor, direction: "down", command: nil), on: host, landed: landed) } label: {
                    Label("Split down", systemImage: "rectangle.split.1x2")
                }
            }
        }
        Button { model.composing = .init(host: host, folder: folder) } label: {
            Label("New workspace in this folder…", systemImage: "macwindow.badge.plus")
        }
    }
}

/// A Mac's quick creations, offered on its own row (the Mac is the row's):
/// a new workspace running a shell or a Claude in its home folder, now, and
/// the sheet for another folder, program or conversation.
struct QuickCreateItems: View {
    let host: VigilPhone.Host
    @EnvironmentObject private var model: VigilPhone

    var body: some View {
        Section("New workspace on \(host.name)") {
            Button { open(nil) } label: {
                Label("Shell in Home", systemImage: "terminal")
            }
            ForEach(Create.presets, id: \.command) { preset in
                Button { open(preset.command) } label: {
                    Label("\(preset.name) in Home", systemImage: "sparkle")
                }
            }
            Button { model.composing = .init(host: host, folder: nil) } label: {
                Label("Choose folder, program or conversation…", systemImage: "folder")
            }
        }
    }

    /// A workspace in the Mac's home folder, opened as soon as it runs.
    private func open(_ command: String?) {
        model.begin(.workspace(cwd: "~", command: command, label: nil), on: host) { ref in
            model.typeInto = ref
            model.opening = ref
        }
    }
}

/// The phone's facts for the shared sheet: each paired Mac, its folders
/// and programs from its directory, its conversations from its engine.
extension VigilPhone: CreationModel {
    var creationMacs: [CreationMac] { hosts.map { CreationMac(id: $0.id, name: $0.name, reachable: reachable($0)) } }
    func recentFolders(onMac id: String) -> [String] { hosts.first { $0.id == id }.map(recentFolders(on:)) ?? [] }
    func knownCommands(onMac id: String) -> [String] { hosts.first { $0.id == id }.map(knownCommands(on:)) ?? [] }
    var creationBusy: Bool { creating != nil }
    var creationProblem: String? {
        get { failure?.message }
        set { failure = newValue.map { .init(title: "Not created", message: $0) } }
    }

    func create(_ plan: CreationPlan, onMac id: String, done: @escaping @MainActor () -> Void) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        let birth: Birth = switch plan {
        case .run(let cwd, let command, let label): .workspace(cwd: cwd, command: command, label: label)
        case .resume(let ref, let folder, let label): .resume(ref, folder: folder, label: label)
        }
        begin(birth, on: host) { [weak self] ref in
            done()
            self?.typeInto = ref
            self?.opening = ref
        }
    }

    func conversations(onMac id: String) async throws -> [ConversationRow] {
        let data = try await VigilLink.call(linked(), device: id, .conversation(.init(op: .list, filter: .init(limit: 200))))
        return try JSONDecoder().decode(ConversationAnswer<[ConversationRow]>.self, from: data).value
    }

    func startCheck(_ ask: StartCheck.Ask, onMac id: String) async throws -> StartCheck.Answer {
        let data = try await VigilLink.call(linked(), device: id, .startCheck(ask))
        return try JSONDecoder().decode(StartCheck.Answer.self, from: data)
    }

    func move(_ card: ConversationRow, running holding: Holding, toMac id: String) {
        guard let pane = holding.pane, let source = hosts.first(where: { $0.name == holding.mac }),
              let target = hosts.first(where: { $0.id == id }), let directory = directories[source.id],
              let place = directory.place(of: pane) else {
            failure = .init(title: "Not moved", message: "Its pane on \(holding.mac) is not listed here, so it cannot be moved from this phone.")
            return
        }
        composing = nil
        let subject = MoveSubject(host: source, workspace: place.workspace.name, label: place.workspace.label, anchor: pane, part: .pane)
        move(subject, to: Move.Target(device: target.id, name: target.name, unreachable: reachable(target) ? nil : "out of reach"))
    }
}
