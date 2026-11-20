#if os(macOS)
import Foundation
import CryptoKit
import Darwin
import VigilWire

/// Session edits belong to the home app's registry writer. This socket is
/// an authenticated-user command channel, separate from terminal bytes and
/// from the authorization broker's decision protocol.
enum VigilSessionControl {
    typealias Request = WorkspaceCommand.Request

    struct InputDiagnostic: Codable, Sendable {
        let pane: String
        let host: String?
        let clientID: String?
        let readonly: Bool
        let keyboardFocus: Bool
        let keyWindow: Bool
        let visible: Bool
        let keyEvents: UInt64
        let keyActions: UInt64
        let lastKeyAt: TimeInterval?
        let lastKeyHandled: Bool?
        let transportState: UInt8?
        let pendingBytes: UInt64?
        let writtenBytes: UInt64?
    }

    /// The app's own account of itself (`status`): the counts only it
    /// knows and the kernel's memory figures, so a checker compares
    /// structured facts instead of parsing a tool's table.
    struct Status: Codable, Sendable {
        let footprintMB: Double
        let heapInUseMB: Double
        let views: Int
        let windowedViews: Int
        let mirrorViews: Int
        let sessions: Int
        let heldTabs: Int
        let uptimeSeconds: Double
    }

    struct Reply: Codable, Sendable {
        let id: UUID?
        let ok: Bool
        let code: String
        let message: String
        var revision: String?
        var pane: String?
        var session: String?
        var input: [InputDiagnostic]?
        var status: Status?
        var released: [String: Move.TranscriptProof]?
        /// Revisions of the pane writers the source actually retired, captured
        /// before their daemons stopped and retained with the source burial.
        var writerRevisions: [String: String]?
        var page: Move.Page?
        var successors: [String: VigilWorkspaces.MoveSuccessor]?

        static func failure(_ request: Request?, _ code: String, _ message: String) -> Self {
            .init(id: request?.id, ok: false, code: code, message: message)
        }
    }

    // Up to 256 panes with 16 named SHA-256 checkpoints apiece.
    static let maxBytes = 2 << 20
    static let lifetime: TimeInterval = 86400
    static var directory: URL {
        VigilPaths.root
    }
    static var socketPath: String { directory.appendingPathComponent("workspace-control.sock").path }

    @MainActor
    static func revision(_ tabs: [Registry.Tab]) -> String {
        // Runtime titles/cwd/attention must not invalidate a structural edit.
        struct Shape: Encodable {
            let panes: [String]
            let layout: Registry.Layout?
            let dock: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(tabs.map {
            Shape(panes: $0.panes.map(\.id), layout: $0.layout, dock: $0.dock?.panes.map(\.id) ?? [])
        })) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// All parsing and socket I/O is off the app thread. Only the registry
    /// transaction enters MainActor. A quiet server has no periodic work.
    static func start() -> DispatchSourceRead? {
        let path = socketPath
        guard var address = try? UnixSocket.address(path) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        // The manager's instance lock is already held; no competing writer
        // can own this endpoint. Remove only the old socket, never a file.
        var old = stat()
        if lstat(path, &old) == 0 {
            guard old.st_mode & S_IFMT == S_IFSOCK else { close(fd); return nil }
            unlink(path)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return nil }
        let queue = DispatchQueue(label: "vigil.session-control", qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                _ = fcntl(client, F_SETFL, 0)
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async { serve(client) }
            }
        }
        source.setCancelHandler { close(fd); unlink(path) }
        source.resume()
        return source
    }

    private static func serve(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count <= maxBytes {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { close(fd); return }
            let start = bytes.endIndex
            bytes.append(contentsOf: buffer.prefix(count))
            if let newline = bytes[start...].firstIndex(of: 10) {
                guard newline < maxBytes,
                      let request = try? JSONDecoder().decode(Request.self, from: bytes.prefix(upTo: newline)),
                      newline < 65536 || ["release_move_v2", "ack_move_v2", "abandon_move_v2", "return_panes_v2"].contains(request.operation) else {
                    send(.failure(nil, "invalid_request", "Expected one workspace command JSON line."), to: fd)
                    return
                }
                Task { @MainActor in
                    let reply = await transact(request)
                    DispatchQueue.global(qos: .userInitiated).async { send(reply, to: fd) }
                }
                return
            }
        }
        send(.failure(nil, "request_too_large", "Workspace command exceeds the handoff limit of 2 MiB."), to: fd)
    }

