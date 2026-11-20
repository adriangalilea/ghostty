import AppKit
import SwiftUI
import VigilWire

/// Identity from the pane’s glance and transcript comparisons from its home.
@MainActor
enum VigilMemberCard {
    private static var shown: [String: NSWindow] = [:]

    static func show(_ pane: VigilWorkspaces.SidebarPane) {
        guard pane.member != nil || pane.conversationRef != nil else { return }
        let key = [pane.id, pane.conversationRef?.key ?? pane.member?.key ?? ""].joined(separator: "/")
        if let window = shown[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: Card(pane: pane).frame(minWidth: 380, minHeight: 240)))
        window.title = Card.name(pane: pane)
        window.setContentSize(NSSize(width: 460, height: 380))
        window.isReleasedWhenClosed = false
        window.center()
        shown[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { shown[key] = nil }
        }
        window.makeKeyAndOrderFront(nil)
        sidebarLog.info("member card opened", ["pane": pane.id])
    }

    private struct Card: View {
        let pane: VigilWorkspaces.SidebarPane

        /// The member's name, the one every card and chat says (one look per
        /// agent); the conversation's or the row's only while it has none.
        static func name(pane: VigilWorkspaces.SidebarPane) -> String {
            pane.member?.name ?? pane.conversationName ?? pane.title
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Its face as its row wears it: the emoji given it,
                        // else its agent's mark in its member's tint.
                        if let emoji = pane.emoji {
                            Text(emoji)
                        } else if case .agent(let agent) = PaneFace.of(emoji: nil, program: pane.program), AgentMark.knows(agent) {
                            AgentMark(agent: agent, size: 15, tint: pane.member?.tint)
                        }
                        Text(Self.name(pane: pane)).font(.headline)
                        Spacer()
                        if let member = pane.member {
                            Text("@\(member.handle)").font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if let ref = pane.conversationRef {
                        let remote = VigilRemote.split(pane.id)?.device
                        let home = remote.flatMap { VigilRemote.shared.host($0)?.name } ?? (remote == nil ? "This Mac" : "The pane’s Mac")
                        Divider()
                        VigilTranscriptCopies(conversation: ref, home: home) { subject in
                            await Task.detached {
                                Local.Client(socket: VigilPaths.hub).progressChanges(device: remote, ref: subject)
                            }.value
                        }
                        .id(ref)
                    }
                    if let member = pane.member {
                        Text([pane.program, member.runs.isEmpty ? "not running" : "running"].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        Divider()
                        section("Lineage") {
                            if let parent = member.forkedFrom { line("forked from \(parent)") }
                            if let parent = member.continuedFrom { line("continued from \(parent) (after /clear)") }
                            if !member.forks.isEmpty { line("forks: \(member.forks.joined(separator: " · "))") }
                            if member.forkedFrom == nil, member.continuedFrom == nil, member.forks.isEmpty { line("none") }
                        }
                        section("Subagents") {
                            if member.subagents.isEmpty { line("none") }
                            ForEach(member.subagents, id: \.key) { sub in
                                HStack(spacing: 6) {
                                    Text(String(repeating: "   ", count: sub.depth - 1) + "↳ " + sub.title)
                                    if let caption = sub.caption { Text(caption).foregroundStyle(.secondary) }
                                    Text(sub.running ? "running" : "finished").foregroundStyle(sub.running ? .green : .secondary)
                                    Spacer()
                                    Text("@\(sub.handle)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        section("Reached") {
                            line(member.runs.isEmpty
                                ? "not running: a send is refused for now (resuming it is a later step)"
                                : "its inbox, in this pane (\(member.runs.joined(separator: ", ")))")
                        }
                        section("Ids") {
                            Text(member.key).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if let conversation = pane.conversation {
                                Text("conversation \(conversation)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                content()
            }
        }

        private func line(_ text: String) -> some View { Text(text).textSelection(.enabled) }
    }
}
