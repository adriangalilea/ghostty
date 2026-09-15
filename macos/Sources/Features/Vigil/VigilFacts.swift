#if os(macOS)
import Darwin
import Foundation

/// Files are observations, never the session ownership registry. The kernel
/// invalidates them; one worker reads them and publishes an immutable revision.
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
        var files: [String: File] = [:]
        var leases: [Lease] = []
    }

    private let root: String
    private let queue = DispatchQueue(label: "vigil.files", qos: .userInitiated)
    private let deliver: @Sendable (Snapshot) -> Void
    private let trace: @Sendable (String) -> Void
    private let beforeRead: @Sendable () -> Void
    private var current = Snapshot()
    private var directories: [String: DispatchSourceFileSystemObject] = [:]
    private var inPlace: [String: (UInt64, DispatchSourceFileSystemObject)] = [:]
    private var processes: [Int32: DispatchSourceProcess] = [:]
    private var pending = false
    private var stopped = false
    private static let folders = ["vigild", "wake/state", "wake/leases"]

    init(root: String = NSHomeDirectory() + "/.local/state",
         beforeRead: @escaping @Sendable () -> Void = {},
         trace: @escaping @Sendable (String) -> Void,
         deliver: @escaping @Sendable (Snapshot) -> Void) {
        self.root = root
        self.beforeRead = beforeRead
        self.trace = trace
        self.deliver = deliver
    }

    func start() { queue.async { self.invalidate() } }
    func stop() {
        queue.async {
            self.stopped = true
            self.directories.values.forEach { $0.cancel() }
            self.inPlace.values.forEach { $0.1.cancel() }
            self.processes.values.forEach { $0.cancel() }
            self.directories.removeAll(); self.inPlace.removeAll(); self.processes.removeAll()
        }
    }

    /// The revision names the state actually seen. A late write cannot clear a
    /// newer question: readers accept a receipt only for that exact revision.
    func markSeen(_ pane: String, revision: String) {
        guard !pane.isEmpty, !pane.contains("/"), !pane.hasPrefix(".") else { return }
        queue.async {
            guard !self.stopped else { return }
            let path = self.root + "/wake/state/" + pane
            guard Self.read(path + ".state")?.revision == revision else { return }
            if Self.read(path + ".seen")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == revision { return }
            do {
                try Data((revision + "\n").utf8).write(to: URL(fileURLWithPath: path + ".seen"), options: .atomic)
                self.invalidate()
            } catch { self.trace("!! seen: cannot write \(pane): \(error)") }
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

    private func watchDirectories() {
        for folder in Self.folders where directories[folder] == nil {
            let path = root + "/" + folder
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let fd = open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { trace("!! facts: cannot watch \(folder)"); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.directories.removeValue(forKey: folder)?.cancel()
                }
                self.invalidate()
            }
            source.setCancelHandler { close(fd) }
            directories[folder] = source
            source.resume()
        }
    }

    private func reload() {
        dispatchPrecondition(condition: .onQueue(queue))
        let began = ContinuousClock.now
        beforeRead()
        watchDirectories()
        var files: [String: File] = [:]
        for folder in Self.folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + folder)) ?? []
            for name in names {
                let ext = name.split(separator: ".").last.map(String.init) ?? ""
                let wanted = folder == "vigild" ? ["pid", "tree", "died", "size", "screen"].contains(ext)
                    : folder == "wake/state" ? ["state", "seen"].contains(ext) : ext == "json"
                guard wanted else { continue }
                let key = folder + "/" + name
                if let file = Self.read(root + "/" + key, previous: current.files[key]) { files[key] = file }
            }
        }
        var leases: [Lease] = []
        for (key, file) in files where key.hasPrefix("wake/leases/") {
            guard let lease = try? JSONDecoder().decode(Lease.self, from: file.data) else { continue }
            if kill(lease.pid, 0) == 0 { leases.append(lease) } else {
                try? FileManager.default.removeItem(atPath: root + "/" + key)
                files[key] = nil
            }
        }
        leases.sort { ($0.pane, $0.pid, $0.note) < ($1.pane, $1.pid, $1.note) }
        watchInPlace(files)
        watchProcesses(Set(leases.map(\.pid)))
        guard files != current.files || leases != current.leases || current.revision == 0 else { return }
        current = Snapshot(revision: current.revision + 1, files: files, leases: leases)
        deliver(current)
        let elapsed = began.duration(to: .now)
        if elapsed > .milliseconds(100) { trace("facts: revision \(current.revision) read off main in \(elapsed)") }
    }

    /// Size and screen hashes currently change in place; directory watches
    /// alone cannot observe those writes. Their inode watches follow replacement.
    private func watchInPlace(_ files: [String: File]) {
        let wanted = files.filter { $0.key.hasPrefix("vigild/") && ($0.key.hasSuffix(".size") || $0.key.hasSuffix(".screen")) }
        for key in Array(inPlace.keys) where wanted[key]?.inode != inPlace[key]?.0 {
            inPlace.removeValue(forKey: key)?.1.cancel()
        }
        for (key, file) in wanted where inPlace[key] == nil {
            let fd = open(root + "/" + key, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in self?.invalidate() }
            source.setCancelHandler { close(fd) }
            inPlace[key] = (file.inode, source)
            source.resume()
        }
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
