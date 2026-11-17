import Foundation
import Ink
import Log
import SwiftUI
import VigilWire

/// Every watch of every Mac as the person reads it (harness's
/// `WatchRecord`, composed on each watch's own Mac): what it waits on, why
/// it was armed, who it reaches, how it stands, its runs, and what is
/// broken, in words. Drawn with Ink's notices, facts and log and nothing of
/// its own: the window lists every watch, a pane's aside the ones that
/// reach that pane. What a record holds is the watch's Mac's word; where
/// "go to" leads is the host's (`VigilWatchHost`).

/// What the views ask of the app that holds them.
struct VigilWatchHost {
    /// This Mac's tether root: another Mac's watch says its Mac.
    var here: String?
    /// A Mac's name by its root.
    var mac: @MainActor (_ root: String) -> String
    /// A pane of the Mac `root`, as its rows name it.
    var pane: @MainActor (_ root: String, _ pane: String) -> String
    /// Go to the pane `pane` of the Mac `root`.
    var open: @MainActor (_ root: String, _ pane: String) -> Void
}

/// One watch of one Mac.
struct VigilWatchItem: Identifiable, Equatable {
    let root: String
    let record: WatchRecord
    var id: String { "\(root)/\(record.id)" }
}

enum VigilWatchList {
    /// Every Mac's watches, the broken first, then the live, then the
    /// ended, the newest first within each.
    static func items(_ boards: [String: [String: WatchRecord]]) -> [VigilWatchItem] {
        boards.flatMap { root, records in records.values.map { VigilWatchItem(root: root, record: $0) } }
            .sorted { (rank($0), -$0.record.created, $0.id) < (rank($1), -$1.record.created, $1.id) }
    }

    private static func rank(_ item: VigilWatchItem) -> Int { item.record.isBroken ? 0 : item.record.live ? 1 : 2 }

    /// The ones that reach `pane` of the Mac `root`, or were armed in it.
    static func reaching(_ boards: [String: [String: WatchRecord]], root: String, pane: String) -> [VigilWatchItem] {
        items([root: boards[root] ?? [:]]).filter { $0.record.panes.contains(pane) || $0.record.armedIn == pane }
    }

    /// Under three headings: what keeps a watch from its job comes first,
    /// in the care tone; then what watches; then what ended this week.
    static func sections(_ items: [VigilWatchItem]) -> [InkNotice.Section<VigilWatchItem>] {
        let broken = items.filter(\.record.isBroken), live = items.filter { !$0.record.isBroken && $0.record.live }
        let ended = items.filter { !$0.record.isBroken && !$0.record.live }
        return [
            InkNotice.Section("Broken", tone: .warn, broken),
            InkNotice.Section("Watching", live),
            InkNotice.Section("Ended this week", ended),
        ].filter { !$0.items.isEmpty }
    }

    /// What rows wear (`WatchMark`): the live watches reaching each pane,
    /// by root then pane, each pane's in id order.
    static func marks(_ boards: [String: [String: WatchRecord]]) -> [String: [String: [WatchRecord]]] {
        var marks: [String: [String: [WatchRecord]]] = [:]
        for (root, records) in boards {
            for record in records.values where record.live {
                for pane in Set(record.panes) { marks[root, default: [:]][pane, default: []].append(record) }
            }
        }
        return marks.mapValues { $0.mapValues { $0.sorted { $0.id < $1.id } } }
    }

    /// Whether two sets of marks draw the same: which watches, their state
    /// and what is broken (a run's history is the list's alone), so a
    /// store replaces what rows observe only when a row would change.
    static func drawSame(_ a: [String: [String: [WatchRecord]]], _ b: [String: [String: [WatchRecord]]]) -> Bool {
        func drawn(_ all: [String: [String: [WatchRecord]]]) -> [String: [String: [String]]] {
            all.mapValues { $0.mapValues { $0.map { "\($0.id) \($0.state.kind) \($0.broken.map(\.words))" } } }
        }
        return drawn(a) == drawn(b)
    }

    static func tone(_ record: WatchRecord) -> InkTone {
        if record.isBroken { return .warn }
        switch record.state.kind {
        case .waiting, .delivering: return .info
        case .armed: return .ok
        case .dormant, .down, .ended: return .neutral
        }
    }
}

/// The Watches window's content: every watch of every Mac.
struct VigilWatches: View {
    let boards: [String: [String: WatchRecord]]
    let host: VigilWatchHost

    var body: some View {
        InkNotices(VigilWatchList.sections(VigilWatchList.items(boards)), unread: { $0.record.isBroken }) { item in
            VigilWatchRow(item: item, host: host)
        } empty: {
            Text("No watch on any Mac. `vigil watch` arms one.").foregroundStyle(.secondary)
        }
    }
}

/// A pane's watches beside it: those that will reach it, and what ended.
struct VigilPaneWatches: View {
    let boards: [String: [String: WatchRecord]]
    let root: String
    let pane: String
    let host: VigilWatchHost

    var body: some View {
        InkNotices(VigilWatchList.sections(VigilWatchList.reaching(boards, root: root, pane: pane)), separation: .lines,
                   unread: { $0.record.isBroken }) { item in
            VigilWatchRow(item: item, host: host)
        } empty: {
            Text("No watch reaches this pane.").foregroundStyle(.secondary)
        }
    }
}

/// One watch: its command and whom it reaches as the line, how it stands
/// as the detail, and when opened every fact of it, its runs as a log.
struct VigilWatchRow: View {
    let item: VigilWatchItem
    let host: VigilWatchHost

    private var record: WatchRecord { item.record }

