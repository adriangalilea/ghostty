import Foundation
import GitKit
import GitViews
import SwiftUI
import VigilWire

/// One `GitCall` answered by a pane's Mac: over the link from the phone or
/// for another Mac's pane, by this Mac's hub for its own (`Local.here`).
/// What it throws is said as it describes itself: the host puts its
/// failures in words (`PaneGitCallFailed`).
typealias PaneGitCall = @Sendable (GitCall) async throws -> Data

/// A repository of the pane's Mac watched (`Open.gitWatch`), by its top
/// level: one element each time it may have changed.
typealias PaneGitWatch = @Sendable (String) -> AsyncStream<Void>

/// A call that did not come back, in the host's words.
struct PaneGitCallFailed: Error, CustomStringConvertible {
    let description: String
}

/// A repository read through its pane's Mac (harness/GIT-VIEW.md): each call
/// of `Git.Source` asked of it (`Open.git`), answered by that Mac's
/// `Git.LocalSource`, GitKit's own value coming back, and watched by it
/// (`changes()`). A submodule is the same source rooted at its checkout.
struct VigilGitSource: Git.Source {
    let git: PaneGitCall
    let watch: PaneGitWatch
    let root: String

    var name: String { (root as NSString).lastPathComponent }

    func changes() -> AsyncStream<Void> { watch(root) }

    func snapshot() async throws -> Git.Snapshot {
        try await call(GitCall(kind: .snapshot, repo: root))
    }

    func diff(_ scope: Git.ChangeScope) async throws -> Git.Diff {
        try await call(GitCall(kind: .diff, repo: root, scope: JSONEncoder().encode(scope)))
    }

    func log(_ revision: String?, limit: Int) async throws -> [Git.Commit] {
        try await call(GitCall(kind: .log, repo: root, revision: revision, limit: limit))
    }

    func submodule(_ path: String) -> (any Git.Source)? {
        VigilGitSource(git: git, watch: watch, root: root + "/" + path)
    }

    func contents(_ path: String, in target: Git.ChangeScope.Target) async throws -> String {
        let scope = try JSONEncoder().encode(Git.ChangeScope(target: target))
        // Lossy on purpose: a bad byte reads as U+FFFD, the rest of the file still shows.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: try await git(GitCall(kind: .contents, repo: root, scope: scope, path: path)), as: UTF8.self)
    }

    private func call<Value: Decodable>(_ call: GitCall) async throws -> Value {
        try JSONDecoder().decode(Value.self, from: await git(call))
    }
}

/// The pane's changes: what its agent edited in this conversation, in a
/// repository or not; each of its repositories in the git browser, opening
/// on the agent's work there; and any other repository on its Mac, found by
/// folder. A quote goes where the host says (the phone's reply box). Drawn
/// by the phone's pane screen and the Mac's changes window alike.
struct VigilChanges: View {
    let git: PaneGitCall
    let watch: PaneGitWatch
    let quote: (DiffQuote) -> Void
    /// Opens the conversation on an edit's call (its feed entry id), where
    /// the host has one.
    let show: ((String) -> Void)?

    enum Shown: Hashable {
        case edits
        case repo(String)
        case open
    }

