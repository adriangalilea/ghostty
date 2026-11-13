import Foundation
import MachineStates
import VigilWire

/// This Mac's power, disk and heat, for the other devices: read by
/// swift-utils' `MachineStates` as the system posts each change, and replaced
/// whole at `VigilPaths.machineState` (tmp + rename, so the hub's folder watch
/// hears every document and never half of one). The hub serves that file to
/// whoever follows this Mac (`Open.machine`); this app is its one writer.
@MainActor
enum VigilMachine {
    private static var publishing: Task<Void, Never>?

    /// For the app's life, from its first window's start.
    static func publish() {
        guard publishing == nil else { return }
        publishing = Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for await state in MachineState.changes() {
                // A Mac whose power hardware answers nonsense: its row says so,
                // and so does the log, each time the answer changes.
                if let unread = state.power.unread {
                    remoteLog.error("this Mac's power not read", ["why": unread])
                }
                do {
                    try FileManager.default.createDirectory(
                        at: VigilPaths.machine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try encoder.encode(state).write(to: VigilPaths.machineState, options: .atomic)
                } catch {
                    remoteLog.error("machine state not written: other devices see what they last had", ["err": error])
                }
            }
        }
    }
}
