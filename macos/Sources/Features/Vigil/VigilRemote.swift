import Foundation
import SystemConfiguration

/// Other Macs' sessions, read through ssh. ONE source: `ssh <alias> vigild
/// dir` returns the machine's registry (vigil.json verbatim) plus per-pane
/// process truth (alive, agent state token, tree argv), streamed per change.
/// Surfaces attach through `ssh <alias> vigild proxy <pane>`. Structural
/// intent uses `vigild session`: the home app commits it, and the directory
/// stream projects it here. This Mac never writes the home registry.
/// Reachability, keys and the network are the
/// user's ssh config (`vigil-hosts` lists aliases, nothing more).
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

    struct Session: Decodable {
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

    struct Directory: Decodable {
        var host: String
        var sessions: [Session]
        var panes: [String: PaneTruth]
    }

    struct Host {
        let alias: String
        var directory: Directory?
        /// The bytes the directory was decoded from: change detection.
        var raw: Data?
        var error: String?
        var fetched: Date?
        /// The alias points at THIS Mac (`vigil-hosts` is one shared
        /// config across Adrian's Macs, so every Mac lists itself): never
        /// polled, never a row.
        var isSelf = false
    }

    static let selfError = "this Mac"

    @Published private(set) var hosts: [Host] = []
    static var trace: ((String) -> Void)?

    /// One `ssh <alias> vigild dir --watch` per host, for as long as the
    /// host is configured: the remote emits its directory once per change,
    /// nothing is polled and no process is spawned per tick. A dead stream
    /// re-dials after 15s.
    private var streams: [String: Process] = [:]
    private var resolving = Set<String>()
    private var stopped = false
    private var streamBuffers: [String: Data] = [:]
    private var inflight = Set<String>()
    private var arrivals: [String: (revision: String, at: Date)] = [:]
    func arrival(alias: String, pane: String, revision: String) -> Date {
        let id = Self.compositeId(alias, pane)
        if let value = arrivals[id], value.revision == revision { return value.at }
        let now = Date(); arrivals[id] = (revision, now)
        return now
    }

    /// Session ids of remote sessions are namespaced by alias so they can
    /// never collide with local ones: `alias/name`.
    static func compositeId(_ alias: String, _ name: String) -> String { "\(alias)/\(name)" }

    nonisolated static func split(_ composite: String) -> (alias: String, name: String)? {
        guard let slash = composite.firstIndex(of: "/") else { return nil }
        return (String(composite[..<slash]), String(composite[composite.index(after: slash)...]))
    }

    func configure(aliases: [String]) {
        guard !stopped else { return }
        let known = Set(hosts.map(\.alias))
        let wanted = Set(aliases)
        hosts.removeAll { !wanted.contains($0.alias) }
        arrivals = arrivals.filter { Self.split($0.key).map { wanted.contains($0.alias) } ?? false }
        for (alias, stream) in streams where !wanted.contains(alias) {
            streams[alias] = nil; streamBuffers[alias] = nil; stream.terminate()
        }
        for alias in aliases where !known.contains(alias) {
            hosts.append(Host(alias: alias))
        }
        VigilHarnessCoordinator.shared.configureRemoteHomes()
        guard !aliases.isEmpty else { return }
        Self.trace?("remote: hosts \(aliases)")
        // The streams wait for self-resolution: a stream from this Mac's
        // own alias would paint a host row for the one tick it takes.
        let unresolved = aliases.filter { !known.contains($0) }
        resolving.formUnion(unresolved)
        resolveSelf(unresolved) { [weak self] in
            self?.resolving.subtract(unresolved)
            self?.streamAll()
        }
    }

    func stop() {
        stopped = true
        let running = Array(streams.values)
        streams.removeAll()
        streamBuffers.removeAll()
        for process in running where process.isRunning { process.terminate() }
        Self.trace?("remote: directory streams stopped")
    }

    private func streamAll() {
        for host in hosts where !host.isSelf { stream(host.alias) }
    }

    private func stream(_ alias: String) {
        guard !stopped, !resolving.contains(alias), streams[alias] == nil,
              let host = host(alias), !host.isSelf else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=15",
                          "-o", "ServerAliveCountMax=2", "-T", alias, "vigild", "dir", "--watch", "--until-eof"]
        // The write end lives with Process. App death closes it; the home
        // subscription exits on EOF even if no directory fact changes.
        proc.standardInput = Pipe()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self, weak proc] in
                guard let self, let proc, self.streams[alias] === proc else { return }
                self.streamed(alias, data)
            }
        }
        proc.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.streams[alias] === proc else { return }
                self.streams[alias] = nil
                self.streamBuffers[alias] = nil
                if let index = self.hosts.firstIndex(where: { $0.alias == alias }) {
                    let msg = "stream ended (ssh exit \(proc.terminationStatus))"
                    if self.hosts[index].error != msg {
                        Self.trace?("remote: \(alias) \(msg); re-dialing in 15s")
                        self.hosts[index].error = msg
                        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    MainActor.assumeIsolated { self?.stream(alias) }
                }
            }
        }
        do {
            try proc.run()
            streams[alias] = proc
            Self.trace?("remote: \(alias) stream opened")
        } catch {
            Self.trace?("remote: \(alias) stream failed to start: \(error.localizedDescription)")
        }
    }

    /// Lines off the stream, each a whole directory document.
    private func streamed(_ alias: String, _ data: Data) {
        streamBuffers[alias, default: Data()].append(data)
        while let buffer = streamBuffers[alias], let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[buffer.startIndex..<newline])
            streamBuffers[alias]?.removeSubrange(buffer.startIndex...newline)
            do { apply(alias, .success((try JSONDecoder().decode(Directory.self, from: line), line))) }
            catch { apply(alias, .failure(error)) }
        }
    }

    /// Which aliases name this Mac, decided from the ssh CONFIG (`ssh -G`
    /// prints the resolved HostName), never from a reply: self must read
    /// as self before sshd is even enabled here. Matches this Mac's own
    /// names and every address on its interfaces.
    private func resolveSelf(_ aliases: [String], then done: @escaping @MainActor () -> Void) {
        guard !aliases.isEmpty else { done(); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mine = Self.localIdentities()
            var selfAliases: [String] = []
            for alias in aliases {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = ["-G", alias]
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = FileHandle.nullDevice
                guard (try? proc.run()) != nil else { continue }
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                proc.waitUntilExit()
                let target = text.split(separator: "\n")
                    .first { $0.hasPrefix("hostname ") }
                    .map { String($0.dropFirst("hostname ".count)).lowercased() } ?? alias.lowercased()
                if mine.contains(target) { selfAliases.append(alias) }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for alias in selfAliases {
                    guard let index = self.hosts.firstIndex(where: { $0.alias == alias }) else { continue }
                    Self.trace?("remote: \(alias) is this Mac, never polled")
                    self.hosts[index].isSelf = true
                    self.hosts[index].error = Self.selfError
                    self.hosts[index].directory = nil
                    self.hosts[index].raw = nil
                    if let stream = self.streams.removeValue(forKey: alias) { stream.terminate() }
                    self.streamBuffers[alias] = nil
                }
                if !selfAliases.isEmpty {
                    NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                }
                done()
            }
        }
    }

    /// This Mac's names (hostName, its short form, the Bonjour name) and
    /// every numeric address on its interfaces, lowercased.
    private static func localIdentities() -> Set<String> {
        var ids = Set<String>()
        let full = ProcessInfo.processInfo.hostName.lowercased()
        ids.insert(full)
        ids.insert(String(full.split(separator: ".").first ?? Substring(full)))
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            ids.insert(local.lowercased())
            ids.insert(local.lowercased() + ".local")
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return ids }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                ids.insert(String(cString: buffer).lowercased())
            }
        }
        return ids
    }

    func host(_ alias: String) -> Host? { hosts.first { $0.alias == alias } }

    /// One finite RPC per user edit. The held directory stream publishes
    /// the result to every viewport; pane proxy streams remain untouched.
    func command(_ alias: String, request: VigilSessionControl.Request) async throws -> VigilSessionControl.Reply {
        let payload = try JSONEncoder().encode(request) + Data([10])
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                 "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
                                 alias, "vigild", "session"]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let error = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "VigilSessionControl", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: String(data: error, encoding: .utf8) ?? "The home session writer did not reply."
                ])
            }
            let reply = try JSONDecoder().decode(VigilSessionControl.Reply.self, from: data)
            guard reply.id == request.id else {
                throw NSError(domain: "VigilSessionControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "The home reply did not match this command."])
            }
            return reply
        }.value
    }

    func session(_ composite: String) -> (alias: String, session: Session)? {
        guard let (alias, name) = Self.split(composite),
              let session = host(alias)?.directory?.sessions.first(where: { $0.name == name && $0.buriedUntil == nil })
        else { return nil }
        return (alias, session)
    }

    /// One `ssh <alias> vigild dir`, off the main thread; the result lands
    /// on the main actor. A failure keeps the last good directory and
    /// records the error (the header shows it).
    func refresh(_ alias: String) {
        guard !inflight.contains(alias) else { return }
        inflight.insert(alias)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T", alias, "vigild", "dir"]
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            var result: Result<(Directory, Data), Error>
            do {
                try proc.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    throw NSError(domain: "vigil.remote", code: Int(proc.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "ssh exit \(proc.terminationStatus)" : msg])
                }
                result = .success((try JSONDecoder().decode(Directory.self, from: data), data))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inflight.remove(alias)
                self.apply(alias, result)
            }
        }
    }

    /// One directory landed (from the stream or a one-shot refresh): the
    /// host's rows follow, with a receipt only when something changed.
    private func apply(_ alias: String, _ result: Result<(Directory, Data), Error>) {
        guard let index = hosts.firstIndex(where: { $0.alias == alias }) else { return }
                switch result {
                case .success((let dir, let data)):
                    // An alias that resolves to THIS Mac would list every
                    // local session twice under a host header: not a
                    // remote, dropped with a receipt.
                    if dir.host == ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) {
                        if self.hosts[index].error != Self.selfError {
                            Self.trace?("remote: \(alias) is this Mac (\(dir.host)), ignored")
                            self.hosts[index].isSelf = true
                            self.hosts[index].error = Self.selfError
                            self.hosts[index].directory = nil
                            if let stream = self.streams.removeValue(forKey: alias) { stream.terminate() }
                            self.streamBuffers[alias] = nil
                            self.hosts[index].raw = nil
                            NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                        }
                        return
                    }
                    let changed = self.hosts[index].raw != data
                    // A receipt per SHAPE change (a session or pane came or
                    // went), not per state flip: the stream delivers every
                    // flip and a busy fleet would write the log a few times
                    // a second.
                    let shape = (dir.sessions.count, dir.panes.count)
                    let before = self.hosts[index].directory.map { ($0.sessions.count, $0.panes.count) }
                    arrivals = arrivals.filter { entry in
                        guard let split = Self.split(entry.key), split.alias == alias else { return true }
                        return dir.panes[split.name] != nil
                    }
                    self.hosts[index].directory = dir
                    VigilSessionManager.shared.remoteDirectoryChanged(alias)
                    self.hosts[index].raw = data
                    self.hosts[index].error = nil
                    self.hosts[index].fetched = Date()
                    if changed {
                        if before == nil || before! != shape {
                            Self.trace?("remote: \(alias) = \(dir.host), \(dir.sessions.count) sessions, \(dir.panes.count) panes")
                        }
                        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                    }
                case .failure(let error):
                    let msg = error.localizedDescription
                    if self.hosts[index].error != msg {
                        Self.trace?("remote: \(alias) unreachable: \(msg)")
                        self.hosts[index].error = msg
                        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                    }
                }
    }

    /// The sidebar's rows for every remote host, in `vigil-hosts` order,
    /// built like the local snapshot: session → tabs → panes, program from
    /// the tree argv, state from the token. Everything cold (no local
    /// views exist), row ids namespaced by alias.
    func sidebarRows() -> [VigilSessionManager.SidebarSessionRow] {
        var rows: [VigilSessionManager.SidebarSessionRow] = []
        for host in hosts where !host.isSelf {
            let hostLabel = host.directory?.host ?? host.alias
            let header = host.error.map { "\(hostLabel) (\($0))" } ?? hostLabel
            guard let dir = host.directory else {
                rows.append(.init(
                    id: Self.compositeId(host.alias, ""), emoji: nil, label: "…",
                    stateTag: "remote", attention: .none, states: [], tabs: [], host: header))
                continue
            }
            let sessions = dir.sessions.filter { $0.buriedUntil == nil }
                .sorted { ($0.label.lowercased(), $0.name) < ($1.label.lowercased(), $1.name) }
            for session in sessions {
                let composite = Self.compositeId(host.alias, session.name)
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
                            ?? URL(fileURLWithPath: pane.cwd).lastPathComponent
                        return .init(
                            id: Self.compositeId(host.alias, pane.id),
                            paneId: nil,
                            title: title,
                            program: program,
                            state: state,
                            isDock: offset >= tab.panes.count,
                            emoji: pane.emoji)
                    }
                    let anchor = all.first.map { Self.compositeId(host.alias, $0.id) }
                    let title = tab.label.flatMap { $0.isEmpty ? nil : $0 }
                        ?? URL(fileURLWithPath: tab.panes.first?.cwd ?? "").lastPathComponent
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
    /// Written through `ssh <alias> vigild seen <pane>` only on a seen-FLIP
    /// (unseen done/blocked), never on the presence pulse; the directory is
    /// updated optimistically so the row decays with the glance, and the
    /// next poll confirms it.
    func seen(alias: String, pane: String) {
        guard let index = hosts.firstIndex(where: { $0.alias == alias }),
              let truth = hosts[index].directory?.panes[pane],
              let revision = truth.stateRevision, revision.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let token = truth.state, let state = Self.agentState(token),
              state == .done || state == .blocked,
              (truth.seen ?? 0) < (truth.since ?? 0) else { return }
        let key = "\(alias)/\(pane)"
        guard !seenInFlight.contains(key) else { return }
        seenInFlight.insert(key)
        hosts[index].directory?.panes[pane]?.seen = truth.since
        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T", alias, "vigild", "seen", pane, revision]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            let status: Int32 = (try? proc.run()).map { proc.waitUntilExit(); return proc.terminationStatus } ?? -1
            Task { @MainActor [weak self] in
                self?.seenInFlight.remove(key)
                if status != 0, let self, let index = self.hosts.firstIndex(where: { $0.alias == alias }),
                   self.hosts[index].directory?.panes[pane]?.stateRevision == revision {
                    self.hosts[index].directory?.panes[pane]?.seen = truth.seen
                    NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                }
                Self.trace?("remote: seen \(key)" + (status == 0 ? "" : " FAILED (ssh exit \(status))"))
            }
        }
    }
}
