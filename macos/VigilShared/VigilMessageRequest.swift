import AuthzProtocol
import AuthzUI
import Ink
import SwiftUI
import VigilWire

// AuthzUI names a `Message` of its own: vigil's is spelled whole here.

/// The request on a message waiting for the person's yes (CHATS.md, decided
/// 2026-11-19: "A request sits on the message it is about … never a detached
/// bar"), drawn inside its bubble: "Waiting for you" and how long it has
/// waited, the one mark every surface draws for it, then the request's own
/// consent drawn with Authz's controls (`ConsentChoice`: once, or a standing
/// yes for both conversations on Authz's slider of times and "always"), its
/// refusal and its yes. The request is the one its Mac built and Authz
/// carries (`Record.request`), and the answer is a `Decision` on it, which
/// that Mac decides at once, Authz reachable or not (harness/README.md
/// "Messages"); only from a person's click (`VigilChatHost.pressedByPerson`).
/// A yes that needs the owner (a stop's) asks for Touch ID or the device's
/// password first (`authenticated`). Nothing is offered on an older Mac's
/// records. Once answered here, what came of it, in the Mac's words.
struct VigilMessageRequest: View {
    let item: MessageThread.Item
    let answered: String?
    let act: (VigilWire.Message.Act) -> Void
    @State private var position = 0
    @State private var minutes: Int?

    var body: some View {
        let record = item.record
        VStack(alignment: .leading, spacing: 6) {
            if let answered, !record.awaitsYou {
                Text(answered).inkText(.detail)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    (Text("Waiting for you · asked ")
                        + Text(Date(timeIntervalSince1970: record.arrived), format: .relative(presentation: .named)))
                        .inkText(.detail)
                }
                if let request = record.request, let consent = request.consent {
                    ConsentChoice(consent, position: $position, minutes: $minutes)
                    HStack(spacing: 8) {
                        Button(request.actions[consent.refusal].label) { answer(request, .no, consent) }.buttonStyle(.ink)
                        // Never a default button: Return is the composer's.
                        Button(ConsentAnswers.yes(consent, position: position)) {
                            answer(request, .yes(ConsentChoice.clamped(position, consent), lasting: minutes), consent)
                        }
                        .buttonStyle(.inkProminent)
                    }
                    .focusable(false)
                } else {
                    Text("Its Mac's vigil is older: answer it on its card in Authz there.").inkText(.detail)
                }
                if let answered { Text(answered).inkText(.detail) }
            }
        }
        .padding(.top, 2)
    }

    /// The person's pick, as the request's own form reads it.
    private func answer(_ request: AskRequest, _ pick: Pick, _ consent: AnswerForm.Consent) {
        guard let decision = request.form?.decision(for: pick, of: request) else { return }
        let yes = pick != .no
        act(.answer(item.id, decision, authenticated: yes && consent.authenticated))
    }
}

/// The standing yes that let a thread's newest message of a pair through,
/// said under it with a way to revoke it (`Act.revoke`): the next message of
/// the pair waits for the person again.
struct VigilStandingYes: View {
    let item: MessageThread.Item
    let act: (VigilWire.Message.Act) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal").inkForeground(.muted)
            Text(Self.said(item.record.allowance)).inkText(.detail)
            Button("Revoke") { act(.revoke(item.id)) }.buttonStyle(.ink).focusable(false)
        }
    }

    static func said(_ allowance: Envelope.Allowance?) -> String {
        guard case .standing(let until) = allowance else { return "" }
        let end = until.map { "until " + VigilWire.Message.clock($0, zone: .current) } ?? "until you revoke it"
        return "These two message each other without asking you, \(end)"
    }
}
