#if os(macOS)
import CoreServices
import Darwin
import Foundation

/// Files are observations, never the session ownership registry. FSEvents
/// names each file that changed; one worker reads exactly those and publishes
/// an immutable revision. A folder is listed whole only at start and when
/// FSEvents says it lost track (dropped events, a folder replaced): a pane's
/// process list is rewritten every few seconds while its agent works, and
/// listing and stat'ing every pane's files for each such rewrite was most of
/// the app's idle CPU (2026-10-30: 32 panes, ~5% of a core).
final class VigilFacts: @unchecked Sendable {
    struct File: Equatable, Sendable {
        let data: Data
        let text: String
        let lines: [String]
        let revision: String
        let inode: UInt64
        let since: Date
    }
    struct Lease: Decodable, Equatable, Sendable {
        let pane: String
        let pid: Int32
        let note: String
        let deadline: Double?
    }
    struct Snapshot: Sendable {
        var revision: UInt64 = 0
        var sidebarRevision: UInt64 = 0
        var files: [String: File] = [:]
        var leases: [Lease] = []
    }
    /// What the worker reports; the host decides where it is written.
    enum Event: Sendable {
        case seenUnwritable(pane: String, error: any Error)
        case unwatchable(folder: String)
        case slowRead(revision: UInt64, elapsed: Duration)
    }

    private let root: String
    private let queue = DispatchQueue(label: "vigil.files", qos: .userInitiated)
    private let deliver: @Sendable (Snapshot) -> Void
    private let report: @Sendable (Event) -> Void
    private let beforeRead: @Sendable () -> Void
    private var current = Snapshot()
    private var stream: FSEventStreamRef?
    /// The root as FSEvents spells the paths it reports (symlinks resolved).
    private var resolvedRoot = ""
    /// Files FSEvents named since the last read (`folder/name`).
    private var changed: Set<String> = []
    /// Folders to list whole on the next read: all of them at start, one
    /// whose events FSEvents could not deliver one by one.
    private var rescan: Set<String> = Set(VigilFacts.folders)
    private var processes: [Int32: DispatchSourceProcess] = [:]
    private var pending = false
    private var stopped = false
    /// Under vigil's one folder (VigilPaths): each pane's daemon files, its
    /// agent state and seen mark, the watch leases.
    private static let folders = ["panes", "state", "leases"]

    /// `root` is vigil's one folder as the host resolves it (VigilPaths:
    /// `VIGIL_STATE` moves it), never guessed here.
    init(root: String,
         beforeRead: @escaping @Sendable () -> Void = {},
         report: @escaping @Sendable (Event) -> Void,
         deliver: @escaping @Sendable (Snapshot) -> Void) {
        self.root = root
        self.beforeRead = beforeRead
        self.report = report
        self.deliver = deliver
    }

    func start() { queue.async { self.invalidate() } }
    func stop() {
        queue.async {
            self.stopped = true
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            self.processes.values.forEach { $0.cancel() }
            self.processes.removeAll()
        }
    }

    /// The revision names the state actually seen. A late write cannot clear a
    /// newer question: readers accept a receipt only for that exact revision.
    func markSeen(_ pane: String, revision: String) {
        guard !pane.isEmpty, !pane.contains("/"), !pane.hasPrefix(".") else { return }
        queue.async {
            guard !self.stopped else { return }
            let path = self.root + "/state/" + pane
            guard Self.read(path + ".state")?.revision == revision else { return }
            if Self.read(path + ".seen")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == revision { return }
            do {
                try Data((revision + "\n").utf8).write(to: URL(fileURLWithPath: path + ".seen"), options: .atomic)
                self.changed.insert("state/" + pane + ".seen")
                self.invalidate()
            } catch { self.report(.seenUnwritable(pane: pane, error: error)) }
        }
    }

