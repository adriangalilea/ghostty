import Foundation
import VigilWire

/// The left bar's rows and the one function that builds them from values
/// (`SidebarBuilder`). Nothing here touches a view, a window or the app's
/// registry object: `VigilSidebarSnapshots` reads what the rows need on the
/// main thread in one pass (`SidebarInputs`) and the rows are worked out on
/// a queue of their own.
extension VigilWorkspaces {
    struct SidebarPane: Identifiable, Equatable {
        let id: String            // attach id, or a synthetic id for daemon-less panes
        let paneId: String?       // vigild daemon id when daemon-backed
        /// Remote rows navigate by their full identity but have no local
        /// daemon id: local rename, drag and close paths must stay separate.
        var navigationId: String? { paneId ?? (VigilRemote.split(id) != nil ? id : nil) }
        let title: String         // display: the one naming rule (`Directory.titles`)
        var messageAlias: String? = nil
        let program: String?      // the argv truth alone; nil = just a shell
        let state: AgentState?
        /// Its row's dots, by the one rule every surface draws (`PaneDot`):
        /// a dot per agent no subagent row of its own shows, then its main
        /// agent's.
        var dots: [PaneDot] { state.map { $0.dots(background: background, member: member, rowsShown: true) } ?? [] }
        /// Its dots where its subagent rows are hidden (a folded row's
        /// cluster): every agent of it.
        var foldedDots: [PaneDot] { state.map { $0.dots(background: background, member: member, rowsShown: false) } ?? [] }
        let isDock: Bool
        var emoji: String?        // the pane's custom face
        /// Declared watch leases (notes) on this pane - the sentry's own
        /// words ("vigía de Carlos: awaiting his TG reply").
        var watchNotes: [String] = []
        /// Underived truth: background processes alive under the pane
        /// beyond its program (tree file argv, shortened).
        var watchProcs: [String] = []
        /// What a Claude pane's turns left running in no account of the
        /// agent's, by command (its glance's `left`); nil where no broker
        /// says (a shell, Codex, a pane with no agent).
        var left: [String]?
        /// What the antenna stands for: a declared watch, and what is alive
        /// here that no agent accounts for. On a Claude pane that is the
        /// broker's word (its own tool servers and the shells its gear
        /// counts are not it); elsewhere, the processes beyond the pane's
        /// program while it is quiet.
        var sentries: [String] {
            watchNotes + (left ?? (state != .working ? watchProcs : []))
        }
        /// Who looks at it from off its Mac (its daemon's `viewers`).
        var lookers: [Viewer] = []
        /// A phone follows it (the hub's board).
        var followed: Bool = false
        var priority: Registry.Priority = .normal
        /// The agent's conversation (its glance), while one runs there: its
        /// id (Claude's session id, what `c -r` and its logs name) and its
        /// name (what the agent's own UI calls it).
        var conversationRef: ConversationRef?
        var conversation: String? { conversationRef?.id }
        var conversationName: String?
        var resumeMenu: PaneGlance.ResumeMenu?
        var account: String?
        /// Its agent's account cannot run a turn (its glance).
        var accountBlock: AccountBlock?
        var liveConversation: ConversationRef?
        /// The conversation its own was forked from, by id (its glance).
        var forkedFrom: String?
        /// The member it holds, as its Mac's tuples say (its glance): the
        /// handle, the subagent tree under its row, the member card.
        var member: MemberGlance?
        /// What its agent runs in the background now (its glance): counted,
        /// with the first running task's title.
        var background: PaneGlance.Background?
        /// Its program ended badly and nobody opened it yet (`PaneEnd`).
        var ended: PaneEnd?
        /// Moved from another Mac and not opened here yet: the pane it
        /// was there (`Registry.Arrival`).
        var arrived: Registry.Arrival?
        /// What its agent instance reports that needs the person's attention.
        var problems: [ConversationProblem] = []
        /// What became of its restart, as its Mac's broker says (its glance).
        var restart: Restart.Note?
        /// Where its switch to an account stands, the same way.
        var resume: Restart.Status?

        /// Its conversation was written on its Mac and on another, and
        /// nobody has said which copy goes on (`PaneConflict`).
        var conflict: PaneConflict?

