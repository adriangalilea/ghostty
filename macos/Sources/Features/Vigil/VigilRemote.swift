import Foundation

/// Other Macs' sessions, read through ssh. ONE source: `ssh <alias> vigild
/// dir` returns the machine's registry (vigil.json verbatim) plus per-pane
/// process truth (alive, agent state token, tree argv), polled on a slow
/// tick per alias and on demand. Nothing here owns anything: a remote
/// session is a VIEWPORT target only (mounted as mirror surfaces attached
/// through `ssh <alias> vigild proxy <pane>`), never persisted, killed or
/// buried from this Mac. Reachability, keys and the network are the
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
    }

    struct PaneTruth: Decodable, Equatable {
        var alive: Bool
        var state: String?
        var tree: [String]?
        var pid: String?
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
    }

    @Published private(set) var hosts: [Host] = []
    static var trace: ((String) -> Void)?

    private var timer: Timer?
    private var inflight = Set<String>()

    /// Session ids of remote sessions are namespaced by alias so they can
    /// never collide with local ones: `alias/name`.
    static func compositeId(_ alias: String, _ name: String) -> String { "\(alias)/\(name)" }

    static func split(_ composite: String) -> (alias: String, name: String)? {
        guard let slash = composite.firstIndex(of: "/") else { return nil }
        return (String(composite[..<slash]), String(composite[composite.index(after: slash)...]))
    }

    func configure(aliases: [String]) {
        let known = Set(hosts.map(\.alias))
        let wanted = Set(aliases)
        hosts.removeAll { !wanted.contains($0.alias) }
        for alias in aliases where !known.contains(alias) {
            hosts.append(Host(alias: alias))
        }
        timer?.invalidate()
        timer = nil
        guard !aliases.isEmpty else { return }
        Self.trace?("remote: hosts \(aliases)")
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func refreshAll() {
        for host in hosts { refresh(host.alias) }
    }

    func host(_ alias: String) -> Host? { hosts.first { $0.alias == alias } }

    func session(_ composite: String) -> (alias: String, session: Session)? {
        guard let (alias, name) = Self.split(composite),
              let session = host(alias)?.directory?.sessions.first(where: { $0.name == name })
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
                guard let self, let index = self.hosts.firstIndex(where: { $0.alias == alias }) else { return }
                self.inflight.remove(alias)
                switch result {
                case .success((let dir, let data)):
                    // An alias that resolves to THIS Mac would list every
                    // local session twice under a host header: not a
                    // remote, dropped with a receipt.
                    if dir.host == ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) {
                        if self.hosts[index].error != "this Mac" {
                            Self.trace?("remote: \(alias) is this Mac (\(dir.host)), ignored")
                            self.hosts[index].error = "this Mac"
                            self.hosts[index].directory = nil
                            self.hosts[index].raw = nil
                            NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
                        }
                        return
                    }
                    let changed = self.hosts[index].raw != data
                    self.hosts[index].directory = dir
                    self.hosts[index].raw = data
                    self.hosts[index].error = nil
                    self.hosts[index].fetched = Date()
                    if changed {
                        Self.trace?("remote: \(alias) = \(dir.host), \(dir.sessions.count) sessions, \(dir.panes.count) panes")
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
        }
    }

    /// The sidebar's rows for every remote host, in `vigil-hosts` order,
    /// built like the local snapshot: session → tabs → panes, program from
    /// the tree argv, state from the token. Everything cold (no local
    /// views exist), row ids namespaced by alias.
    func sidebarRows() -> [VigilSessionManager.SidebarSessionRow] {
        var rows: [VigilSessionManager.SidebarSessionRow] = []
        for host in hosts {
            let hostLabel = host.directory?.host ?? host.alias
            let header = host.error.map { "\(hostLabel) (\($0))" } ?? hostLabel
            guard let dir = host.directory else {
                rows.append(.init(
                    id: Self.compositeId(host.alias, ""), emoji: nil, label: "…",
                    stateTag: "remote", attention: .none, states: [], tabs: [], host: header))
                continue
            }
            let sessions = dir.sessions.sorted { ($0.label.lowercased(), $0.name) < ($1.label.lowercased(), $1.name) }
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
                        let state = truth?.state.flatMap { Self.agentState($0) }
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
                    attention: .none,
                    states: VigilSessionManager.clusterStates(tabs.flatMap(\.panes).compactMap(\.state)),
                    tabs: tabs,
                    host: header))
            }
        }
        return rows
    }

    /// The state file's first token; a flavor may follow.
    static func agentState(_ token: String) -> VigilSessionManager.AgentState? {
        switch token.split(separator: " ").first.map(String.init) ?? "" {
        case "working": return .working
        case "blocked": return .blocked
        case "done": return .done
        case "idle": return .idle
        default: return nil
        }
    }
}
