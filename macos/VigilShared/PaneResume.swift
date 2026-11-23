import Ink
import SwiftUI
import VigilWire

/// What a pane's Resume items and their notice are drawn from: its broker's
/// word (its glance: the menu's revision, a resume kept for the agent's
/// quit, what became of a restart, an account that cannot run a turn) and
/// the accounts its Mac's router reads (`VigilAccountFacts`). Both apps
/// build it from their own rows.
struct PaneResumeFacts {
    let menu: PaneGlance.ResumeMenu
    /// `claude`, `codex`.
    let agent: String
    let conversation: String
    /// The account the agent runs on now.
    let account: String?
    let block: AccountBlock?
    let restart: Restart.Note?
    /// Where its Mac's accounts are read.
    let accounts: VigilAccountFacts.Key

    /// The router the person knows the accounts by.
    var router: String { agent == "codex" ? "cx" : "c" }
    var agentName: String { Restart.agentName(agent) }

    /// What the notice reads live, from the same row.
    var live: PaneResumeLive { PaneResumeLive(menu: menu, restart: restart, agent: agent) }

    /// The heading over the one-press switch: why no turn can run.
    func blockTitle(_ block: AccountBlock) -> String {
        let who = account.map { " on " + $0 } ?? ""
        return switch block.kind {
        case .limit: "\(agentName) cannot take a turn\(who): \(block.said)"
        case .login: "\(agentName) is signed out\(who): \(block.said)"
        }
    }

    /// The first line of an accounts submenu: whose facts these are and when
    /// they were read, or why there are none.
    func header(_ reading: VigilAccountFacts.Reading?) -> String {
        switch reading {
        case nil: return "Reading \(router) accounts on the pane’s Mac…"
        case .failed(let why, _): return "No account facts: \(why)"
        case .facts(let accounts, let at):
            let model = accounts.model.map { " for " + $0 } ?? ""
            return "\(router) accounts\(model), read \(at.formatted(date: .omitted, time: .standard))"
        }
    }

    struct Line {
        let name: String
        let title: String
        let icon: String
        let unusable: Bool
        /// The router's facts of it, drawn as its table row where a menu
        /// can show colour (`AccountTable`); nil for a name it did not list.
        var account: AgentAccounts.Account? = nil
        /// "this pane", "c’s pick".
        var marks: String? = nil
    }

    /// An account a line per item: the broker's names are what it resumes
    /// on, the router's order and facts are what they are drawn with (a
    /// name the router did not list keeps its place after, bare). Logged
    /// out cannot be chosen; nor, for a switch, the account that is blocked.
    func lines(_ accounts: AgentAccounts?, switching: Bool, now: Date) -> [Line] {
        let known = accounts?.accounts.filter { menu.accounts.contains($0.name) } ?? []
        let bare = menu.accounts.filter { name in !known.contains { $0.name == name } }
        return known.map { entry in
            let current = entry.name == account
            let pick = entry.name == accounts?.pick
            let said = [current ? "this pane" : nil, pick ? "\(router)’s pick" : nil].compactMap { $0 }
            let marks = [entry.name] + said
            let icon = entry.loggedOut ? "person.crop.circle.badge.xmark"
                : current && block != nil ? "exclamationmark.triangle"
                : entry.spent ? "xmark.octagon"
                : pick ? "star.fill"
                : current ? "checkmark.circle"
                : "person.crop.circle"
            return Line(name: entry.name, title: (marks + [entry.facts(now: now)]).joined(separator: " · "),
                        icon: icon, unusable: entry.loggedOut || (switching && current),
                        account: entry, marks: said.isEmpty ? nil : said.joined(separator: ", "))
        } + bare.map { name in
            Line(name: name, title: name == account ? name + " · this pane" : name, icon: "person.crop.circle",
                 unusable: switching && name == account)
        }
    }
}

/// The pane's facts a notice follows after the menu closed: it resolves
/// from them, not from the answer alone.
struct PaneResumeLive {
    var menu: PaneGlance.ResumeMenu?
    var restart: Restart.Note?
    var agent: String
}

