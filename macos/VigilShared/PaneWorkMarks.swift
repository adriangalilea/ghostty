import Ink
import SwiftUI
import VigilWire

/// What runs beside a pane's agent, drawn the same on every surface (the
/// Mac's sidebar rows and folded rows, the phone's tree and its cards). Two
/// marks, one meaning each; a pane's background agents are no mark, they are
/// dots of their own (`PaneDot.agent`).

/// How large a row's marks are, from the size of the row's own text: every
/// mark is as tall as that text's capitals and drawn in lines as thick as
/// its stems, so the count, the gears, the antenna and the dots read as one
/// set. The ratios were chosen on a still bench of the four side by side;
/// a symbol's lines thin with its size, which is why the smaller symbols
/// are the heavier ones.
struct PaneMarkSizes {
    /// The row's text size, in points.
    let text: CGFloat

    /// A count beside a mark: the row's own size, plain.
    var count: Font { .system(size: text, weight: .regular).monospacedDigit() }
    /// A word beside a mark (how a program ended, a Mac's name).
    var word: Font { .system(size: text * 0.9, weight: .regular) }
    /// One symbol standing as a mark.
    var symbol: Font { .system(size: text * 0.82, weight: .medium) }
    /// The point size of the gears (two symbols, each smaller than this).
    var gears: CGFloat { text * 0.95 }
    /// A dot's diameter: the capitals' height.
    var dot: CGFloat { (text * 0.72).rounded() }
    /// Between two marks of a row.
    var gap: CGFloat { (text * 0.36).rounded() }
}

struct PaneProblemItem: Identifiable {
    var id: String { pane + "/" + problem.kind.rawValue }
    let pane: String
    let problem: ConversationProblem
    let button: String
    let act: () -> Void
    var ended: PaneEnd? = nil
    var writers: PaneConflict.Writers? = nil
}

/// A row and its folded ancestors use the same mark. Keeping the contents
/// derived from its current inputs also updates an already-open list.
struct PaneProblemsMark: View {
    let items: [PaneProblemItem]
    let sizes: PaneMarkSizes
    @State private var showing = false

    private var tone: Color {
        if items.contains(where: { $0.writers == .both || $0.problem.kind == .twoLive }) { return .red }
        if items.allSatisfy({ $0.writers != nil }) { return .secondary }
        return .orange
    }

    var body: some View {
        if !items.isEmpty {
            Button { showing = true } label: {
                let ends = items.compactMap(\.ended)
                if ends.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").font(sizes.symbol).foregroundStyle(tone)
                } else {
                    EndedMark(ends: ends, sizes: sizes)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(items.count) pane problems")
            .help(items.map { $0.problem.title }.joined(separator: "\n"))
            .popover(isPresented: $showing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.problem.title).font(.headline)
                                Text(item.pane).font(.caption).foregroundStyle(.secondary)
                                Text(item.problem.says)
                                ForEach(item.problem.fix, id: \.self) { Text($0).font(.callout) }

                                Button(item.button) { showing = false; item.act() }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .frame(idealWidth: 340, idealHeight: min(460, CGFloat(items.count) * 210))
                .presentationCompactAdaptation(.sheet)
            }
        }
    }
}

/// A row's dots, by swift-utils' `InkStateDotCluster`: a pane's own (each
/// background agent not finished, then its main agent's state) or a folded
/// row's. How a dot looks for what it says is here and nowhere else.
struct PaneDots: View {
    let dots: [PaneDot]
    let sizes: PaneMarkSizes
    private var size: CGFloat { sizes.dot }

    var body: some View {
        InkStateDotCluster(dots.map(Self.look), size: size)
            .help(dots.map(Self.said).joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dots.map(Self.said).joined(separator: ", "))
    }

