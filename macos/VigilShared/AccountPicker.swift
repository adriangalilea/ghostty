import Ink
import SwiftUI
import VigilWire

/// One account as its router reads it, drawn from the facts themselves
/// (`AgentAccounts.Account`): its name, its plan, where it stands, and a
/// line per limit (how much is used, when it resets). One drawing for the
/// Mac and the phone.
struct AccountRow: View {
    let account: AgentAccounts.Account
    /// The pane runs on it now.
    let current: Bool
    /// A bare `c` / `cx` would pick it now.
    let pick: Bool
    /// The router's command, for the pick's word ("c’s pick").
    let router: String
    let now: Date
    @InkMetrics private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: .inkGap) {
            HStack(alignment: .firstTextBaseline, spacing: .inkGap) {
                Text(account.name).inkText(.label, emphasized: current)
                if let plan = account.plan { Text(plan).inkText(.detail) }
                Spacer(minLength: .inkGap)
                if account.loggedOut {
                    InkStatus("logged out", tone: .neutral)
                } else if account.spent {
                    InkStatus("spent", tone: .bad)
                } else if current {
                    InkStatus("this pane", tone: .ok)
                } else if pick {
                    InkStatus("\(router)’s pick", tone: .info)
                }
            }
            if !account.limits.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: .inkGap, verticalSpacing: .inkTight) {
                    ForEach(account.limits, id: \.label) { limit in
                        GridRow {
                            Text(limit.label).inkText(.caption)
                            ProgressView(value: min(max(limit.percent / 100, 0), 1))
                                .progressViewStyle(.ink)
                                .tint(Self.tone(limit).color)
                                .frame(width: metrics.height * 3)
                                .gridCellAnchor(.leading)
                            Text("\(Int(limit.percent.rounded()))%").inkText(.caption).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(limit.resets.map { "resets in " + Self.span(from: now, to: $0) } ?? "").inkText(.caption).monospacedDigit()
                        }
                    }
                }
            } else if let note = account.note {
                Text(note).inkText(.caption)
            }
        }
        .opacity(account.loggedOut || account.spent ? .inkDimmed : 1)
        .accessibilityElement(children: .combine)
    }

    /// How a limit reads: spent, near its end, or with room.
    static func tone(_ limit: AgentAccounts.Limit) -> InkTone {
        limit.spent ? .bad : limit.percent >= 80 ? .warn : .info
    }

    /// A span in its two largest units: "5d 4h", "4h 32m", "12m".
    static func span(from now: Date, to then: Date) -> String {
        let minutes = max(0, Int(then.timeIntervalSince(now) / 60))
        let (days, hours, rest) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }
}

/// The accounts a pane's conversation can come back on, each a row to
/// press: the choice acts at once when no turn runs, and is kept for the
/// turn's end when one does (`Restart.Intent.resume`).
struct AccountPicker: View {
    let facts: PaneResumeFacts
    let choose: (String) -> Void
    @ObservedObject private var store = VigilAccountFacts.shared
    @State private var hovered: String?

    var body: some View {
        let reading = store.reading(facts.accounts)
        let now = Date()
        VStack(alignment: .leading, spacing: .inkTight) {
            Text(facts.header(reading)).inkText(.caption)
                .padding(.horizontal, .inkBlock).padding(.top, .inkGap)
            ForEach(facts.lines(reading?.facts, switching: false, now: now), id: \.name) { line in
                Button { choose(line.name) } label: {
                    Group {
                        if let account = line.account {
                            AccountRow(account: account, current: line.name == facts.account, pick: line.name == reading?.facts?.pick,
                                       router: facts.router, now: now)
                        } else {
                            Text(line.title).inkText(.label)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, .inkBlock).padding(.vertical, .inkGap)
                    .background(hovered == line.name ? Color.inkRowHover : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(line.unusable)
                #if os(macOS)
                .onHover { hovered = $0 ? line.name : (hovered == line.name ? nil : hovered) }
                #endif
            }
        }
        .padding(.bottom, .inkGap)
    }
}
