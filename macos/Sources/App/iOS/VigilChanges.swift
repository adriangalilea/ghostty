import Foundation
import GitKit
import GitViews
import SwiftUI
import VigilLink
import VigilWire

/// A pane's repository read through its Mac (harness/GIT-VIEW.md): each call
/// of `Git.Source` asked over the link (`Open.git`), answered by that Mac's
/// `Git.LocalSource`, GitKit's own value coming back. A submodule is the
/// same source rooted at its checkout, which the Mac reads only inside one
/// of the pane's repositories.
struct VigilGitSource: Git.Source {
    let ref: PaneRef
    let root: String

    var name: String { (root as NSString).lastPathComponent }

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
        VigilGitSource(ref: ref, root: root + "/" + path)
    }

    private func call<Value: Decodable>(_ call: GitCall) async throws -> Value {
        try JSONDecoder().decode(Value.self, from: await VigilPhone.shared.git(call, in: ref))
    }
}

/// The pane's changes: which of its repositories, then the git browser over
/// it, opening on what the agent changed since it started when it did.
/// A quote goes to the conversation's reply box.
struct VigilChanges: View {
    let ref: PaneRef
    let quote: (DiffQuote) -> Void
    @State private var repos: [RepoInfo]?
    @State private var chosen: String?
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                GitStateView(.failed(Unread(description: failure), retry: { Task { await load() } }))
            } else if let repos, repos.isEmpty {
                GitStateView(.empty(title: "No repository", message: "This pane's folder is in none, and its agent edited none.",
                                    symbol: "folder.badge.questionmark"))
            } else if let repos, let repo = repos.first(where: { $0.root == chosen }) ?? repos.first {
                VStack(spacing: 0) {
                    if repos.count > 1 { picker(repos, chosen: repo.root) }
                    GitBrowser(source: VigilGitSource(ref: ref, root: repo.root), agent: agent(repo))
                        .id(repo.root)
                }
            } else {
                GitStateView(.loading("Reading the repositories"))
            }
        }
        .onQuote { quote($0) }
        .task { await load() }
    }

    private func agent(_ repo: RepoInfo) -> GitBrowser.Agent? {
        guard let edits = repo.edits, let base = edits.base else { return nil }
        return GitBrowser.Agent(base: base, touched: edits.paths, name: "Since the agent started")
    }

    private func picker(_ repos: [RepoInfo], chosen: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(repos, id: \.root) { repo in
                    Button {
                        self.chosen = repo.root
                    } label: {
                        Label((repo.root as NSString).lastPathComponent, systemImage: repo.edits == nil ? "folder" : "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .tint(repo.root == chosen ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    /// Why the repositories were not read, in the link's words.
    private struct Unread: Error, CustomStringConvertible {
        let description: String
    }

    private func load() async {
        failure = nil
        do {
            let data = try await VigilPhone.shared.git(GitCall(kind: .repos), in: ref)
            let read = try JSONDecoder().decode([RepoInfo].self, from: data)
            // The repository the agent worked in first, else the pane's folder's.
            repos = read.sorted { ($0.edits != nil ? 0 : 1) < ($1.edits != nil ? 0 : 1) }
            failure = nil
        } catch {
            failure = VigilLink.reason(error)
        }
    }
}