        /// The ids we communicate by, each only where it exists: the
        /// pane's daemon id, its conversation's name and id.
        var identifiers: [Identifier] {
            [("Pane ID", paneId ?? VigilRemote.split(id)?.name), ("Conversation Name", conversationName),
             ("Conversation ID", conversation), ("Handle", member.map { "@\($0.handle)" })]
                .compactMap { label, value in value.map { Identifier(label: label, value: $0) } }
        }
    }

    struct Identifier: Hashable {
        let label: String
        let value: String
    }

    struct SidebarTab: Identifiable, Equatable {
        let id: String
        let title: String
        let index: Int
        let panes: [SidebarPane]
        /// Any pane id of this tab: the join key row clicks resolve by
        /// (indices shift as tabs mount and release, pane ids never lie).
        var anchor: String?
        /// Exists as its capture only (lazy shapeshift): daemons run, no
        /// views until a viewport mounts it.
        var captured: Bool = false
        /// The tab's custom face.
        var emoji: String?
        /// You gave this tab a name or a face: it carries information of
        /// its own, so the tree never elides its row.
        var named: Bool = false
    }

    struct SidebarWorkspaceRow: Identifiable, Equatable {
        let id: String            // the session name (the identity)
        let emoji: String?
        let label: String
        let stateTag: String      // Place.rawValue, or "remote"
        let attention: Attention
        /// The collapsed row's cluster: its panes' dots (`PaneDot.cluster`).
        let states: [PaneDot]
        let tabs: [SidebarTab]
        /// A remote host's session (VigilRemote): the header text of the
        /// host group it sits under; nil = this Mac. Row ids of remote
        /// workspaces are `device/name`.
        var host: HostHeader?
        /// A move of it being decided or done ("mbp-m4: Waiting for your
        /// yes in Authz"), from the destination's ticket (`moveNote`).
        var moving: String?

        /// A Mac's header: its name, and how it stands when that is not
        /// "here and live" ("away since 12:34", why it cannot be read).
        /// Two facts, drawn apart: joined in one string the standing read
        /// as part of the Mac's name.
        struct HostHeader: Equatable {
            var name: String
            var standing: String?
            var renewalURL: URL? = nil
            /// Its facts as it last sent them (`Open.machine`), or that what it
            /// sent does not read here; nil until it has sent anything (a Mac
            /// whose app predates it never does).
            var machine: VigilMachine.Heard?
        }

        /// The ONE tab whose row the tree elides: a lone tab that carries
        /// no information of its own (no name, no face). A lone NAMED tab
        /// earns its row like any tab among many.
        var soleTab: SidebarTab? {
            guard tabs.count == 1, let only = tabs.first, !only.named else { return nil }
            return only
        }
    }

    /// Row identity FOLLOWS THE TAB (its anchor pane), never its
    /// position: index-based ids made selection, collapse and rename
    /// UI stick to whatever tab happened to sit at that row after a
    /// reorder (the renamed-tab-was-a-different-terminal bug).
    nonisolated static func tabRowId(_ session: String, anchor: String?, index: Int = 0) -> String {
        anchor.map { "\(session)-tab-\($0)" } ?? "\(session)-t\(index)"
    }

    // MARK: A pane's facts, read from one facts revision

    /// Immutable file facts are loaded by the directory watcher off main.
    struct PaneState {
        let state: AgentState
        let flavor: BlockFlavor?
        let since: Date
        let revision: String
    }

    /// A watcher's self-declaration (sd_notify's shape on vigil's rails):
    /// one JSON file in leases/, written by the watching process itself,
    /// removed on exit. The lease says WHY (note) and UNTIL WHEN
    /// (deadline); liveness is NEVER trusted from the file - the pid must
    /// be alive. Spec: PROTOCOL.md.
    struct WatchLease: Equatable {
        let pane: String
        let note: String
        let deadline: Date?
    }

    nonisolated static func lines(_ facts: VigilFacts.Snapshot, _ pane: String, _ ext: String) -> [String] {
        facts.files["panes/\(pane).\(ext)"]?.lines ?? []
    }

    /// The tty's foreground pid (`<pane>.pid`'s third line, the tty's
    /// e_tpgid).
    nonisolated static func foreground(_ facts: VigilFacts.Snapshot, _ pane: String) -> Int32? {
        let lines = lines(facts, pane, "pid")
        return lines.count >= 3 ? Int32(lines[2].trimmingCharacters(in: .whitespaces)) : nil
    }

