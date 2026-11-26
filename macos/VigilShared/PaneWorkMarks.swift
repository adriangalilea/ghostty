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
    struct Subject {
        let key: String
        let title: String
        let face: PaneFace
        let state: AgentState?
        let conversation: ConversationRef?
        let note: Restart.Note?
    }
    let subject: Subject
    let problem: ConversationProblem
    var visit: (() -> Void)?
    var requestRestart: ((Restart.Intent) async throws -> Restart.Answer)?
    var button: String?
    var act: (() -> Void)?
    var ended: PaneEnd?
    var writers: PaneConflict.Writers?
    var id: String { subject.key + "/" + problem.kind.rawValue }
    var operationID: String { id + "/" + (subject.conversation?.key ?? "") + "/" + (problem.relayRetry?.uuidString ?? "") }
}

/// A row and its folded ancestor can present the same request. Keep its
/// acknowledgement across popover dismissal. The broker owns scheduled work.
@MainActor @Observable private final class PaneRestartFeedback {
    static let shared = PaneRestartFeedback()
    struct Receipt {
        let id = UUID()
        var note: Restart.Note?
        var status: InkNotice.ActionFeedback
        var sending = true
    }
    private var receipts: [String: Receipt] = [:]

    func receipt(_ item: PaneProblemItem) -> Receipt? {
        guard let r = receipts[item.operationID], r.sending || r.note == item.subject.note else { return nil }
        return r
    }

    func perform(_ intent: Restart.Intent, for item: PaneProblemItem, progress: String) {
        guard let request = item.requestRestart, receipt(item)?.sending != true else { return }
        let key = item.operationID
        var r = Receipt(note: item.subject.note, status: .working(progress))
        receipts[key] = r
        Task {
            do {
                let answer = try await request(intent)
                r.status = [.relayUpdated, .cancelled].contains(answer.outcome) ? .succeeded(answer.said) : .failed(answer.said)
            } catch {
                r.status = .failed(error.localizedDescription)
            }
            guard receipts[key]?.id == r.id else { return }
            r.sending = false
            receipts[key] = r
        }
    }

    func forget(_ key: String) { receipts[key] = nil }
}

struct PaneProblemsMark: View {
    let items: [PaneProblemItem]
    let sizes: PaneMarkSizes
    @State private var showing = false
    @State private var selected: String?
    @State private var copied: String?
    @State private var manualRestart: String?
    private let feedback = PaneRestartFeedback.shared

    private var tone: Color {
        if items.contains(where: { $0.writers == .both || $0.problem.kind == .twoLive }) { return .red }
        if items.allSatisfy({ $0.writers != nil }) { return .secondary }
        return .orange
    }

    var body: some View {
        if let first = items.first {
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
            .inkActionPopover(isPresented: $showing) {
                let current = items.first(where: { $0.id == selected }) ?? first
                VStack(alignment: .leading, spacing: 0) {
                    if items.count > 1 && (!grouped || selected != nil) {
                        Picker("Problem", selection: Binding(get: { current.id }, set: { selected = $0.isEmpty ? nil : $0 })) {
                            if grouped { Text("All affected panes").tag("") }
                            ForEach(items) { item in Text(item.subject.title + " · " + item.problem.title).tag(item.id) }
                        }
                        .pickerStyle(.menu).padding(.horizontal, .inkBlock).padding(.vertical, .inkGap)
                    }
                    panel(current, folded: grouped && !items.contains { $0.id == selected }).id(current.id)
                }
            }
            .onChange(of: showing) { _, open in
                if !open { selected = nil; copied = nil; manualRestart = nil }
            }
            .onChange(of: items.map(\.operationID)) { old, new in
                for key in Set(old).subtracting(new) { feedback.forget(key) }
            }
        }
    }

