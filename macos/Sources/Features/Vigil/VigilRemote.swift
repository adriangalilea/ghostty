import Foundation
import MachineStates
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
        var pairing: String?
        /// Its last directory as the sidebar projects it (content
        /// receipts dropped: they are the phone's, never a row's).
        var directory: Directory?
        var error: String?
        /// When its last document arrived: live, moments ago; away, when it
        /// was last heard (kept on disk across launches, `KeptDirectory`).
        var received: Date?
        /// Out of reach with a directory still held: drawn as it last was.
        var withheld = false
        var away: Bool { !withheld && error != nil && directory != nil }
        /// Its facts as its app last wrote them (`Open.machine`), followed
        /// beside its directory, or that its last document does not read.
        var machine: VigilMachine.Heard?
        /// The moves it decides and does as their destination
        /// (`Open.moves`), followed beside its directory.
        var moves: [Move.Ticket] = []
    }

    @Published private(set) var hosts: [Host] = []

    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)
    private var started = false
    private var stopped = false
    /// Each Mac's directory, followed by the hub (its socket to the hub):
    /// the hub keeps it alive across the Mac going out of reach, so the
    /// socket ends only with the hub itself.
    private var followIDs: [String: UUID] = [:]
    private var following: [String: Int32] = [:]
    /// Each Mac's state, followed the same way (its socket to the hub).
    private var followingMachine: [String: Int32] = [:]
    private var followingMoves: [String: Int32] = [:]
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
        if let peersSocket { shutdown(peersSocket, SHUT_RDWR) }
        unfollowAll()
        for host in hosts { keep(host.device) }
        remoteLog.info("directories no longer followed")
    }

    // MARK: A Mac that is away is still listed (PORTABILITY.md)

    /// Macs whose directory moved since it was last written to disk.
    private var unkept = Set<String>()
    private var receivedDirectories: [String: Directory] = [:]

    func sourceDirectory(_ device: String) -> Directory? { receivedDirectories[device] ?? host(device)?.directory }

    private var keeping: DispatchWorkItem?

    /// A live directory moves several times a second: it is written when
    /// its Mac goes out of reach, when the app stops, and otherwise half a
    /// minute after its first unwritten change, so a crash of this app loses
    /// at most that of a Mac's last shape.
    private func keepSoon(_ device: String) {
        unkept.insert(device)
        guard keeping == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keeping = nil
                for device in self.unkept { self.keep(device) }
            }
        }
        keeping = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func keep(_ device: String) {
        guard unkept.remove(device) != nil, let host = host(device), let directory = sourceDirectory(device), let received = host.received
        else { return }
        guard let pairing = host.pairing else { return }
        let kept = KeptDirectory(device: device, pairing: pairing, name: host.name, received: received.timeIntervalSince1970, directory: directory)
        DispatchQueue.global(qos: .utility).async {
            do { try kept.write(in: VigilPaths.away) } catch {
                remoteLog.error("directory not kept: this Mac will not be listed once away, after a relaunch", ["host": kept.name, "err": error])
            }
        }
    }

    /// A Mac first heard of in this launch, drawn from what was kept of it
    /// until its own directory arrives.
    private func kept(_ peer: Local.Peer) -> Host {
        var host = Host(device: peer.id, name: peer.name, pairing: peer.pairing)
        do {
            guard let pairing = peer.pairing, let kept = try KeptDirectory.read(peer.id, in: VigilPaths.away),
                  kept.pairing == pairing else { return host }
            receivedDirectories[peer.id] = kept.directory
            host.directory = kept.directory.projected
            host.received = Date(timeIntervalSince1970: kept.received)
            host.error = "not heard yet"
            remoteLog.info("kept directory read", [
                "host": peer.name, "received": kept.received, "workspaces": kept.directory.workspaces.count, "panes": kept.directory.panes.count,
            ])
        } catch {
            remoteLog.error("kept directory unreadable: the Mac is listed empty until it answers", ["host": peer.name, "err": error])
        }
        return host
    }

    private static let awayDay: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("dMMMHHmm")
        return format
    }()
    private static let awayHour: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("HHmm")
        return format
    }()

    /// "away since 9 Nov 02:05", today's as the hour alone.
    static func awaySince(_ received: Date) -> String {
        "away since " + (Calendar.current.isDateInToday(received) ? awayHour : awayDay).string(from: received)
    }

    private func unfollowAll() {
        for fd in following.values { shutdown(fd, SHUT_RDWR) }
        followIDs.removeAll()
        following.removeAll()
        for fd in followingMachine.values { shutdown(fd, SHUT_RDWR) }
        followingMachine.removeAll()
        for fd in followingMoves.values { shutdown(fd, SHUT_RDWR) }
        followingMoves.removeAll()
    }

    /// The hub's Macs stream, one at a time. Each attempt is numbered and its
    /// reader's events are applied on the main queue, which runs them in the
    /// order they were made (a task per event has no such order: a first
    /// line applied after its own stream's end would read open, unwatched
    /// and undialed, for good), and only while that attempt is the one in
    /// hand.
    private enum Peers {
        case idle
        /// Dialed and not yet answered. `changed`: the hub's folder changed
        /// since, so the hub may have come up after this dial was refused.
        case dialing(attempt: Int, changed: Bool)
        case open(attempt: Int)

        func holds(_ asked: Int) -> Bool {
            switch self {
            case .idle: false
            case .dialing(let attempt, _), .open(let attempt): attempt == asked
            }
        }
    }
    private var peersState = Peers.idle
    private var attempts = 0
    /// The stream's socket while it is open: `stop` shuts it. Closed where its
    /// reader's end is applied, on main, so the number is never another's.
    private var peersSocket: Int32?

    /// Dials the hub when nothing is dialed or open. The folder is watched
    /// BEFORE the dial, every time: a hub that comes up between a refused
    /// dial and a watch set after it changes its folder once, unseen, and
    /// nothing dials it again (2026-11-17, a drill: the broker back within
    /// a second, its Mac's dead pane restored a minute later, by an
    /// unrelated event). A dial refused under the watch waits for the
    /// folder's next change; nothing else may wait.
    private func followPeers() {
        guard !stopped, case .idle = peersState else { return }
        attempts += 1
        let attempt = attempts
        peersState = .dialing(attempt: attempt, changed: false)
        awaitHub()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var socket: Int32 = -1
            let failure: (any Error)?
            do {
                let fd = try Self.hub.request(.peers)
                socket = fd
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Nobody to shut it later: shut now, and the read below ends.
                        guard let self, !self.stopped, self.peersState.holds(attempt) else {
                            shutdown(fd, SHUT_RDWR)
                            return
                        }
                        self.peersSocket = fd
                    }
                }
                let reader = Lines.Reader(fd: fd)
                var answered = false
                while let line = try reader.next() {
                    let peers = try JSONDecoder().decode([Local.Peer].self, from: line)
                    let first = !answered
                    answered = true
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.heard(attempt, peers, first: first) }
                    }
                }
                failure = nil
            } catch {
                failure = error
            }
            let dialed = socket
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.ended(attempt, failure)
                    if dialed >= 0 { close(dialed) }
                }
            }
        }
    }

    private func heard(_ attempt: Int, _ peers: [Local.Peer], first: Bool) {
        guard !stopped, peersState.holds(attempt) else { return }
        if first {
            // Open: its folder is no longer watched (the broker replaces
            // files there all day).
            peersState = .open(attempt: attempt)
            hubWatch?.cancel()
            hubWatch = nil
        }
        self.peers(peers)
        // This Mac's mailbox is the hub's to serve, from its first line on.
        if first { VigilMessageStore.shared.hubAnswers() }
        if first { VigilWatchStore.shared.hubAnswers() }
    }

    private func ended(_ attempt: Int, _ failure: (any Error)?) {
        precondition(peersState.holds(attempt), "VigilRemote: attempt \(attempt) ended, in hand \(peersState)")
        // A stream that was open is dialed again at once, under a new watch:
        // no watch stood while it was open, so a hub that came back before
        // this end was applied left no change to wait for. A dial that was
        // never answered is made again only if the folder changed since;
        // otherwise the watch set before it stands.
        let again: Bool
        switch peersState {
        case .open: again = true
        case .dialing(_, let changed): again = changed
        case .idle: preconditionFailure("unreachable: holds(attempt)")
        }
        peersState = .idle
        peersSocket = nil
        unfollowAll()
        VigilMessageStore.shared.hubGone()
        VigilWatchStore.shared.hubGone()
        remoteLog.warn("macs stream ended", [
            "attempt": attempt, "err": failure.map { "\($0)" } ?? "closed by the hub", "next": again ? "dialed again" : "waits for the hub's folder",
        ])
        if again { followPeers() } else { awaitHub() }
    }

    /// The hub's directory, watched while no stream is open (a hub coming
    /// up renames a listening socket into place): a change dials the hub,
    /// or is kept for the end of the dial in flight. One watch at a time.
    private var hubWatch: DispatchSourceFileSystemObject?
    private func awaitHub() {
        guard !stopped, hubWatch == nil else { return }
        let dir = (VigilPaths.hub as NSString).deletingLastPathComponent
        // The folder is the broker's to make; on a Mac where it never ran,
        // there must still be something to watch for its first start.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            remoteLog.error("hub folder not watched; other Macs out of reach until relaunch", ["path": dir, "errno": errno])
            return
        }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.peersState {
                case .dialing(let attempt, _): self.peersState = .dialing(attempt: attempt, changed: true)
                case .idle: self.followPeers()
                // A change made before the first line cancelled this watch,
                // delivered after it: the stream is open, nothing to do.
                case .open: break
                }
            }
        }
        watch.setCancelHandler { close(fd) }
        hubWatch = watch
        watch.resume()
    }

    private func peers(_ peers: [Local.Peer]) {
        let wanted = Set(peers.map(\.id))
        let continuing = Set(peers.filter { peer in host(peer.id)?.pairing == peer.pairing }.map(\.id))
        for device in Set(hosts.map(\.device)).symmetricDifference(wanted) {
            VigilWorkspaces.shared.moveContact(device, waiting: true, recheck: true)
        }
        receivedDirectories = receivedDirectories.filter { continuing.contains($0.key) }
        for (device, fd) in following where !continuing.contains(device) {
            followIDs[device] = nil
            following[device] = nil
            shutdown(fd, SHUT_RDWR)
        }
        for (device, fd) in followingMachine where !continuing.contains(device) {
            followingMachine[device] = nil
            shutdown(fd, SHUT_RDWR)
        }
        for (device, fd) in followingMoves where !continuing.contains(device) {
            followingMoves[device] = nil
            shutdown(fd, SHUT_RDWR)
        }
        hosts.removeAll { !continuing.contains($0.device) }
        arrivals = arrivals.filter { Self.split($0.key).map { continuing.contains($0.device) } ?? false }
        VigilMessageStore.shared.macs(continuing)
        VigilWatchStore.shared.macs(continuing)
        for peer in peers {
            if let index = hosts.firstIndex(where: { $0.device == peer.id }) {
                hosts[index].name = peer.name
            } else {
                hosts.append(kept(peer))
            }
            follow(peer.id)
            followMachine(peer.id)
            followMoves(peer.id)
        }
        VigilMessageStore.shared.macs(wanted)
        VigilWatchStore.shared.macs(wanted)
        remoteLog.info("macs", ["macs": peers.map(\.name)])
        NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
    }

    /// A Mac's directory, followed through the hub: each step a line.
    private func follow(_ device: String) {
        guard !stopped, following[device] == nil, host(device) != nil else { return }
        let fd: Int32
        do { fd = try Self.hub.request(.directory(of: device)) } catch {
            return failed(device, "\(error)")
        }
        let generation = UUID()
        followIDs[device] = generation
        following[device] = fd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = Lines.Reader(fd: fd)
            do {
                while let line = try reader.next() {
                    let step = try JSONDecoder().decode(Local.Following.self, from: line)
                    DispatchQueue.main.async { [weak self] in
                        guard self?.followIDs[device] == generation else { return }
                        self?.stepped(device, step)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard self?.followIDs[device] == generation else { return }
                    self?.failed(device, "unreadable directory: \(error)")
                }
            }
            close(fd)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.followIDs[device] == generation else { return }
                self.followIDs[device] = nil
                self.following[device] = nil
                self.failed(device, "this Mac's vigil-agent stopped")
            }
        }
    }

    /// A Mac's state, followed through the hub: each document a line, kept
    /// alive by the hub across the Mac going out of reach. A document that
    /// does not read (a vigil of another release wrote it) is said, and takes
    /// the place of the last one: that Mac's facts are unavailable, never the
    /// numbers it sent before drawn as if they were current.
    private func followMachine(_ device: String) {
        guard !stopped, followingMachine[device] == nil, host(device) != nil else { return }
        let fd: Int32
        do { fd = try Self.hub.request(.machine(of: device)) } catch {
            return remoteLog.warn("machine state not followed", ["host": host(device)?.name ?? device, "err": error])
        }
        followingMachine[device] = fd
        let pairing = host(device)?.pairing
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = Lines.Reader(fd: fd)
            while let line = try? reader.next() {
                let heard: VigilMachine.Heard
                do { heard = try VigilMachine.read(line) } catch {
                    heard = .unreadable
                    Task { @MainActor in remoteLog.warn("machine state unreadable", ["device": device, "err": error]) }
                }
                Task { @MainActor [weak self] in
                    guard let self, self.host(device)?.pairing == pairing else { return }
                    self.machine(device, heard)
                }
            }
            close(fd)
            Task { @MainActor [weak self] in
                guard let self, self.followingMachine[device] == fd else { return }
                self.followingMachine[device] = nil
            }
        }
    }

    /// A Mac's moves as their destination, followed through the hub as its
    /// state is: each document a line; one that does not read is said and
    /// dropped, the last one stays drawn.
    private func followMoves(_ device: String) {
        guard !stopped, followingMoves[device] == nil, host(device) != nil else { return }
        let fd: Int32
        do { fd = try Self.hub.request(.moves(of: device)) } catch {
            return remoteLog.warn("moves not followed", ["host": host(device)?.name ?? device, "err": error])
        }
        followingMoves[device] = fd
        let pairing = host(device)?.pairing
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = Lines.Reader(fd: fd)
            while let line = try? reader.next() {
                do {
                    let moves = try JSONDecoder().decode([Move.Ticket].self, from: line)
                    Task { @MainActor [weak self] in
                        guard let self, self.host(device)?.pairing == pairing else { return }
                        self.moves(device, moves)
                    }
                } catch {
                    Task { @MainActor in remoteLog.warn("moves unreadable", ["device": device, "err": error]) }
                }
            }
            close(fd)
            Task { @MainActor [weak self] in
                guard let self, self.followingMoves[device] == fd else { return }
                self.followingMoves[device] = nil
            }
        }
    }

    private func moves(_ device: String, _ moves: [Move.Ticket]) {
        guard let index = hosts.firstIndex(where: { $0.device == device }), hosts[index].moves != moves else { return }
        hosts[index].moves = moves
        NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
    }

    private func machine(_ device: String, _ machine: VigilMachine.Heard) {
        VigilWorkspaces.shared.moveContact(device)
        guard let index = hosts.firstIndex(where: { $0.device == device }), hosts[index].machine != machine else { return }
        hosts[index].machine = machine
        NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
    }

    private func stepped(_ device: String, _ step: Local.Following) {
        VigilWorkspaces.shared.moveContact(device, waiting: step.step == .waiting)
        switch step.step {
        case .open: remoteLog.info("following", ["host": host(device)?.name ?? device])
        case .current:
            if host(device)?.error != nil, let held = receivedDirectories[device] { apply(device, held) }
        case .directory: if let directory = step.directory { apply(device, directory) }
        // The panes that moved, onto the directory held (it is whole: a
        // follower always gets a whole document first).
        case .changes:
            guard let changes = step.changes, let held = host(device)?.directory else { return }
            apply(device, held.applying(changes))
        case .withheld:
            guard let i = hosts.firstIndex(where: { $0.device == device }) else { return }
            hosts[i].withheld = true
            hosts[i].error = step.reason ?? "Waiting for approval"
            NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
        case .waiting: failed(device, step.reason ?? "out of reach")
        }
    }

    private func failed(_ device: String, _ why: String) {
        guard let index = hosts.firstIndex(where: { $0.device == device }), hosts[index].error != why else { return }
        hosts[index].withheld = false
        remoteLog.warn("out of reach", ["host": hosts[index].name, "why": why])
        // Away since now, when it was reachable until now: a quiet Mac's
        // last document can be hours old while it was here all along.
        if hosts[index].error == nil, hosts[index].directory != nil {
            hosts[index].received = Date()
            unkept.insert(device)
        }
        hosts[index].error = why
        keep(device)
        NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
    }

    func host(_ device: String) -> Host? { hosts.first { $0.device == device } }

    /// One finite call per user edit. The held directory stream publishes
    /// the result to every viewport; pane proxy streams remain untouched.
    func command(_ device: String, request: VigilSessionControl.Request) async throws -> VigilSessionControl.Reply {
        if let host = host(device), let reason = host.error {
            throw NSError(domain: "VigilRemote", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(host.name): \(reason)"])
        }
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
        receivedDirectories[device] = received
        let wasAway = hosts[index].error != nil
        let dir = received.projected
        guard hosts[index].directory != dir || hosts[index].error != nil else { return }
        // A glance that did not travel or did not read: said once per
        // reason; the row names its pane without it.
        for (pane, facts) in dir.panes where facts.glanceError != hosts[index].directory?.panes[pane]?.glanceError {
            if let why = facts.glanceError {
                remoteLog.warn("glance not read: the pane is named without it", ["host": hosts[index].name, "pane": pane, "err": why])
            }
        }
        // A receipt per SHAPE change (a session or pane came or went), not
        // per state flip: the stream delivers every flip and a busy fleet
        // would write the log a few times a second.
        let shape = (dir.workspaces.count, dir.panes.count)
        let before = hosts[index].directory.map { ($0.workspaces.count, $0.panes.count) }
        arrivals = arrivals.filter { entry in
            guard let split = Self.split(entry.key), split.device == device else { return true }
            return dir.panes[split.name] != nil
        }
        for burial in dir.workspaces where burial.buriedUntil == .distantFuture {
            guard let arrival = burial.moveCheckpoint?.arrival,
                  let local = VigilWorkspaces.shared.workspaces[arrival],
                  local.tabs.flatMap(\.members).contains(where: { $0.from?.device == device && burial.moveCheckpoint?.panes.contains($0.from?.pane ?? "") == true }),
                  hosts[index].directory?.workspaces.first(where: { $0.name == burial.name })?.buriedUntil != .distantFuture else { continue }
            VigilWorkspaces.shared.reportIncompleteMove(local.label, "The source on \(hosts[index].name) changed or could not confirm its conversation here. Its panes remain in Recently Closed there.")
        }
        hosts[index].directory = dir
        hosts[index].received = Date()
        keepSoon(device)
        VigilWorkspaces.shared.remoteDirectoryChanged(device)
        VigilWorkspaces.shared.syncOwnerGrids()
        hosts[index].error = nil
        hosts[index].withheld = false
        if before == nil || wasAway { VigilWorkspaces.shared.resumeMoves(from: device) }
        if before.map({ $0 != shape }) ?? true {
            remoteLog.info("directory", [
                "host": hosts[index].name, "home": dir.host, "workspaces": dir.workspaces.count, "panes": dir.panes.count,
            ])
        }
        NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
    }

    /// The sidebar's rows for every remote Mac, built like the local
    /// snapshot: session → tabs → panes, program and state by the rules
    /// every row follows (`Program`, `AgentState`). Everything captured
    /// (no local views exist), row ids namespaced by the Mac.
    func sidebarRows() -> [VigilWorkspaces.SidebarWorkspaceRow] {
        var rows: [VigilWorkspaces.SidebarWorkspaceRow] = []
        for host in hosts {
            let hostLabel = host.directory?.host ?? host.name
            // Away, the header says since when; the reason is the log's (and
            // the row's tooltip would repeat "no path to …" on every row).
            let header = VigilWorkspaces.SidebarWorkspaceRow.HostHeader(
                name: hostLabel,
                standing: host.away ? host.received.map(Self.awaySince) ?? host.error : host.error,
                renewalURL: host.withheld ? VigilWire.renewalLink(refusal: host.error, root: host.device) : nil,
                machine: host.machine)
            guard let dir = host.directory else {
                rows.append(.init(
                    id: Self.compositeId(host.device, ""), emoji: nil, label: "…",
                    stateTag: "remote", attention: .none, states: [], tabs: [], host: header))
                continue
            }
            // An away Mac's workspaces by what last mattered; a live one's in
            // its own order.
            for session in host.away ? dir.byLastActivity : dir.ordered {
                let composite = Self.compositeId(host.device, session.name)
                var tabs: [VigilWorkspaces.SidebarTab] = []
                for (index, tab) in (session.tabs ?? []).enumerated() {
                    let all = tab.members
                    guard !all.isEmpty else { continue }
                    let panes = all.enumerated().map { offset, pane -> VigilWorkspaces.SidebarPane in
                        let truth = dir.panes[pane.id]
                        let program = truth?.program
                        return .init(
                            id: Self.compositeId(host.device, pane.id),
                            paneId: nil,
                            title: dir.title(of: pane),
                            messageAlias: pane.label ?? (all.count == 1 ? tab.label : nil),
                            program: program,
                            state: truth?.shown,
                            isDock: offset >= tab.panes.count,
                            emoji: pane.emoji,
                            // Another Mac looking at a remote pane is this
                            // one (two Macs): only the phone is news.
                            lookers: truth?.lookers.filter { $0 == .phone } ?? [],
                            priority: pane.priority ?? .normal,
                            conversationRef: truth?.meaning?.reference,
                            conversationName: truth?.meaning?.title,
                            resumeMenu: truth?.meaning?.resumeMenu,
                            account: truth?.meaning?.account,
                            liveConversation: !host.away && host.error == nil && truth?.alive == true ? truth?.meaning?.reference : nil,
                            forkedFrom: truth?.meaning?.forkedFrom,
                            member: truth?.meaning?.member,
                            background: truth?.meaning?.background,
                            ended: truth?.abnormalEnd,
                            problems: (truth?.liveProblems ?? []) + [session.offlineContinuations?[pane.id]?.problem].compactMap { $0 },
                            restart: truth?.problemGlance?.restart,
                            conflict: truth?.conflict)
                    }
                    let anchor = all.first.map { Self.compositeId(host.device, $0.id) }
                    tabs.append(.init(
                        id: VigilWorkspaces.tabRowId(composite, anchor: anchor, index: index),
                        title: dir.title(ofTab: index, in: session),
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
                    stateTag: host.away ? "away" : "remote",
                    attention: states.contains(.blocked) ? .input : (states.contains(.done) ? .done : .none),
                    states: PaneDot.cluster(tabs.flatMap(\.panes).flatMap(\.dots)),
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
              let revision = truth.unseenRevision,
              let since = truth.since,
              VigilWorkspaces.personActed(after: Date(timeIntervalSince1970: since)) else { return }
        let key = "\(device)/\(pane)"
        guard !seenInFlight.contains(key) else { return }
        seenInFlight.insert(key)
        hosts[index].directory?.panes[pane]?.seen = truth.since
        NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
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
                    NotificationCenter.default.post(name: VigilWorkspaces.stateDidChange, object: nil)
                }
                if let failure {
                    remoteLog.warn("seen not written", ["pane": key, "err": failure])
                } else {
                    remoteLog.info("seen", ["pane": key])
                }
            }
        }
    }
}
