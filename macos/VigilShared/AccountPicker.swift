import Ink
import SwiftUI
import VigilWire

/// One account as its router knows it, drawn from the facts themselves
/// (`AgentAccounts.Account`): its name, its plan, how its login stands, a
/// line per limit (how much is used, when it resets) and, for Codex, what
/// the provider gates and the resets it holds. One drawing for the Mac and
/// the phone.
struct AccountRow: View {
    let account: AgentAccounts.Account
    /// The pane runs on it now.
    let current: Bool
    /// A bare `c` / `cx` of the pane's model would start on it now.
    let pick: Bool
    /// The router passes it over for the model while another is left.
    let spent: Bool
    /// The router's command, for the pick's word ("c’s pick").
    let router: String
    let now: Date
    @InkMetrics private var metrics

    private var loggedOut: Bool { account.login.state == .loggedOut }

    var body: some View {
        VStack(alignment: .leading, spacing: .inkGap) {
            HStack(alignment: .firstTextBaseline, spacing: .inkGap) {
                Text(account.name).inkText(.label, emphasized: current)
                if let plan = account.plan { Text(plan).inkText(.detail) }
                Spacer(minLength: .inkGap)
                if account.login.state != .ready {
                    InkStatus(account.login.state.said, tone: loggedOut ? .bad : .warn)
                } else if spent {
                    InkStatus("spent", tone: .bad)
                } else if current {
                    InkStatus("this pane", tone: .ok)
                } else if pick {
                    InkStatus("\(router)’s pick", tone: .info)
                }
            }
            // Whose login it is, so the name is never taken for the account.
            if let email = account.email { Text(email).inkText(.caption) }
            if let detail = account.login.detail { Text(detail).inkText(.caption) }
            if account.login.state != .ready, let fix = account.login.fix {
                Text(fix).inkText(.caption).textSelection(.enabled)
            }
            if !account.limits.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: .inkGap, verticalSpacing: .inkTight) {
                    ForEach(Array(account.limits.enumerated()), id: \.offset) { _, limit in
                        let used = limit.percent(at: now)
                        GridRow {
                            Text(Self.name(limit)).inkText(.caption)
                            ProgressView(value: min(max((used ?? 0) / 100, 0), 1))
                                .progressViewStyle(.ink)
                                .tint(Self.tone(limit, used: used).color)
                                .frame(width: metrics.height * 3)
                                .gridCellAnchor(.leading)
                            Text(used.map { "\(Int($0.rounded()))%" } ?? "–").inkText(.caption).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(Self.note(limit, used: used, now: now)).inkText(.caption).monospacedDigit()
                        }
                    }
                }
            }
            ForEach(Self.words(account, now: now), id: \.self) { Text($0).inkText(.caption) }
        }
        .opacity(loggedOut || spent ? .inkDimmed : 1)
        .accessibilityElement(children: .combine)
    }

    /// A window's name: its label, with the model whose own window it is
    /// when the label does not already say it ("5h" of a model beside the
    /// account's "5h").
    static func name(_ limit: AgentAccounts.Limit) -> String {
        guard let model = limit.model, !limit.label.lowercased().contains(model.lowercased()) else { return limit.label }
        return "\(model) \(limit.label)"
    }

    /// How a limit reads: spent, near its end, or with room. A
    /// window that rolled over since it was measured has no known use.
    static func tone(_ limit: AgentAccounts.Limit, used: Double?) -> InkTone {
        guard let used else { return .neutral }
        return limit.spent ? .bad : used >= 80 ? .warn : .info
    }

    /// Beside a limit's number: when it resets, or that it rolled over
    /// since anyone measured it.
    static func note(_ limit: AgentAccounts.Limit, used: Double?, now: Date) -> String {
        guard used != nil else { return "reset since it was read" }
        return limit.resets.map { "resets in " + span(from: now, to: $0) } ?? ""
    }

    /// What the document says of the account beyond its windows, a line
    /// each: a read that failed, and Codex's standing word, closed gates
    /// and held resets.
    static func words(_ account: AgentAccounts.Account, now: Date) -> [String] {
        var lines: [String] = []
        // A read that failed beside numbers a minute or two old is normal
        // (the usage endpoint refuses some asks): it is said, not alarmed.
        if let error = account.usage.error {
            let since = account.usage.readAt.map { ", numbers from " + $0.formatted(date: .omitted, time: .shortened) } ?? ", never read"
            lines.append("last read: \(error)\(since)")
        }
        for word in account.served ?? [] where word.refuses(at: now) {
            let until = word.until.map { " for " + span(from: now, to: $0) } ?? ""
            lines.append("the provider refuses \(word.model ?? "ordinary usage")\(until)")
        }
        for gate in account.gates ?? [] where !gate.open {
            let back = gate.back.flatMap { $0 > now ? ", back in " + span(from: now, to: $0) : nil } ?? ""
            lines.append("\(gate.model) closed\(back)")
        }
        if let resets = account.resets, resets.held > 0 {
            lines.append("\(resets.held) usage reset\(resets.held == 1 ? "" : "s") held, \(resets.applicable) usable now")
        }
        return lines
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
/// turn's end when one does (`Restart.Intent.resume`). Only an account
/// known to be logged out cannot be pressed: the agent would only ask to
/// log in there.
struct AccountPicker: View {
    let facts: PaneResumeFacts
    let choose: (String) -> Void
    @ObservedObject private var store = VigilAccountFacts.shared
    @State private var hovered: String?

    var body: some View {
        let reading = store.reading(facts.accounts)
        let now = Date()
        VStack(alignment: .leading, spacing: .inkTight) {
            Text(facts.header(reading, now: now)).inkText(.caption)
                .padding(.horizontal, .inkBlock).padding(.top, .inkGap)
            if let trouble = store.troubles[facts.accounts] {
                Text("Not brought up to date: \(trouble)").inkText(.caption).foregroundStyle(InkTone.warn.color)
                    .padding(.horizontal, .inkBlock)
            }
            ForEach(facts.lines(reading?.facts), id: \.account.name) { line in
                let name = line.account.name
                Button { choose(name) } label: {
                    AccountRow(account: line.account, current: name == facts.account, pick: line.pick, spent: line.spent,
                               router: facts.router, now: now)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, .inkBlock).padding(.vertical, .inkGap)
                        .background(hovered == name ? Color.inkRowHover : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(line.account.login.state == .loggedOut)
                #if os(macOS)
                .onHover { hovered = $0 ? name : (hovered == name ? nil : hovered) }
                #endif
            }
        }
        .padding(.bottom, .inkGap)
    }
}
