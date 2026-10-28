import AuthzGlance
import SwiftUI
import VigilActivity
import VigilWire

/// vigil for iPhone drawn from made-up state, for review in light AND dark
/// (`bin/vigil-ios-fixtures`, launched with `-VigilFixture <name>`): no
/// tether, no Mac, only the views as the widget draws them. Prints
/// "fixture drawn" once on screen, which the script waits for.
enum VigilFixture: String {
    /// The agents Live Activity's Lock Screen faces.
    case activity
    /// More faces: a command, a finished turn, the stale and unopened ones.
    case activityMore = "activity-more"
    /// The Dynamic Island's faces.
    case activityIsland = "activity-island"
    /// An agent pane's conversation: a turn's rows, done, its reply box.
    case conversation
    /// A permission on its tool call's row, a question with its options.
    case conversationWaiting = "conversation-waiting"
    /// A question asked mid-turn, its options as buttons.
    case conversationQuestion = "conversation-question"
    /// The other kinds of rows (a plan, a subagent, a compaction, a
    /// failure, a tool vigil does not type), working.
    case conversationLong = "conversation-long"
    /// A turn done, waiting on its background work: a fork and an agent
    /// running, a shell watching CI, three that ended.
    case conversationBackground = "conversation-background"
    /// A turn at work: a task's end as its line, a command running in the
    /// foreground (Run in background), two messages waiting in its queue
    /// (Send all now), every message with when it was sent.
    case conversationWorking = "conversation-working"
    /// The same turn with the reply box taking the keyboard: the box on the
    /// keyboard, its ↑ ↓ and hide row, nothing over it.
    case conversationTyping = "conversation-typing"
    /// A conversation opened as a phone saw one blank (2026-10-27): its
    /// snapshot of 30 rows, a live update 80 ms later, then new rows and
    /// live updates, each through `Conversation.receive` as the network's.
    /// The list's own check says in the log whether it ever showed no row.
    case conversationArriving = "conversation-arriving"
    /// The home tree: agent panes drawn by their glance (waiting, asked,
    /// working, done and waiting on its background work), a shell and an
    /// agent with no glance beside them, drawn as terminals.
    case home
    /// A terminal surface fed known bytes through a socketpair, as the
    /// transport feeds a pane's stream: prompt colors, the 16 and 256
    /// color palettes, box drawing, wide characters, a title.
    case terminal

    /// The fixture this launch asked for, if any.
    static var asked: VigilFixture? {
        let arguments = CommandLine.arguments
        guard let at = arguments.firstIndex(of: "-VigilFixture"), arguments.indices.contains(at + 1) else { return nil }
        guard let fixture = VigilFixture(rawValue: arguments[at + 1]) else {
            preconditionFailure("no fixture named \(arguments[at + 1])")
        }
        return fixture
    }
}

/// `terminal`: the bytes a pane's stream would carry, written into one end
/// of a socketpair whose other end the surface reads, exactly as the
/// transport hands a pane to the attach backend. Drawn once the core has
/// parsed through the closing title and the display has shown two frames.
private struct TerminalFixture: View {
    @EnvironmentObject private var core: TerminalCore
    @State private var surfaceView: TerminalSurface?

    private static let title = "fixture terminal"

    /// What a shell and a TUI print, one fact per line.
    private static var screen: String {
        let esc = "\u{1b}["
        var lines = [
            "\(esc)1;32madrian@phone\(esc)0m:\(esc)1;34m~/vigil\(esc)0m$ ls --color",
            "\(esc)34mghostty\(esc)0m  \(esc)32mbin\(esc)0m  README.md  \(esc)31mbuild.zip\(esc)0m",
            "",
            (0..<8).map { "\(esc)4\($0)m  \(esc)0m" }.joined() + "  normal",
            (0..<8).map { "\(esc)10\($0)m  \(esc)0m" }.joined() + "  bright",
            stride(from: 16, to: 232, by: 6).map { "\(esc)48;5;\($0)m \(esc)0m" }.joined(),
            "\(esc)1mbold\(esc)0m \(esc)3mitalic\(esc)0m \(esc)4munderline\(esc)0m \(esc)9mstrike\(esc)0m",
            "┌──────────┐",
            "│ 日本語 ✓ │",
            "└──────────┘",
            "\(esc)1;32m❯\(esc)0m ",
        ]
        lines[lines.count - 1] += "\u{1b}]2;\(title)\u{07}"
        return lines.joined(separator: "\r\n")
    }