    private func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !pending, !stopped else { return }
        pending = true
        queue.async {
            self.pending = false
            guard !self.stopped else { return }
            self.reload()
        }
    }

    /// One stream over the three folders, started once and never re-armed:
    /// FSEvents follows a path, so a folder deleted and made again is still
    /// watched (its own event asks for a listing).
    private func watch() {
        guard stream == nil else { return }
        for folder in Self.folders {
            try? FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        // realpath, never URL.resolvingSymlinksInPath: Foundation strips a
        // leading /private, which FSEvents keeps (/var is /private/var).
        guard let resolved = realpath(root, nil) else {
            Self.folders.forEach { report(.unwatchable(folder: $0)) }
            return
        }
        resolvedRoot = String(cString: resolved)
        free(resolved)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let facts = Unmanaged<VigilFacts>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            facts.observed(names, Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        // No latency and no defer: the first change after a quiet moment is
        // read at once, and a burst arrives as one batch of names.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
                                             kFSEventStreamCreateFlagUseCFTypes)
        let paths = Self.folders.map { resolvedRoot + "/" + $0 } as CFArray
        guard let created = FSEventStreamCreate(nil, callback, &context, paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags) else {
            Self.folders.forEach { report(.unwatchable(folder: $0)) }
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            Self.folders.forEach { report(.unwatchable(folder: $0)) }
            return
        }
        stream = created
    }

    /// What FSEvents named, as keys to read again; anything it could not name
    /// one by one is a folder to list whole.
    private func observed(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                                           kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for (path, flag) in zip(paths, flags) {
            if flag & lost != 0 { rescan.formUnion(Self.folders); continue }
            guard path.hasPrefix(resolvedRoot + "/") else { continue }
            let parts = path.dropFirst(resolvedRoot.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            guard let folder = parts.first.map(String.init), Self.folders.contains(folder) else { continue }
            switch parts.count {
            case 1: rescan.insert(folder)
            case 2: changed.insert(folder + "/" + parts[1])
            default: continue
            }
        }
        invalidate()
    }

    private static func wanted(_ key: String) -> Bool {
        let parts = key.split(separator: "/")
        guard parts.count == 2 else { return false }
        let ext = parts[1].split(separator: ".").last.map(String.init) ?? ""
        switch parts[0] {
        case "panes": return ["pid", "tree", "died", "size", "screen", "viewers", "command", "title", "ended"].contains(ext)
        case "state": return ["state", "seen", "glance"].contains(ext)
        case "leases": return ext == "json"
        default: return false
        }
    }

    private func reload() {
        dispatchPrecondition(condition: .onQueue(queue))
        let began = ContinuousClock.now
        beforeRead()
        watch()
        var touched = changed
        for folder in rescan {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + folder)) ?? [] {
                touched.insert(folder + "/" + name)
            }
            touched.formUnion(current.files.keys.filter { $0.hasPrefix(folder + "/") })
        }
        changed.removeAll(); rescan.removeAll()
        var files = current.files
        for key in touched where Self.wanted(key) {
            files[key] = Self.read(root + "/" + key, previous: current.files[key])
        }
        var leases: [Lease] = []
        for (key, file) in files where key.hasPrefix("leases/") {
            guard let lease = try? JSONDecoder().decode(Lease.self, from: file.data) else { continue }
            if kill(lease.pid, 0) == 0 { leases.append(lease) } else {
                try? FileManager.default.removeItem(atPath: root + "/" + key)
                files[key] = nil
                touched.insert(key)
            }
        }
        leases.sort { ($0.pane, $0.pid, $0.note) < ($1.pane, $1.pid, $1.note) }
        watchProcesses(Set(leases.map(\.pid)))
        let moved = touched.filter { files[$0] != current.files[$0] }
        guard !moved.isEmpty || leases != current.leases || current.revision == 0 else { return }
        // Renderer receipts can change on every output beat. They update the
        // cache, but never invalidate a sidebar whose inputs stayed identical.
        // Identical means the BYTES: a tree rewritten with the same lines (a
        // child that came and went between two reads) is a new inode and
        // mtime and no new fact; each such rewrite was a sidebar revision.
        // A glance is rewritten with every tool call its agent makes; the
        // sidebar draws only its conversation (agent, id, name).
        let sidebarChanged = current.revision == 0 || leases != current.leases ||
            moved.contains { key in
                guard Self.sidebarKey(key) else { return false }
                guard let file = files[key], let before = current.files[key] else { return true }
                if key.hasSuffix(".tree") { return before.data != file.data }
                if key.hasSuffix(".glance") { return Self.conversation(before) != Self.conversation(file) }
                return true
            }
        current = Snapshot(revision: current.revision + 1,
            sidebarRevision: current.sidebarRevision + (sidebarChanged ? 1 : 0), files: files, leases: leases)
        deliver(current)
        let elapsed = began.duration(to: .now)
        if elapsed > .milliseconds(100) { report(.slowRead(revision: current.revision, elapsed: elapsed)) }
    }

    private func watchProcesses(_ pids: Set<Int32>) {
        for pid in Array(processes.keys) where !pids.contains(pid) { processes.removeValue(forKey: pid)?.cancel() }
        for pid in pids where processes[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.invalidate() }
            processes[pid] = source
            source.resume()
        }
    }

    private static func identity(_ info: stat) -> String {
        "\(info.st_ino)-\(info.st_mtimespec.tv_sec * 1_000_000_000 + Int(info.st_mtimespec.tv_nsec))"
    }

    /// What a sidebar draws of a glance file (VigilWire's `PaneGlance`): its
    /// agent, conversation id and name, nil when it does not read (the
    /// reader that names the pane says why).
    static func conversation(_ file: File) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: file.data) as? [String: Any] else { return nil }
        return ["agent", "conversation", "name"].map { object[$0] as? String ?? "" }
    }

    private static func sidebarKey(_ key: String) -> Bool {
        !(key.hasPrefix("panes/") && (key.hasSuffix(".size") || key.hasSuffix(".screen")))
    }

    private static func read(_ path: String, previous: File? = nil) -> File? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576 else { return nil }
        if let previous, identity(info) == previous.revision { return previous }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576 else { return nil }
        let revision = identity(info)
        guard let data = try? handle.read(upToCount: 1_048_577), data.count == info.st_size else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, identity(after) == revision else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        return File(data: data, text: text, lines: text.components(separatedBy: "\n").filter { !$0.isEmpty },
                    revision: revision, inode: UInt64(info.st_ino),
                    since: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
    }
}
#endif
