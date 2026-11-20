import Combine
import Foundation
import Log
import SwiftUI
import TetherKit
import UIKit
import VigilLink
import VigilWire

/// Move To on the phone (PORTABILITY.md "Move to"): the same move every
/// device asks, from a row's long press. The phone hosts nothing, so its
/// list is every Mac but the thing's own, each by name (`Move.targets`,
/// `hosts: false`). The dialog is the shared one (`MoveDialog`): its facts
/// are the destination's own read (`Open.moveSheet`), and its Move button
/// sends the order to the destination, which asks the person in Authz; the
/// dialog then says each stage of the destination's ticket as it is
/// published (`Open.moves`).
extension VigilPhone {
    /// What a row moves: its workspace whole, the tab of its first pane, or
    /// the pane.
    struct MoveSubject {
        let host: Host
        let workspace: String
        let label: String
        let anchor: String
        let part: Registry.Workspace.Part?
    }

    func moveSubject(_ node: Node) -> MoveSubject? {
        guard node.kind != .host, let host = host(of: node), let directory = directories[host.id] else { return nil }
        let parts = node.id.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let whole = directory.live.first(where: { $0.name == parts[1] }) else { return nil }
        switch node.kind {
        case .workspace: return MoveSubject(host: host, workspace: whole.name, label: whole.label, anchor: "", part: nil)
        case .tab:
            guard let anchor = node.anchor else { return nil }
            return MoveSubject(host: host, workspace: whole.name, label: whole.label, anchor: anchor, part: .tab)
        case .pane:
            guard let anchor = node.followPane else { return nil }
            return MoveSubject(host: host, workspace: whole.name, label: whole.label, anchor: anchor, part: .pane)
        case .host: return nil
        }
    }

    /// The Macs a row may move to, as a phone lists them.
    func moveTargets(_ subject: MoveSubject) -> [Move.Target] {
        Move.targets(home: subject.host.id, macs: hosts.map { host in
            Move.Mac(device: host.id, name: host.name, unreachable: reachable(host) ? nil : "out of reach")
        }, hosts: false)
    }

    /// The dialog of moving `subject` to `target`, shown over the tree.
    func move(_ subject: MoveSubject, to target: Move.Target) {
        guard let device = target.device else { return }
        let node: TetherNode
        do { node = try linked() } catch {
            return receipts.warn("move", "not opened", ["workspace": subject.workspace, "to": target.name, "err": error])
        }
        let source = subject.host
        let ask = Move.Ask(from: source.id, workspace: subject.workspace, anchor: subject.anchor, part: subject.part)
        let targetHome = directories[device]?.home
        let sources = MoveDialogModel.Sources(
            question: { [weak self] in self?.moveQuestion(subject, targetHome: targetHome) },
            heard: objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            // The target reads the sheet from what it heard of the source:
            // asked again whenever the source moves as the phone hears it.
            read: { _, _, _ in
                let data = try VigilPhone.blocking { try await VigilLink.call(node, device: device, .moveSheet(ask)) }
                return try JSONDecoder().decode(Move.Answer.self, from: data)
            },
            changes: nil,
            askSource: nil)
        let model = MoveDialogModel(
            workspace: subject.workspace, anchor: subject.anchor, part: subject.part, mac: source.name, target: target.name,
            what: VigilPhone.moving(subject.label, subject.part), home: targetHome ?? "/", sources: sources)
        guard model.open() else {
            return receipts.warn("move", "not listed", ["workspace": subject.workspace, "to": target.name])
        }
        model.close = { [weak self] _ in self?.moving = nil }
        model.submitMove = { [weak self, weak model] revision in
            guard let self, let model else { return }
            let request = WorkspaceCommand.Request.moveTo(
                subject.workspace, from: source.id, asker: Move.Asker(mac: UIDevice.current.name, via: .phone),
                anchor: subject.anchor, part: subject.part, checkoutRevision: revision)
            model.moveID = request.id
            model.moveNotice = "Asking \(target.name)…"
            Task { @MainActor [weak self, weak model] in
                guard let self, let model else { return }
                await self.order(request, to: device, named: target.name, model: model)
            }
        }
        moving = model
    }

    /// The order sent to the destination, then its ticket followed until it
    /// is moved or ends, each stage said on the dialog.
    private func order(_ request: WorkspaceCommand.Request, to device: String, named name: String, model: MoveDialogModel) async {
        let fields: LogFields = ["workspace": request.session, "to": name, "id": request.id.uuidString]
        let node: TetherNode
        do {
            node = try linked()
            let data = try await VigilLink.command(node, device: device, try request.line)
            let outcome = try JSONDecoder().decode(WorkspaceCommand.Outcome.self, from: data)
            guard outcome.ok else {
                receipts.warn("move", "refused", fields.merging(["why": outcome.message]) { a, _ in a })
                model.moveNotice = outcome.message
                return
            }
            receipts.info("move", "asked", fields)
        } catch {
            receipts.error("move", "not asked", fields.merging(["err": error]) { a, _ in a })
            model.moveNotice = "\(name) did not take it: \(VigilLink.reason(error))"
            return
        }
        for await line in VigilLink.movesLines(node, device: device) {
            guard case .line(let raw) = line,
                  let ticket = (try? JSONDecoder().decode([Move.Ticket].self, from: raw))?.first(where: { $0.id == request.id }) else { continue }
            model.moveNotice = ticket.words(destination: name)
            if !ticket.open {
                receipts.info("move", ticket.stage.rawValue, fields.merging(["why": ticket.why ?? ""]) { a, _ in a })
                return
            }
        }
    }

    /// The panes as the source says them, read against the destination's
    /// home, and how the source stands as the phone hears it.
    private func moveQuestion(_ subject: MoveSubject, targetHome: String?)
        -> (question: Move.Question, standing: MoveDialogModel.Standing)? {
        guard let directory = directories[subject.host.id],
              let whole = directory.live.first(where: { $0.name == subject.workspace }),
              let source = subject.part.map({ whole.only($0, of: subject.anchor) }) ?? whole else { return nil }
        var question = Move.Question(panes: directory.moving(source, here: targetHome ?? "/"), commit: false)
        question.progressSource = subject.host.id
        return (question, reachable(subject.host) ? .live : .away(since: "out of reach"))
    }

    static func moving(_ label: String, _ part: Registry.Workspace.Part?) -> String {
        switch part {
        case .tab: "this tab of \(label)"
        case .pane: "this pane of \(label)"
        case nil: label
        }
    }

    /// An async call waited for on the dialog's own read queue (never main).
    nonisolated private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        final class Box: @unchecked Sendable { var result: Result<T, Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// A row's Move To, as every row's menu offers it: one Mac is one item,
/// more are one submenu, each Mac by name.
struct PhoneMoveItems: View {
    let node: VigilPhone.Node
    @EnvironmentObject private var model: VigilPhone

    var body: some View {
        if let subject = model.moveSubject(node) {
            let targets = model.moveTargets(subject)
            switch Move.menu(targets) {
            case .none: EmptyView()
            case .one(let target): item(subject, target, target.action)
            case .submenu(let all):
                Menu {
                    ForEach(all) { target in item(subject, target, target.title) }
                } label: { Label("Move To", systemImage: "arrow.right.to.line") }
            }
        }
    }

    private func item(_ subject: VigilPhone.MoveSubject, _ target: Move.Target, _ title: String) -> some View {
        Button { model.move(subject, to: target) } label: { Label(title, systemImage: "desktopcomputer") }
            .disabled(target.unreachable != nil)
    }
}
