import Foundation
import VigilHarness
import VigilWire

/// Other Macs' sessions, through this Mac's vigil hub (vigil-agent: the one
/// tether node of app `vigil` here, VigilWire). The Macs are the paired
/// devices running vigil, streamed by the hub as they change; each one's
/// directory (its registry, vigil.json verbatim, plus per-pane process
/// truth) arrives as a `dir` stream, one document per change. Surfaces
/// attach through the same hub (the Zig attach opens `proxy` itself).
/// Structural intent is a `session` call: the home app commits it and the
/// directory stream projects it here. This Mac never writes the home
/// registry. Who may reach whom is tether's pairing, nothing configured here.
@MainActor
final class VigilRemote: ObservableObject {
    static let shared = VigilRemote()

    struct Pane: Decodable, Equatable {
        let id: String
        var cwd: String
        var title: String?
        var label: String?
        var emoji: String?
        var command: String?
    }

    struct Session: Decodable, Equatable {
        let name: String
        var label: String
        var emoji: String?
        var cwd: String
        var tabs: [VigilSessionManager.Tab]?
        var buriedUntil: Double?
        var layoutRevision: String?
    }

    struct PaneTruth: Decodable, Equatable {
        var alive: Bool
        var state: String?
        var tree: [String]?
        var pid: String?
        /// The state file's mtime and the `<pane>.seen` mtime, unix seconds:
        /// seen >= since is the one seen-rule, the same the home Mac applies.
        var stateRevision: String?
        var since: Double?
        var seen: Double?
        /// `<pane>.size` as the daemon publishes it: "rows cols <owner hello>".
        /// A mirror here letterboxes a foreign owner's grid from it, exactly
        /// as a local surface does from the file.
        var size: String?
    }

    struct Directory: Decodable, Equatable {
        var host: String
        var sessions: [Session]
        var panes: [String: PaneTruth]
    }

    /// A paired Mac running vigil, by its tether root.
    struct Host {
        let device: String
        var name: String
        var directory: Directory?
        var error: String?
    }

    @Published private(set) var hosts: [Host] = []
    static var trace: ((String) -> Void)?

    private var started = false
    private var stopped = false
    /// The open directory stream per Mac (its socket to the hub).
    private var streams: [String: FileHandle] = [:]
    private var streamBuffers: [String: Data] = [:]
    private var arrivals: [String: (revision: String, at: Date)] = [:]
    func arrival(device: String, pane: String, revision: String) -> Date {
        let id = Self.compositeId(device, pane)
        if let value = arrivals[id], value.revision == revision { return value.at }
        let now = Date(); arrivals[id] = (revision, now)
        return now
    }

    /// Session ids of remote sessions are namespaced by the Mac so they can
    /// never collide with local ones: `<device>/<name>` (a tether root is hex).
    static func compositeId(_ device: String, _ name: String) -> String { "\(device)/\(name)" }

    nonisolated static func split(_ composite: String) -> (device: String, name: String)? {
        guard let slash = composite.firstIndex(of: "/") else { return nil }
        return (String(composite[..<slash]), String(composite[composite.index(after: slash)...]))
    }

    /// Follows the hub's list of Macs for the app's life: each new Mac's
    /// directory stream opens, a Mac gone takes its rows with it. A hub
    /// not answering (vigil-agent restarting) is asked again after 5s.
    func start() {
        guard !started else { return }
        started = true
        followPeers()
    }

    func stop() {
        stopped = true
        for handle in streams.values { try? handle.close() }
        streams.removeAll()
        streamBuffers.removeAll()
        Self.trace?("remote: directory streams stopped")
    }

