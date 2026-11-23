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
        /// Its app stopped reading its facts and said so: nothing it read
        /// before is drawn, and its menu says since when.
        case stopped(Stopped)
        /// Its last document is none this vigil reads (the two Macs run
        /// vigils of different releases): nothing of it is drawn, and nothing
        /// it sent before stands in for it.
        case unreadable

        var snapshot: MachineState.Snapshot? {
            if case .snapshot(let snapshot) = self { snapshot } else { nil }
        }
    }

    /// The document a Mac's app writes in place of a snapshot when its facts
    /// stopped being read: `{"stopped":{"at":…,"why":…}}`, a key no snapshot
    /// has. It stands until that app's next start writes a snapshot again.
    struct Stopped: Codable, Equatable, Sendable {
        /// When the reading stopped.
        var at: Date
        /// Why, in the feed's own words.
        var why: String

        /// "Facts not read since 16:40", with the day when it is not today.
        var words: String {
            "Facts not read since "
                + at.formatted(date: Calendar.current.isDateInToday(at) ? .omitted : .abbreviated, time: .shortened)
        }
    }

    /// A stopped reading's place in the document, beside nothing else.
    private struct Ended: Codable {
        var stopped: Stopped
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
        try encoded(snapshot)
    }

    /// The document that says the reading stopped.
    nonisolated static func document(_ stopped: Stopped) throws -> Data {
        try encoded(Ended(stopped: stopped))
    }

    private nonisolated static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    /// What a document another Mac's app wrote says: a snapshot, or that its
    /// reading stopped. Anything else throws, which a reader holds as
    /// `unreadable`.
    nonisolated static func read(_ document: Data) throws -> Heard {
        let decoder = JSONDecoder()
        if let ended = try? decoder.decode(Ended.self, from: document) { return .stopped(ended.stopped) }
        return .snapshot(try decoder.decode(MachineState.Snapshot.self, from: document))
    }

    /// For the app's life, from its first window's start. The feed is the
    /// Mac's `machined` while one answers and this process otherwise; when
    /// the daemon goes mid-stream the feed reads on here.
    static func publish() {
        guard publishing == nil else { return }
        publishing = Task.detached(priority: .utility) {
            await follow(MachineState.ThisMac().changes())
        }
    }

    /// Each snapshot of `snapshots` written as this Mac's document, until the
    /// stream ends. A stream that ends, by itself or by throwing, is not
    /// followed again and nothing reads in its place: the document is
    /// replaced with one that says the reading stopped and when, so no
    /// viewer draws the last snapshot as this Mac now. The app's next start
    /// is the restart.
    nonisolated static func follow(_ snapshots: AsyncThrowingStream<MachineState.Snapshot, any Error>) async {
        let why: String
        do {
            for try await snapshot in snapshots {
                // A Mac whose power hardware answers nonsense: its row says so,
                // and so does the log, each time the answer changes.
                if let unread = snapshot.power.unread {
                    remoteLog.error("this Mac's power not read", ["why": unread])
                }
                do { try write(document(snapshot)) } catch {
                    remoteLog.error("machine state not written: other devices see what they last had", ["err": error])
                }
            }
            why = "the feed ended"
        } catch {
            why = "\(error)"
        }
        let stopped = Stopped(at: Date(), why: why)
        remoteLog.error("this Mac's facts stopped being read: other devices are told, until this app starts again", ["why": why])
        do { try write(document(stopped)) } catch {
            remoteLog.error(
                "machine state not written: other devices still draw this Mac's last facts as current", ["err": error])
        }
    }

    private nonisolated static func write(_ document: Data) throws {
        try FileManager.default.createDirectory(
            at: VigilPaths.machine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try document.write(to: VigilPaths.machineState, options: .atomic)
    }
}