    /// The label of the pane's deep foreground process; nil = the shell
    /// itself holds the tty (a pane at its prompt).
    nonisolated static func foregroundLabel(_ facts: VigilFacts.Snapshot, _ pane: String) -> String? {
        Program.foreground(tree: lines(facts, pane, "tree"), pid: foreground(facts, pane))
    }

    /// One pane's program, what you see in it (`Program.of`, the rule every
    /// row on every device names a pane by).
    nonisolated static func program(_ facts: VigilFacts.Snapshot, _ pane: String) -> String? {
        Program.of(tree: lines(facts, pane, "tree"), foreground: foreground(facts, pane))
    }

    /// What this Mac knows of one of its panes, in the directory's own shape
    /// (`Directory.Facts`, what `vigild dir` would print for it), so the
    /// sidebar names its rows by the very rule the phone and a remote
    /// sidebar apply to the same pane (`Directory.titles`). The three files
    /// that need decoding are decoded by the caller (which says when one
    /// does not read).
    nonisolated static func directoryFacts(_ facts: VigilFacts.Snapshot, _ pane: String,
                                           glance: PaneGlance?, ended: PaneEnd?, conflict: PaneConflict?) -> Directory.Facts {
        // Not alive: its daemon was found gone with its pidfile left.
        Directory.Facts(alive: !facts.gone.contains(pane), tree: lines(facts, pane, "tree"),
                        pid: lines(facts, pane, "pid").joined(separator: "\n"),
                        blankOutput: facts.files["panes/\(pane).blank-output"] != nil,
                        title: lines(facts, pane, "title").first, glance: glance,
                        // A row is marked by an end that keeps its pane; a
                        // clean one's pane is closing.
                        ended: ended.flatMap { $0.clean ? nil : $0 },
                        conflict: conflict)
    }

    /// The pane's continuous program state as its broker last published it
    /// on this Mac (`StateToken`).
    nonisolated static func localAgentState(_ facts: VigilFacts.Snapshot, _ pane: String) -> PaneState? {
        guard let file = facts.files["state/\(pane).state"] else { return nil }
        guard let token = StateToken(file.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            attentionLog.error("state file holds no state", ["pane": pane, "text": file.text])
            return nil
        }
        return PaneState(state: token.state, flavor: token.flavor, since: file.since, revision: file.revision)
    }

    /// When this Mac's pane was last seen: its seen file names the state
    /// revision it saw (`state/<pane>.seen`).
    nonisolated static func localAck(_ facts: VigilFacts.Snapshot, _ pane: String) -> Date? {
        guard let state = facts.files["state/\(pane).state"],
              facts.files["state/\(pane).seen"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) == state.revision
        else { return nil }
        return state.since
    }

    /// Seen-ack changes presentation only; it never resolves a broker request.
    nonisolated static func shown(_ state: PaneState?, ack: Date?) -> AgentState? {
        guard let state else { return nil }
        if state.state == .done || state.state == .blocked, let ack, ack >= state.since { return .idle }
        return state.state
    }

    /// Background SENTRIES under a pane: labeled tree processes that are
    /// neither the shell nor the pane's program - "something is keeping
    /// watch under this quiet pane" (a tg watch under an idle claude, a
    /// build, a server). Truth from the daemon's kqueue tree file, never
    /// inferred from the screen. QUIET is the gate, per pane class: an
    /// adapter-managed pane (agent state file exists) is quiet when the
    /// agent isn't working - the view applies that; a PLAIN pane is quiet
    /// only when the shell itself holds the tty. A foreground TUI's own
    /// subprocess churn (lazygit's git calls) is the program working, not
    /// a sentry - antenna semantics, not process accounting. Declared
    /// leases are never gated: the watcher said why it watches.
    /// `program` is the pane's (`program(_:_:)`) and `managed` whether it
    /// has an agent state (`localAgentState`), passed by a caller that has
    /// them already.
    nonisolated static func watchers(_ facts: VigilFacts.Snapshot, _ pane: String, program: String?, managed: Bool) -> [String] {
        if !managed, foregroundLabel(facts, pane) != nil { return [] }
        var out: [String] = []
        for argv in Program.commands(lines(facts, pane, "tree")) {
            guard let label = Program.label(argv), label != program else { continue }
            let short = argv.count > 90 ? String(argv.prefix(87)) + "…" : argv
            if !out.contains(short) { out.append(short) }
        }
        return out
    }

