#if os(macOS)
import AppKit
import Darwin
import Foundation
import Security
import VigilWire

/// vigil as a dictation DESTINATION. utter (the Mac's one speech-to-text
/// app) asks at a press where its words go while a vigil window is in
/// front: vigil names the focused pane and its workspace's words (the
/// cortex keywords, proper nouns a recognizer would misspell), and utter
/// sends every final of that press to the pane, wherever focus goes after.
/// Delivery is raw keystrokes into the pane's daemon (`PaneLink.type`), NO
/// Enter: speech lands in the input line as if typed, and the human submits.
///
/// The channel carries dictated text, so it is closed both ways: an
/// owner-only socket (`dictation.sock`, 0600) that serves only utter, by its
/// code signature; utter checks this app's signature the same way.
///
/// Wire: one JSON line in, one out, then the connection closes.
/// `{"v":1,"op":"target"}` → `{"ok":true,"pane":…,"workspace":…,"words":[…]}`
/// `{"v":1,"op":"type","pane":…,"text":…}` → `{"ok":true}` once the
/// daemon took the bytes. A refusal is `{"ok":false,"why":…}`.
enum VigilDictation {
    static var socketPath: String { VigilPaths.root.appendingPathComponent("dictation.sock").path }
    static let peerRequirement =
        #"identifier "garden.untitled.utter" and anchor apple generic and certificate leaf[subject.OU] = "G387QW47LV""#
    static let maxBytes = 65536

    struct Request: Decodable {
        let v: Int
        let op: String
        let pane: String?
        let text: String?
    }

    struct Reply: Encodable {
        let ok: Bool
        var why: String?
        var pane: String?
        var workspace: String?
        var words: [String]?

        static func refused(_ why: String) -> Reply { Reply(ok: false, why: why) }
    }

    /// Socket I/O off the app thread; only `target` enters MainActor. A quiet
    /// server does no work.
    static func start() -> DispatchSourceRead? {
        let path = socketPath
        guard var address = try? UnixSocket.address(path) else { return nil }
        try? FileManager.default.createDirectory(at: VigilPaths.root, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        // The app's instance lock is held: no other vigil owns this path.
        var old = stat()
        if lstat(path, &old) == 0 {
            guard old.st_mode & S_IFMT == S_IFSOCK else { close(fd); return nil }
            unlink(path)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            dictationLog.error("socket refused", ["path": path, "errno": errno])
            close(fd)
            return nil
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: accepting)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                _ = fcntl(client, F_SETFL, 0)
                guard peerIsUtter(client) else {
                    dictationLog.warn("refused a caller that is not utter")
                    close(client)
                    continue
                }
                DispatchQueue.global(qos: .userInitiated).async { serve(client) }
            }
        }
        source.setCancelHandler { close(fd); unlink(path) }
        source.resume()
        dictationLog.ready("dictation destination", ["socket": path])
        return source
    }

    private static let accepting = DispatchQueue(label: "vigil.dictation", qos: .userInitiated)
    /// Lines reach a pane in the order they were said: one delivery at a time.
    private static let delivering = DispatchQueue(label: "vigil.dictation.deliver", qos: .userInitiated)

    /// Same user, and signed as utter by this team.
    private static func peerIsUtter(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return false }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return false }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        var requirement: SecRequirement?
        guard
            SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: data] as CFDictionary, [], &code)
                == errSecSuccess, let code,
            SecRequirementCreateWithString(peerRequirement as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
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
            guard let newline = bytes.firstIndex(of: 10) else { continue }
            guard let request = try? JSONDecoder().decode(Request.self, from: bytes.prefix(upTo: newline)),
                  request.v == 1
            else { return send(.refused("expected one version 1 request line"), to: fd) }
            switch request.op {
            case "target":
                Task { @MainActor in
                    let reply = target()
                    DispatchQueue.global(qos: .userInitiated).async { send(reply, to: fd) }
                }
            case "type":
                guard let pane = request.pane, let text = request.text else {
                    return send(.refused("type needs a pane and a text"), to: fd)
                }
                delivering.async { send(deliver(text, into: pane), to: fd) }
            default:
                send(.refused("unknown op \(request.op)"), to: fd)
            }
            return
        }
        send(.refused("request exceeds 64 KiB"), to: fd)
    }

    /// The pane in front: the key terminal's focused surface (the quick
    /// terminal included), else the terminal last worked in. A view of
    /// another Mac's pane is refused: its daemon is not here, and utter then
    /// types into the window like any app.
    @MainActor
    private static func target() -> Reply {
        let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ?? TerminalController.preferredParent
        guard let surface = controller?.focusedSurface else {
            dictationLog.info("target: no terminal in front")
            return .refused("no terminal in front")
        }
        guard surface.vigilHost == nil else {
            dictationLog.info("target: the pane lives on another Mac")
            return .refused("the pane lives on another Mac")
        }
        guard let pane = surface.vigilAttachId else { return .refused("the surface has no pane") }
        let workspaces = VigilWorkspaces.shared
        let words = workspaces.cortexIdentity(ofPane: pane)?.keywords ?? []
        let workspace = workspaces.workspaceOwning(pane: pane)
        dictationLog.info("target", ["pane": pane, "workspace": workspace, "words": words.count])
        return Reply(ok: true, pane: pane, workspace: workspace, words: words)
    }

    /// One final as raw keystrokes, a trailing space so the next lands a
    /// word apart. Never a newline: control characters become spaces.
    private static func deliver(_ text: String, into pane: String) -> Reply {
        let clean = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Reply(ok: true) }
        // Typed by the app itself over the pane's socket: a pane answers the
        // app and vigil-agent, never a vigild it runs.
        do {
            try PaneLink.type(pane, keys: clean + " ", hello: "app dictation")
        } catch {
            dictationLog.error("not delivered", ["pane": pane, "err": "\(error)"])
            return .refused("\(error)")
        }
        dictationLog.info("delivered", ["pane": pane, "chars": clean.count])
        return Reply(ok: true)
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
}
#endif
