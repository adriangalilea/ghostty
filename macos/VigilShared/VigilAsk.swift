import AttentionViews
import Attentions
import AuthzContract
import AuthzContractViews
import Ink
import SwiftUI
import VigilWire

/// An ask the host holds on its own surface (`Asks.Standing`: a delivery
/// waiting for the person's answer, a chat an agent proposed, a question about
/// a pane), drawn where it is about (inside the post's bubble, above the
/// chat's composer, in the pane's thread) by Authz's own view of an ask
/// (`Authz.AskView`: each answer taken as its terms say, the owner's
/// answers proven as they are pressed), with whom or what it waits on over
/// it.
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
            let bindings = standing.bindings
            Authz.AskView(
                standing.ask, binding: { prompt in bindings[prompt.id] },
                answer: { given, shown, owner in try await give(given, shown: shown, owner: owner) })
            if let line = said ?? answered { Text(line).inkText(.detail) }
        }
        .padding(.top, 2)
    }

    /// A press the owner authenticated for, or a finger on Touch ID (the
    /// answer's reach, `Authz.QuietTouchID`), is the person's; any other
    /// must be a click of theirs, read in the press's own turn.
    private func give(_ given: Attention.Answer, shown: Authz.Binding, owner: Bool) async throws {
        let touchID = if case .channel(let channel)? = given.reach { channel.name == "Touch ID" } else { false }
        guard owner || touchID || pressedByPerson() else {
            throw Refused(description: "Not answered: only a click of yours answers it here.")
        }
        said = try await answer(Asks.Press(answer: given, shown: shown, ownerAuthenticated: owner))
    }

    private struct Refused: Error, CustomStringConvertible { let description: String }
}

/// The lasting answer that let a post through to a member, said under the
/// chat's newest such post with a way to end it (`Act.revoke`): the two
/// members' next posts to each other wait for the person again.
struct VigilLastingAnswer: View {
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
