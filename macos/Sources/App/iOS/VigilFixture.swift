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
        ZStack {
            LinearGradient(colors: [.indigo, .teal], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 12) {
                switch fixture {
                case .activity:
                    ForEach(Self.faces.indices, id: \.self) { at in Self.lockScreen(Self.faces[at]) }
                case .activityMore:
                    ForEach(Self.more.indices, id: \.self) { at in Self.lockScreen(Self.more[at]) }
                case .activityIsland:
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
        .task {
            // One turn of the run loop: the views are laid out and drawn.
            await Task.yield()
            print("fixture drawn")
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
            note: opened ? Agents(mac: mac, rows: rows, more: more) : nil, stale: stale)
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
