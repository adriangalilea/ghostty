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
