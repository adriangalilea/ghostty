import ActivityKit
import AppIntents
import SwiftUI
import VigilActivity
import VigilWire
import WidgetKit

/// A followed session, tab or pane on the Lock Screen and in the Dynamic
/// Island, shaped by what it needs from you:
///
/// - working: what it does now (the verb in the state's color, the status
///   line's facts as chips), the last lines above its prompt in a terminal
///   well, the turn's clock ticking on the phone;
/// - blocked: the question, its evidence (the command, the edit), and wide
///   Allow / Deny when one tap may answer it (through authz, unlocked);
/// - done and idle: its last words.
///
/// Reply (a line typed into the pane) and Open are always one tap away.
/// Every word beyond the state arrives sealed to this phone (`Detail`) and
/// is opened here with the app's key; without it the activity shows the
/// state alone. Within Apple's limits: 160 pt tall on the Lock Screen,
/// buttons only where they can act (Lock Screen, expanded island), compact
/// views that fit the narrowest island.
@main struct VigilLive: WidgetBundle {
    var body: some Widget { SessionActivityWidget() }
}

struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivity.self) { context in
            LockScreen(context: context, detail: context.state.opened)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .activityBackgroundTint(Color(white: 0.06).opacity(0.82))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let state = context.state.state
            let detail = context.state.opened
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Badge(attributes: context.attributes, state: state, size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Clock(state: context.state, detail: detail)
                        .font(.title3.weight(.semibold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Subtitle(attributes: context.attributes, state: state, detail: detail).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StateContent(context: context, detail: detail, compact: true).padding(.top, 4)
                }
            } compactLeading: {
                Badge(attributes: context.attributes, state: state, size: 22)
            } compactTrailing: {
                if state == .working {
                    Clock(state: context.state, detail: detail).font(.caption.weight(.semibold)).frame(maxWidth: 46)
                } else {
                    Image(systemName: state.symbol).foregroundStyle(state.tint)
                }
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            .widgetURL(context.attributes.url)
            .keylineTint(state.tint)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreen: View {
    let context: ActivityViewContext<SessionActivity>
    let detail: Detail?

    var body: some View {
        let state = context.state.state
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Badge(attributes: context.attributes, state: state, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.label).font(.headline).lineLimit(1)
                    Subtitle(attributes: context.attributes, state: state, detail: detail).font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Clock(state: context.state, detail: detail)
                    .font(.title2.weight(.semibold))
                    .fixedSize()
            }
            StateContent(context: context, detail: detail, compact: false)
        }
    }
}

// MARK: - What the state needs

/// The body under the header, on the Lock Screen and in the expanded
/// island alike (`compact` trims it for the island). Every state is budgeted
/// to Apple's 160 pt Lock Screen limit with the header: past it the system
/// draws nothing at all (a 175 pt layout showed a black activity).
private struct StateContent: View {
    let context: ActivityViewContext<SessionActivity>
    let detail: Detail?
    let compact: Bool

    var body: some View {
        let state = context.state.state
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .blocked:
                if let question = detail?.question {
                    // The evidence is the question (the command, the edit);
                    // the title stands in only when there is none.
                    if let body = question.body, !body.isEmpty {
                        Well(text: body, lines: 2)
                    } else {
                        Text(question.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if let deny = question.deny, let allow = question.allow {
                            AnswerButton(title: "Deny", symbol: "xmark", tint: .red,
                                         intent: AnswerIntent(device: context.attributes.device, request: question.request, action: deny, shown: question.title))
                            AnswerButton(title: "Allow", symbol: "checkmark", tint: .green,
                                         intent: AnswerIntent(device: context.attributes.device, request: question.request, action: allow, shown: question.title))
                        } else {
                            Pill(title: "Answer in vigil", symbol: "arrow.up.forward.app", url: ActivityLink.pane(detail?.pane ?? ""), wide: true)
                        }
                    }
                } else {
                    Text("Waiting for you in the terminal").font(.subheadline.weight(.medium))
                    Actions(detail: detail, facts: false)
                }
            case .working:
                HStack(spacing: 6) {
                    if let now = detail?.now { Now(text: now, tint: state.tint) } else { Facts(detail: detail) }
                    Spacer(minLength: 4)
                    if let pane = detail?.pane {
                        Pill(title: nil, symbol: "arrowshape.turn.up.left.fill", url: ActivityLink.reply(pane), wide: false)
                        Pill(title: nil, symbol: "terminal.fill", url: ActivityLink.pane(pane), wide: false)
                    }
                }
                if let tail = detail?.tail, !tail.isEmpty, !(compact && detail?.now != nil) {
                    Well(text: tail.joined(separator: "\n"), lines: 2)
                }
            case .done, .idle:
                if let said = detail?.said, !said.isEmpty {
                    Text(said)
                        .font(.footnote)
                        .foregroundStyle(state == .idle ? .secondary : .primary)
                        .lineLimit(compact ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let tail = detail?.tail, !tail.isEmpty {
                    Well(text: tail.joined(separator: "\n"), lines: 2)
                }
                Actions(detail: detail, facts: !compact)
            }
            if context.isStale && !compact {
                Label("Not updated lately", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// What it does now: the status line's verb in the state's color, its
/// first fact ("↓ 9.4k tokens") as a chip, and the context; a tool line
/// ("$ bun test") whole, monospaced when it is a command.
private struct Now: View {
    let text: String
    let tint: Color

    var body: some View {
        let parts = text.components(separatedBy: " · ")
        HStack(spacing: 6) {
            Text(parts[0])
                .font(parts[0].hasPrefix("$ ") ? .subheadline.monospaced().weight(.medium) : .subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .layoutPriority(1)
            ForEach(Array(parts.dropFirst().prefix(2).enumerated()), id: \.offset) { _, fact in
                Chip(text: fact)
            }
        }
    }
}

/// Context and how many panes work, as chips.
private struct Facts: View {
    let detail: Detail?
    var body: some View {
        HStack(spacing: 6) {
            if let context = detail?.context { Chip(text: "\(Self.tokens(context)) ctx", symbol: "brain") }
            if let detail, detail.panes > 1 { Chip(text: "\(detail.working)/\(detail.panes) working", symbol: "square.stack") }
        }
    }

    static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1_000_000)
            : count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }
}

/// Context, then Reply and Open.
private struct Actions: View {
    let detail: Detail?
    let facts: Bool

    var body: some View {
        HStack(spacing: 6) {
            if facts { Facts(detail: detail) }
            Spacer(minLength: 4)
            if let pane = detail?.pane {
                Pill(title: "Reply", symbol: "arrowshape.turn.up.left.fill", url: ActivityLink.reply(pane), wide: false)
                Pill(title: "Open", symbol: "terminal.fill", url: ActivityLink.pane(pane), wide: false)
            }
        }
    }
}

// MARK: - Pieces

/// The session's face (its emoji) on a tile tinted by the state, or the
/// state's own symbol when it has none.
private struct Badge: View {
    let attributes: SessionActivity
    let state: SessionState
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(state.tint.opacity(0.24))
            .overlay {
                if let emoji = attributes.emoji {
                    Text(emoji).font(.system(size: size * 0.52))
                } else {
                    Image(systemName: state.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(state.tint)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(state.tint.opacity(0.45), lineWidth: 1))
            .frame(width: size, height: size)
    }
}

/// "Working · E-id handoff brief review · mbp-m5-max": the state in its
/// color, the followed tab or pane (else the agent), the Mac.
private struct Subtitle: View {
    let attributes: SessionActivity
    let state: SessionState
    let detail: Detail?

    var body: some View {
        let what = attributes.detail ?? detail?.agent.map(\.capitalized)
        (Text(state.words).foregroundStyle(state.tint).fontWeight(.semibold)
            + Text([what, attributes.mac].compactMap { $0 }.map { "  ·  \($0)" }.joined()).foregroundStyle(.secondary))
            .lineLimit(1)
    }
}

/// How long: the turn's own clock while it works (the phone ticks it, no
/// push needed), else since the state began.
private struct Clock: View {
    let state: SessionActivity.ContentState
    let detail: Detail?
    var body: some View {
        let since = Date(timeIntervalSince1970: state.state == .working ? detail?.turn ?? state.since : state.since)
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(state.state.tint)
    }
}

/// Terminal text as the pane shows it: monospaced, in a dark well.
private struct Well: View {
    let text: String
    let lines: Int
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(lines)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct Chip: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.1), in: Capsule())
    }
}

/// A link into the app, as a pill (its symbol alone when it has no title).
private struct Pill: View {
    let title: String?
    let symbol: String
    let url: URL
    let wide: Bool
    var body: some View {
        Link(destination: url) {
            Group {
                if let title { Label(title, systemImage: symbol) } else { Image(systemName: symbol) }
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: wide ? .infinity : nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white.opacity(0.16), in: Capsule())
        }
    }
}

/// Allow or Deny, wide and tinted, answered in the app's process.
private struct AnswerButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let intent: AnswerIntent
    var body: some View {
        Button(intent: intent) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension SessionState {
    /// The sidebar's colors: blocked asks (orange), working (yellow), done
    /// (teal), idle (quiet).
    var tint: Color {
        switch self {
        case .blocked: .orange
        case .working: .yellow
        case .done: .teal
        case .idle: .gray
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "hand.raised.fill"
        case .working: "bolt.fill"
        case .done: "checkmark"
        case .idle: "moon.zzz.fill"
        }
    }

    var words: String {
        switch self {
        case .blocked: "Waiting for you"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        }
    }
}
