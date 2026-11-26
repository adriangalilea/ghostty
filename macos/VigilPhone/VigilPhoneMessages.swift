import Combine
import Ink
import SwiftUI
import UIKit
import VigilWire

/// Each paired host's chats as the phone draws them: one store per host
/// (`VigilChats`, the Mac app's own), drawn by the Mac's own views
/// (`VigilChat`, `VigilPaneChat`, `MessagesMark`).
///
/// Nothing carries a host's chats to the phone yet, so every host stands
/// out of reach and says so: "can't reach this host's chats yet" is drawn
/// apart from a host that answers and has none. What follows a host feeds
/// its store (`VigilChats.take`), and nothing else here changes then.
@MainActor
final class VigilPhoneMessages: ObservableObject {
    static let shared = VigilPhoneMessages()

    /// Each paired host's chats, by its tether root.
    @Published private(set) var hosts: [String: VigilChats] = [:]
    /// What the tree's rows and the tab's badge draw, apart from the chats:
    /// only a changed count repaints them.
    let marks = Marks()

    @MainActor
    final class Marks: ObservableObject {
        @Published fileprivate(set) var unreadByPane: [String: [String: Int]] = [:]
        @Published fileprivate(set) var waitingByPane: [String: [String: Set<String>]] = [:]
        /// What the person has not read, on every host.
        @Published fileprivate(set) var unread = 0

        func unread(root: String, pane: String) -> Int { unreadByPane[root]?[pane] ?? 0 }
        func waiting(root: String, pane: String) -> Set<String> { waitingByPane[root]?[pane] ?? [] }
    }

    private static let notCarried = "Its chats are not sent to the phone yet."
    private struct Failed: Error, CustomStringConvertible { let description: String }

    private init() {}

    /// The paired hosts now: each one's chats held, a host gone taken out.
    func macs(_ roots: Set<String>) {
        var next = hosts.filter { roots.contains($0.key) }
        for root in roots where next[root] == nil {
            let chats = VigilChats(host: VigilChatHost(
                page: { _, _, _ in throw Failed(description: Self.notCarried) },
                post: { _ in throw Failed(description: Self.notCarried) },
                act: { _ in throw Failed(description: Self.notCarried) },
                press: { _, _ in throw Failed(description: Self.notCarried) },
                open: { pane in Self.open(root: root, pane: pane) },
                mention: { _, _ in throw Failed(description: Self.notCarried) }))
            chats.unreachable(Self.notCarried)
            chats.changed = { [weak self] in self?.remark() }
            next[root] = chats
        }
        if Set(next.keys) != Set(hosts.keys) {
            hosts = next
            remark()
        }
    }

    func chats(_ root: String) -> VigilChats? { hosts[root] }

    private func remark() {
        let unreadByPane = hosts.mapValues(\.marks.unread), waitingByPane = hosts.mapValues(\.marks.waiting)
        let unread = hosts.values.reduce(0) { $0 + $1.unread }
        if unreadByPane != marks.unreadByPane { marks.unreadByPane = unreadByPane }
        if waitingByPane != marks.waitingByPane { marks.waitingByPane = waitingByPane }
        if unread != marks.unread { marks.unread = unread }
    }

    /// A pane of the host `root` as its row names it: what a watch calls it.
    static func title(root: String, pane: String) -> String {
        let phone = VigilPhone.shared
        let mac = phone.hosts.first { $0.id == root }?.name ?? "a Mac"
        let place = phone.directories[root]?.place(of: pane)
        let alias = place?.pane.label ?? place.flatMap { $0.tab.members.count == 1 ? $0.tab.label : nil }
        let node = phone.node(for: PaneRef(host: .init(id: root, name: mac), pane: pane, title: ""))
        return alias ?? node?.glance?.member?.alias ?? node?.glance?.title ?? node?.glance?.member?.name ?? node?.title ?? pane
    }

    /// Go to a pane from a chat or a watch: the pane screen, over whatever shows.
    static func open(root: String, pane: String, from scope: String = "messages") {
        let phone = VigilPhone.shared
        let mac = phone.hosts.first { $0.id == root }?.name ?? ""
        if let node = phone.node(for: PaneRef(host: .init(id: root, name: mac), pane: pane, title: "")), let ref = node.pane {
            phone.opening = ref
        } else {
            phone.openPane(pane)
        }
        phone.receipts.info(scope, "went to a pane", ["pane": pane])
    }
}

/// Every paired host's chats: the Messages tab. One host: its chats. More:
/// each host with how it stands, its chats a press away.
struct PhoneMessagesScreen: View {
    @ObservedObject private var store = VigilPhoneMessages.shared
    @ObservedObject private var phone = VigilPhone.shared

    var body: some View {
        let hosts = phone.hosts.filter { store.hosts[$0.id] != nil }
        Group {
            if hosts.count == 1, let chats = store.hosts[hosts[0].id] {
                PhoneHostChats(chats: chats)
            } else if hosts.isEmpty {
                Text("No host is paired with this phone").inkText(.detail)
            } else {
                List(hosts, id: \.id) { host in
                    if let chats = store.hosts[host.id] {
                        NavigationLink {
                            PhoneHostChats(chats: chats).navigationTitle(host.name).toolbarTitleDisplayMode(.inline)
                        } label: {
                            PhoneHostRow(name: host.name, chats: chats)
                        }
                    }
                }
            }
        }
        .navigationTitle("Messages")
        .toolbarTitleDisplayMode(.inline)
    }
}

private struct PhoneHostChats: View {
    @ObservedObject var chats: VigilChats
    @State private var chosen: String?

    var body: some View { VigilChat(chats: chats, chosen: $chosen) }
}

/// A host in the list of hosts: its name, and whether its chats are
/// reached, none, or how many are unread.
private struct PhoneHostRow: View {
    let name: String
    @ObservedObject var chats: VigilChats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.headline)
            switch chats.reach {
            case .unreachable(let why): Text("Can't reach this host's chats yet. \(why)").inkText(.detail)
            case .waiting: Text("Reaching its chats…").inkText(.detail)
            case .reached:
                Text(chats.rows.isEmpty ? "You have no chats" : "\(chats.rows.count) chats, \(chats.unread) unread").inkText(.detail)
            }
        }
    }
}

/// A pane's agent's chat, the pane screen's Messages mode. The pane
/// screen's bar names the pane; the column says which chat it shows.
struct PaneMessages: View {
    let root: String
    let pane: String
    @ObservedObject private var store = VigilPhoneMessages.shared

    var body: some View {
        if let chats = store.hosts[root] {
            VigilPaneChat(pane: pane, chats: chats, waiting: chats.marks.waiting(pane: pane))
        } else {
            Text("That host is not paired with this phone").inkText(.detail)
        }
    }
}

/// A row's marks for its pane's chats, or a folded row's panes'.
struct PhoneMessagesMark: View {
    let refs: [PaneRef]
    let sizes: PaneMarkSizes
    @ObservedObject private var marks = VigilPhoneMessages.shared.marks

    var body: some View {
        // What waits on your answer first, each once across the folded
        // panes; then what you have not read.
        WaitingMark(
            messages: refs.reduce(into: Set<String>()) { $0.formUnion(marks.waiting(root: $1.host.id, pane: $1.pane)) }, sizes: sizes)
        MessagesMark(unread: refs.reduce(0) { $0 + marks.unread(root: $1.host.id, pane: $1.pane) }, sizes: sizes)
    }
}
