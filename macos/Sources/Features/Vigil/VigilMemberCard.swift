import AppKit
import SwiftUI
import VigilWire

/// The member card (harness/IDENTITY.md section 10): who an agent pane's
/// conversation is, as its Mac's tuples say it. Every row is a view of
/// the glance's member (`PaneGlance.member`), which the pane's broker
/// builds from its tuples: its handle, its lineage, its subagents, the
/// runs that speak for it, its ids. One window per card, closed by the
/// person; read only.
enum VigilMemberCard {
    private static var shown: [String: NSWindow] = [:]

    static func show(_ pane: VigilWorkspaces.SidebarPane) {
        guard let member = pane.member else { return }
        if let window = shown[member.key] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: Card(pane: pane, member: member).frame(minWidth: 380, minHeight: 240)))
        window.title = Card.name(pane: pane, member: member)
        window.setContentSize(NSSize(width: 460, height: 380))
        window.isReleasedWhenClosed = false
        window.center()
        shown[member.key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { shown[member.key] = nil }
        }
        window.makeKeyAndOrderFront(nil)
        sidebarLog.info("member card opened", ["pane": pane.id, "member": member.key])
    }

    private struct Card: View {
        let pane: VigilWorkspaces.SidebarPane
        let member: MemberGlance

        /// The member's name, the one every card and chat says (one look per
        /// agent); the conversation's or the row's only while it has none.
        static func name(pane: VigilWorkspaces.SidebarPane, member: MemberGlance) -> String {
            member.name ?? pane.conversationName ?? pane.title
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
                            AgentMark(agent: agent, size: 15, tint: member.tint)
                        }
                        Text(Self.name(pane: pane, member: member)).font(.headline)
                        Spacer()
                        Text("@\(member.handle)").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
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
                                Text(String(repeating: "   ", count: sub.depth - 1) + "↳ " + (sub.name.isEmpty ? sub.handle : sub.name))
                                if let type = sub.type { Text(type).foregroundStyle(.secondary) }
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