    nonisolated static func leases(_ facts: VigilFacts.Snapshot) -> [String: [WatchLease]] {
        Dictionary(grouping: facts.leases.map {
            WatchLease(pane: $0.pane, note: $0.note, deadline: $0.deadline.map(Date.init(timeIntervalSince1970:)))
        }, by: \.pane)
    }

    /// What the row of workspace `name` (of `home`; nil: this Mac, whose
    /// move root is `root`) says of a move of it being decided or done,
    /// from every destination's tickets.
    nonisolated static func moveNote(home: String?, workspace name: String, root: String?,
                                     destinations: [(name: String, tickets: [Move.Ticket])]) -> String? {
        guard let source = home ?? root else { return nil }
        return Move.note(workspace: name, source: source, destinations: destinations)
    }
}

/// Everything the rows are built from, read on the main thread in one pass
/// (`VigilWorkspaces.sidebarInputs`): values only, so the rows can be worked
/// out anywhere.
struct SidebarInputs {
    struct Workspace {
        let name: String
        let label: String
        let emoji: String?
        let order: Int
        let attention: VigilWorkspaces.Attention
        let place: VigilWorkspaces.Place
        let tabs: [Registry.Tab]
        /// The panes that have a live view on this Mac (a member tree, a
        /// dock, a held runtime): a tab with none is captured.
        let live: Set<String>
    }

    /// Another Mac, as its rows need it: its header already worked out.
    struct Remote {
        let device: String
        let header: VigilWorkspaces.SidebarWorkspaceRow.HostHeader
        let directory: Directory?
        let away: Bool
        /// Live and answering: its conversations run now.
        let answering: Bool
    }

    var workspaces: [Workspace]
    var facts: VigilFacts.Snapshot
    var phoneFollows: Set<String>
    var continuations: [String: Registry.OfflineContinuation]
    var remotes: [Remote]
    var moveRoot: String?
    var moveDestinations: [(name: String, tickets: [Move.Ticket])]
    var home: String
}

/// The rows, as `SidebarBuilder` built them.
struct SidebarBuilt {
    var rows: [VigilWorkspaces.SidebarWorkspaceRow] = []
    /// Conversations written by more than one live pane, read off the rows.
    var writerProblems: [ConversationRef: ConversationProblem] = [:]
    /// The read the last build was made from (`VigilSidebarSnapshots`),
    /// whether or not its rows differed: 0 for none yet.
    var capture: UInt64 = 0
    /// Moves with every build whose rows differ from the one before.
    var revision: UInt64 = 0
}

/// What a pane's facts come to (its program, what its agent means) and what
/// a tab's panes are called, worked out again only when the facts they come
/// from changed. Worked out at every refresh of every window, they were most
/// of the main thread's work at idle (the Time Profiler on the M4: the
/// snapshot 1,800 of 3,441 ms over 40 s, of which `Program.of` reading the
/// process trees 1,197 ms and the names 439 ms). Owned by one builder, used
/// on its queue alone.
final class SidebarDerived {
    /// The facts a pane's program, meaning and name read, and nothing else
    /// (`Facts.program`: the tree and the tty's foreground; `Facts.meaning`:
    /// those and the glance; `Pane.ownName`: those and the title it set), so
    /// a screen that changes on a busy pane keeps what was worked out.
    struct Read: Equatable {
        var tree: [String]?
        var foreground: Int32?
        var glance: PaneGlance?
        var title: String?
        init(_ facts: Directory.Facts) {
            tree = facts.tree; foreground = facts.foreground; glance = facts.glance; title = facts.title
        }
    }

    private var panes: [String: (read: Read, program: String?, meaning: PaneGlance?)] = [:]
    private var titles: [[String]: (members: [Registry.Pane], read: [Read?], names: [String])] = [:]
    /// The panes and tabs the build under way asked for: everything else is
    /// dropped when it is done (`keepOnly`).
    private var askedPanes: Set<String> = []
    private var askedTabs: Set<[String]> = []

    func pane(_ id: String, _ facts: Directory.Facts) -> (program: String?, meaning: PaneGlance?) {
        askedPanes.insert(id)
        let read = Read(facts)
        if let held = panes[id], held.read == read { return (held.program, held.meaning) }
        let derived = (read: read, program: facts.program, meaning: facts.meaning)
        panes[id] = derived
        return (derived.program, derived.meaning)
    }

