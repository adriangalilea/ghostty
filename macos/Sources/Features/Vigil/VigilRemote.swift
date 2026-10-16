import Foundation
import VigilHarness
import VigilWire

/// Other Macs' sessions, through this Mac's vigil hub (vigil-agent: the one
/// tether node of app `vigil` here, VigilWire). The Macs are the paired
/// devices running vigil, streamed by the hub as they change; each one's
/// `Directory` (its registry plus per-pane facts) arrives as a `dir`
/// stream, one document per change. Surfaces attach through the same hub
/// (the Zig attach opens `proxy` itself). Structural intent is a `session`
/// call: the home app commits it and the directory stream projects it
/// here. This Mac never writes the home registry. Who may reach whom is
/// tether's pairing, nothing configured here.
@MainActor
final class VigilRemote: ObservableObject {
    static let shared = VigilRemote()

    /// A paired Mac running vigil, by its tether root.
    struct Host {
        let device: String
        var name: String
        /// Its last directory as the sidebar projects it (content
        /// receipts dropped: they are the phone's, never a row's).
        var directory: Directory?
        var error: String?
    }

    @Published private(set) var hosts: [Host] = []
    static var trace: ((String) -> Void)?

    private nonisolated static let hub = Local.Client(socket: HarnessPaths.hub)
    private var started = false
    private var stopped = false
    /// The open directory stream per Mac (its socket to the hub).
    private var streams: [String: FileHandle] = [:]
    private var lines: [String: Lines] = [:]
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
        lines.removeAll()
        Self.trace?("remote: directory streams stopped")
    }

    private func followPeers() {
        guard !stopped else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let why: String
            do {
                let fd = try Self.hub.request(.peers)
                defer { close(fd) }
                let reader = Lines.Reader(fd: fd)
                while let line = try reader.next() {
                    let peers = try JSONDecoder().decode([Local.Peer].self, from: line)
                    Task { @MainActor [weak self] in self?.peers(peers) }
                }
                why = "the hub closed the Macs stream"
            } catch {
                why = "hub: \(error)"
            }
            Task { @MainActor [weak self] in
                Self.trace?("remote: \(why); asking again in 5s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self?.followPeers() } }
            }
        }
    }

    private func peers(_ peers: [Local.Peer]) {
        let wanted = Set(peers.map(\.id))
        for (device, handle) in streams where !wanted.contains(device) {
            streams[device] = nil; lines[device] = nil; try? handle.close()
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
            let result = Result { try Self.hub.request(.open(device: device, .dir)) }
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
                                self.lines[device] = nil
                                self.ended(device, "stream ended")
                            } else {
                                self.streamed(device, data)
                            }
                        }
                    }
                    self.streams[device] = handle
                    self.lines[device] = Lines()
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

    /// Bytes off the stream: each whole line is a directory document.
    private func streamed(_ device: String, _ data: Data) {
        do {
            for line in try lines[device, default: Lines()].append(data) {
                apply(device, Result { try JSONDecoder().decode(Directory.self, from: line) })
            }
        } catch {
            apply(device, .failure(error))
        }
    }

    func host(_ device: String) -> Host? { hosts.first { $0.device == device } }

    /// One finite call per user edit. The held directory stream publishes
    /// the result to every viewport; pane proxy streams remain untouched.
    func command(_ device: String, request: VigilSessionControl.Request) async throws -> VigilSessionControl.Reply {
        let payload = try JSONEncoder().encode(request) + Data([10])
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.hub.call(device: device, .session(payload))
        }.value
        let reply = try JSONDecoder().decode(VigilSessionControl.Reply.self, from: data)
        guard reply.id == request.id else {
            throw NSError(domain: "VigilSessionControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "The home reply did not match this command."])
        }
        return reply
    }

    func session(_ composite: String) -> (device: String, session: Registry.Session)? {
        guard let (device, name) = Self.split(composite),
              let session = host(device)?.directory?.live.first(where: { $0.name == name })
        else { return nil }
        return (device, session)
    }

    /// One directory landed: the Mac's rows follow, with a receipt only
    /// when something changed.
    private func apply(_ device: String, _ result: Result<Directory, Error>) {
        guard let index = hosts.firstIndex(where: { $0.device == device }) else { return }
        switch result {
        case .success(let received):
            let dir = received.projected
            guard hosts[index].directory != dir || hosts[index].error != nil else { return }
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
            if before.map({ $0 != shape }) ?? true {
                Self.trace?("remote: \(hosts[index].name) = \(dir.host), \(dir.sessions.count) sessions, \(dir.panes.count) panes")
            }
            NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
        case .failure(let error):
            let msg = "unreadable directory: \(error)"
            if hosts[index].error != msg {
                Self.trace?("!! remote: \(hosts[index].name) \(msg)")
                hosts[index].error = msg
                NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
            }
        }
    }

    /// The sidebar's rows for every remote Mac, built like the local
    /// snapshot: session → tabs → panes, program and state by the rules
    /// every row follows (`Program`, `AgentState`). Everything captured
    /// (no local views exist), row ids namespaced by the Mac.
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
            for session in dir.ordered {
                let composite = Self.compositeId(host.device, session.name)
                var tabs: [VigilSessionManager.SidebarTab] = []
                for (index, tab) in (session.tabs ?? []).enumerated() {
                    let all = tab.members
                    guard !all.isEmpty else { continue }
                    let panes = all.enumerated().map { offset, pane -> VigilSessionManager.SidebarPane in
                        let truth = dir.panes[pane.id]
                        let program = truth?.program
                        let title = pane.label
                            ?? program
                            ?? pane.command.flatMap(Program.label)
                            ?? pane.title
                            ?? (pane.cwd as NSString).lastPathComponent
                        return .init(
                            id: Self.compositeId(host.device, pane.id),
                            paneId: nil,
                            title: title,
                            program: program,
                            state: truth?.shown,
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
                let states = tabs.flatMap(\.panes).compactMap(\.state)
                rows.append(.init(
                    id: composite,
                    emoji: session.emoji,
                    label: session.label,
                    stateTag: "remote",
                    attention: states.contains(.blocked) ? .input : (states.contains(.done) ? .done : .none),
                    states: AgentState.cluster(states),
                    tabs: tabs,
                    host: header))
            }
        }
        return rows
    }

    private var seenInFlight = Set<String>()

    /// A remote console is under the eyes here: the ack belongs to ITS Mac.
    /// Written through a `seen` call only on a seen-FLIP (an outcome not yet
    /// seen), never on the presence pulse; the directory is updated
    /// optimistically so the row decays with the glance, and the Mac's next
    /// document confirms it.
    func seen(device: String, pane: String) {
        guard let index = hosts.firstIndex(where: { $0.device == device }),
              let truth = hosts[index].directory?.panes[pane],
              let revision = truth.unseenRevision else { return }
        let key = "\(device)/\(pane)"
        guard !seenInFlight.contains(key) else { return }
        seenInFlight.insert(key)
        hosts[index].directory?.panes[pane]?.seen = truth.since
        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let failure: String?
            do {
                _ = try Self.hub.call(device: device, .seen(pane, revision: revision))
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
}