    /// Its motion is the state: a turning arc is at work (the arc alone, a
    /// background agent), a breathing dot waits on the person, a still one
    /// in teal is done and unseen, a faint still one is at rest.
    static func look(_ dot: PaneDot) -> InkStateDotCluster.Dot {
        switch dot {
        case .agent: .init(.turningArc, color: .yellow)
        case .state(.working): .init(.turning, color: .yellow)
        case .state(.blocked): .init(.pulsing, color: .orange)
        case .state(.done): .init(.still, color: .teal)
        case .state(.interrupting): .init(.still, color: .yellow)
        case .state(.unknown): .init(.still, color: .gray)
        case .state(.idle): .init(.still, color: .gray.opacity(0.6))
        }
    }

    static func said(_ dot: PaneDot) -> String {
        switch dot {
        case .agent: "A background agent, not finished"
        case .state(.working): "Working"
        case .state(.blocked): "Waiting for you"
        case .state(.done): "Done, not seen yet"
        case .state(.interrupting): "Interruption requested; waiting for confirmation"
        case .state(.unknown): "Its state is unconfirmed"
        case .state(.idle): "At rest"
        }
    }
}

/// The shells its agent runs in the background: their count, then gears
/// that turn while they run (`PaneGlance.Background.jobs`). Several
/// backgrounds: a folded row's panes, summed. Nothing while there is none.
struct GearsMark: View {
    let backgrounds: [PaneGlance.Background]
    let sizes: PaneMarkSizes

    private var count: Int { backgrounds.reduce(0) { $0 + $1.jobs } }

    var body: some View {
        if count > 0 {
            HStack(spacing: 1) {
                Text("\(count)").font(sizes.count).foregroundStyle(.yellow)
                // swift-utils' `InkTurningGears`: each gear on its own axis,
                // in the render server, still when out of sight.
                InkTurningGears(size: sizes.gears, color: .yellow, period: 3)
            }
            // Its own width, whatever the row has left: squeezed, the count
            // was the first thing clipped.
            .fixedSize()
            .help(said)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(said)
        }
    }

    private var said: String {
        backgrounds.filter { $0.jobs > 0 }.flatMap { ["In the background: \($0.words)"] + [$0.title].compactMap { $0 } }
            .joined(separator: "\n")
    }
}

/// A program that ended badly while nobody looked: red, with how it ended
/// (one pane) or how many did (a folded row, so a fold never hides one).
/// What it says in full (how, when, what it ran) is its tooltip and its
/// spoken label. Opening the pane shows its final screen; closing it clears
/// the mark. Nothing while there is none.
struct EndedMark: View {
    let ends: [PaneEnd]
    let sizes: PaneMarkSizes