    func titles(_ members: [Registry.Pane], _ facts: [String: Directory.Facts], home: String) -> [String] {
        let key = members.map(\.id)
        askedTabs.insert(key)
        let read: [Read?] = members.map { facts[$0.id].map(Read.init) }
        if let held = titles[key], held.members == members, held.read == read { return held.names }
        let names = Directory.titles(of: members, facts: facts, home: home)
        titles[key] = (members, read, names)
        return names
    }

    /// The build is done: what it no longer holds is forgotten.
    func keepOnly() {
        panes = panes.filter { askedPanes.contains($0.key) }
        titles = titles.filter { askedTabs.contains($0.key) }
        askedPanes.removeAll()
        askedTabs.removeAll()
    }
}

/// Builds the rows from `SidebarInputs`, on one queue (it is not shared
/// between threads): every session, wherever displayed → its tabs → their
/// panes (splits AND dock tenants), each pane named and decorated from its
/// daemon's facts (program from the tree file, title from `<pane>.title`)
/// and its continuous AgentState, never from a live view; then every other
/// Mac's rows from its directory. Every registered row renders whether or
/// not its view exists yet: nothing flashes while a tab mounts. Sendable
/// unchecked as `VigilFacts` is: its caches are touched by its owner's one
/// queue alone (`VigilSidebarSnapshots`).
final class SidebarBuilder: @unchecked Sendable {
    private let derived = SidebarDerived()
    /// Each decoded file by pane, kept while its revision stands: a glance,
    /// an end record or a conflict record is decoded once per change of its
    /// file, and one that does not read is said once per change.
    private var glances: [String: (revision: String, value: PaneGlance?)] = [:]
    private var ends: [String: (revision: String, value: PaneEnd?)] = [:]
    private var conflicts: [String: (revision: String, value: PaneConflict?)] = [:]

    private func decoded<T: Decodable>(_ cache: inout [String: (revision: String, value: T?)], _ pane: String,
                                       _ file: VigilFacts.File?, unread: (any Error) -> Void) -> T? {
        guard let file else {
            cache[pane] = nil
            return nil
        }
        if let held = cache[pane], held.revision == file.revision { return held.value }
        let value: T?
        do { value = try JSONDecoder().decode(T.self, from: file.data) } catch {
            unread(error)
            value = nil
        }
        cache[pane] = (file.revision, value)
        return value
    }