    var body: some View {
        ZStack {
            core.background.ignoresSafeArea()
            if let surfaceView {
                SurfaceHost(view: surfaceView, purpose: "fixture", interactive: false, visible: true) { _, _ in .own }
            }
        }
        .task { await draw() }
    }

    private func draw() async {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { preconditionFailure("socketpair: \(errno)") }
        let view = TerminalSurface(core.app, pane: "fixture", stream: ends[0])
        view.attended = true
        surfaceView = view
        // Played as vigild plays it: the screen is sent once the client's
        // first size arrives (the surface declared its viewport, laid out
        // in its window), never into the placeholder grid before. The
        // attach's other frames are read and dropped.
        let peer = ends[1]
        await withCheckedContinuation { (sized: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { Self.readFrames(peer, firstSize: sized) }
        }
        let bytes = Array(Self.screen.utf8)
        precondition(write(peer, bytes, bytes.count) == bytes.count, "the fixture's bytes were not written whole")
        // Parsed: the title is the last thing the bytes set.
        for await title in view.$title.values where title == Self.title { break }
        // Drawn: the renderer hands the render layer a new frame after that.
        await Self.nextFrame(of: view)
        print("fixture drawn")
    }

    /// The attach's frames ([type][u16 LE length][payload]) until the
    /// stream ends; `firstSize` resumes at the first size ('r').
    nonisolated private static func readFrames(_ fd: Int32, firstSize: CheckedContinuation<Void, Never>) {
        var pending: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var sized = false
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            pending += chunk[0..<n]
            while pending.count >= 3 {
                let length = Int(pending[1]) | Int(pending[2]) << 8
                guard pending.count >= 3 + length else { break }
                if pending[0] == UInt8(ascii: "r"), !sized {
                    sized = true
                    firstSize.resume()
                }
                pending.removeFirst(3 + length)
            }
        }
        precondition(sized, "the fixture's stream ended before the surface sent its size")
    }

    /// The render layer's next frame: libghostty sets an IOSurface as its
    /// `contents` on the main thread for every frame it presents.
    private static func nextFrame(of view: TerminalSurface) async {
        let mine = Set(view.subviews.map { ObjectIdentifier($0.layer) })
        guard let render = view.layer.sublayers?.first(where: { !mine.contains(ObjectIdentifier($0)) }) else {
            preconditionFailure("the surface has no render layer")
        }
        await withCheckedContinuation { (presented: CheckedContinuation<Void, Never>) in
            let watch = FrameWatch(presented)
            watch.observation = render.observe(\.contents, options: [.new]) { _, _ in watch.fire() }
        }
    }
}

/// One frame awaited: resumes once and stops watching.
private final class FrameWatch: @unchecked Sendable {
    // Main thread only: libghostty sets `contents` there, and the watch is
    // made there.
    var observation: NSKeyValueObservation?
    private var presented: CheckedContinuation<Void, Never>?

    init(_ presented: CheckedContinuation<Void, Never>) { self.presented = presented }

    func fire() {
        observation?.invalidate()
        observation = nil
        presented?.resume()
        presented = nil
    }
}

struct VigilFixtureView: View {
    let fixture: VigilFixture

    var body: some View {
        Group {
            switch fixture {
            case .conversation:
                ConversationFixture(conversation: Self.conversation(Self.turn, live: Self.doneLive,
                                                                    reply: .init(text: "Good. Add a line about it to the changelog.")))
            case .conversationWaiting:
                ConversationFixture(conversation: Self.conversation(Self.asking, live: Self.askingLive, offer: Self.consent))
            case .conversationQuestion:
                ConversationFixture(conversation: Self.conversation(Self.questioning, live: Self.questionLive, offer: Self.question))
            case .conversationLong: ConversationFixture(conversation: Self.conversation(Self.long, live: Self.workingLive, earlier: true))
            case .conversationBackground:
                ConversationFixture(conversation: Self.conversation(Self.launching, live: Self.backgroundLive))
            case .conversationWorking: ConversationFixture(conversation: Self.atWorkConversation)
            case .conversationArriving: ArrivingFixture()
            case .conversationTyping:
                ConversationFixture(conversation: Self.atWorkConversation)
                    .onAppear { VigilPhone.shared.typeInto = Self.pane }
            case .activity, .activityMore, .activityIsland: activity
            case .home:
                // As the app shows it: dark, its tree from `VigilPhone`.
                NavigationStack { HomeView() }
                    .environmentObject(VigilPhone.shared)
                    .preferredColorScheme(.dark)
            case .terminal: TerminalFixture()
            }
        }
        .task {
            // A replay, or a terminal, says when it is done itself.
            guard fixture != .conversationArriving, fixture != .terminal else { return }
            // One turn of the run loop: the views are laid out and drawn.
            await Task.yield()
            print("fixture drawn")
        }
    }