/// One command and what became of it, for one row, reached from either
/// platform's menu.
struct PaneResumeReceipt {
    let id = UUID()
    let row: String
    let title: String
    /// `Restart.kind` of what was sent; nil for a question not yet answered.
    var intent: String?
    let sentAt = Date()
    var answer: Restart.Answer?
    var confirm: (() -> Void)?
    var offerImmediate: (() -> Void)?
    var cancel: ((UUID) -> Void)?

    /// What the notice says now: the answer, followed by what the pane's
    /// broker says since (a resume still waiting, done, not done).
    func notice(_ live: PaneResumeLive?) -> (detail: String, tone: InkTone, waiting: UUID?) {
        guard let answer else { return ("Asking the pane’s Mac…", .neutral, nil) }
        // What became of a restart since this was sent: the broker's word.
        if let note = live?.restart, note.at >= sentAt.timeIntervalSince1970 - 1,
           answer.outcome == .armed || answer.outcome == .restarting {
            switch note.state {
            case .ran: return ("Restarted. " + note.said, .neutral, nil)
            case .notRun: return ("Not restarted: " + note.said, .warn, nil)
            case .ending: return (note.said, .neutral, nil)
            case .armed: break
            }
        }
        switch answer.outcome {
        case .armed:
            if let ticket = answer.scheduleID, live?.menu?.scheduled == ticket { return (answer.said, .neutral, ticket) }
            if answer.scheduleID == nil { return (answer.said, .neutral, nil) }
            return ("It no longer waits: the resume was cancelled, or the pane’s agent or conversation changed.", .neutral, nil)
        case .refused: return ("Not done: " + answer.said, .warn, nil)
        case .restarting, .relayUpdated, .busy, .cancelled: return (answer.said, answer.outcome == .busy ? .warn : .neutral, nil)
        }
    }

    @MainActor
    func actions(_ live: PaneResumeLive?, dismiss: @escaping () -> Void) -> InkActionPanel.Actions {
        if let command = answer?.manualCommand {
            return .buttons([InkHUD.Action("Copy resume command") {
                VigilPasteboard.copy(command)
                dismiss()
            }])
        }
        if let ticket = notice(live).waiting {
            var buttons: [InkHUD.Action] = []
            if let offerImmediate { buttons.append(InkHUD.Action("Resume now…") { offerImmediate() }) }
            if let cancel { buttons.append(InkHUD.Action("Cancel resume") { cancel(ticket) }) }
            return .buttons(buttons)
        }
        return []
    }
}

struct PaneResumeItems: View {
    let facts: PaneResumeFacts
    let title: String
    let row: String
    @Binding var receipt: PaneResumeReceipt?
    let request: (Restart.Intent) async throws -> Restart.Answer
    @ObservedObject private var store = VigilAccountFacts.shared

    private var menu: PaneGlance.ResumeMenu { facts.menu }

