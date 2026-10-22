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
            case .activity, .activityMore, .activityIsland: activity
            }
        }
        .task {
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

// MARK: - A conversation, made up

extension VigilFixtureView {
    static let pane = PaneRef(host: .init(id: "fixture", name: mac), pane: "vigil-quiet-ledger-3", title: "ledger › claude")

    static func conversation(_ entries: [FeedEntry], live: FeedLive, earlier: Bool = false, offer: Conversation.Offer? = nil,
                             reply: Conversation.Reply? = nil) -> Conversation {
        Conversation(ref: pane, entries: entries, live: live, earlier: earlier, offer: offer, reply: reply)
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

    private static func tool(_ id: String, _ turn: String, _ name: String, _ call: ToolCall.Call, _ result: ToolCall.Result?) -> FeedEntry {
        row(id, turn, .tool(ToolCall(id: id, name: name, call: call, result: result)))
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
}

/// The conversation as the pane screen shows it: under its bar.
private struct ConversationFixture: View {
    let conversation: Conversation
    var body: some View {
        NavigationStack {
            ConversationView(conversation: conversation) {}
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "chevron.left") } }
                    ToolbarItem(placement: .principal) {
                        PaneTitle(title: conversation.ref.title, line: "\(conversation.ref.host.name) · \(conversation.live?.state.words(conversation.live?.flavor) ?? "")",
                                  tint: conversation.live?.state.tint ?? .gray)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {} label: { Image(systemName: "terminal") }
                        Button {} label: { Image(systemName: "rectangle.stack") }
                    }
                }
        }
    }
}
