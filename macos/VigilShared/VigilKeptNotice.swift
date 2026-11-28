import AttentionViews
import Attentions
import SwiftUI
import VigilWire

/// A notice the host kept on its own surface while Authz was away
/// (`Asks.Kept`), drawn as Authz would draw it: its "Go there" opens the
/// pane it names, and Dismiss takes it off the host's surface.
struct VigilKeptNotice: View {
    let kept: Asks.Kept
    let chats: VigilChats
    let dismiss: @Sendable (Asks.Kept) async throws -> Void
    @State private var failed: String?

    private static let dismissID = "vigil.kept.dismiss"

    var body: some View {
        var notice = kept.notice
        notice.actions.append(Attention.Action("Dismiss", id: Self.dismissID, role: .cancel))
        if let failed { notice.feedback = .failed(failed, actions: [Attention.Action("Dismiss", id: Self.dismissID, role: .cancel)]) }
        let open = chats.host.open
        let kept = kept, dismiss = dismiss
        let acts = kept.notice.actions.compactMap { action -> NoticeAct? in
            guard let url = URL(string: action.id), let ref = VigilRef(url: url), ref.kind == .pane else { return nil }
            return NoticeAct(action.title, id: action.id, symbol: action.symbol) { open(ref.id) }
        } + [NoticeAct("Dismiss", id: Self.dismissID, role: .cancel) {
            Task { @MainActor in
                do { try await dismiss(kept) } catch { failed = "\(error)" }
            }
        }]
        return Attention.Card(notice, acts: acts)
            .padding(.horizontal, .inkGap)
            .padding(.top, .inkGap)
    }
}
