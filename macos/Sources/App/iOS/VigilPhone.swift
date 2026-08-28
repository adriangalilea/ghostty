import Foundation
import CryptoKit
import NIOSSH
import OSLog
import Security

/// The phone's model: the Macs it knows (ssh endpoints), one ed25519 key
/// born on first launch and kept in the Keychain, each Mac's directory
/// (`vigild dir`, the same document the Mac's own remote sidebar reads)
/// rendered as the sidebar's tree, and the attach path (an fd from
/// `vigild proxy <pane>`). Nothing here owns a session: the phone is a
/// viewport, every fact stays on the Mac.
@MainActor
final class VigilPhone: ObservableObject {
    static let shared = VigilPhone()
    private static let logger = Logger(subsystem: "com.adriangalilea.vigil", category: "phone")

    struct Host: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var hostname: String
        var port: Int = 22
        var user: String
        var endpoint: VigilSSH.Endpoint { .init(host: hostname, port: port, user: user) }
    }

    // The Mac's directory document (vigild dir).
    struct Pane: Decodable {
        let id: String
        var cwd: String
        var title: String?
        var label: String?
        var emoji: String?
        var command: String?
    }
    struct Dock: Decodable { var panes: [Pane] }
    struct Tab: Decodable {
        var panes: [Pane]
        var label: String?
        var emoji: String?
        var dock: Dock?
    }
    struct Session: Decodable {
        let name: String
        var label: String
        var emoji: String?
        var order: Int?
        var tabs: [Tab]?
    }
    struct PaneTruth: Decodable {
        var alive: Bool
        var state: String?
        var tree: [String]?
    }
    struct Directory: Decodable {
        var host: String
        var sessions: [Session]
        var panes: [String: PaneTruth]
    }

    /// One row of the tree, flattened (session / tab / pane), the same
    /// order and naming as the Mac's sidebar and `vigil tree`.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case session, tab, pane }
        let id: String
        let kind: Kind
        let depth: Int
        let title: String
        let emoji: String?
        let state: String?     // working / blocked / done / idle
        let alive: Bool
        let paneId: String?
        let session: String
    }

    @Published var hosts: [Host] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(hosts), forKey: "vigil.hosts") }
    }
    @Published private(set) var directories: [UUID: Directory] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var trace: [String] = []
    let key: Curve25519.Signing.PrivateKey
    private var connections: [UUID: VigilSSH] = [:]
    private var timer: Timer?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "vigil.hosts"),
           let saved = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = saved
        } else {
            hosts = []
        }
        key = Self.loadOrMintKey()
        VigilSSH.trace = { [weak self] line in Task { @MainActor in self?.log(line) } }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    /// Every receipt goes three ways: the in-app list, os_log (Console /
    /// `log stream`), and stderr (`devicectl … launch --console` over the
    /// cable). Nothing happens in this app without a line here.
    func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        Self.logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data("vigil: \(line)\n".utf8))
        trace.append("\(stamp) \(line)")
        if trace.count > 400 { trace.removeFirst(trace.count - 400) }
    }

    var publicKeyLine: String { key.openSSHPublicLine }

    // MARK: Key (Keychain-held, minted once)

    private static func loadOrMintKey() -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "vigil.ssh",
            kSecAttrAccount as String: "ed25519",
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "vigil.ssh",
            kSecAttrAccount as String: "ed25519",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        SecItemAdd(add as CFDictionary, nil)
        return key
    }

    // MARK: Connections

    /// Host keys are trusted on first use, per hostname, remembered by
    /// their serialized bytes. A changed key is REFUSED with a receipt;
    /// forget it from the host's settings to re-trust.
    /// Stored as the OpenSSH public-key line, per hostname (v2: the v1
    /// store held a reflection string and is ignored).
    private func trust(_ host: Host, _ fingerprint: String) -> Bool {
        let store = "vigil.hostkey2.\(host.hostname)"
        if let known = UserDefaults.standard.string(forKey: store) {
            if known == fingerprint { return true }
            Task { @MainActor in self.log("ssh: HOST KEY CHANGED for \(host.hostname), refused") }
            return false
        }
        UserDefaults.standard.set(fingerprint, forKey: store)
        Task { @MainActor in self.log("ssh: trusting \(host.hostname) on first use") }
        return true
    }

    func forgetHostKey(_ host: Host) {
        UserDefaults.standard.removeObject(forKey: "vigil.hostkey2.\(host.hostname)")
        log("ssh: forgot host key for \(host.hostname)")
        connections[host.id]?.close()
        connections[host.id] = nil
        errors[host.id] = nil
    }

    /// The live connection to a Mac, made on demand. Liveness is the
    /// connection's own published `state` (never a Channel read); a
    /// connection that closed is dropped here on its own report.
    func connection(for host: Host) async throws -> VigilSSH {
        if let live = connections[host.id], live.state == .connected, live.endpoint == host.endpoint { return live }
        connections[host.id]?.close()
        connections[host.id] = nil
        let ssh = VigilSSH(endpoint: host.endpoint, key: key) { [weak self] line in
            guard let self else { return false }
            return self.trust(host, line)
        }
        ssh.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .closed(let why) = state, self.connections[host.id] === ssh {
                self.connections[host.id] = nil
                self.errors[host.id] = why
            }
        }
        try await ssh.connect()
        connections[host.id] = ssh
        return ssh
    }

    // MARK: Directory

    func refreshAll() {
        for host in hosts { Task { await refresh(host) } }
    }

    private var refreshing = Set<UUID>()

    func refresh(_ host: Host) async {
        guard !refreshing.contains(host.id) else { return }
        refreshing.insert(host.id)
        defer { refreshing.remove(host.id) }
        do {
            let ssh = try await connection(for: host)
            let data = try await ssh.exec("vigild dir")
            let dir = try JSONDecoder().decode(Directory.self, from: data)
            directories[host.id] = dir
            errors[host.id] = nil
            log("dir: \(host.name) = \(dir.host), \(dir.sessions.count) sessions, \(dir.panes.count) panes")
        } catch {
            errors[host.id] = error.localizedDescription
            log("dir: \(host.name): \(error.localizedDescription)")
            connections[host.id]?.close()
            connections[host.id] = nil
        }
    }

    /// The tree rows for one Mac, sidebar order.
    func rows(for host: Host) -> [Row] {
        guard let dir = directories[host.id] else { return [] }
        var out: [Row] = []
        let sessions = dir.sessions.sorted { ($0.order ?? 0, $0.label) < ($1.order ?? 0, $1.label) }
        for s in sessions {
            let tabs = s.tabs ?? []
            let ids = tabs.flatMap { $0.panes.map(\.id) + ($0.dock?.panes.map(\.id) ?? []) }
            let anyAlive = ids.contains { dir.panes[$0]?.alive ?? false }
            let states = ids.compactMap { dir.panes[$0]?.state?.split(separator: " ").first.map(String.init) }
            out.append(Row(id: s.name, kind: .session, depth: 0, title: s.label, emoji: s.emoji,
                           state: Self.rollup(states), alive: anyAlive, paneId: nil, session: s.name))
            for (ti, t) in tabs.enumerated() {
                let showTab = tabs.count > 1 || t.label != nil || t.emoji != nil
                if showTab {
                    let name = t.label ?? URL(fileURLWithPath: t.panes.first?.cwd ?? "").lastPathComponent
                    out.append(Row(id: "\(s.name)/t\(ti)", kind: .tab, depth: 1,
                                   title: name.isEmpty ? "tab \(ti + 1)" : name, emoji: t.emoji,
                                   state: nil, alive: true, paneId: nil, session: s.name))
                }
                for p in t.panes + (t.dock?.panes ?? []) {
                    let truth = dir.panes[p.id]
                    let program = Self.program(truth?.tree)
                    let title = p.label ?? program
                        ?? p.command.map { String($0.split(separator: " ").first ?? "").split(separator: "/").last.map(String.init) ?? $0 }
                        ?? p.title ?? URL(fileURLWithPath: p.cwd).lastPathComponent
                    out.append(Row(id: p.id, kind: .pane, depth: showTab ? 2 : 1, title: title, emoji: p.emoji,
                                   state: truth?.state?.split(separator: " ").first.map(String.init),
                                   alive: truth?.alive ?? false, paneId: p.id, session: s.name))
                }
            }
        }
        return out
    }

    private static let shells: Set<String> = ["fish", "bash", "zsh", "sh", "login", "caffeinate"]
    private static func program(_ tree: [String]?) -> String? {
        var out: String?
        for line in tree ?? [] {
            let argv = line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? ""
            let first = argv.split(separator: " ").first.map(String.init) ?? ""
            let base = String(first.split(separator: "/").last ?? "")
            if base.isEmpty || base.hasPrefix("-") || base.hasSuffix(":") || shells.contains(base) { continue }
            if ["node", "python", "python3", "ruby", "bun", "deno", "tsx"].contains(base) {
                let script = argv.split(separator: " ").dropFirst()
                    .first { !$0.hasPrefix("-") && !$0.contains("=") && $0.contains(".") }
                out = script.map { String($0.split(separator: "/").last ?? $0) } ?? base
            } else {
                out = base
            }
        }
        return out
    }

    /// blocked > working > done > idle, the sidebar's cluster head.
    private static func rollup(_ states: [String]) -> String? {
        for s in ["blocked", "working", "done"] where states.contains(s) { return s }
        return states.isEmpty ? nil : "idle"
    }

    // MARK: Attach

    /// A live stream to one pane, as an fd for the Attach backend.
    func attach(_ host: Host, pane: String) async throws -> Int32 {
        let ssh = try await connection(for: host)
        let fd = try await ssh.stream("vigild proxy \(pane)")
        log("attach: \(host.name) \(pane) fd \(fd)")
        return fd
    }
}
