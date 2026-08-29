import Foundation
import CryptoKit
import GhosttyKit
import Network
import NIOSSH
import OSLog
import Security

/// Receipts, observed by the settings sheet ALONE.
@MainActor
final class VigilReceipts: ObservableObject {
    @Published private(set) var lines: [String] = []
    func append(_ line: String) {
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }
}

/// A pane on a Mac, the navigation value the tree hands to the pane screen.
struct PaneRef: Hashable {
    let host: VigilPhone.Host
    let pane: String
    let title: String

    /// Identity is the Mac and the pane; the title is display.
    static func == (a: PaneRef, b: PaneRef) -> Bool { a.host.id == b.host.id && a.pane == b.pane }
    func hash(into h: inout Hasher) { h.combine(host.id); h.combine(pane) }
}

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
        /// "rows cols", the owner's pty grid (a preview renders it scaled).
        var size: String?
        var grid: (rows: Int, cols: Int)? {
            let p = (size ?? "").split(separator: " ").compactMap { Int($0) }
            return p.count == 2 && p[0] > 0 && p[1] > 0 ? (p[0], p[1]) : nil
        }
    }
    struct Directory: Decodable {
        var host: String
        var sessions: [Session]
        var panes: [String: PaneTruth]
    }

    @Published var hosts: [Host] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(hosts), forKey: "vigil.hosts")
            rebuildTree()
        }
    }
    /// Directories and errors publish; the TREE is derived once per change
    /// (never in a body), and receipts live in their own object so a log
    /// line can never re-render the tree (every receipt re-rendered every
    /// row and taps died mid-update, 2026-08-28).
    private(set) var directories: [UUID: Directory] = [:] { didSet { rebuildTree() } }
    private(set) var errors: [UUID: String] = [:] { didSet { rebuildTree() } }
    @Published private(set) var nodes: [Node] = []
    let receipts = VigilReceipts()
    var trace: [String] { receipts.lines }
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
        Ghostty.SurfaceView.trace = { [weak self] line in Task { @MainActor in self?.log(line) } }
        // The directory is polled every 15s on the tree and every 3s while
        // a pane is on screen: a MIRROR draws the grid `dir` last reported,
        // and a Mac window settling its size stepped the pty a dozen
        // times while the phone lagged 15s behind each (2026-08-29).
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ticks += 1
                if self.presenting != nil || self.ticks % 5 == 0 { self.refreshAll() }
            }
        }
    }
    private var ticks = 0

    /// Every receipt goes three ways: the in-app list, os_log (Console /
    /// `log stream`), and stderr (`devicectl … launch --console` over the
    /// cable). Nothing happens in this app without a line here.
    func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        Self.logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data("vigil: \(line)\n".utf8))
        receipts.append("\(stamp) \(line)")
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
            var ssh = try await connection(for: host)
            var data: Data
            do {
                data = try await ssh.exec("vigild dir")
            } catch VigilSSH.Failure.timeout {
                // Dead under us (network change): dial again, once.
                ssh = try await connection(for: host)
                data = try await ssh.exec("vigild dir")
            }
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

    /// The home tree: hosts → sessions → tabs → panes, one collapsible
    /// tree with the sidebar's rollup semantics (a collapsed node wears
    /// its descendants' state cluster: distinct active states, blocked
    /// first, capped at 4; idle only when idle is all there is).
    struct Node: Identifiable, Equatable {
        enum Kind: Equatable { case host, session, tab, pane }
        let id: String
        let kind: Kind
        let title: String
        var subtitle: String? = nil
        var emoji: String? = nil
        /// A pane's own state; nodes above carry the cluster.
        var state: String? = nil
        var alive: Bool = true
        var pane: PaneRef? = nil
        /// The owner's grid, for the row's live preview.
        var rows: Int = 0
        var cols: Int = 0
        var children: [Node] = []

        /// The cluster this node shows when collapsed (its own state for a
        /// pane), the sidebar's rule.
        var cluster: [String] {
            if kind == .pane { return alive ? [state ?? "idle"] : [] }
            let all = children.flatMap { $0.leafStates }
            let active = all.filter { $0 != "idle" }
                .sorted { Self.rank($0) > Self.rank($1) }
            var seen = Set<String>()
            let distinct = active.filter { seen.insert($0).inserted }
            if !distinct.isEmpty { return Array(distinct.prefix(4)) }
            return all.isEmpty ? [] : ["idle"]
        }
        var leafStates: [String] {
            if kind == .pane { return alive ? [state ?? "idle"] : [] }
            return children.flatMap { $0.leafStates }
        }
        /// Every pane node under this one.
        var leaves: [Node] {
            if kind == .pane { return [self] }
            return children.flatMap { $0.leaves }
        }
        static func rank(_ s: String) -> Int {
            switch s { case "blocked": return 3; case "working": return 2; case "done": return 1; default: return 0 }
        }
    }

    /// Collapse state, persisted: node ids the user folded.
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "vigil.collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "vigil.collapsed") }
    }

    func tree() -> [Node] { nodes }

    private func rebuildTree() {
        let fresh = deriveTree()
        guard fresh != nodes else { return }
        nodes = fresh
        indexTree()
    }

    private func deriveTree() -> [Node] {
        hosts.map { host in
            let dir = directories[host.id]
            var node = Node(id: "host:\(host.id.uuidString)", kind: .host,
                            title: dir?.host ?? host.name,
                            subtitle: errors[host.id] ?? (dir == nil ? "connecting…" : nil))
            guard let dir else { return node }
            let sessions = dir.sessions.sorted { ($0.order ?? 0, $0.label) < ($1.order ?? 0, $1.label) }
            node.children = sessions.map { s in
                let tabs = s.tabs ?? []
                let sid = "\(host.id.uuidString)/\(s.name)"
                var sess = Node(id: sid, kind: .session, title: s.label, emoji: s.emoji)
                func paneNode(_ p: Pane) -> Node {
                    let truth = dir.panes[p.id]
                    let program = Self.program(truth?.tree)
                    let title = p.label ?? program
                        ?? p.command.map { String($0.split(separator: " ").first ?? "").split(separator: "/").last.map(String.init) ?? $0 }
                        ?? p.title ?? URL(fileURLWithPath: p.cwd).lastPathComponent
                    let alive = truth?.alive ?? false
                    return Node(id: "\(sid)/\(p.id)", kind: .pane, title: title, emoji: p.emoji,
                                state: truth?.state?.split(separator: " ").first.map(String.init),
                                alive: alive,
                                pane: alive ? PaneRef(host: host, pane: p.id, title: title) : nil,
                                rows: truth?.grid?.rows ?? 0, cols: truth?.grid?.cols ?? 0)
                }
                for (ti, t) in tabs.enumerated() {
                    let all = t.panes + (t.dock?.panes ?? [])
                    let showTab = tabs.count > 1 || t.label != nil || t.emoji != nil
                    if showTab {
                        let name = t.label ?? URL(fileURLWithPath: t.panes.first?.cwd ?? "").lastPathComponent
                        var tab = Node(id: "\(sid)/t\(ti)", kind: .tab, title: name.isEmpty ? "tab \(ti + 1)" : name, emoji: t.emoji)
                        tab.children = all.map(paneNode)
                        sess.children.append(tab)
                    } else {
                        sess.children.append(contentsOf: all.map(paneNode))
                    }
                }
                return sess
            }
            return node
        }
    }

    private static let shells: Set<String> = ["fish", "bash", "zsh", "sh", "login", "caffeinate"]
    nonisolated private static func program(_ tree: [String]?) -> String? {
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

    // MARK: Discovery (Bonjour: the Macs on THIS network)

    /// A Mac advertising ssh on the local network (macOS Remote Login
    /// publishes `_ssh._tcp`). Its `.local` name resolves on any LAN the
    /// phone shares with it: a hotel's wifi, the phone's own hotspot.
    struct DiscoveredMac: Identifiable, Equatable {
        var id: String { name }
        let name: String
        var hostname: String { "\(name).local" }
    }
    @Published private(set) var discovered: [DiscoveredMac] = []
    private var browser: NWBrowser?

    func startDiscovery() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { r -> DiscoveredMac? in
                if case .service(let name, _, _, _) = r.endpoint { return DiscoveredMac(name: name) }
                return nil
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                if macs != self.discovered {
                    self.discovered = macs
                    self.log("bonjour: \(macs.map(\.name))")
                }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state { Task { @MainActor in self?.log("bonjour: failed \(err)") } }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    // MARK: URLs (vigil://<host>/<session>/<pane>)

    /// The landing for an alert: resolve a host by name or hostname, make
    /// sure its directory is loaded, and hand back the pane to show.
    func resolve(url: URL) async -> PaneRef? {
        guard url.scheme == "vigil", let hostName = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else { log("url: \(url) wants /<session>/<pane>"); return nil }
        let (session, pane) = (parts[0], parts[1])
        guard let host = hosts.first(where: {
            $0.name.caseInsensitiveCompare(hostName) == .orderedSame
                || $0.hostname.caseInsensitiveCompare(hostName) == .orderedSame
                || $0.hostname.caseInsensitiveCompare("\(hostName).local") == .orderedSame
                || (directories[$0.id]?.host).map { $0.caseInsensitiveCompare(hostName) == .orderedSame } ?? false
        }) else { log("url: no Mac named \(hostName)"); return nil }
        if directories[host.id] == nil { await refresh(host) }
        let title = nodes.first { $0.id == "host:\(host.id.uuidString)" }?
            .children.first { $0.title == session || $0.id.hasSuffix("/\(session)") }?
            .leaves.first { $0.pane?.pane == pane }?.title ?? pane
        log("url: \(url) -> \(host.name) \(pane)")
        return PaneRef(host: host, pane: pane, title: title)
    }

    // MARK: Attach

    /// A live stream to one pane, as an fd for the Attach backend.
    func attach(_ host: Host, pane: String, preview: Bool = false) async throws -> Int32 {
        // One retry: a stream that times out declared its connection
        // dead, and the second attempt dials a fresh one.
        for attempt in 1...2 {
            do {
                let ssh = try await connection(for: host)
                let fd = try await ssh.stream("vigild proxy \(pane)")
                log("\(preview ? "preview" : "attach"): \(host.name) \(pane) fd \(fd)\(attempt > 1 ? " (retry)" : "")")
                return fd
            } catch {
                log("\(preview ? "preview" : "attach"): \(host.name) \(pane) attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == 2 { throw error }
            }
        }
        fatalError("unreachable")
    }

    // MARK: Surfaces: the model owns every live stream

    /// One surface per pane, owned HERE (never by a view's @State): a
    /// surface is a stream to a daemon, an identity the screens borrow.
    /// A row's preview and the pane screen show the SAME surface; hosting
    /// (which container holds the UIView right now) is the representable's
    /// business (`SurfaceHost`), lifetime is this table's.
    private(set) var surfaces: [String: Ghostty.SurfaceView] = [:]
    /// Panes whose row is on screen (a row scrolled out leaves; the
    /// surface outlives the row only while the pane screen shows it).
    private var rowsOnScreen = Set<String>()
    /// The pane the screen shows, ONE fact: rows read it to know their
    /// view is borrowed, the occlusion policy reads it to idle the rest.
    @Published private(set) var presenting: PaneRef?

    /// Every live surface is a full Metal renderer plus an ssh channel.
    static let surfaceCap = 6

    /// The surface for a pane, dialing one if none exists. `nil` when the
    /// cap is reached (rows show a placeholder; the screen always gets
    /// one: it evicts an idle row's surface).
    func surface(for ref: PaneRef, app: ghostty_app_t, screen: Bool) async throws -> Ghostty.SurfaceView? {
        if let existing = surfaces[ref.pane], existing.surface != nil { return existing }
        if surfaces.count >= Self.surfaceCap {
            guard screen, let victim = surfaces.keys.first(where: { $0 != ref.pane && $0 != presenting?.pane }) else {
                log("surface: cap \(Self.surfaceCap) reached, \(ref.pane) not shown")
                return nil
            }
            log("surface: cap reached, evicting \(victim) for the screen")
            endSurface(victim)
        }
        let fd = try await attach(ref.host, pane: ref.pane, preview: !screen)
        var config = Ghostty.SurfaceConfiguration()
        config.vigilAttach = ref.pane
        config.vigilFd = fd
        config.vigilMirror = true
        // The phone never owns the pty by focus: only an own-size screen
        // claims, explicitly (a fit viewport mirrors the owner's grid).
        config.vigilExplicitClaim = true
        // A phone reads at 8pt (the Mac's 13 minus five loupe taps).
        config.fontSize = 8
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        view.onStreamEnd = { [weak self, weak view] in
            guard let self, let view, self.surfaces[ref.pane] === view else { return }
            self.log("surface: \(ref.pane) stream died, dropping it; the screen re-dials")
            self.endSurface(ref.pane)
            self.streamGeneration += 1
        }
        surfaces[ref.pane] = view
        return view
    }

    /// Bumped when a live stream dies (the ssh connection dropped on a
    /// network change): every screen holding a dead surface re-dials.
    @Published private(set) var streamGeneration = 0

    func endSurface(_ pane: String) {
        guard let view = surfaces.removeValue(forKey: pane) else { return }
        view.detach()
        log("surface: \(pane) ended (\(surfaces.count) live)")
    }

    /// A row with a preview came on screen / left it.
    func rowAppeared(_ ref: PaneRef) { rowsOnScreen.insert(ref.pane) }
    func rowDisappeared(_ ref: PaneRef) {
        rowsOnScreen.remove(ref.pane)
        // A row leaves under a pushed screen too (the nav stack hides the
        // list): the surface stays while presented, and ends when its row
        // is gone once the screen returns (`present(nil)` sweeps).
        if presenting == nil { endSurface(ref.pane) }
    }

    /// The pane screen is showing `ref` (nil = the tree). Occlusion
    /// follows: only the presented surface renders while a screen is up;
    /// with the tree up, every row's surface renders.
    func present(_ ref: PaneRef?) {
        guard presenting != ref else { return }
        presenting = ref
        log("present: \(ref?.pane ?? "tree")")
        for (pane, view) in surfaces {
            view.visible = ref == nil || pane == ref?.pane
        }
        // Back on the tree: rows re-appear within a frame (the stack's
        // pop fires their onAppear after this); a surface no row claims
        // by then ends. Deferred, never at the pop itself, so a return
        // never re-dials what the rows still show.
        if ref == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.presenting == nil else { return }
                for pane in self.surfaces.keys where !self.rowsOnScreen.contains(pane) { self.endSurface(pane) }
            }
        }
    }

    // MARK: Index (derived with the tree, never walked in a body)

    private(set) var paneNodes: [PaneRef: Node] = [:]
    private(set) var sessionTitles: [PaneRef: String] = [:]

    func node(for ref: PaneRef) -> Node? { paneNodes[ref] }
    func sessionTitle(for ref: PaneRef) -> String { sessionTitles[ref] ?? "" }
    struct LivePane: Identifiable {
        let ref: PaneRef
        let session: String
        var id: PaneRef { ref }
    }
    /// Every live pane on a Mac, labelled by its session.
    func livePanes(on host: Host) -> [LivePane] {
        paneNodes.keys.filter { $0.host.id == host.id }
            .sorted { ($0.pane) < ($1.pane) }
            .map { LivePane(ref: $0, session: sessionTitles[$0] ?? "") }
    }

    private func indexTree() {
        var panes: [PaneRef: Node] = [:]
        var titles: [PaneRef: String] = [:]
        for host in nodes {
            for session in host.children {
                for leaf in session.leaves {
                    guard let ref = leaf.pane else { continue }
                    panes[ref] = leaf
                    titles[ref] = session.title
                }
            }
        }
        paneNodes = panes
        sessionTitles = titles
    }
}