    var body: some View {
        InkNotice(
            line, from: from, at: Date(timeIntervalSince1970: when), detail: detail,
            mark: record.feed ? "dot.radiowaves.up.forward" : "binoculars", tone: VigilWatchList.tone(record),
            unread: record.isBroken
        ) {
            if record.isBroken {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(record.broken, id: \.self) { broken in
                        Label(broken.words, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(InkTone.warn.color)
                    }
                }
            }
        } opened: {
            VigilWatchFacts(item: item, host: host)
        }
        .menu {
            ForEach(record.panes, id: \.self) { pane in
                Button("Go to \(host.pane(item.root, pane))", systemImage: "arrow.right.circle") { host.open(item.root, pane) }
            }
        }
    }

    /// The command, quoted, and whom its verdict reaches.
    private var line: String {
        let reaches = record.recipients.map { "`\(host.pane(item.root, $0.pane))`" } + (record.userText == nil ? [] : ["you"])
        let command = record.command.isEmpty ? "`\(record.id)`" : "`\(record.command.joined(separator: " "))`"
        return reaches.isEmpty ? command : "\(command) for \(reaches.joined(separator: ", "))"
    }

    private var from: String {
        ([record.workspace, item.root == host.here ? nil : host.mac(item.root)].compactMap { $0 }).joined(separator: " · ")
    }

    private var when: Double { record.state.since ?? record.runs.last?.started ?? record.created }

    private var detail: String {
        var words = record.state.words
        if let deadline = record.state.deadline {
            words += ", until \(Date(timeIntervalSince1970: deadline).formatted(date: .omitted, time: .shortened))"
        }
        if record.feed { words += " · \(record.matches) of \(record.totalRuns) runs matched" }
        return words
    }
}

/// Every fact of a watch, and its runs as a log.
struct VigilWatchFacts: View {
    let item: VigilWatchItem
    let host: VigilWatchHost

    private var record: WatchRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InkFacts {
                InkFact("Waits on") { Text(record.command.joined(separator: " ")).font(.body.monospaced()).textSelection(.enabled) }
                if let agentText = record.agentText { InkFact("Tells the agent") { Text(agentText) } }
                if let userText = record.userText { InkFact("Tells you") { Text(userText) } }
                InkFact("Reaches") {
                    ForEach(record.recipients, id: \.pane) { r in
                        Button { host.open(item.root, r.pane) } label: {
                            Text(reach(r))
                        }
                        .buttonStyle(.plain)
                    }
                }
                InkFact("State") { Text(record.state.words) }
                if let runner = record.runner { InkFact("Runner") { Text("process \(runner)").monospacedDigit() } }
                InkFact("Log") { Text(record.log).font(.callout.monospaced()).textSelection(.enabled) }
                if let lastError = record.lastError {
                    InkFact("Last stderr") { Text(lastError).font(.callout.monospaced()).foregroundStyle(InkTone.warn.color) }
                }
            }
            if !record.runs.isEmpty {
                InkLog(Self.lines(record), title: record.totalRuns > record.runs.count
                       ? "The last \(record.runs.count) of \(record.totalRuns) runs" : "Runs", filter: false, label: "runs")
                    .frame(height: 200)
                    .inkGroup(padding: 0)
            }
        }
    }

    private func reach(_ r: WatchRecord.Recipient) -> String {
        var words = host.pane(item.root, r.pane)
        if !r.alive { words += " (not running)" }
        if let asked = r.conversation {
            words += r.holds == asked ? ", the conversation that armed it" : ", armed by \(asked.prefix(8)), holds \(r.holds.map { String($0.prefix(8)) } ?? "none") now"
        }
        return words
    }

    /// A run's start, its verdict and each delivery, a line each.
    static func lines(_ record: WatchRecord) -> [InkLogLine] {
        record.runs.enumerated().flatMap { index, run -> [InkLogLine] in
            var lines = [InkLogLine(id: "\(index)s", .event(.init(
                at: Date(timeIntervalSince1970: run.started), level: .debug, verb: "start", source: "command",
                message: "started" + (run.pid.map { ", process \($0)" } ?? ""))))]
            if let verdict = run.verdict {
                let level: LogLevel = switch verdict.kind {
                case .match: .info
                case .deadline: .debug
                case .failed, .notFound, .runaway: .error
                }
                var fields: [InkLogLine.Field] = verdict.exit.map { [.init("exit", "\($0)")] } ?? []
                if let stderr = run.stderr { fields.append(.init("stderr", stderr)) }
                lines.append(InkLogLine(id: "\(index)v", .event(.init(
                    at: Date(timeIntervalSince1970: run.ended ?? run.started), level: level, verb: verdict.kind == .match ? "success" : nil,
                    source: "verdict", message: verdict.words, fields: fields))))
            }
            for (d, delivery) in run.deliveries.enumerated() {
                let message: String = switch delivery.how {
                case .message: "posted to \(delivery.to)'s mailbox" + (delivery.message.map { " as \($0.prefix(8))" } ?? "")
                case .typed: "typed into \(delivery.to)" + (delivery.typed == true ? ", receipted" : "") + (delivery.why.map { " (\($0))" } ?? "")
                case .told: "told you through Authz"
                case .notDelivered: "not delivered to \(delivery.to): \(delivery.why ?? "")"
                }
                lines.append(InkLogLine(id: "\(index)d\(d)", .event(.init(
                    at: Date(timeIntervalSince1970: delivery.at), level: delivery.how == .notDelivered ? .warn : .info,
                    source: "delivery", message: message))))
            }
            return lines
        }
    }
}
