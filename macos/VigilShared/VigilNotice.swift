import AttentionViews
import Attentions
import SwiftUI

/// An action a notice offers, with what a press on it does here: a notice
/// is a value (`Attention.Notice`, its actions by id) and its card hands
/// back the id pressed, so each place keeps the id beside its work.
struct NoticeAct {
    let action: Attention.Action
    let run: @MainActor () -> Void

    init(_ title: String, id: String? = nil, symbol: String? = nil, role: Attention.Action.Role = .plain,
         _ run: @escaping @MainActor () -> Void) {
        action = Attention.Action(title, id: id ?? title, symbol: symbol, role: role)
        self.run = run
    }
}

extension Attention.Card {
    /// A notice whose every action (its own, its group's and its feedback's)
    /// is among `acts`: a press runs the one of that id.
    init(_ notice: Attention.Notice, acts: [NoticeAct]) {
        self.init(notice, act: { id in acts.first { $0.action.id == id }?.run() })
    }
}