    private var activity: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .teal], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 12) {
                switch fixture {
                case .activity:
                    ForEach(Self.faces.indices, id: \.self) { at in Self.lockScreen(Self.faces[at]) }
                case .activityMore:
                    ForEach(Self.more.indices, id: \.self) { at in Self.lockScreen(Self.more[at]) }
                default:
                    Self.island(Self.faces[0])
                    Self.island(Self.faces[2])
                    HStack(spacing: 10) {
                        Self.compact(Self.faces[0])
                        Self.minimal(Self.faces[0])
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// As the Lock Screen shows it: under the system's material, cut at
    /// 160 pt the way the system cuts a taller view.
    private static func lockScreen(_ shown: AgentsShown) -> some View {
        AgentsLockScreen(shown: shown)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 160, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// The expanded island: below the camera's height, cut at 160 pt, dark.
    private static func island(_ shown: AgentsShown) -> some View {
        AgentsIslandBottom(shown: shown)
            .padding(.horizontal, 12)
            .padding(.top, 38)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 160, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .background(.black, in: RoundedRectangle(cornerRadius: 42, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    private static func compact(_ shown: AgentsShown) -> some View {
        HStack {
            AgentsCompactLeading(shown: shown)
            Spacer(minLength: 120)
            AgentsCompactTrailing(shown: shown)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.black, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private static func minimal(_ shown: AgentsShown) -> some View {
        AgentsMinimal(shown: shown)
            .frame(width: 36, height: 36)
            .background(.black, in: Circle())
            .environment(\.colorScheme, .dark)
    }

    // MARK: Made-up state

    static let mac = "mbp-m5-max"
    static let now = Date().timeIntervalSince1970

    static func shown(_ rows: [Agents.Row], more: Int = 0, stale: Bool = false, opened: Bool = true) -> AgentsShown {
        let lead = rows.first?.state ?? .idle
        return AgentsShown(
            state: AgentsActivity.ContentState(state: lead, since: now - 300), mac: mac,
            note: opened ? Agents(mac: mac, from: "fixture", rows: rows, more: more) : nil, stale: stale)
    }

    static let permission = Agents.Row(
        pane: "vigil-clever-cedar-40", label: "misc › ~ 1 › claude 2", emoji: nil, state: .blocked, flavor: .permission,
        since: now - 95, line: nil, pinned: true,
        detail: Detail(pane: "vigil-clever-cedar-40", agent: "claude", context: 41, turn: now - 400,
                       question: .init(request: "r1", title: "Run a command", body: "swift test --filter InboxTests 2>&1 | tail -20",
                                       answers: .init(allow: "allow", allowLabel: "Allow", deny: "deny", denyLabel: "Deny"))))

    static let asked = Agents.Row(
        pane: "vigil-bold-willow-12", label: "finances › adrian", emoji: "🏦", state: .blocked, flavor: .ask,
        since: now - 1_800, line: "Should I file the Q3 VAT return now, or wait for the last invoice?", pinned: true,
        detail: Detail(pane: "vigil-bold-willow-12", agent: "claude", context: 73))

    static let working = Agents.Row(
        pane: "vigil-proud-heron-0", label: "sentinel", emoji: "🛡️", state: .working, flavor: nil,
        since: now - 40, line: nil, pinned: false,
        detail: Detail(pane: "vigil-proud-heron-0", agent: "claude", action: .init(tool: "Bash", subject: "deps scan --surface github --json | jq '.hits | length'", shell: true),
                       context: 22, turn: now - 260))

    static let done = Agents.Row(
        pane: "vigil-calm-tundra-0", label: "typed-line-test", emoji: nil, state: .done, flavor: nil,
        since: now - 620, line: nil, pinned: false,
        detail: Detail(pane: "vigil-calm-tundra-0", agent: "claude",
                       said: "The watch's message now arrives as a paste followed by its own Enter, so it submits by itself. The drill covers both modes.",
                       context: 12))

    static let command = Agents.Row(
        pane: "vigil-sunny-pulsar-30", label: "authz › build", emoji: nil, state: .done, flavor: nil,
        since: now - 30, line: nil, pinned: false, agent: false,
        command: CommandFact(started: now - 212, ended: now - 30, exit: 1, line: "swift build -c release"))

    /// The first faces: a permission with others waiting, a question its
    /// turn ended on, a working agent, nothing needing you.
    static let faces: [AgentsShown] = [
        shown([permission, asked, working], more: 1),
        shown([asked]),
        shown([working, done]),
        shown([]),
    ]

    /// The rest: a finished turn's words, a failed command, out of date,
    /// not openable here.
    static let more: [AgentsShown] = [
        shown([done]),
        shown([command]),
        shown([permission], stale: true),
        shown([permission], opened: false),
    ]
}

// MARK: - The home tree, made up

extension VigilFixtureView {
    static let host = VigilPhone.Host(id: "fixture", name: mac)

    private static func agent(_ pane: String, _ title: String, _ state: AgentState, flavor: BlockFlavor? = nil,
                              glance: PaneGlance?) -> VigilPhone.Node {
        VigilPhone.Node(id: "fixture/lively-harbor/\(pane)", kind: .pane, title: title, state: state, flavor: flavor,
                        agent: true, glance: glance, pane: PaneRef(host: host, pane: pane, title: "minerlab › \(title)"),
                        rows: glance == nil ? 40 : 0, cols: glance == nil ? 120 : 0, path: "minerlab › \(title)",
                        followPane: pane, anchor: pane)
    }

    private static func tab(_ index: Int, _ title: String, _ panes: [VigilPhone.Node]) -> VigilPhone.Node {
        VigilPhone.Node(id: "fixture/lively-harbor/t\(index)", kind: .tab, title: title, anchor: panes.first?.followPane,
                        children: panes)
    }

    /// Minerlab as the M5 shows it: a codex scoring, two claudes in one tab
    /// (one waiting on a permission, one that asked a question), a claude
    /// done four minutes ago with two agents and a shell still running in
    /// the background, beside a shell, and a claude whose Mac
    /// publishes no glance (an older broker): a terminal, as before.
    static let home: [VigilPhone.Node] = {
        let codex = agent("vigil-lively-harbor-88", "Score the qubic miners", .working, glance: PaneGlance(
            agent: "codex", conversation: "0199f3c2-7d41-7a10-9c2e-5b8e1f0a3d77", name: "Score the qubic miners",
            prompt: "score the last two epochs and tell me if our miners beat the pool average",
            said: """
            Epoch 141 is scored: our 7 keys averaged **4,061** against the pool's 3,980, so we are ahead by about 2%. \
            ALPWDHYK carried most of it; GNNYAYWW is still below average after its restart.

            Running 142 with the top 20 now, then I'll compare both epochs against the pool's numbers.
            """,
            saidAt: now - 14,
            action: .init(tool: "Bash", subject: "python3 score.py --epoch 142 --top 20", shell: true), actionAt: now - 12,
            context: 33, turn: now - 340))
        let waiting = agent("vigil-lively-harbor-90", "Urgent qubic/core commit", .blocked, flavor: .permission, glance: PaneGlance(
            agent: "claude", conversation: "00f4d5db-1c3e-4b9a-8f2d-6a7e9b0c1d2e", name: "Urgent qubic/core commit",
            prompt: "the fill is destroying built cores, fix it and ship it before the next epoch",
            said: """
            Found it: the fill phase still drew about 22% wiring walks, which rewired a built core back into chaos. \
            r119 makes the fill use LUT walks only, so a built machine survives its fill.

            The fix is committed on `core-fix` and the tests pass. Pushing it so CI picks it up.
            """, saidAt: now - 97,
            question: "Run git push origin core-fix", context: 58, turn: now - 95))
        let asked = agent("vigil-lively-harbor-91", "pgbot infra integration", .blocked, flavor: .ask, glance: PaneGlance(
            agent: "claude", conversation: "7b2e0a41-93c8-4d6f-a1b5-2c9e8d7f6a50", name: "pgbot infra integration",
            prompt: "move pgbot onto the infra registry",
            said: """
            Done for production: the bot now reads its pool from the infra registry and the health check passes. \
            I kept the old config file as a fallback for one release.

            Should I also move the staging bot over, or keep it on the old config for now?
            """,
            saidAt: now - 600, question: "Should I also move the staging bot over, or keep it on the old config for now?",
            context: 71))
        let done = agent("vigil-lively-harbor-92", "Fix the hashrate chart", .done, glance: PaneGlance(
            agent: "claude", conversation: "c41d77e0-5a2b-4e19-b8f3-90d1e2a3b4c5", name: "Fix the hashrate chart",
            prompt: "the hashrate chart spikes every few minutes, it makes it unreadable",
            said: """
            Fixed: the chart now plots the 1h average instead of raw samples, so the spikes are gone.

            The spikes were real samples: each restart reports its first minute at 10x before it settles. \
            The average hides them; the raw line is still one tap away under **Details**.

            The tests pass. The parity run and the fork culling the failed phase are still going in the background.
            """,
            saidAt: now - 240, context: 24, background: .init(agents: 2, shells: 1, title: "Waiting on the parity run")))
        let shell = VigilPhone.Node(id: "fixture/lively-harbor/vigil-lively-harbor-93", kind: .pane, title: "fish", state: .idle,
                                    pane: PaneRef(host: host, pane: "vigil-lively-harbor-93", title: "minerlab › fish"),
                                    rows: 40, cols: 120, path: "minerlab › fish", followPane: "vigil-lively-harbor-93",
                                    anchor: "vigil-lively-harbor-93")
        let older = agent("vigil-lively-harbor-94", "claude", .working, glance: nil)
        var workspace = VigilPhone.Node(id: "fixture/lively-harbor", kind: .workspace, title: "minerlab", emoji: "⛏️",
                                        anchor: "vigil-lively-harbor-93")
        workspace.children = [
            tab(0, "scorer", [codex]),
            tab(1, "minerlab 1", [waiting, asked]),
            tab(2, "minerlab 2", [done, shell, older]),
        ]
        var mac = VigilPhone.Node(id: "host:fixture", kind: .host, title: Self.mac)
        mac.children = [workspace]
        return [mac]
    }()
}

// MARK: - A conversation, made up

extension VigilFixtureView {
    static let pane = PaneRef(host: .init(id: "fixture", name: mac), pane: "vigil-quiet-ledger-3", title: "ledger › claude")

    static func conversation(_ entries: [FeedEntry], live: FeedLive, earlier: Bool = false, offer: Conversation.Offer? = nil,
                             reply: Conversation.Reply? = nil) -> Conversation {
        Conversation(ref: pane, entries: entries, live: live, earlier: earlier, offer: offer, reply: reply)
    }

    static var atWorkConversation: Conversation {
        Conversation(
            ref: pane, entries: atWork, live: FeedLive(state: .working, context: 61),
            queued: [FeedQueued(text: "also check the CSV header while you wait", at: now - 40),
                     FeedQueued(text: "and keep the old column names", at: now - 12)])
    }

    static let consent = Conversation.Offer.consent(allow: "allow", allowLabel: "Allow", deny: "deny", denyLabel: "Deny")

    static let question = Conversation.Offer.choices([
        .init(id: "q", title: "Which staging should it go to?", multiple: false, choices: [
            .init(id: "eu", label: "eu-staging", description: "Frankfurt, the one QA uses"),
            .init(id: "us", label: "us-staging"),
            .init(id: "both", label: "Both"),
        ]),
    ])

    /// A question standing on its call.
    static let questioning: [FeedEntry] = Array(turn.suffix(3)) + [
        row("p2", "p2", .prompt(.init(text: Clip(text: "Ship it to staging.")))),
        tool("q1", "p2", "AskUserQuestion", .question([
            .init(header: "Target", question: "Which staging should it go to?", options: ["eu-staging", "us-staging", "Both"], multiple: false),
        ]), nil),
    ]

    static let questionLive = FeedLive(state: .blocked, flavor: .question, request: .init(id: "fixture-question", toolUse: "q1"), context: 40)

    private static func row(_ id: String, _ turn: String, _ body: FeedEntry.Body) -> FeedEntry {
        FeedEntry(id: id, at: now, turn: turn, native: "fixture", body: body)
    }

    private static func tool(_ id: String, _ turn: String, _ name: String, _ call: ToolCall.Call, _ result: ToolCall.Result?,
                             task: String? = nil) -> FeedEntry {
        row(id, turn, .tool(ToolCall(id: id, name: name, call: call, result: result, task: task)))
    }

    static let root = "/Users/adrian/Developer/ledger/src/reports"

    /// A finished turn: asked, searched, read, explained, patched, tested.
    static let turn: [FeedEntry] = [
        row("p1", "p1", .prompt(.init(text: Clip(text: "The monthly export times out for big months. Find out why and fix it, keep the CSV columns as they are.")))),
        row("k1", "p1", .thinking(Clip(text: "Probably the row builder: check how the rows are fetched before guessing at the formatter."))),
        tool("t1", "p1", "Grep", .search(pattern: "buildExportRows", path: root),
             .init(status: .ok, output: Clip(text: "src/reports/export.ts:42\nsrc/reports/export.test.ts:8"))),
        tool("t2", "p1", "Read", .read(path: "\(root)/export.ts", offset: 30, limit: 60), .init(status: .ok)),
        row("r1", "p1", .reply(Clip(text: """
            The export loads **every row of the month** before writing a single line:

            - `fetchRows` runs one query per account
            - the formatter copies the whole array twice

            Streaming the rows fixes both, and the columns stay as they are.
            """))),
        tool("t3", "p1", "Edit", .patch(path: "\(root)/export.ts", hunks: [
            .init(oldStart: 41, oldLines: 4, newStart: 41, newLines: 5, lines: [
                " export async function buildExportRows(month: Month) {",
                "-  const rows = await Promise.all(accounts.map(fetchRows))",
                "-  return rows.flat().map(formatRow)",
                "+  for await (const row of streamRows(month)) {",
                "+    yield formatRow(row)",
                "+  }",
                " }",
            ]),
        ], exact: true, created: false), .init(status: .ok)),
        tool("t4", "p1", "Bash", .shell(command: "npm test -- reports/export", description: "Run the export tests", background: false),
             .init(status: .ok, output: Clip(text: "PASS src/reports/export.test.ts\n  ✓ streams a month of 40 000 rows (812 ms)\n\nTests: 12 passed, 12 total"))),
        tool("t5", "p1", "TodoWrite", .todos([
            .init(text: "Find why the export times out", status: "completed"),
            .init(text: "Stream the rows", status: "completed"),
            .init(text: "Check the mobile app still parses the file", status: "in_progress"),
        ]), .init(status: .ok)),
        row("r2", "p1", .reply(Clip(text: "Fixed: the export now streams its rows. A 40 000 row month takes under a second, and the tests pass."))),
        row("e1", "p1", .event(.turnEnded(milliseconds: 134_000))),
    ]

    static let doneLive = FeedLive(state: .done, context: 38, title: "Fix the monthly export")

    /// A turn waiting on a permission, after one that asked a question.
    static let asking: [FeedEntry] = Array(turn.suffix(4)) + [
        row("p2", "p2", .prompt(.init(text: Clip(text: "Ship it to staging.")))),
        tool("q1", "p2", "AskUserQuestion", .question([
            .init(header: "Target", question: "Which staging should it go to?", options: ["eu-staging", "us-staging", "Both"], multiple: false),
        ]), .init(status: .ok, answers: ["Which staging should it go to?": "eu-staging"])),
        row("r3", "p2", .reply(Clip(text: "Building the release for eu-staging."))),
        tool("t6", "p2", "Bash", .shell(command: "rm -rf build && npm run build:release -- --target eu-staging", description: "Clean release build", background: false), nil),
    ]

    static let askingLive = FeedLive(state: .blocked, flavor: .permission, request: .init(id: "fixture-request", toolUse: "t6"), context: 41)

    /// Every other kind of row, the turn still running.
    static let long: [FeedEntry] = [
        row("x1", "x1", .event(.compacted(trigger: "auto", before: 162_000, after: 14_000))),
        row("x2", "x1", .event(.summary(Clip(text: "Working on the monthly export: rows now stream; the mobile app's parser is next.")))),
        row("x3", "x3", .event(.command(name: "/model", arguments: "opus"))),
        row("x4", "x3", .event(.notice(Clip(text: "Set model to opus")))),
        row("x5", "x5", .prompt(.init(text: Clip(text: "Plan the mobile side before touching it."), images: 1))),
        tool("x6", "x5", "ExitPlanMode", .plan(Clip(text: """
            ## Plan
            1. Read how the app parses the CSV
            2. Add a test with a 40 000 row file
            3. Stream the parse the same way
            """)), .init(status: .ok)),
        tool("x7", "x5", "WebFetch", .fetch(url: "https://example.com/docs/csv-streaming"), .init(status: .failed, output: Clip(text: "Request failed with status 404"))),
        tool("x8", "x5", "Agent", .agent(description: "Survey the parser's callers", type: "Explore", background: false),
             .init(status: .ok, output: Clip(text: "Three callers: the importer, the preview and the share sheet."))),
        tool("x9", "x5", "mcp__calendar__list", .generic([.init(name: "range", value: "this week"), .init(name: "calendar", value: "work")]), .init(status: .rejected)),
        row("x10", "x5", .event(.failure(Clip(text: "API error: overloaded. Retrying.")))),
        row("x11", "x5", .opaque),
        tool("x12", "x5", "Write", .patch(path: "/Users/adrian/Developer/ledger-app/Tests/ParseTests.swift", hunks: [
            .init(oldStart: 0, oldLines: 0, newStart: 1, newLines: 3, lines: [
                "+func testStreamsALargeFile() async throws {",
                "+  XCTAssertEqual(try await parse(fixture(rows: 40_000)).count, 40_000)",
                "+}",
            ]),
        ], exact: false, created: true), .init(status: .ok)),
        tool("x13", "x5", "Bash", .shell(command: "swift test --filter ParseTests", description: nil, background: false), nil),
    ]

    static let workingLive = FeedLive(state: .working, context: 74)

    /// A turn at work, after a background task it started ended.
    static let atWork: [FeedEntry] = [
        FeedEntry(id: "w1", at: now - 300, turn: "w1", native: "fixture",
                  body: .prompt(.init(text: Clip(text: "Re-import last month's ledger and tell me what changed.")))),
        FeedEntry(id: "w2", at: now - 200, turn: "w1", native: "fixture", body: .event(.taskEnded(AgentTask(
            id: "b7y1", kind: .shell, title: "npm run vet", state: .completed, started: now - 260, ended: now - 200, exitCode: 0)))),
        row("w3", "w1", .reply(Clip(text: "The vet passed. Importing the ledger now; this takes a few minutes."))),
        tool("w4", "w1", "Bash", .shell(command: "python3 import.py --month 2026-09", description: "Import September", background: false), nil),
    ]

    /// A turn that launched its work in the background and ended.
    static let launching: [FeedEntry] = [
        row("b1", "b1", .prompt(.init(text: Clip(text: "Cull the failed phase in a fork, survey the parsers, and wait for CI.")))),
        tool("b2", "b1", "Agent", .agent(description: "Cull a failed core phase", type: "fork", background: true),
             .init(status: .ok, output: Clip(text: "Async agent launched successfully.")), task: "a16bec942d6e67d1f"),
        tool("b3", "b1", "Agent", .agent(description: "Survey the parsers' callers", type: "Explore", background: true),
             .init(status: .ok, output: Clip(text: "Async agent launched successfully.")), task: "a06d1e2f3a4b5c6d7"),
        tool("b4", "b1", "Bash", .shell(command: "gh run watch --exit-status", description: "Wait for CI", background: true),
             .init(status: .ok, output: Clip(text: "Command running in background with ID: bq3x9.")), task: "bq3x9"),
        row("b5", "b1", .reply(Clip(text: "Three things run in the background now. I'll pick each up as it finishes."))),
        row("b6", "b1", .event(.turnEnded(milliseconds: 21_000))),
    ]

    static let backgroundLive = FeedLive(state: .done, context: 46, title: "Cull the failed phase", background: [
        AgentTask(id: "a16bec942d6e67d1f", kind: .fork, title: "Cull a failed core phase", state: .running, started: now - 1_205,
                  label: "Waiting on the parity run", tokens: 594_100),
        AgentTask(id: "a06d1e2f3a4b5c6d7", kind: .agent, title: "Survey the parsers' callers", state: .running, started: now - 312,
                  label: "Reading Parser.swift", tokens: 41_200),
        AgentTask(id: "bq3x9", kind: .shell, title: "Wait for CI", state: .running, started: now - 95),
        AgentTask(id: "a1c2", kind: .agent, title: "Read the pool engine policy", state: .completed, started: now - 2_400,
                       ended: now - 1_300, tokens: 594_100, toolUses: 31),
        AgentTask(id: "b7y1", kind: .shell, title: "npm run vet", state: .failed, started: now - 1_900, ended: now - 1_850, exitCode: 144),
        AgentTask(id: "a9f0", kind: .fork, title: "Port the miner to population 32", state: .ended, started: now - 3_600, ended: now - 2_000),
    ])
}

/// The conversation as the pane screen shows it: under its bar.
/// `conversation-arriving`: a feed's real timing replayed into an empty
/// conversation opened as the app opens one (pushed onto a navigation
/// stack, the snapshot landing mid-slide), then "fixture drawn". The
/// snapshot is a real one when `/tmp/vigil-fixture-feed.json` holds it
/// (`vigil-agent feed <pane> --once > …`: a person's conversation, so a
/// file on the Mac, never in the repository), else made-up rows.
private struct ArrivingFixture: View {
    @State private var conversation = Conversation(ref: VigilFixtureView.pane)
    @State private var path: [Int] = []
    static let realFeed = "/tmp/vigil-fixture-feed.json"

    /// Thirty-odd rows of every height the feed draws, ids unique per round.
    private static var rows: [FeedEntry] {
        (0..<2).flatMap { round in
            (VigilFixtureView.turn + VigilFixtureView.long + VigilFixtureView.atWork).map { entry in
                var entry = entry
                entry.id = "\(round)-\(entry.id)"
                entry.turn = entry.turn.map { "\(round)-\($0)" }
                return entry
            }
        }
    }

    /// The first message, real or made up.
    private static var snapshot: FeedMessage {
        if let data = FileManager.default.contents(atPath: realFeed) {
            do { return try JSONDecoder().decode(FeedMessage.self, from: data) } catch {
                preconditionFailure("\(realFeed) is not a feed message: \(error)")
            }
        }
        return .snapshot(FeedSnapshot(
            pane: VigilFixtureView.pane.pane, agent: "claude", agentVersion: nil, conversation: "fixture",
            entries: Array(rows.dropLast(3)), earlier: true,
            cursor: FeedCursor(conversation: "fixture", parser: "fixture", offset: 0), live: VigilFixtureView.workingLive))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(for: Int.self) { _ in
                    ConversationView(conversation: conversation) {}
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
            .task {
                let cursor = FeedCursor(conversation: "fixture", parser: "fixture", offset: 0)
                let tail = Self.rows.suffix(3).map { entry in
                    var entry = entry
                    entry.id = "new-\(entry.id)"
                    return entry
                }
                try? await Task.sleep(for: .milliseconds(300))
                // Opened as a row's tap opens it, the snapshot 220 ms into
                // the slide (the phone's receipts: present 33.302, snapshot
                // 33.522), a live update 80 ms after it.
                path = [1]
                try? await Task.sleep(for: .milliseconds(220))
                print("fixture: \(FileManager.default.fileExists(atPath: Self.realFeed) ? "the real snapshot" : "made-up rows")")
                conversation.receive(Self.snapshot)
                try? await Task.sleep(for: .milliseconds(80))
                conversation.receive(.live(FeedLive(state: .working, context: 75)))
                for entry in tail {
                    try? await Task.sleep(for: .milliseconds(250))
                    conversation.receive(.entries([entry], cursor: cursor))
                    conversation.receive(.live(FeedLive(state: .working, context: 76)))
                }
                try? await Task.sleep(for: .milliseconds(800))
                print("fixture drawn")
            }
    }
}

private struct ConversationFixture: View {
    let conversation: Conversation
    var body: some View {
        NavigationStack {
            ConversationView(conversation: conversation) {}
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "chevron.left") } }
                    ToolbarItem(placement: .principal) {
                        PaneTitle(title: conversation.ref.title, state: nil, host: conversation.ref.host.name, tint: .gray)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {} label: { Image(systemName: "terminal") }
                        Button {} label: { Image(systemName: "rectangle.stack") }
                    }
                }
        }
    }
}
