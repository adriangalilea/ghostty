#if os(macOS)
import AskKit
import AuthzProtocol
import Foundation

/// The fast lane's reading of a request: every answerable kind becomes one
/// or more HUD asks (a yes/no, a numbered choice, a text entry), and each
/// answer becomes a typed decision or one question's answer. The card is
/// the fallback for what no ask shape can carry (a secret, a schema form,
/// an oversized review), never the first surface for a question.
enum VigilAskPlan {
    enum Part {
        case decision(Decision)
        case answer(questionID: String, QuestionAnswer)
    }

    struct Step {
        let spoken: String
        let detail: Ask.Detail?
        let options: [String]?
        let textOptions: Set<Int>
        let multi: Bool
        /// Open the text stage at once (a free-text question has no choice
        /// to make before typing).
        let enterText: Bool
        let timeout: TimeInterval
        /// nil = the answer fits no typed outcome; the card takes over.
        let resolve: (Answer, _ picks: [Int]) -> Part?
    }

    /// nil = nothing the HUD can carry for this request.
    static func steps(for request: AskRequest) -> [Step]? {
        guard request.responseMode == .interactive, !request.containsSecrets else { return nil }
        let spoken = request.safeGist.isEmpty ? request.title : request.safeGist
        let detail = request.detail.map { Ask.Detail(text: $0, format: request.detailFormat) }
        switch request.kind {
        case .questionnaire, .form:
            guard !request.questions.isEmpty else { return nil }
            // A batch reads like the terminal's tab strip: the question's
            // header and its place in the batch lead, so the HUD and the
            // dialog beside it name the same question even though only the
            // HUD advances (the dialog closes when the batch submits).
            let count = request.questions.count
            var steps: [Step] = []
            for (index, question) in request.questions.enumerated() {
                let place = count > 1 ? "\(index + 1) of \(count)" : nil
                let lead = [question.header, place].compactMap { $0 }.joined(separator: " · ")
                let spoken = lead.isEmpty ? question.title : "\(lead): \(question.title)"
                guard let step = self.step(for: question, spoken: spoken, timeout: 45) else { return nil }
                steps.append(step)
            }
            return steps
        case .permission, .planReview, .changeReview, .externalAction, .conversation, .unknown:
            guard !request.actions.isEmpty else { return nil }
            return [actions(request.actions, spoken: spoken, detail: detail,
                            timeout: request.kind == .permission ? 20 : 45)]
        }
    }

    /// A plain allow-once permission with a refusal is a yes/no; anything
    /// with more verbs (a scoped grant, a revision) is a numbered choice
    /// where the revision opens the input for its feedback.
    private static func actions(_ actions: [Action], spoken: String, detail: Ask.Detail?,
                                timeout: TimeInterval) -> Step {
        let yes = actions.first { $0.effect == .approveOnce }
        let no = actions.first { $0.effect == .reject } ?? actions.first { $0.effect == .cancel }
        if let yes, let no, actions.count == 2 {
            return Step(spoken: spoken, detail: detail, options: nil, textOptions: [], multi: false,
                        enterText: false, timeout: timeout) { answer, _ in
                switch answer {
                case .yes: .decision(.action(yes.id, feedback: nil))
                case .no: .decision(.action(no.id, feedback: nil))
                case .option, .options, .text: nil
                }
            }
        }
        let revisions = Set(actions.indices.filter { actions[$0].effect == .revise })
        return Step(spoken: spoken, detail: detail, options: actions.map(\.label), textOptions: revisions,
                    multi: false, enterText: false, timeout: timeout) { answer, _ in
            switch answer {
            case .option(let index) where actions.indices.contains(index):
                .decision(.action(actions[index].id, feedback: nil))
            case .text(let text, let index) where actions.indices.contains(index):
                .decision(.action(actions[index].id, feedback: text))
            case .yes: yes.map { Part.decision(.action($0.id, feedback: nil)) }
            case .no: no.map { Part.decision(.action($0.id, feedback: nil)) }
            default: nil
            }
        }
    }

    private static func step(for question: Question, spoken: String, timeout: TimeInterval) -> Step? {
        let id = question.id
        // Choice descriptions are shown as evidence under the question,
        // never narrated: the labels carry the voice, the block the fine
        // print.
        let described = question.choices.enumerated().compactMap { offset, choice in
            choice.description.map { "\(offset + 1). \(choice.label): \($0)" }
        }
        let detail = described.isEmpty ? nil : Ask.Detail(text: described.joined(separator: "\n"))
        switch question.kind {
        case .singleChoice, .multipleChoice:
            guard !question.choices.isEmpty else { return nil }
            let ids = question.choices.map(\.id)
            let other = question.allowOther ? question.choices.count : nil
            let options = question.choices.map(\.label) + (other == nil ? [] : ["Something else"])
            let multi = question.kind == .multipleChoice
            return Step(spoken: spoken, detail: detail, options: options,
                        textOptions: other.map { [$0] } ?? [], multi: multi, enterText: false,
                        timeout: timeout) { answer, picks in
                switch answer {
                case .option(let index) where ids.indices.contains(index):
                    .answer(questionID: id, .choices([ids[index]], other: nil))
                case .options(let indices):
                    .answer(questionID: id, .choices(indices.filter(ids.indices.contains).map { ids[$0] }, other: nil))
                case .text(let text, let index) where index == other:
                    // A multi-select's toggles ride along with the typed
                    // "something else"; a single choice is the text alone.
                    .answer(questionID: id, .choices(multi ? picks.filter(ids.indices.contains).map { ids[$0] } : [],
                                                     other: text))
                default: nil
                }
            }
        case .text:
            return Step(spoken: spoken, detail: detail, options: ["Answer"], textOptions: [0],
                        multi: false, enterText: true, timeout: timeout) { answer, _ in
                guard case .text(let text, _) = answer else { return nil }
                return .answer(questionID: id, .text(text))
            }
        case .number:
            return Step(spoken: spoken, detail: detail, options: ["Answer"], textOptions: [0],
                        multi: false, enterText: true, timeout: timeout) { answer, _ in
                guard case .text(let text, _) = answer, let value = Double(text.trimmingCharacters(in: .whitespaces))
                else { return nil }
                return .answer(questionID: id, .number(value))
            }
        case .boolean:
            return Step(spoken: spoken, detail: detail, options: nil, textOptions: [], multi: false,
                        enterText: false, timeout: timeout) { answer, _ in
                switch answer {
                case .yes: .answer(questionID: id, .boolean(true))
                case .no: .answer(questionID: id, .boolean(false))
                default: nil
                }
            }
        }
    }
}
#endif