    func build(_ input: SidebarInputs) -> [VigilWorkspaces.SidebarWorkspaceRow] {
        let facts = input.facts
        let leases = VigilWorkspaces.leases(facts)

        func paneFacts(_ pane: String) -> Directory.Facts {
            let glance: PaneGlance? = decoded(&glances, pane, facts.files["state/\(pane).glance"]) {
                sidebarLog.warn("glance not read: the pane is named without it", ["pane": pane, "err": $0])
            }
            let ended: PaneEnd? = decoded(&ends, pane, facts.files["panes/\(pane).ended"]) {
                sidebarLog.warn("ended record not read: the pane is drawn unmarked", ["pane": pane, "err": $0])
            }
            let conflict: PaneConflict? = decoded(&conflicts, pane, facts.files["state/\(pane).conflict"]) {
                sidebarLog.warn("conflict record not read: the pane is drawn unmarked", ["pane": pane, "err": $0])
            }
            return VigilWorkspaces.directoryFacts(facts, pane, glance: glance, ended: ended, conflict: conflict)
        }

        /// A tab's panes (splits, then the dock) named by the one rule every
        /// surface reads (`Directory.titles`: yours, an agent's conversation
        /// from its glance, then its daemon's published title, what runs
        /// there, ...), from this Mac's files in the directory's own shape,
        /// so the phone reads the very same names.
        func paneRows(_ tab: Registry.Tab) -> [VigilWorkspaces.SidebarPane] {
            let members = tab.members
            let known = Dictionary(uniqueKeysWithValues: members.map { ($0.id, paneFacts($0.id)) })
            let names = derived.titles(members, known, home: input.home)
            return members.indices.map {
                paneRow(members[$0], title: names[$0], facts: known[members[$0].id]!,
                        tabAlias: members.count == 1 ? tab.label : nil, isDock: $0 >= tab.panes.count)
            }
        }

        func paneRow(_ pane: Registry.Pane, title: String, facts paneFacts: Directory.Facts,
                     tabAlias: String?, isDock: Bool) -> VigilWorkspaces.SidebarPane {
            let (program, meaning) = derived.pane(pane.id, paneFacts)
            let state = VigilWorkspaces.localAgentState(facts, pane.id)
            return VigilWorkspaces.SidebarPane(
                id: pane.id,
                paneId: pane.id,
                title: title,
                messageAlias: pane.label ?? tabAlias,
                program: program,
                state: VigilWorkspaces.shown(state, ack: VigilWorkspaces.localAck(facts, pane.id)),
                isDock: isDock,
                emoji: pane.emoji,
                watchNotes: leases[pane.id]?.map(\.note) ?? [],
                watchProcs: VigilWorkspaces.watchers(facts, pane.id, program: program, managed: state != nil),
                left: meaning?.agent == "claude" ? (meaning?.background?.commands ?? []) : nil,
                lookers: Viewer.parse(VigilWorkspaces.lines(facts, pane.id, "viewers").joined(separator: "\n")),
                followed: input.phoneFollows.contains(pane.id),
                priority: pane.priority ?? .normal,
                conversationRef: meaning?.reference,
                conversationName: meaning?.title,
                resumeMenu: meaning?.resumeMenu,
                account: meaning?.account,
                accountBlock: meaning?.accountBlock,
                liveConversation: paneFacts.alive ? meaning?.reference : nil,
                forkedFrom: meaning?.forkedFrom,
                member: meaning?.member,
                background: meaning?.background,
                ended: paneFacts.ended,
                arrived: pane.dormant == true ? pane.from : nil,
                problems: paneFacts.liveProblems + [input.continuations[pane.id]?.problem].compactMap { $0 },
                restart: paneFacts.problemGlance?.restart,
                resume: paneFacts.problemGlance?.resume,
                conflict: paneFacts.conflict)
        }

        var rows: [VigilWorkspaces.SidebarWorkspaceRow] = []
        for session in input.workspaces.sorted(by: { ($0.order, $0.label) < ($1.order, $1.label) }) {
            let name = session.name
            var tabs: [VigilWorkspaces.SidebarTab] = []
            // A tab's skim label: yours, else WHERE it lives (home as `~`),
            // namesakes numbered: the phone's rule, the phone's strings.
            let tabTitles = Directory.titles(ofTabs: session.tabs, home: input.home)
            for (index, tab) in session.tabs.enumerated() {
                let ids = tab.paneIds
                guard !ids.isEmpty else { continue }
                let anchor = tab.panes.first?.id ?? tab.dock?.panes.first?.id
                tabs.append(VigilWorkspaces.SidebarTab(
                    id: VigilWorkspaces.tabRowId(name, anchor: anchor, index: index),
                    title: tabTitles[index],
                    index: index,
                    panes: paneRows(tab),
                    anchor: anchor,
                    captured: !ids.contains(where: session.live.contains),
                    emoji: tab.emoji,
                    named: tab.label?.isEmpty == false || tab.emoji?.isEmpty == false))
            }
            rows.append(VigilWorkspaces.SidebarWorkspaceRow(
                id: name,
                emoji: session.emoji,
                label: session.label,
                stateTag: session.place.rawValue,
                attention: session.attention,
                states: PaneDot.cluster(tabs.flatMap(\.panes).flatMap(\.foldedDots)),
                tabs: tabs))
        }
        derived.keepOnly()
        let present = Set(facts.files.keys)
        glances = glances.filter { present.contains("state/\($0.key).glance") }
        ends = ends.filter { present.contains("panes/\($0.key).ended") }
        conflicts = conflicts.filter { present.contains("state/\($0.key).conflict") }
        // A move under way, on the row of what moves, wherever it is asked
        // and wherever it goes.
        return (rows + Self.remoteRows(input.remotes)).map { row in
            var row = row
            let home = VigilRemote.split(row.id)
            row.moving = VigilWorkspaces.moveNote(home: home?.device, workspace: home?.name ?? row.id,
                                                  root: input.moveRoot, destinations: input.moveDestinations)
            return row
        }
    }