    private static func send(_ reply: Reply, to fd: Int32) {
        defer { close(fd) }
        guard var bytes = try? JSONEncoder().encode(reply) else { return }
        bytes.append(10)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private struct Receipt: Codable {
        let request: Request
        let reply: Reply?
    }

    /// Commands under way, by id: a birth is awaited, so a retry of one can
    /// arrive while it is still being done (its receipt holds no reply yet,
    /// which otherwise means the app stopped during it).
    @MainActor private static var underWay: Set<UUID> = []

    @MainActor
    static func transact(_ request: Request) async -> Reply {
        guard request.version == 1 else { return .failure(request, "unsupported_version", "Workspace command version 1 is required.") }
        // The rule the hub asks of another device's request, asked of every
        // sender (this Mac's own included).
        if let why = request.refusal { return .failure(request, "invalid_request", why) }
        if let original = request.receiptSubject {
            let file = directory.appendingPathComponent("workspace-receipts/" + original.id.uuidString + ".json")
            do {
                guard let receipt = try Durable.decode(Receipt.self, file).get() else {
                    return .failure(request, "receipt_unknown", "The home has no receipt for this workspace command. Its outcome is unknown.")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(receipt.request) == encoder.encode(original) else {
                    return .failure(request, "id_reused", "The recorded command has different arguments.")
                }
                return receipt.reply ?? .failure(request, "receipt_unknown", "The home recorded the command and has no final answer yet.")
            } catch { return .failure(request, "receipt_unknown", "The home's workspace receipt could not be read: " + String(describing: error)) }
        }
        let age = Date().timeIntervalSince1970 - request.issuedAt
        // No request may outlive the receipt that prevents repeating it.
        guard age >= -300, age < lifetime || ["retire_move", "release_move_v2", "ack_move_v2", "abandon_move_v2", "return_panes_v2"].contains(request.operation) else { return .failure(request, "expired", "This command has expired; it will not be executed.") }
        if request.operation == "inspect-input" {
            let views = Ghostty.SurfaceView.vigilAttachSurfaces.allObjects
                .filter { request.anchor.isEmpty || $0.vigilAttachId == request.anchor }
                .compactMap { $0.vigilInputDiagnostics() }
            return .init(id: request.id, ok: true, code: "ok", message: "Content-free input diagnostics.", input: views)
        }
        if request.operation == "status" {
            return .init(id: request.id, ok: true, code: "ok", message: "App status.", status: VigilWorkspaces.shared.status())
        }
        // A handoff reads or advances one durable transfer. A retry after a lost reply
        // must see its current phase, including a release made before an app restart.
        if ["release_move_v2", "ack_move_v2", "abandon_move_v2", "return_panes_v2"].contains(request.operation) {
            return await VigilWorkspaces.shared.handoffCommand(request)
        }
        if request.operation == "describe" { return VigilWorkspaces.shared.applySessionEdit(request) }
        guard !underWay.contains(request.id) else {
            return .failure(request, "in_progress", "This command is still being done on its Mac. Ask again in a moment for its outcome.")
        }
        let receipts = directory.appendingPathComponent("workspace-receipts")
        let file = receipts.appendingPathComponent(request.id.uuidString + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try Durable.folder(receipts)
            switch Durable.read(file) {
            case .unreadable(let why): return .failure(request, "receipt_failed", "Its previous outcome cannot be read: " + why)
            case .absent: break
            case .data(let previous):
                let receipt = try JSONDecoder().decode(Receipt.self, from: previous)
                guard try encoder.encode(receipt.request) == encoder.encode(request) else {
                    return .failure(request, "id_reused", "Command ID was already used for different arguments.")
                }
                return receipt.reply ?? .failure(request, "indeterminate", "vigil on that Mac stopped during this command. Check the workspace there before sending another.")
            }
            // Bounded durable deduplication, cleaned at human input events.
            let files = try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
            var count = 0
            for old in files where old.pathExtension == "json" {
                guard let data = try? Data(contentsOf: old), let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else {
                    count += 1
                    continue
                }
                if receipt.request.operation == "retire_move" { continue }
                if Date().timeIntervalSince1970 - receipt.request.issuedAt >= lifetime { try FileManager.default.removeItem(at: old) }
                else { count += 1 }
            }
            guard count < 4096 else { return .failure(request, "busy", "Too many workspace commands are on record; try again shortly.") }
            // Write intent before any side effect. A crash can leave an
            // indeterminate receipt but a retry cannot create another pane.
            try Durable.create(file, with: encoder.encode(Receipt(request: request, reply: nil)), exclusive: true)
            underWay.insert(request.id)
            defer { underWay.remove(request.id) }
            let reply = await VigilWorkspaces.shared.applySessionCommand(request)
            do { try Durable.replace(file, with: encoder.encode(Receipt(request: request, reply: reply))) } catch {
                return .init(id: request.id, ok: false, code: "indeterminate", message: "The command was taken. Its outcome could not be recorded. Check the workspace before acting again.", pane: reply.pane, session: reply.session)
            }
            return reply
        } catch {
            return .failure(request, "receipt_failed", "Cannot durably record command: \(error.localizedDescription)")
        }
    }
}
#endif