    @State private var shown: Shown?
    @State private var edits: ConversationEdits?
    @State private var repos: [RepoInfo]?
    /// Repositories opened by folder, shown beside the pane's own.
    @State private var opened: [String] = []
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            if edits != nil || repos != nil { picker }
            Group {
                if let failure {
                    GitStateView(.failed(Unread(description: failure), retry: { Task { await load() } }))
                } else {
                    switch shown {
                    case .edits:
                        if let edits {
                            EditsView(edits: edits, show: show)
                                // A file shown whole is now's text against before: its
                                // lines between hunks are the file on the Mac now.
                                .diffContents { [git] file in
                                    guard let path = edits.files.first(where: { $0.whole && Self.names($0, file.path) })?.path else {
                                        throw Unread(description: "not shown whole")
                                    }
                                    // Lossy on purpose, as above.
                                    // swiftlint:disable:next optional_data_string_conversion
                                    return String(decoding: try await git(GitCall(kind: .file, path: path)), as: UTF8.self)
                                }
                        }
                    // The coercions restate the stored types: without them the
                    // Swift 5 mode checker reads these @Sendable closures as
                    // non-Sendable inside a view builder and warns.
                    case .repo(let root):
                        GitBrowser(source: VigilGitSource(git: git as PaneGitCall, watch: watch as PaneGitWatch, root: root),
                                   agent: agent(root))
                            .id(root)
                    case .open:
                        FolderBrowser(git: git as PaneGitCall, places: places) { root in
                            if !roots.contains(root) { opened.append(root) }
                            shown = .repo(root)
                        }
                    case nil:
                        GitStateView(.loading("Reading the edits"))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onQuote { quote($0) }
        .task { await load() }
    }

    private var roots: [String] { (repos ?? []).map(\.root) + opened }

    /// The Mac draws an edited file under its home as `~/…`: the same file.
    private static func names(_ file: EditedFile, _ shown: String) -> Bool {
        shown.hasPrefix("~/") ? file.path.hasSuffix(String(shown.dropFirst())) : file.path == shown
    }

    /// Where the folder browser offers to start: the pane's repositories and
    /// the folders its agent edited in.
    private var places: [String] {
        var seen: [String] = []
        for place in roots + (edits?.files ?? []).map({ ($0.path as NSString).deletingLastPathComponent })
        where !seen.contains(place) { seen.append(place) }
        return seen
    }

    private func agent(_ root: String) -> GitBrowser.Agent? {
        guard let edits = repos?.first(where: { $0.root == root })?.edits, let base = edits.base else { return nil }
        return GitBrowser.Agent(base: base, touched: edits.paths, name: "Since the agent started")
    }

    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.edits, "Edits", symbol: "sparkles", count: edits.map { $0.files.count + $0.more })
                ForEach(roots, id: \.self) { root in
                    let mine = repos?.first { $0.root == root }
                    chip(.repo(root), (root as NSString).lastPathComponent,
                         symbol: mine?.edits != nil ? "arrow.triangle.branch" : "folder", count: nil)
                }
                chip(.open, "Open…", symbol: "folder.badge.plus", count: nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ target: Shown, _ title: String, symbol: String, count: Int?) -> some View {
        Button {
            shown = target
        } label: {
            Label(count.map { "\(title) \($0)" } ?? title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .tint(shown == target ? .accentColor : .secondary)
    }

    /// Why something was not read, in the link's words.
    fileprivate struct Unread: Error, CustomStringConvertible {
        let description: String
    }

    private func load() async {
        failure = nil
        do {
            async let editsData = git(GitCall(kind: .edits))
            async let reposData = git(GitCall(kind: .repos))
            let edits = try JSONDecoder().decode(ConversationEdits.self, from: await editsData)
            let read = try JSONDecoder().decode([RepoInfo].self, from: await reposData)
            // The repository the agent worked in first, else the pane's folder's.
            let repos = read.sorted { ($0.edits != nil ? 0 : 1) < ($1.edits != nil ? 0 : 1) }
            self.edits = edits
            self.repos = repos
            if shown == nil {
                // What the agent edited when it did; else the pane's repository.
                shown = !edits.files.isEmpty ? .edits : repos.first.map { .repo($0.root) } ?? .edits
            }
        } catch {
            failure = "\(error)"
        }
    }
}

/// Every file the agent edited in the conversation as one diff page: each
/// file before the agent's first edit against the file now, or, when it
/// also changed outside those edits, the agent's edits one after another.
private struct EditsView: View {
    let edits: ConversationEdits
    let show: ((String) -> Void)?
    @State private var diff: Git.Diff?
    @State private var listed = false

    /// Each file, its edits and when the last came; a tap opens the
    /// conversation on that edit where the host has one.
    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { listed.toggle() }
            } label: {
                Label(listed ? "Hide the files" : "Each file's edits",
                      systemImage: listed ? "chevron.down" : "chevron.right")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            if listed {
                // A list that keeps the diff on screen under it.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(edits.files, id: \.path) { file in
                            if let last = file.edits.last {
                                if let show {
                                    Button { show(last.entry) } label: { row(file, last) }
                                        .buttonStyle(.plain)
                                } else {
                                    row(file, last)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: edits.files.count < 6)
            }
        }
    }

    private func row(_ file: EditedFile, _ last: EditedFile.Edit) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text((file.path as NSString).lastPathComponent).font(.callout).lineLimit(1)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(file.edits.count == 1 ? "1 edit" : "\(file.edits.count) edits").font(.caption)
                if let at = last.at {
                    Text(Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if show != nil { Image(systemName: "text.bubble").font(.caption).foregroundStyle(.tint) }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let unread = edits.unread {
            GitStateView(.empty(title: "No edits read", message: unread, symbol: "doc.badge.ellipsis"))
        } else if edits.files.isEmpty {
            GitStateView(.empty(title: "No edits yet", message: "The agent has edited no file in this conversation.",
                                symbol: "doc.badge.ellipsis"))
        } else if let diff {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    summary(diff)
                    files
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
                DiffPage(diff)
                    .diffCollapsed(edits.files.count > 8)
            }
        } else {
            GitStateView(.loading("Reading the edits"))
                .task { diff = Self.diff(edits) }
        }
    }

    private func summary(_ diff: Git.Diff) -> some View {
        let apart = edits.files.filter { !$0.whole }
        var line = "\(edits.files.count + edits.more) files edited in this conversation · +\(diff.additions) −\(diff.deletions)"
        if edits.more > 0 { line += " · the latest \(edits.files.count) shown" }
        return VStack(alignment: .leading, spacing: 2) {
            Text(line)
            if !apart.isEmpty {
                Text("\(apart.count) shown as the agent's edits, not the whole change: \(Self.reasons(apart))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Each reason once, with how many files it applies to.
    private static func reasons(_ files: [EditedFile]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for why in files.map({ $0.why ?? "unknown" }) {
            if counts[why] == nil { order.append(why) }
            counts[why, default: 0] += 1
        }
        return order.map { counts[$0] == 1 ? $0 : "\($0) (\(counts[$0]!))" }.joined(separator: "; ")
    }

    /// The files' diffs as one, a file without one as its header alone.
    static func diff(_ edits: ConversationEdits) -> Git.Diff {
        Git.Diff(files: edits.files.map { file in
            file.diff.flatMap { try? JSONDecoder().decode(Git.FileDiff.self, from: $0) }
                ?? Git.FileDiff(oldPath: file.path, newPath: file.path, change: .modified, hunks: [])
        })
    }
}

/// A folder on the pane's Mac at a time, its repositories marked: tap a
/// repository to open it, any other folder to go inside, or type a path.
private struct FolderBrowser: View {
    let git: PaneGitCall
    let places: [String]
    let open: (String) -> Void

    @State private var path = "~"
    @State private var listing: FolderListing?
    @State private var failure: String?
    @State private var typed = ""

    var body: some View {
        List {
            Section {
                TextField("A folder on the Mac, like ~/Developer", text: $typed)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .onSubmit {
                        let folder = typed.trimmingCharacters(in: .whitespaces)
                        if !folder.isEmpty { path = folder }
                    }
            }
            if !places.isEmpty {
                Section("This pane") {
                    ForEach(places, id: \.self) { place in
                        Button { path = place } label: {
                            Label(shown(place), systemImage: "folder").lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
            if let failure {
                Section { Text(failure).foregroundStyle(.secondary) }
            }
            if let listing {
                Section {
                    if let repo = listing.repo {
                        Button { open(repo) } label: {
                            Label("Open \((repo as NSString).lastPathComponent)", systemImage: "arrow.triangle.branch")
                                .bold()
                        }
                    }
                    if listing.path != "/" {
                        Button { path = (listing.path as NSString).deletingLastPathComponent } label: {
                            Label("Up", systemImage: "arrow.up")
                        }
                    }
                    ForEach(listing.folders, id: \.name) { folder in
                        let inside = (listing.path as NSString).appendingPathComponent(folder.name)
                        Button {
                            if folder.isRepo { open(inside) } else { path = inside }
                        } label: {
                            Label(folder.name, systemImage: folder.isRepo ? "arrow.triangle.branch" : "folder")
                        }
                        .contextMenu {
                            Button { path = inside } label: { Label("Look inside", systemImage: "folder") }
                        }
                    }
                    if listing.more > 0 {
                        Text("\(listing.more) more not listed").foregroundStyle(.secondary)
                    }
                } header: {
                    Text(shown(listing.path)).textCase(nil).lineLimit(1).truncationMode(.head)
                }
            } else if failure == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: path) { await load() }
    }

    /// A path as the Mac's home is written: `~`.
    private func shown(_ place: String) -> String {
        guard let home = listing?.home, place == home || place.hasPrefix(home + "/") else { return place }
        return "~" + place.dropFirst(home.count)
    }

    private func load() async {
        do {
            let data = try await git(GitCall(kind: .browse, repo: path))
            listing = try JSONDecoder().decode(FolderListing.self, from: data)
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }
}