    /// The sidebar's rows for every remote Mac, built like this Mac's:
    /// session → tabs → panes, program and state by the rules every row
    /// follows (`Program`, `AgentState`). Everything captured (no local
    /// views exist), row ids namespaced by the Mac.
    static func remoteRows(_ remotes: [SidebarInputs.Remote]) -> [VigilWorkspaces.SidebarWorkspaceRow] {
        var rows: [VigilWorkspaces.SidebarWorkspaceRow] = []
        for host in remotes {
            guard let dir = host.directory else {
                rows.append(.init(
                    id: VigilRemote.compositeId(host.device, ""), emoji: nil, label: "…",
                    stateTag: "remote", attention: .none, states: [], tabs: [], host: host.header))
                continue
            }
            // A pane's name among its tab's (`Directory.title(of:)`): the
            // first live tab that lists it names it, worked out once per tab.
            var paneTitles: [String: String] = [:]
            for workspace in dir.live {
                for tab in workspace.tabs ?? [] {
                    let members = tab.members
                    let names = Directory.titles(of: members, facts: dir.panes, home: dir.home)
                    for (index, member) in members.enumerated() where paneTitles[member.id] == nil {
                        paneTitles[member.id] = names[index]
                    }
                }
            }
            // An away Mac's workspaces by what last mattered; a live one's in
            // its own order.
            for session in host.away ? dir.byLastActivity : dir.ordered {
                let composite = VigilRemote.compositeId(host.device, session.name)
                let tabTitles = Directory.titles(ofTabs: session.tabs ?? [], home: dir.home)
                var tabs: [VigilWorkspaces.SidebarTab] = []
                for (index, tab) in (session.tabs ?? []).enumerated() {
                    let all = tab.members
                    guard !all.isEmpty else { continue }
                    let panes = all.enumerated().map { offset, pane -> VigilWorkspaces.SidebarPane in
                        let truth = dir.panes[pane.id]
                        let meaning = truth?.meaning
                        return .init(
                            id: VigilRemote.compositeId(host.device, pane.id),
                            paneId: nil,
                            title: paneTitles[pane.id] ?? pane.ownName(truth, home: dir.home),
                            messageAlias: pane.label ?? (all.count == 1 ? tab.label : nil),
                            program: truth?.program,
                            state: truth?.shown,
                            isDock: offset >= tab.panes.count,
                            emoji: pane.emoji,
                            // Another Mac looking at a remote pane is this
                            // one (two Macs): only the phone is news.
                            lookers: truth?.lookers.filter { $0 == .phone } ?? [],
                            priority: pane.priority ?? .normal,
                            conversationRef: meaning?.reference,
                            conversationName: meaning?.title,
                            resumeMenu: meaning?.resumeMenu,
                            account: meaning?.account,
                            accountBlock: meaning?.accountBlock,
                            liveConversation: host.answering && truth?.alive == true ? meaning?.reference : nil,
                            forkedFrom: meaning?.forkedFrom,
                            member: meaning?.member,
                            background: meaning?.background,
                            ended: truth?.abnormalEnd,
                            problems: (truth?.liveProblems ?? []) + [session.offlineContinuations?[pane.id]?.problem].compactMap { $0 },
                            restart: truth?.problemGlance?.restart,
                            resume: truth?.problemGlance?.resume,
                            conflict: truth?.conflict)
                    }
                    let anchor = all.first.map { VigilRemote.compositeId(host.device, $0.id) }
                    tabs.append(.init(
                        id: VigilWorkspaces.tabRowId(composite, anchor: anchor, index: index),
                        title: tabTitles[index],
                        index: index,
                        panes: panes,
                        anchor: anchor,
                        captured: true,
                        emoji: tab.emoji,
                        named: tab.label?.isEmpty == false || tab.emoji?.isEmpty == false))
                }
                let states = tabs.flatMap(\.panes).compactMap(\.state)
                rows.append(.init(
                    id: composite,
                    emoji: session.emoji,
                    label: session.label,
                    stateTag: host.away ? "away" : "remote",
                    attention: states.contains(.blocked) ? .input : (states.contains(.done) ? .done : .none),
                    states: PaneDot.cluster(tabs.flatMap(\.panes).flatMap(\.foldedDots)),
                    tabs: tabs,
                    host: host.header))
            }
        }
        return rows
    }
}
