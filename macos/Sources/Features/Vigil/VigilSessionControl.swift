#if os(macOS)
import Foundation
import CryptoKit
import Darwin

/// Session edits belong to the home app's registry writer. This socket is
/// an authenticated-user command channel, separate from terminal bytes and
/// from the authorization broker's decision protocol.
enum VigilSessionControl {
    struct Request: Codable, Sendable {
        let version: Int
        let id: UUID
        let issuedAt: TimeInterval
        let session: String
        let revision: String
        let operation: String
        let anchor: String
        let direction: String?
    }

    struct Reply: Codable, Sendable {
        let id: UUID?
        let ok: Bool
        let code: String
        let message: String
        var revision: String?
        var pane: String?
        var session: String?

        static func failure(_ request: Request?, _ code: String, _ message: String) -> Self {
            .init(id: request?.id, ok: false, code: code, message: message)
        }
    }

    static let maxBytes = 65536
    static let lifetime: TimeInterval = 86400
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/wake")
    }
    static var socketPath: String { directory.appendingPathComponent("session-control.sock").path }

    @MainActor
    static func revision(_ tabs: [VigilSessionManager.Tab]) -> String {
        // Runtime titles/cwd/attention must not invalidate a structural edit.
        struct Shape: Encodable {
            let panes: [String]
            let layout: VigilSessionManager.Layout?
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
        guard path.utf8.count < 104 else { return nil }
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
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
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
            bytes.append(contentsOf: buffer.prefix(count))
            if let newline = bytes.firstIndex(of: 10) {
                guard newline < maxBytes,
                      let request = try? JSONDecoder().decode(Request.self, from: bytes.prefix(upTo: newline)) else {
                    send(.failure(nil, "invalid_request", "Expected one session command JSON line."), to: fd)
                    return
                }
                Task { @MainActor in
                    let reply = transact(request)
                    DispatchQueue.global(qos: .userInitiated).async { send(reply, to: fd) }
                }
                return
            }
        }
        send(.failure(nil, "request_too_large", "Session command exceeds 64 KiB."), to: fd)
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

    @MainActor
    static func transact(_ request: Request) -> Reply {
        guard request.version == 1 else { return .failure(request, "unsupported_version", "Session API version 1 is required.") }
        let age = Date().timeIntervalSince1970 - request.issuedAt
        guard age >= -300, age < lifetime else { return .failure(request, "expired", "This command has expired; it will not be executed.") }
        if request.operation == "describe" { return VigilSessionManager.shared.applySessionCommand(request) }
        let receipts = directory.appendingPathComponent("session-receipts")
        let file = receipts.appendingPathComponent(request.id.uuidString + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
            if let previous = try? Data(contentsOf: file) {
                let receipt = try JSONDecoder().decode(Receipt.self, from: previous)
                guard try encoder.encode(receipt.request) == encoder.encode(request) else {
                    return .failure(request, "id_reused", "Command ID was already used for different arguments.")
                }
                return receipt.reply ?? .failure(request, "indeterminate", "The home app stopped during this command. Inspect the session before issuing another command.")
            }
            // Bounded durable deduplication, cleaned at human input events.
            let files = try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
            var count = 0
            for old in files where old.pathExtension == "json" {
                if let data = try? Data(contentsOf: old),
                   let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                   Date().timeIntervalSince1970 - receipt.request.issuedAt >= lifetime {
                    try FileManager.default.removeItem(at: old)
                } else { count += 1 }
            }
            guard count < 4096 else { return .failure(request, "busy", "The session command receipt store is full.") }
            // Write intent before any side effect. A crash can leave an
            // indeterminate receipt but a retry cannot create another pane.
            try encoder.encode(Receipt(request: request, reply: nil)).write(to: file, options: .atomic)
            let reply = VigilSessionManager.shared.applySessionCommand(request)
            try encoder.encode(Receipt(request: request, reply: reply)).write(to: file, options: .atomic)
            return reply
        } catch {
            return .failure(request, "receipt_failed", "Cannot durably record command: \(error.localizedDescription)")
        }
    }
}
#endif
