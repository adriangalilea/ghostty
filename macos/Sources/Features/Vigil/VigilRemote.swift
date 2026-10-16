import Foundation
import VigilHarness
import VigilWire

/// Other Macs' sessions, through this Mac's vigil hub (vigil-agent: the one
/// tether node of app `vigil` here, VigilWire). The Macs are the paired
/// devices running vigil, streamed by the hub as they change; each one's
/// `Directory` (its registry plus per-pane facts) is followed by the hub
/// (`Local` `directory`: a document per change, kept alive across the Mac
/// being out of reach, every step said). Surfaces attach through the same hub
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

    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private var started = false
    private var stopped = false
    /// Each Mac's directory, followed by the hub (its socket to the hub):
    /// the hub keeps it alive across the Mac going out of reach, so the
    /// socket ends only with the hub itself.
    private var following: [String: Int32] = [:]
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
    /// directory is followed (by the hub, which outlives the Mac being out
    /// of reach), a Mac gone takes its rows with it. The hub itself
    /// restarting (vigil-agent deployed) ends every socket: everything is
    /// followed again when its socket appears again (the hub's directory
    /// is watched; the socket is listening by the time it appears).
    func start() {
        guard !started else { return }
        started = true
        followPeers()
    }

    func stop() {
        stopped = true
        hubWatch?.cancel()
        hubWatch = nil
        unfollowAll()
        Self.trace?("remote: directories no longer followed")
    }

    private func unfollowAll() {
        for fd in following.values { shutdown(fd, SHUT_RDWR) }
        following.removeAll()
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
                guard let self else { return }
                Self.trace?("remote: \(why); asking again when the hub's socket changes")
                self.unfollowAll()
                self.awaitHub()
            }
        }
    }

    /// The hub's directory, watched until its socket changes (a hub coming
    /// up renames a listening socket into place): then the Macs are asked
    /// for again. One watch at a time.
    private var hubWatch: DispatchSourceFileSystemObject?
    private func awaitHub() {
        guard !stopped, hubWatch == nil else { return }
        let dir = (VigilPaths.hub as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            Self.trace?("!! remote: cannot watch \(dir) (errno \(errno)); the other Macs stay out of reach until relaunch")
            return
        }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hubWatch?.cancel()
                self.hubWatch = nil
                self.followPeers()
            }
        }
        watch.setCancelHandler { close(fd) }
        hubWatch = watch
        watch.resume()
    }

    private func peers(_ peers: [Local.Peer]) {
        let wanted = Set(peers.map(\.id))
        for (device, fd) in following where !wanted.contains(device) {
            following[device] = nil
            shutdown(fd, SHUT_RDWR)
        }
        hosts.removeAll { !wanted.contains($0.device) }
        arrivals = arrivals.filter { Self.split($0.key).map { wanted.contains($0.device) } ?? false }
        for peer in peers {
            if let index = hosts.firstIndex(where: { $0.device == peer.id }) {
                hosts[index].name = peer.name
            } else {
                hosts.append(Host(device: peer.id, name: peer.name))
            }
            follow(peer.id)
        }
        Self.trace?("remote: Macs \(peers.map(\.name))")
        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
    }

    /// A Mac's directory, followed through the hub: each step a line.
    private func follow(_ device: String) {
        guard !stopped, following[device] == nil, host(device) != nil else { return }
        let fd: Int32
        do { fd = try Self.hub.request(.directory(of: device)) } catch {
            return failed(device, "\(error)")
        }
        following[device] = fd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = Lines.Reader(fd: fd)
            do {
                while let line = try reader.next() {
                    let step = try JSONDecoder().decode(Local.Following.self, from: line)
                    Task { @MainActor [weak self] in self?.stepped(device, step) }
                }
            } catch {
                Task { @MainActor [weak self] in self?.failed(device, "unreadable directory: \(error)") }
            }
            close(fd)
            Task { @MainActor [weak self] in
                guard let self, self.following[device] == fd else { return }
                self.following[device] = nil
                self.failed(device, "this Mac's vigil-agent stopped")
            }
        }
    }

    private func stepped(_ device: String, _ step: Local.Following) {
        switch step.step {
        case .open: Self.trace?("remote: \(host(device)?.name ?? device) following")
        case .directory: if let directory = step.directory { apply(device, directory) }
        case .waiting: failed(device, step.reason ?? "out of reach")
        }
    }

    private func failed(_ device: String, _ why: String) {
        guard let index = hosts.firstIndex(where: { $0.device == device }), hosts[index].error != why else { return }
        Self.trace?("remote: \(hosts[index].name): \(why)")
        hosts[index].error = why
        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
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

    func session(_ composite: String) -> (device: String, session: Registry.Workspace)? {
        guard let (device, name) = Self.split(composite),
              let session = host(device)?.directory?.live.first(where: { $0.name == name })
        else { return nil }
        return (device, session)
    }

    /// One directory landed: the Mac's rows follow, with a receipt only
    /// when something changed.
    private func apply(_ device: String, _ received: Directory) {
        guard let index = hosts.firstIndex(where: { $0.device == device }) else { return }
        let dir = received.projected
        guard hosts[index].directory != dir || hosts[index].error != nil else { return }
        // A receipt per SHAPE change (a session or pane came or went), not
        // per state flip: the stream delivers every flip and a busy fleet
        // would write the log a few times a second.
        let shape = (dir.workspaces.count, dir.panes.count)
        let before = hosts[index].directory.map { ($0.workspaces.count, $0.panes.count) }
        arrivals = arrivals.filter { entry in
            guard let split = Self.split(entry.key), split.device == device else { return true }
            return dir.panes[split.name] != nil
        }
        hosts[index].directory = dir
        VigilSessionManager.shared.remoteDirectoryChanged(device)
        hosts[index].error = nil
        if before.map({ $0 != shape }) ?? true {
            Self.trace?("remote: \(hosts[index].name) = \(dir.host), \(dir.workspaces.count) workspaces, \(dir.panes.count) panes")
        }
        NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
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
                            emoji: pane.emoji,
                            // Another Mac looking at a remote pane is this
                            // one (two Macs): only the phone is news.
                            lookers: truth?.lookers.filter { $0 == .phone } ?? [],
                            priority: pane.priority ?? .normal)
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
