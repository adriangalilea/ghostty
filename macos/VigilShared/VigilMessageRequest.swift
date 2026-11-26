import AuthzProtocol
import AuthzUI
import Ink
import SwiftUI
import VigilWire

/// The request on a post's delivery waiting for the person's yes, drawn
/// inside the post's bubble (a request sits on what it is about, never in a
/// detached bar): whom it would go to and how long it has waited, then the
/// request's own consent drawn with Authz's controls (`ConsentChoice`: once,
/// or a standing yes for the two members on Authz's slider of times and
/// "always"), its refusal and its yes. The request is the very one the host
/// built and Authz carries (`Messages.Standing.requests`), and the answer is
/// a `Decision` on it, which that host decides at once, Authz reachable or
/// not; only from a person's click (`VigilChatHost.pressedByPerson`). A yes
/// that needs the owner (a stop's) asks for owner authentication on this
/// device first (`authenticated`). Once answered here, what came of it, in
/// the host's words.
struct VigilDeliveryRequest: View {
    /// The member it would be delivered to, by name.
    let to: String
    let request: AskRequest
    /// Since when it waits, unix seconds.
    let since: Double?
    let answered: String?
    let answer: (_ decision: Decision, _ authenticated: Bool) -> Void
    @State private var position = 0
    @State private var minutes: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                if let since {
                    (Text("To \(to): waiting for you · asked ")
                        + Text(Date(timeIntervalSince1970: since), format: .relative(presentation: .named)))
                        .inkText(.detail)
                } else {
                    Text("To \(to): waiting for you").inkText(.detail)
                }
            }
            if let consent = request.consent {
                ConsentChoice(consent, position: $position, minutes: $minutes)
                HStack(spacing: 8) {
                    Button(request.actions[consent.refusal].label) { pick(.no, consent) }.buttonStyle(.ink)
                    // Never a default button: Return is the composer's.
                    Button(ConsentAnswers.yes(consent, position: position)) {
                        pick(.yes(ConsentChoice.clamped(position, consent), lasting: minutes), consent)
                    }
                    .buttonStyle(.inkProminent)
                }
                .focusable(false)
            }
            if let answered { Text(answered).inkText(.detail) }
        }
        .padding(.top, 2)
    }

    /// The person's pick, as the request's own form reads it.
    private func pick(_ pick: Pick, _ consent: AnswerForm.Consent) {
        guard let decision = request.form?.decision(for: pick, of: request) else { return }
        answer(decision, pick != .no && consent.authenticated)
    }
}

/// A chat an agent or a command proposed, waiting for the person's one yes
/// (`Messages.Page.request`), drawn above the chat's composer with Authz's
/// controls: Allow lets its members talk there, Refuse takes it away.
struct VigilChatRequest: View {
    let request: AskRequest
    let answered: String?
    let answer: (_ decision: Decision, _ authenticated: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Waiting for you").inkText(.detail)
            }
            if let consent = request.consent {
                Text(request.title).font(.headline)
                if let detail = request.detail { Text(detail).inkText(.detail) }
                if let subtitle = request.subtitle { Text(subtitle).inkText(.detail) }
                HStack(spacing: 8) {
                    Button(request.actions[consent.refusal].label) { pick(.no, consent) }.buttonStyle(.ink)
                    Button(ConsentAnswers.yes(consent, position: 0)) { pick(.yes(0, lasting: nil), consent) }.buttonStyle(.inkProminent)
                }
                .focusable(false)
            }
            if let answered { Text(answered).inkText(.detail) }
        }
        .padding(8)
    }

    private func pick(_ pick: Pick, _ consent: AnswerForm.Consent) {
        guard let decision = request.form?.decision(for: pick, of: request) else { return }
        answer(decision, pick != .no && consent.authenticated)
    }
}

/// The standing yes that let a post through to a member, said under the
/// chat's newest such post with a way to revoke it (`Act.revoke`): the two
/// members' next posts to each other wait for the person again.
struct VigilStandingYes: View {
    /// When it runs out, unix seconds; 0: it stands until revoked.
    let until: Double
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal").inkForeground(.muted)
            Text("These two post to each other without asking you, " + (until > 0 ? "until " + Messages.clock(until, zone: .current) : "until you revoke it"))
                .inkText(.detail)
            Button("Revoke", action: revoke).buttonStyle(.ink).focusable(false)
        }
    }
}