    private func followPeers() {
        guard !stopped else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd: Int32
            do { fd = try Hub.request(.peers) } catch {
                Task { @MainActor [weak self] in
                    Self.trace?("remote: hub: \(error); asking again in 5s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self?.followPeers() } }
                }
                return
            }
            let reader = Hub.LineReader(fd: fd)
            while let line = reader.next() {
                guard let peers = try? JSONDecoder().decode([Local.Peer].self, from: line) else { continue }
                Task { @MainActor [weak self] in self?.peers(peers) }
            }
            close(fd)
            Task { @MainActor [weak self] in
                Self.trace?("remote: hub closed the Macs stream; asking again in 5s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self?.followPeers() } }
            }
        }
    }

    private func peers(_ peers: [Local.Peer]) {
        let wanted = Set(peers.map(\.id))
        for (device, handle) in streams where !wanted.contains(device) {
            streams[device] = nil; streamBuffers[device] = nil; try? handle.close()
        }
        hosts.removeAll { !wanted.contains($0.device) }
        arrivals = arrivals.filter { Self.split($0.key).map { wanted.contains($0.device) } ?? false }
        for peer in peers {
            if let index = hosts.firstIndex(where: { $0.device == peer.id }) {
                hosts[index].name = peer.name
            } else {
                hosts.append(Host(device: peer.id, name: peer.name))
                stream(peer.id)
            }
        }
        Self.trace?("remote: Macs \(peers.map(\.name))")
        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
    }

    /// A Mac's directory stream, through the hub. A stream that ends is
    /// dialed again after 15s while the Mac is still paired.
    private func stream(_ device: String) {
        guard !stopped, streams[device] == nil, host(device) != nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Hub.request(.open(device: device, .dir)) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.ended(device, "\(error)")
                case .success(let fd):
                    guard self.host(device) != nil, !self.stopped else { close(fd); return }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    handle.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        Task { @MainActor [weak self] in
                            guard let self, self.streams[device] === handle else { return }
                            if data.isEmpty {
                                handle.readabilityHandler = nil
                                self.streams[device] = nil
                                self.streamBuffers[device] = nil
                                self.ended(device, "stream ended")
                            } else {
                                self.streamed(device, data)
                            }
                        }
                    }
                    self.streams[device] = handle
                    Self.trace?("remote: \(self.host(device)?.name ?? device) stream opened")
                }
            }
        }
    }

    private func ended(_ device: String, _ why: String) {
        guard let index = hosts.firstIndex(where: { $0.device == device }) else { return }
        if hosts[index].error != why {
            Self.trace?("remote: \(hosts[index].name) \(why); dialing again in 15s")
            hosts[index].error = why
            NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            MainActor.assumeIsolated { self?.stream(device) }
        }
    }

    /// Lines off the stream, each a whole directory document.
    private func streamed(_ device: String, _ data: Data) {
        streamBuffers[device, default: Data()].append(data)
        while let buffer = streamBuffers[device], let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[buffer.startIndex..<newline])
            streamBuffers[device]?.removeSubrange(buffer.startIndex...newline)
            do { apply(device, .success(try JSONDecoder().decode(Directory.self, from: line))) }
            catch { apply(device, .failure(error)) }
        }
    }

    func host(_ device: String) -> Host? { hosts.first { $0.device == device } }

    /// One finite call per user edit. The held directory stream publishes
    /// the result to every viewport; pane proxy streams remain untouched.
    func command(_ device: String, request: VigilSessionControl.Request) async throws -> VigilSessionControl.Reply {
        let payload = try JSONEncoder().encode(request) + Data([10])
        let data = try await Task.detached(priority: .userInitiated) {
            try Hub.call(device: device, .session, input: payload)
        }.value
        let reply = try JSONDecoder().decode(VigilSessionControl.Reply.self, from: data)
        guard reply.id == request.id else {
            throw NSError(domain: "VigilSessionControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "The home reply did not match this command."])
        }
        return reply
    }

    func session(_ composite: String) -> (device: String, session: Session)? {
        guard let (device, name) = Self.split(composite),
              let session = host(device)?.directory?.sessions.first(where: { $0.name == name && $0.buriedUntil == nil })
        else { return nil }
        return (device, session)
    }

    /// One directory landed: the Mac's rows follow, with a receipt only
    /// when something changed.
    private func apply(_ device: String, _ result: Result<Directory, Error>) {
        guard let index = hosts.firstIndex(where: { $0.device == device }) else { return }
        switch result {
        case .success(let dir):
            // Wire-only renderer hashes are not sidebar inputs. Compare
            // decoded facts before deciding whether projections changed.
            let changed = hosts[index].directory != dir || hosts[index].error != nil
            guard changed else { return }
            // A receipt per SHAPE change (a session or pane came or went),
            // not per state flip: the stream delivers every flip and a busy
            // fleet would write the log a few times a second.
            let shape = (dir.sessions.count, dir.panes.count)
            let before = hosts[index].directory.map { ($0.sessions.count, $0.panes.count) }
            arrivals = arrivals.filter { entry in
                guard let split = Self.split(entry.key), split.device == device else { return true }
                return dir.panes[split.name] != nil
            }
            hosts[index].directory = dir
            VigilSessionManager.shared.remoteDirectoryChanged(device)
            hosts[index].error = nil
            if before == nil || before! != shape {
                Self.trace?("remote: \(hosts[index].name) = \(dir.host), \(dir.sessions.count) sessions, \(dir.panes.count) panes")
            }
            NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
        case .failure(let error):
            let msg = error.localizedDescription
            if hosts[index].error != msg {
                Self.trace?("remote: \(hosts[index].name) unreadable directory: \(msg)")
                hosts[index].error = msg
                NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
            }
        }
    }

    /// The sidebar's rows for every remote Mac, built like the local
    /// snapshot: session → tabs → panes, program from the tree argv, state
    /// from the token. Everything cold (no local views exist), row ids
    /// namespaced by the Mac.
    func sidebarRows() -> [VigilSessionManager.SidebarSessionRow] {
        var rows: [VigilSessionManager.SidebarSessionRow] = []
        for host in hosts {
            let hostLabel = host.directory?.host ?? host.name
            let header = host.error.map { "\(hostLabel) (\($0))" } ?? hostLabel
            guard let dir = host.directory else {
                rows.append(.init(
                    id: Self.compositeId(host.device, ""), emoji: nil, label: "…",
                    stateTag: "remote", attention: .none, states: [], tabs: [], host: header))
                continue
            }
            let sessions = dir.sessions.filter { $0.buriedUntil == nil }
                .sorted { ($0.label.lowercased(), $0.name) < ($1.label.lowercased(), $1.name) }
            for session in sessions {
                let composite = Self.compositeId(host.device, session.name)
                var tabs: [VigilSessionManager.SidebarTab] = []
                for (index, tab) in (session.tabs ?? []).enumerated() {
                    let all = tab.panes + (tab.dock?.panes ?? [])
                    guard !all.isEmpty else { continue }
                    let panes = all.enumerated().map { offset, pane -> VigilSessionManager.SidebarPane in
                        let truth = dir.panes[pane.id]
                        let program = truth?.tree?.compactMap { line -> String? in
                            let argv = line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? ""
                            return VigilSessionManager.processLabel(argv)
                        }.last
                        let state = Self.displayState(truth)
                        let title = pane.label
                            ?? program
                            ?? pane.command.flatMap(VigilSessionManager.processLabel)
                            ?? pane.title
                            ?? (pane.cwd as NSString).lastPathComponent
                        return .init(
                            id: Self.compositeId(host.device, pane.id),
                            paneId: nil,
                            title: title,
                            program: program,
                            state: state,
                            isDock: offset >= tab.panes.count,
                            emoji: pane.emoji)
                    }
                    let anchor = all.first.map { Self.compositeId(host.device, $0.id) }
                    let title = tab.label.flatMap { $0.isEmpty ? nil : $0 }
                        ?? ((tab.panes.first?.cwd ?? "") as NSString).lastPathComponent
                    tabs.append(.init(
                        id: VigilSessionManager.tabRowId(composite, anchor: anchor, index: index),
                        title: title.isEmpty ? "tab \(index + 1)" : title,
                        index: index,
                        panes: panes,
                        anchor: anchor,
                        captured: true,
                        emoji: tab.emoji,
                        named: tab.label?.isEmpty == false || tab.emoji?.isEmpty == false))
                }
                rows.append(.init(
                    id: composite,
                    emoji: session.emoji,
                    label: session.label,
                    stateTag: "remote",
                    attention: tabs.flatMap(\.panes).contains(where: { $0.state == .blocked }) ? .input : (tabs.flatMap(\.panes).contains(where: { $0.state == .done }) ? .done : .none),
                    states: VigilSessionManager.clusterStates(tabs.flatMap(\.panes).compactMap(\.state)),
                    tabs: tabs,
                    host: header))
            }
        }
        return rows
    }

    /// The state token, read exactly as the home Mac reads its own file:
    /// first word is the state, and `working unknown` / `working
    /// interrupting` are the harness's typed uncertainty, not work (a codex
    /// pane painted as running for a day because only the first word was
    /// read, 2026-09-14).
    static func agentState(_ token: String) -> VigilSessionManager.AgentState? {
        let parts = token.split(separator: " ")
        switch parts.first.map(String.init) ?? "" {
        case "working":
            if parts.count > 1, parts[1] == "unknown" { return .unknown }
            if parts.count > 1, parts[1] == "interrupting" { return .interrupting }
            return .working
        case "blocked": return .blocked
        case "done": return .done
        case "idle": return .idle
        case "unknown": return .unknown
        case "interrupting": return .interrupting
        default: return nil
        }
    }

    /// What the row shows: the home Mac's seen-decay applied here too.
    /// done/blocked that has been seen (anywhere) reads idle.
    static func displayState(_ truth: PaneTruth?) -> VigilSessionManager.AgentState? {
        guard let truth, let revision = truth.stateRevision, revision.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let token = truth.state, let state = agentState(token) else { return nil }
        if state == .done || state == .blocked,
           let seen = truth.seen, let since = truth.since, seen >= since { return .idle }
        return state
    }

    private var seenInFlight = Set<String>()

    /// A remote console is under the eyes here: the ack belongs to ITS Mac.
    /// Written through a `seen` call only on a seen-FLIP (unseen
    /// done/blocked), never on the presence pulse; the directory is updated
    /// optimistically so the row decays with the glance, and the Mac's next
    /// document confirms it.
    func seen(device: String, pane: String) {
        guard let index = hosts.firstIndex(where: { $0.device == device }),
              let truth = hosts[index].directory?.panes[pane],
              let revision = truth.stateRevision, revision.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let token = truth.state, let state = Self.agentState(token),
              state == .done || state == .blocked,
              (truth.seen ?? 0) < (truth.since ?? 0) else { return }
        let key = "\(device)/\(pane)"
        guard !seenInFlight.contains(key) else { return }
        seenInFlight.insert(key)
        hosts[index].directory?.panes[pane]?.seen = truth.since
        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let failure: String?
            do {
                _ = try Hub.call(device: device, .seen(pane, revision: revision))
                failure = nil
            } catch {
                failure = "\(error)"
            }
            Task { @MainActor [weak self] in
                self?.seenInFlight.remove(key)
                if failure != nil, let self, let index = self.hosts.firstIndex(where: { $0.device == device }),
                   self.hosts[index].directory?.panes[pane]?.stateRevision == revision {
                    self.hosts[index].directory?.panes[pane]?.seen = truth.seen
                    NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                }
                Self.trace?("remote: seen \(key)" + (failure.map { " FAILED (\($0))" } ?? ""))
            }
        }
    }

    /// This Mac's hub (`Local`), by blocking calls: off the main thread only.
    enum Hub {
        enum Failure: Error, CustomStringConvertible {
            case unreachable(String), refused(String), garbled
            var description: String {
                switch self {
                case .unreachable(let why): "this Mac's vigil-agent does not answer (\(why))"
                case .refused(let why): why
                case .garbled: "the hub's answer did not parse"
                }
            }
        }

        static var socket: String { Local.socket(root: HarnessPaths.root).path }

        /// A socket to the hub with `request` sent. For `peers` it then
        /// carries the lines; for a stream `open`, the Ack is read here and
        /// the socket carries the remote stream's bytes.
        static func request(_ request: Local.Request) throws -> Int32 {
            let fd = try connect()
            do {
                guard WireIO.writeLine(fd, try JSONEncoder().encode(request)) else { throw Failure.unreachable("write") }
                if request.kind == .open {
                    // Byte by byte: what follows the Ack is the stream's.
                    guard let line = WireIO.readLine(fd) else { throw Failure.unreachable("no answer") }
                    guard let ack = try? JSONDecoder().decode(Ack.self, from: line) else { throw Failure.garbled }
                    guard ack.ok else { throw Failure.refused(ack.error ?? "refused") }
                }
                return fd
            } catch {
                close(fd)
                throw error
            }
        }

        /// A call: its output, or why it failed.
        static func call(device: String, _ open: Open, input: Data = Data()) throws -> Data {
            let fd = try connect()
            defer { close(fd) }
            guard WireIO.writeLine(fd, try JSONEncoder().encode(Local.Request.open(device: device, open))) else { throw Failure.unreachable("write") }
            if !input.isEmpty { _ = WireIO.writeAll(fd, input) }
            shutdown(fd, SHUT_WR)
            guard let line = WireIO.readLine(fd) else { throw Failure.unreachable("no answer") }
            guard let result = try? JSONDecoder().decode(CallResult.self, from: line) else { throw Failure.garbled }
            guard result.ok else { throw Failure.refused(result.error ?? "failed") }
            return result.output
        }

        private static func connect() throws -> Int32 {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.unreachable("socket: \(errno)") }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socket.utf8)
            guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw Failure.unreachable("socket path too long") }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: path)
                raw[path.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else {
                let why = String(cString: strerror(errno))
                close(fd)
                throw Failure.unreachable(why)
            }
            return fd
        }

        /// Lines off a blocking socket, at most 16 MiB each (a directory).
        final class LineReader {
            private let fd: Int32
            private var buffer = Data()
            init(fd: Int32) { self.fd = fd }
            func next() -> Data? {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    if let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[buffer.startIndex..<newline])
                        buffer.removeSubrange(buffer.startIndex...newline)
                        return line
                    }
                    guard buffer.count < 16 << 20 else { return nil }
                    let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { return nil }
                    buffer.append(contentsOf: chunk[0..<n])
                }
            }
        }
    }
}
