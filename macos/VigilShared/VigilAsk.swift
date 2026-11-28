import AttentionViews
import Attentions
import AuthzContract
import AuthzContractViews
import Ink
import LocalAuthentication
import OwnerAuthentication
import SwiftUI
import VigilWire

/// An ask the host holds on its own surface (`Asks.Standing`: a delivery
/// waiting for the person's yes, a chat an agent proposed, a question about
/// a pane), drawn where it is about (inside the post's bubble, above the
/// chat's composer, in the pane's thread) by Authz's convention: attention's
/// card, each answer taken as its terms say (`Authz.Ask.presses(of:)`: one
/// that applies a plan, needs the owner or lasts takes a deliberate press),
/// an answer that needs the owner drawn as swift-utils'
/// `OwnerAuthenticationButton`, which proves the owner as it is pressed.
///
/// An answer is sent back with the binding the host drew the ask with, so an
/// answer to content that changed since is refused there as stale. Only a
/// person's press answers (`pressedByPerson`, a hardware click on the Mac),
/// or one the owner authenticated for.
struct VigilAsk: View {
    let standing: Asks.Standing
    /// Whom or what it waits on, over the card (a delivery's addressee, why
    /// the Vigil app asks it); nil: the card alone.
    var heading: String?
    /// Since when it waits, unix seconds.
    var since: Double?
    /// What came of an earlier answer to it here, in the host's words.
    var answered: String?
    /// The person's answer; what came of it, in the host's words.
    let answer: @MainActor (_ press: Asks.Press) async throws -> String
    let pressedByPerson: @MainActor () -> Bool
    /// The answers the person authenticated for, by ask id.
    @State private var proven: [String: Set<String>] = [:]
    @State private var said: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if heading != nil || since != nil {
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    if let since {
                        (Text((heading.map { "\($0) · " } ?? "") + "asked ")
                            + Text(Date(timeIntervalSince1970: since), format: .relative(presentation: .named)))
                            .inkText(.detail)
                    } else if let heading {
                        Text(heading).inkText(.detail)
                    }
                }
            }
            if let because = standing.because { Text(because).inkText(.detail) }
            Attention.RequestCard(standing.ask.request) { prompt in
                card(prompt)
            } ended: { _ in }
            if let line = said ?? answered { Text(line).inkText(.detail) }
        }
        .padding(.top, 2)
    }

    private func card(_ prompt: Attention.Prompt) -> Attention.PromptCard {
        let ask = standing.ask
        var card = Attention.PromptCard(prompt) { given, _ in
            try await give(given, to: prompt)
        }
        .presses(ask.presses(of: prompt))
        for action in prompt.answers where ask.terms(of: action.id, to: prompt.id).assurance.sure == .ownerAuthenticated {
            card = card.answer(action.id) { drawn in
                OwnerAuthenticationButton(drawn.action.title, context: nil) {
                    Task { await authenticate(action.id, of: prompt, drawn: drawn) }
                }
            }
        }
        return card
    }

    private func give(_ given: Attention.Answer, to prompt: Attention.Prompt) async throws -> Attention.PromptCard.Applied {
        let owner = proven[prompt.id]?.contains(given.id) ?? false
        guard owner || pressedByPerson() else {
            throw Refused(description: "Not answered: only a click of yours answers it here.")
        }
        guard let shown = standing.bindings[prompt.id] else {
            throw Refused(description: "Not answered: this question is no longer asked.")
        }
        let line = try await answer(Asks.Press(answer: given, shown: shown, ownerAuthenticated: owner))
        said = line
        return .applied(line)
    }

    private func authenticate(_ id: String, of prompt: Attention.Prompt, drawn: Attention.PromptCard.Drawn) async {
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "confirm your answer")))
            == true
        else { return }
        proven[prompt.id, default: []].insert(id)
        drawn.press(by: "owner authenticated")
    }

    private struct Refused: Error, CustomStringConvertible { let description: String }
}

/// The lasting answer that let a post through to a member, said under the
/// chat's newest such post with a way to end it (`Act.revoke`): the two
/// members' next posts to each other wait for the person again.
struct VigilStandingYes: View {
    /// When it runs out, unix seconds; 0: it stands until ended.
    let until: Double
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal").inkForeground(.muted)
            Text("These two post to each other without asking you, " + (until > 0 ? "until " + Messages.clock(until, zone: .current) : "until you end it"))
                .inkText(.detail)
            Button("End", action: revoke).buttonStyle(.ink).focusable(false)
        }
    }
}