    var body: some View {
        // Its account cannot run a turn: there is no turn to protect, so a
        // switch restarts at once, the accounts' facts in front.
        if let block = facts.block, menu.scheduled == nil {
            Section(blockTitle(block)) {
                Menu {
                    accountItems(switching: true)
                } label: { Label("Switch account now", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        if let ticket = menu.scheduled {
            Button { send(.cancel(ticket)) } label: {
                Label("Cancel resume as " + (menu.destination ?? "selected account"), systemImage: "xmark.circle")
            }
        } else {
            Button { if let account = facts.account { resume(as: account) } } label: {
                Label("Resume" + (facts.account.map { " as " + $0 } ?? ""), systemImage: "arrow.clockwise")
            }
            .disabled(!menu.accounts.contains(facts.account ?? ""))
            Menu {
                accountItems(switching: false)
            } label: { Label("Resume as", systemImage: "person.2") }
        }
        if let destination = menu.destination ?? facts.account, menu.accounts.contains(destination) {
            Button { confirmResume(as: destination) } label: { Label("Resume now…", systemImage: "bolt") }
        }
    }

    private func blockTitle(_ block: AccountBlock) -> String { facts.blockTitle(block) }

    /// One line per account, as the router reads it on the pane's Mac and
    /// in its order (its pick first, the spent after the rest): the facts of
    /// `c accounts` / `cx accounts`, so a choice is made seeing them.
    @ViewBuilder
    private func accountItems(switching: Bool) -> some View {
        let reading = store.reading(facts.accounts)
        let now = Date()
        Text(facts.header(reading))
        #if os(macOS)
        let table = reading?.facts.map { accounts in
            AccountTable(accounts, marks: { entry in
                facts.lines(accounts, switching: switching, now: now).first { $0.name == entry.name }?.marks
            }, now: now)
        }
        #endif
        ForEach(facts.lines(reading?.facts, switching: switching, now: now), id: \.name) { line in
            Button {
                switching ? switchAccount(to: line.name) : resume(as: line.name)
            } label: {
                #if os(macOS)
                // The table row, in agent-hud's colours and columns; a menu
                // title would lose both.
                if let table, let account = line.account, let read = reading?.at,
                   let image = table.image(account, marks: line.marks, icon: line.icon, read: read,
                                           scale: NSScreen.main?.backingScaleFactor ?? 2) {
                    Label { Text(line.title) } icon: { Image(nsImage: image) }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(line.title)
                } else {
                    Label(line.title, systemImage: line.icon)
                }
                #else
                Label(line.title, systemImage: line.icon)
                #endif
            }
            .disabled(line.unusable)
        }
    }

    private func selection(_ account: String) -> Restart.Selection {
        Restart.Selection(instance: menu.instance, revision: menu.revision, conversation: facts.conversation, account: account)
    }

    private func confirmResume(as account: String) {
        let choice = selection(account)
        receipt = PaneResumeReceipt(row: row, title: "Resume now as " + account + "?",
                                    confirm: { send(.resumeNow(choice)) })
    }

    private func resume(as account: String) { send(.resume(selection(account))) }

    private func switchAccount(to account: String) { send(.switchAccount(selection(account))) }

    private func send(_ intent: Restart.Intent) {
        let asked = Restart(intent)
        // One press is one request: a menu that fires its action twice
        // sends the second into the first's answer (refused: "already
        // scheduled"), which the notice would show instead of the first.
        if let pending = receipt, pending.row == row, pending.answer == nil, pending.intent == asked.kind {
            resumeLog.warn("resume pressed again while asking", ["row": row, "intent": asked.kind])
            return
        }
        let title = switch intent {
        case .resume(let choice): "Resume as " + choice.account
        case .resumeNow(let choice): "Resume now as " + choice.account
        case .switchAccount(let choice): "Switch to " + choice.account
        case .cancel: "Cancel resume"
        default: self.title
        }
        var pending = PaneResumeReceipt(row: row, title: title, intent: asked.kind)
        if case .resume(let choice) = intent {
            pending.offerImmediate = { confirmResume(as: choice.account) }
            pending.cancel = { ticket in send(.cancel(ticket)) }
        }
        let pendingID = pending.id
        receipt = pending
        resumeLog.info("resume asked", ["row": row, "intent": asked.kind, "account": asked.account ?? ""])
        Task { @MainActor in
            let answer: Restart.Answer
            do { answer = try await request(intent) }
            catch { answer = .init(.refused, error.localizedDescription) }
            resumeLog.info("resume answered", ["row": row, "intent": asked.kind, "outcome": answer.outcome.rawValue,
                                               "said": answer.said, "current": receipt?.id == pendingID])
            if receipt?.id == pendingID { receipt?.answer = answer }
        }
    }
}

extension View {
    /// The notice of a row's resume: the confirmation of Resume now, then
    /// what became of what was sent, followed live from the row (`live`)
    /// until it is done, refused or cancelled.
    func paneResumeFeedback(row: String, receipt: Binding<PaneResumeReceipt?>, live: PaneResumeLive?) -> some View {
        inkActionPopover(isPresented: Binding(get: { receipt.wrappedValue?.row == row }, set: { shown in
            if !shown, receipt.wrappedValue?.row == row { receipt.wrappedValue = nil }
        })) {
            if let result = receipt.wrappedValue {
                if let confirm = result.confirm {
                    InkActionPanel(result.title, detail: "This ends the current turn and stops any running tool or background task.",
                                   tone: .warn, actions: .buttons([
                                       InkHUD.Action("Resume now") { confirm() },
                                       InkHUD.Action("Cancel") { receipt.wrappedValue = nil }
                                   ]))
                } else {
                    let notice = result.notice(live)
                    InkActionPanel(result.title, detail: notice.detail, tone: notice.tone,
                                   actions: result.actions(live) { receipt.wrappedValue = nil })
                }
            }
        }
    }
}
