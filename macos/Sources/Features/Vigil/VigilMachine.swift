import Foundation
import MachineStates
import VigilWire

/// This Mac's facts, for the other devices: a `MachineState.Snapshot` from
/// swift-utils' `MachineStates` each time the system says power, the disk, the
/// heat or memory's pressure changed, replaced whole at
/// `VigilPaths.machineState` (tmp + rename, so the hub's folder watch hears
/// every document and never half of one). The hub serves that file to whoever
/// follows this Mac (`Open.machine`); this app is its one writer, and this
/// type owns the document's JSON both ways.
@MainActor
enum VigilMachine {
    /// What this app holds of another Mac's facts.
    enum Heard: Equatable, Sendable {
        case snapshot(MachineState.Snapshot)
        /// Its last document is not a snapshot this vigil reads (the two Macs
        /// run vigils of different releases): nothing of it is drawn, and
        /// nothing it sent before stands in for it.
        case unreadable

        var snapshot: MachineState.Snapshot? {
            if case .snapshot(let snapshot) = self { snapshot } else { nil }
        }
    }

    /// What a Mac's menu says when its facts are `unreadable`.
    nonisolated static let unavailable = "Facts unavailable: this vigil and that Mac's are different releases"

    /// A Mac's menu lines: everything its power read, then its disk and its
    /// heat in a line each (nominal heat says nothing). Memory, processors and
    /// graphics are left out: a snapshot is written when the system posts a
    /// change, so between changes those three are as they stood then, and a
    /// menu would say them as now.
    nonisolated static func lines(_ snapshot: MachineState.Snapshot) -> [String] {
        var lines = snapshot.lines(of: .power).map { "\($0.label): \($0.value)" }
        if let disk = snapshot.disk { lines.append("Disk: \(disk.summary) (\(disk.name))") }
        if snapshot.heat != .nominal, let heat = snapshot.reading(of: .heat) {
            lines.append("\(heat.title): \(heat.summary)")
        }
        return lines
    }

    private static var publishing: Task<Void, Never>?

    /// The document a snapshot travels as: one line of JSON (the hub refuses
    /// a document holding a newline).
    nonisolated static func document(_ snapshot: MachineState.Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(snapshot)
    }

    /// The snapshot in a document another Mac's app wrote.
    nonisolated static func read(_ document: Data) throws -> MachineState.Snapshot {
        try JSONDecoder().decode(MachineState.Snapshot.self, from: document)
    }

    /// For the app's life, from its first window's start. The feed is the
    /// Mac's `machined` while one answers and this process otherwise; when
    /// the daemon goes mid-stream the feed reads on here, so the stream ends
    /// only when the feed itself gives up, which is said.
    static func publish() {
        guard publishing == nil else { return }
        publishing = Task.detached(priority: .utility) {
            do {
                for try await snapshot in MachineState.ThisMac().changes() {
                    // A Mac whose power hardware answers nonsense: its row says so,
                    // and so does the log, each time the answer changes.
                    if let unread = snapshot.power.unread {
                        remoteLog.error("this Mac's power not read", ["why": unread])
                    }
                    do {
                        try FileManager.default.createDirectory(
                            at: VigilPaths.machine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try document(snapshot).write(to: VigilPaths.machineState, options: .atomic)
                    } catch {
                        remoteLog.error("machine state not written: other devices see what they last had", ["err": error])
                    }
                }
                remoteLog.error("this Mac's facts ended: other devices see what they last had")
            } catch {
                remoteLog.error("this Mac's facts lost: other devices see what they last had", ["err": error])
            }
        }
    }
}
