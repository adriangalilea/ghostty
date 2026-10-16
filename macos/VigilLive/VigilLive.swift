import ActivityKit
import AppIntents
import SwiftUI
import VigilActivity
import VigilWire
import WidgetKit

/// A Mac's agents on the Lock Screen and in the Dynamic Island: the first
/// row in full, shaped by what it needs from you (the question and wide
/// Allow / Deny; the question its turn ended on and Reply; what it does
/// now, its last lines), and under it the others needing you as one line
/// each (a tap opens the pane), ‹ › turning through the rest. Nothing
/// needing you: one quiet line until the Mac ends it.
///
/// Every word beyond the leading state arrives sealed to this phone
/// (`Agents`) and is opened here with the app's key; without it the
/// activity shows the state alone. Within Apple's limits: 160 pt tall on
/// the Lock Screen, buttons only where they can act (Lock Screen, expanded
/// island), compact views that fit the narrowest island.
@main struct VigilLive: WidgetBundle {
    var body: some Widget { AgentsActivityWidget() }
}

/// What one render shows, opened once.
private struct Shown {
    let state: AgentsActivity.ContentState
    let mac: String
    let note: Agents?

    init(_ context: ActivityViewContext<AgentsActivity>) {
        state = context.state
        mac = context.attributes.mac
        note = context.state.opened
    }

    var top: Agents.Row? { note?.rows.first }
    var others: [Agents.Row] { Array(note?.rows.dropFirst() ?? []) }
    /// Everyone needing you or followed, carried or not.
    var count: Int { (note?.rows.count ?? 0) + (note?.more ?? 0) }
    /// Opened, and nothing to show.
    var resting: Bool { note?.rows.isEmpty == true }
    /// One-line rows per page under the first: one when the first row
    /// carries buttons (the 160 pt budget), else two.
    var perPage: Int { top?.detail?.question?.answers != nil ? 1 : 2 }
    var pages: Int { max(1, Int((Double(others.count) / Double(perPage)).rounded(.up))) }
    var page: Int { min(state.page ?? 0, pages - 1) }
    var pageRows: [Agents.Row] { Array(others.dropFirst(page * perPage).prefix(perPage)) }
    var url: URL? { top.map { URL(string: "vigil://pane/\($0.pane)")! } }
}