    var body: some View {
        if !ends.isEmpty {
            HStack(spacing: 1) {
                Image(systemName: "xmark.octagon.fill").font(sizes.symbol)
                Text(ends.count == 1 ? ends[0].how : "\(ends.count) ended")
                    .font(sizes.word.monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(.red)
            .fixedSize()
            .help(said)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(said)
        }
    }

    private var said: String {
        (ends.map { end in
            "Its program ended, \(end.how), \(Self.when(end.at)): \(end.program)"
        } + ["Open it to see its final screen; close it to clear this."]).joined(separator: "\n")
    }

    static func when(_ at: Double) -> String {
        Date(timeIntervalSince1970: at).formatted(.dateTime.day().month().hour().minute())
    }
}


/// Messages for the pane that you have not read, or that you wrote and wait
/// to be handed to its agent (`MessageThreads.Pending`): an envelope and how
/// many, blue while any is unread, quiet while only yours wait. Several: a
/// folded row's panes, summed. `press`, on one pane's, opens its thread.
/// Nothing while there is none.
struct MessagesMark: View {
    let pending: [MessageThreads.Pending]
    let sizes: PaneMarkSizes
    var press: (() -> Void)?

    private var unread: Int { pending.reduce(0) { $0 + $1.unread } }
    private var waiting: Int { pending.reduce(0) { $0 + $1.waiting } }

    var body: some View {
        if unread + waiting > 0 {
            let mark = HStack(spacing: 1) {
                Image(systemName: "envelope.fill").font(sizes.symbol)
                Text("\(unread > 0 ? unread : waiting)").font(sizes.count)
            }
            .foregroundStyle(unread > 0 ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
            .fixedSize()
            .help(said)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(said)
            if let press {
                Button(action: press) { mark }.buttonStyle(.plain)
            } else {
                mark
            }
        }
    }

    private var said: String {
        var lines: [String] = []
        if unread > 0 { lines.append(unread == 1 ? "1 message you have not read" : "\(unread) messages you have not read") }
        if waiting > 0 { lines.append(waiting == 1 ? "1 of yours waits to be handed to its agent" : "\(waiting) of yours wait to be handed to its agent") }
        return lines.joined(separator: "\n") + (press == nil ? "" : "\nPress to open its thread.")
    }
}

/// Messages waiting on your yes (CHATS.md, decided 2026-11-19: "Waiting for
/// your approval is one mark, defined once and drawn the same everywhere,
/// rolling up as the state dots do"): a raised hand in the care tone and how
/// many, by the messages' ids (`MessageThreads.awaitingYou`), so a fold of
/// rows (a tab, a workspace, a Mac) counts each message once however many
/// of its panes it holds. `press` opens where it is answered. Nothing while
/// none waits.
struct WaitingMark: View {
    let messages: Set<String>
    let sizes: PaneMarkSizes
    var press: (() -> Void)?

    var body: some View {
        if !messages.isEmpty {
            let said = messages.count == 1 ? "1 message waits for your yes" : "\(messages.count) messages wait for your yes"
            let mark = HStack(spacing: 1) {
                Image(systemName: "hand.raised.fill").font(sizes.symbol)
                Text("\(messages.count)").font(sizes.count)
            }
            .foregroundStyle(.orange)
            .fixedSize()
            .help(said + (press == nil ? "" : "\nPress to answer it."))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(said)
            if let press {
                Button(action: press) { mark }.buttonStyle(.plain)
            } else {
                mark
            }
        }
    }
}

/// Watches whose verdict will reach the pane (`WatchRecord`, on its own
/// Mac): binoculars, as a watch is drawn wherever it speaks (a thread's
/// sender), and how many when more than one. In the care tone, with the
/// count of them, while any is broken (its pane gone or holding another
/// conversation, its command failing, a verdict never receipted: each in
/// its tooltip); quiet otherwise. Several: a folded row's panes, summed.
/// `press`, on one pane's, opens its watches. Nothing while none.
struct WatchMark: View {
    let watches: [WatchRecord]
    let sizes: PaneMarkSizes
    var press: (() -> Void)?

    private var broken: [WatchRecord] { watches.filter(\.isBroken) }

    var body: some View {
        if !watches.isEmpty {
            let shown = broken.isEmpty ? watches.count : broken.count
            let mark = HStack(spacing: 1) {
                Image(systemName: "binoculars.fill").font(sizes.symbol)
                if shown > 1 || !broken.isEmpty { Text("\(shown)").font(sizes.count) }
            }
            .foregroundStyle(broken.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(InkTone.warn.color))
            .fixedSize()
            .help(said)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(said)
            if let press {
                Button(action: press) { mark }.buttonStyle(.plain)
            } else {
                mark
            }
        }
    }

    private var said: String {
        let lines = watches.flatMap { w in
            ["\(w.isBroken ? "Broken: " : "")\(w.command.joined(separator: " ")) (\(w.state.words))"] + w.broken.map { "  \($0.words)" }
        }
        return (lines + (press == nil ? [] : ["Press to see its watches."])).joined(separator: "\n")
    }
}

/// Something is alive under the pane that no agent accounts for: what its
/// turns left running, or a watch that declared itself (`what`, a line each).
struct AntennaMark: View {
    let what: [String]
    let sizes: PaneMarkSizes

    var body: some View {
        if !what.isEmpty {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(sizes.symbol)
                .foregroundStyle(.yellow)
                .help(what.joined(separator: "\n"))
                .accessibilityLabel("Left running: \(what.joined(separator: ", "))")
        }
    }
}