    private func panel(_ item: PaneProblemItem, folded: Bool) -> InkActionPanel {
        let title = folded && item.problem.kind == .receiver ? "\(items.count) panes can’t receive messages" : item.problem.title
        let showReceipt = [.restartFailed, .restarting].contains(item.problem.kind)
        let detail = showReceipt ? item.problem.says : folded ? "Choose a pane to resume its conversation." : item.subject.title
        let manual = manualRestart == item.operationID
        let panel = InkActionPanel(manual ? "Restart Claude manually" : title,
            detail: manual ? "Finish the turn and background work, save drafts, then quit Claude and resume it from its original project and account." : detail,
            tone: item.writers == .both || item.problem.kind == .twoLive ? .bad : .warn,
            actions: folded ? .group("Choose pane", items.map { target in
                InkHUD.Action(target.subject.title) { selected = target.id }
            }, alongside: []) : actions(item), style: .problem)
        if folded {
            return panel.affectedItems(items.map { other in
                InkActionPanel.Item(other.subject.title, id: other.operationID,
                    status: feedback.receipt(other)?.status.text ?? other.subject.note?.said ?? other.subject.state?.rawValue.capitalized ?? "Unknown") {
                    switch other.subject.face {
                    case .emoji(let emoji): Text(emoji)
                    case .agent(let agent): AgentMark(agent: agent, size: 15, tint: nil)
                    case .plain: Image(systemName: "terminal")
                    }
                }
            }, in: "Affected panes", count: { "\($0) panes" })
        }
        if showReceipt { return panel }
        return panel.details("Details") {
            VStack(alignment: .leading, spacing: .inkGap) {
                Text(item.problem.says).inkText(.body)
                ForEach(item.problem.fix, id: \.self) { Text($0).inkText(.detail) }
            }
        }
    }

    private var grouped: Bool {
        guard items.count > 1, let first = items.first, first.problem.needsManualResume else { return false }
        return items.allSatisfy { $0.problem.kind == first.problem.kind && $0.problem.needsManualResume && $0.subject.note == nil }
    }

    private func actions(_ item: PaneProblemItem) -> InkActionPanel.Actions {
        var alongside: [InkHUD.Action] = []
        if let act = item.act, let label = item.button {
            alongside.append(.init(label) { showing = false; act() })
        } else if let visit = item.visit {
            alongside.append(.init(items.count > 1 ? "Open " + item.subject.title : "Open pane", symbol: "arrow.up.forward") { showing = false; visit() })
        }
        if let r = feedback.receipt(item) {
            let done: [InkHUD.Action] = r.sending ? [] : [.init("Done") { feedback.forget(item.operationID) }]
            return .feedback(r.status, actions: done + alongside)
        }
        if let note = item.subject.note, item.problem.needsManualResume || item.problem.kind == .restartScheduled {
            switch note.state {
            case .armed:
                let cancel: [InkHUD.Action] = if let id = note.scheduleID, item.requestRestart != nil {
                    [.init("Cancel restart") { feedback.perform(.cancel(id), for: item, progress: "Cancelling restart…") }]
                } else { [] }
                return .feedback(.waiting(note.said), actions: cancel + alongside)
            case .ending: return .feedback(.working(note.said), actions: alongside)
            case .notRun, .ran: break
            }
        }
        if item.problem.kind == .outdated, manualRestart != item.operationID {
            if let id = item.problem.relayRetry, item.requestRestart != nil {
                return .buttons([.init("Restart relay") {
                    feedback.perform(.relay(id), for: item, progress: "Restarting relay…")
                }] + alongside)
            }
            return .buttons([.init("Restart manually…") { manualRestart = item.operationID }] + alongside)
        }
        if item.problem.needsManualResume, let command = item.subject.conversation?.manualResumeCommand {
            if copied == item.operationID {
                return .feedback(.succeeded("Command copied. After quitting, run it in the original project folder with the same account."), actions: alongside)
            }
            let copy = InkHUD.Action("Copy resume command", symbol: "doc.on.doc") {
                VigilPasteboard.copy(command)
                copied = item.operationID
            }
            return .buttons([copy] + alongside)
        }
        return .buttons(alongside)
    }
}

/// A row's dots, by swift-utils' `InkStateDotCluster`: a pane's own (each
/// agent not finished that no subagent row shows, then its main agent's
/// state), a subagent row's (its one agent), or a folded row's. How a dot
/// looks for what it says is here and nowhere else.
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
        case .agent: "A subagent, not finished"
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

    var body: some View {
        if unread > 0 {
            let mark = HStack(spacing: 1) {
                Image(systemName: "envelope.fill").font(sizes.symbol)
                Text("\(unread)").font(sizes.count)
            }
            .foregroundStyle(.blue)
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
        (unread == 1 ? "1 unread message for you" : "\(unread) unread messages for you")
            + (press == nil ? "" : "\nPress to open its thread.")
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