struct AgentsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsActivity.self) { context in
            let shown = Shown(context)
            Group {
                if shown.resting {
                    Resting(mac: shown.note?.mac)
                } else {
                    LockScreen(shown: shown, stale: context.isStale)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                }
            }
            .activityBackgroundTint(Color(white: 0.06).opacity(0.82))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(shown.url)
        } dynamicIsland: { context in
            let shown = Shown(context)
            let state = shown.top?.state ?? shown.state.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Badge(emoji: shown.top?.emoji, state: state, size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if shown.count > 1 {
                        Text("\(shown.count)").font(.title3.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary).padding(.trailing, 6)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.top?.label ?? shown.note?.mac ?? "vigil").font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let top = shown.top { Subtitle(row: top, mac: nil).font(.caption2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let top = shown.top {
                        Needs(row: top, mac: shown.mac, compact: true).padding(.top, 4)
                    }
                }
            } compactLeading: {
                Badge(emoji: shown.top?.emoji, state: state, size: 22)
            } compactTrailing: {
                if shown.count > 1 {
                    Text("\(shown.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(state.tint)
                } else {
                    Image(systemName: state.symbol).foregroundStyle(state.tint)
                }
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            .widgetURL(shown.url)
            .keylineTint(state.tint)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreen: View {
    let shown: Shown
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let top = shown.top {
                HStack(alignment: .center, spacing: 10) {
                    Badge(emoji: top.emoji, state: top.state, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(top.label).font(.headline).lineLimit(1)
                        Subtitle(row: top, mac: shown.note?.mac).font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Needs(row: top, mac: shown.mac, compact: false)
            } else {
                // Not opened yet: the leading state alone.
                HStack(spacing: 10) {
                    Badge(emoji: nil, state: shown.state.state, size: 34)
                    Text(shown.state.state.words).font(.headline).foregroundStyle(shown.state.state.tint)
                }
            }
            if !shown.pageRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown.pageRows, id: \.pane) { row in OneLine(row: row) }
                }
                Pager(shown: shown)
            }
            if stale {
                Label("Not updated lately", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Nothing needs you: one quiet line, gone on its own.
private struct Resting: View {
    let mac: String?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AgentState.done.tint.opacity(0.8))
            Text("All caught up").foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let mac { Text(mac).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - What the first row needs

/// The first row's body, on the Lock Screen and in the expanded island
/// (`compact` trims it for the island). Budgeted with the header and the
/// one-line rows to Apple's 160 pt: past it the system truncates.
private struct Needs: View {
    let row: Agents.Row
    let mac: String
    let compact: Bool

    var body: some View {
        let detail = row.detail
        VStack(alignment: .leading, spacing: 6) {
            switch row.state {
            case .blocked where row.flavor == .ask:
                // Its turn ended on a question: the question, and Reply.
                HStack(alignment: .top, spacing: 8) {
                    Text(row.line ?? "Asked you something").font(.subheadline).lineLimit(compact ? 1 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Pill(title: "Reply", symbol: "arrowshape.turn.up.left.fill", intent: OpenPaneIntent(pane: row.pane, keyboard: true), wide: false)
                }
            case .blocked:
                if let question = detail?.question {
                    // The evidence is the question (the command, the edit);
                    // the title stands in only when there is none.
                    if let body = question.body, !body.isEmpty {
                        Well(text: body, lines: 1)
                    } else {
                        Text(question.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let answers = question.answers {
                            AnswerButton(title: answers.denyLabel, symbol: AnswerLook.symbol(.reject), tint: AnswerLook.refuse,
                                         intent: AnswerIntent(device: mac, request: question.request, action: answers.deny, shown: question.title))
                            AnswerButton(title: answers.allowLabel, symbol: AnswerLook.symbol(.approveOnce), tint: AnswerLook.approve,
                                         intent: AnswerIntent(device: mac, request: question.request, action: answers.allow, shown: question.title))
                        } else {
                            Pill(title: "Answer in vigil", symbol: "arrow.up.forward.app", intent: OpenPaneIntent(pane: row.pane, keyboard: false), wide: true)
                        }
                    }
                } else {
                    Text(row.line ?? "Waiting for you in the terminal").font(.subheadline.weight(.medium)).lineLimit(1)
                }
            case .working, .interrupting, .unknown:
                HStack(spacing: 6) {
                    if let now = detail?.now { Now(text: now, tint: row.state.tint) } else { Facts(detail: detail) }
                    Spacer(minLength: 4)
                    Pill(title: nil, symbol: "arrowshape.turn.up.left.fill", intent: OpenPaneIntent(pane: row.pane, keyboard: true), wide: false)
                    Pill(title: nil, symbol: "terminal.fill", intent: OpenPaneIntent(pane: row.pane, keyboard: false), wide: false)
                }
                if let tail = detail?.tail, !tail.isEmpty, !compact {
                    Well(text: tail.joined(separator: "\n"), lines: 1)
                }
            case .done, .idle:
                HStack(alignment: .top, spacing: 8) {
                    if let said = detail?.said ?? row.line, !said.isEmpty {
                        // Its words as one paragraph: the message's own line
                        // breaks are layout for a terminal, not a Lock Screen.
                        Text(said.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.footnote)
                            .foregroundStyle(row.state == .idle ? .secondary : .primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Pill(title: "Reply", symbol: "arrowshape.turn.up.left.fill", intent: OpenPaneIntent(pane: row.pane, keyboard: true), wide: false)
                }
            }
        }
    }
}

/// Another row needing you, in one line: its state, its face and name,
/// what it needs, how long; a tap opens its pane.
private struct OneLine: View {
    let row: Agents.Row
    var body: some View {
        Button(intent: OpenPaneIntent(pane: row.pane, keyboard: false)) {
            HStack(spacing: 6) {
                Circle().fill(row.state.tint).frame(width: 7, height: 7)
                if let emoji = row.emoji { Text(emoji).font(.caption) }
                Text(row.label).font(.caption.weight(.semibold)).lineLimit(1).layoutPriority(1)
                Text(row.line ?? row.state.words).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(Date(timeIntervalSince1970: row.since), style: .relative)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
    }
}

/// ‹ n/m › when the others fill more than a page, "+N more" when the Mac
/// carried fewer than it has.
private struct Pager: View {
    let shown: Shown
    var body: some View {
        let more = shown.note?.more ?? 0
        if shown.pages > 1 || more > 0 {
            HStack(spacing: 10) {
                if shown.pages > 1 {
                    Button(intent: PageIntent(mac: shown.mac, page: (shown.page + shown.pages - 1) % shown.pages)) {
                        Image(systemName: "chevron.left")
                    }
                    Text("\(shown.page + 1)/\(shown.pages)").monospacedDigit()
                    Button(intent: PageIntent(mac: shown.mac, page: (shown.page + 1) % shown.pages)) {
                        Image(systemName: "chevron.right")
                    }
                }
                Spacer(minLength: 0)
                if more > 0 { Text("+\(more) more") }
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }
}

/// What it does now: the status line's verb in the state's color, its
/// facts ("↓ 9.4k tokens", "thinking"; two at most) as chips; a tool line
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
            if let context = detail?.context { Chip(text: "\(context)% ctx", symbol: "brain") }
            if let detail, detail.panes > 1 { Chip(text: "\(detail.working)/\(detail.panes) working", symbol: "square.stack") }
        }
    }
}

// MARK: - Pieces

/// The session's face (its emoji) on a tile tinted by the state, or the
/// state's own symbol when it has none.
private struct Badge: View {
    let emoji: String?
    let state: AgentState
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(state.tint.opacity(0.24))
            .overlay {
                if let emoji {
                    Text(emoji).font(.system(size: size * 0.52))
                } else {
                    Image(systemName: state.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(state.tint)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(state.tint.opacity(0.45), lineWidth: 1))
            .frame(width: size, height: size)
    }
}

/// "Working 1:04 · rebuild-authz-on-tether · mbp-m5-max": the state in its
/// color with how long it has held (`Clock`: a sentence, never a bare
/// number), the conversation's name, the Mac; a followed row wears a pin.
private struct Subtitle: View {
    let row: Agents.Row
    let mac: String?

    var body: some View {
        let words = row.state == .blocked && row.flavor == .ask ? "Asked you" : row.state.words
        let what = row.detail?.name ?? row.detail?.agent.map(\.capitalized)
        HStack(spacing: 4) {
            if row.pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
            Text(words).foregroundStyle(row.state.tint).fontWeight(.semibold)
            Clock(row: row).fontWeight(.semibold)
            Text([what, mac].compactMap { $0 }.map { "·  \($0)" }.joined(separator: "  ")).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .lineLimit(1)
    }
}

/// How long the state has held: working, this turn (since your last
/// message to it; the phone ticks it, no push needed); waiting, how long
/// it has waited for you; done, since it finished.
///
/// A timer text is filled in by the system's renderer after layout, so it
/// has no natural width to lay out with: asked for one (`fixedSize`), the
/// whole Lock Screen view laid out at a NaN width and drew black
/// (2026-10-16, the renderer's display list read `frame (nan …)`). The
/// space is a template's ("0:00:00" in the same font, never shown), the
/// timer draws over it from its leading edge, so the line never moves as
/// it ticks. Its range ends where the activity can (ActivityKit keeps one
/// 8 hours active and 4 more on the Lock Screen).
private struct Clock: View {
    let row: Agents.Row
    static let lifetime: TimeInterval = 12 * 3600
    var body: some View {
        let since = Date(timeIntervalSince1970: row.state == .working ? row.detail?.turn ?? row.since : row.since)
        Text("0:00:00")
            .monospacedDigit()
            .hidden()
            .overlay(alignment: .leading) {
                Text(timerInterval: since...since.addingTimeInterval(Self.lifetime), countsDown: false)
                    .monospacedDigit()
                    .foregroundStyle(row.state.tint)
            }
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

/// Into the app, as a pill (its symbol alone when it has no title): a
/// button with an intent, the only tap target the Lock Screen takes besides
/// the activity's own `widgetURL`.
private struct Pill: View {
    let title: String?
    let symbol: String
    let intent: OpenPaneIntent
    let wide: Bool
    var body: some View {
        Button(intent: intent) {
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
        .buttonStyle(.plain)
    }
}

/// Allow or Deny, wide, in the answer hues every surface uses (authz's
/// `AnswerLook`), answered in the app's process.
private struct AnswerButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let intent: AnswerIntent
    var body: some View {
        Button(intent: intent) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AnswerButtonStyle(tint: tint))
    }
}
