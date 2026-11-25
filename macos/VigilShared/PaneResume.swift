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

    /// The first line of the accounts panel: whose facts these are, for
    /// which model, and what a launch of it would do when that is not
    /// simply "start on the pick"; or why there are none.
    func header(_ reading: VigilAccountFacts.Reading?, now: Date) -> String {
        switch reading {
        case nil: return "Reading \(router) accounts on the pane’s Mac…"
        case .failed(let why): return "No account facts: \(why)"
        case .facts(let accounts):
            let model = (menu.model ?? accounts.model).map { " for " + $0 } ?? ""
            guard let route = accounts.route(for: menu.model), route.verdict != .launch else { return "\(router) accounts\(model)" }
            let back = route.back.flatMap { $0 > now ? ", back in " + AccountRow.span(from: now, to: $0) : nil } ?? ""
            return "\(router) accounts\(model): \(route.verdict.said)\(back)"
        }
    }

    struct Line {
        let account: AgentAccounts.Account
        /// The router passes it over for the model while another is left.
        let spent: Bool
        /// A bare launch of the pane's model would start on it now.
        let pick: Bool
    }

    /// An account a line, as agent-hud's document lists and weighs them
    /// for the model the pane runs: its route's order, then any account
    /// the route did not weigh. Nothing here lists or ranks one.
    func lines(_ accounts: AgentAccounts?) -> [Line] {
        guard let accounts else { return [] }
        let route = accounts.route(for: menu.model)
        let ordered = (route?.order ?? []).compactMap { accounts.account($0) }
        let listed = ordered + accounts.accounts.filter { entry in !ordered.contains { $0.name == entry.name } }
        return listed.map { Line(account: $0, spent: route?.spent.contains($0.name) ?? false, pick: route?.pick == $0.name) }
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
    /// The accounts to choose from, while the panel shows them, and what a
    /// choice does.
    var picking: PaneResumeFacts?
    var choose: ((AgentAccounts.Account) -> Void)?
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
        case .restarting, .relayUpdated, .cancelled: return (answer.said, .neutral, nil)
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
    /// The pane's Mac asked for its accounts document, as kept or current.
    let accounts: VigilAccountFacts.Ask
    let request: (Restart.Intent) async throws -> Restart.Answer

    private var menu: PaneGlance.ResumeMenu { facts.menu }

    var body: some View {
        // Its account cannot run a turn: said over the items that mend it.
        if let block = facts.block { Text(blockTitle(block)) }
        if let ticket = menu.scheduled {
            Button { send(.cancel(ticket)) } label: {
                Label("Cancel resume as " + (menu.destination ?? "selected account"), systemImage: "xmark.circle")
            }
        }
        Button { if let account = facts.account { resume(as: account) } } label: {
            Label("Resume" + (facts.account.map { " as " + $0 } ?? ""), systemImage: "arrow.clockwise")
        }
        .disabled(facts.account == nil)
        // The accounts with their facts, in a panel on the row: a menu can
        // draw neither a bar nor numbers that change while it is open.
        Button { pick() } label: { Label("Resume as…", systemImage: "person.2") }
        if let destination = menu.destination ?? facts.account {
            Button { confirmResume(selection(destination)) } label: { Label("Resume now…", systemImage: "bolt") }
        }
    }

    private func blockTitle(_ block: AccountBlock) -> String { facts.blockTitle(block) }

    /// The row's panel opens on the accounts as last read (`AccountPicker`)
    /// and asks for them brought up to date: a press there is the resume.
    private func pick() {
        resumeLog.info("accounts shown", ["row": row, "model": menu.model ?? ""])
        VigilAccountFacts.shared.want(facts.accounts, current: true, ask: accounts)
        receipt = PaneResumeReceipt(row: row, title: "Resume as", picking: facts,
                                    choose: { send(.resume(selection($0.name, login: $0.account))) })
    }

    /// `login`: the provider's id of the login the pressed row showed, so
    /// the pane's Mac refuses a profile that holds another by then.
    private func selection(_ account: String, login: String? = nil) -> Restart.Selection {
        Restart.Selection(instance: menu.instance, revision: menu.revision, conversation: facts.conversation, account: account, login: login)
    }

    private func confirmResume(_ choice: Restart.Selection) {
        receipt = PaneResumeReceipt(row: row, title: "Resume now as " + choice.account + "?",
                                    confirm: { send(.resumeNow(choice)) })
    }

    private func resume(as account: String) { send(.resume(selection(account))) }


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
        case .cancel: "Cancel resume"
        case .relay: self.title
        }
        var pending = PaneResumeReceipt(row: row, title: title, intent: asked.kind)
        if case .resume(let choice) = intent {
            pending.offerImmediate = { confirmResume(choice) }
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
                if let facts = result.picking, let choose = result.choose {
                    AccountPicker(facts: facts, choose: choose)
                } else if let confirm = result.confirm {
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
