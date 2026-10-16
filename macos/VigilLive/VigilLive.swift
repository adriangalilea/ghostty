import ActivityKit
import AppIntents
import SwiftUI
import VigilActivity
import VigilWire
import WidgetKit

/// A followed session, tab or pane on the Lock Screen and in the Dynamic
/// Island, shaped by what it needs from you:
///
/// - working: what it does now (its own status line or the tool it runs),
///   the last lines above its prompt, the turn's clock ticking on the
///   phone, its context and how many of its panes work;
/// - blocked: the question, its evidence (the command, the edit), and
///   Allow / Deny when one tap may answer it (through authz, unlocked);
/// - done: its last words, Reply (a line typed into the pane) and Open.
///
/// Every word beyond the state arrives sealed to this phone (`Detail`) and
/// is opened here with the app's key; without it the activity shows the
/// state alone. Laid out to Apple's Live Activity guidance: 14 pt margins,
/// the title first, buttons only where they can act (Lock Screen and
/// expanded), compact views that fit the narrowest island.
@main struct VigilLive: WidgetBundle {
    var body: some Widget { SessionActivityWidget() }
}

struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivity.self) { context in
            LockScreen(context: context)
                .padding(14)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let state = context.state.state
            let detail = context.state.opened
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Face(attributes: context.attributes)
                        Glyph(state: state).font(.caption)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Clock(state: context.state, detail: detail).font(.caption.weight(.semibold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Title(attributes: context.attributes).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StateBody(context: context, detail: detail, compact: true).padding(.horizontal, 4)
                }
            } compactLeading: {
                Face(attributes: context.attributes)
            } compactTrailing: {
                CompactTrailing(state: context.state, detail: detail)
            } minimal: {
                Glyph(state: state)
            }
            .widgetURL(context.attributes.url)
            .keylineTint(state.tint)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreen: View {
    let context: ActivityViewContext<SessionActivity>
    var body: some View {
        let detail = context.state.opened
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Face(attributes: context.attributes).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Title(attributes: context.attributes).font(.headline)
                    HStack(spacing: 5) {
                        Glyph(state: context.state.state)
                        Text(context.state.state.words)
                        if let detail, detail.panes > 1 { Text("· \(detail.working) of \(detail.panes) working") }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(context.state.state.tint)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Clock(state: context.state, detail: detail).font(.callout.weight(.semibold))
                    Text(context.attributes.mac).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            StateBody(context: context, detail: detail, compact: false)
            if context.isStale {
                Text("Not updated lately").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The state's own body

/// What the state needs you to see (and do), on the Lock Screen and in the
/// expanded island alike; `compact` trims it for the island.
private struct StateBody: View {
    let context: ActivityViewContext<SessionActivity>
    let detail: Detail?
    let compact: Bool

    var body: some View {
        let device = context.attributes.device
        switch context.state.state {
        case .blocked:
            if let question = detail?.question {
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let body = question.body, !body.isEmpty {
                        Evidence(text: body, lines: compact ? 2 : 4)
                    }
                    HStack(spacing: 8) {
                        if let deny = question.deny, let allow = question.allow {
                            Button(intent: AnswerIntent(device: device, request: question.request, action: deny, shown: question.title)) {
                                Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
                            }
                            .tint(.red)
                            Button(intent: AnswerIntent(device: device, request: question.request, action: allow, shown: question.title)) {
                                Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                            }
                            .tint(.green)
                        } else {
                            Link(destination: ActivityLink.pane(detail?.pane ?? "")) {
                                Label("Answer in vigil", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.footnote.weight(.semibold))
                }
            } else {
                Text("Waiting for you in the terminal").font(.subheadline)
            }
        case .working:
            VStack(alignment: .leading, spacing: 5) {
                if let now = detail?.now { Text(now).font(.subheadline.weight(.medium)).lineLimit(compact ? 1 : 2) }
                if let tail = detail?.tail, !tail.isEmpty, !compact || detail?.now == nil {
                    Evidence(text: tail.joined(separator: "\n"), lines: 2)
                }
                Facts(detail: detail)
            }
        case .done, .idle:
            VStack(alignment: .leading, spacing: 6) {
                if let said = detail?.said, !said.isEmpty {
                    Text(said).font(.footnote).lineLimit(compact ? 2 : 4)
                        .foregroundStyle(context.state.state == .idle ? .secondary : .primary)
                } else if let tail = detail?.tail, !tail.isEmpty {
                    Evidence(text: tail.joined(separator: "\n"), lines: 2)
                }
                if let pane = detail?.pane {
                    HStack(spacing: 8) {
                        Link(destination: ActivityLink.reply(pane)) {
                            Label("Reply", systemImage: "arrowshape.turn.up.left.fill").frame(maxWidth: .infinity)
                        }
                        Link(destination: ActivityLink.pane(pane)) {
                            Label("Open", systemImage: "terminal").frame(maxWidth: .infinity)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                if !compact { Facts(detail: detail) }
            }
        }
    }
}

/// Terminal text as the pane shows it: monospaced, dimmed, in a well.
private struct Evidence: View {
    let text: String
    let lines: Int
    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Context and panes, small.
private struct Facts: View {
    let detail: Detail?
    var body: some View {
        if let context = detail?.context {
            Label("\(Self.tokens(context)) context", systemImage: "brain")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1_000_000)
            : count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }
}

// MARK: - Pieces

/// The session's face, or its first letter.
private struct Face: View {
    let attributes: SessionActivity
    var body: some View {
        if let emoji = attributes.emoji {
            Text(emoji)
        } else {
            Text(attributes.label.prefix(1).uppercased()).font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.15), in: Circle())
        }
    }
}

/// The session's name, and the followed tab or pane.
private struct Title: View {
    let attributes: SessionActivity
    var body: some View {
        HStack(spacing: 4) {
            Text(attributes.label).lineLimit(1)
            if let detail = attributes.detail {
                Text("› \(detail)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
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

/// The compact island's right side: the clock while it works (the width of
/// "12:34"), the state's glyph otherwise.
private struct CompactTrailing: View {
    let state: SessionActivity.ContentState
    let detail: Detail?
    var body: some View {
        if state.state == .working {
            Clock(state: state, detail: detail).font(.caption2.weight(.semibold)).frame(maxWidth: 44)
        } else {
            Glyph(state: state.state)
        }
    }
}

private struct Glyph: View {
    let state: SessionState
    var body: some View {
        Image(systemName: state.symbol).foregroundStyle(state.tint)
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
        case .idle: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "hand.raised.fill"
        case .working: "ellipsis.circle.fill"
        case .done: "checkmark.circle.fill"
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
