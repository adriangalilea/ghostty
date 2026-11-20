import SwiftUI
import VigilLink
import VigilWire

/// The phone's side of a conversation (`VigilShared/VigilConversation.swift`):
/// the pane's Mac reached over tether, requests answered through this
/// phone's authz endpoint, receipts in the app's record; and the host that
/// gives the screen what only the phone knows (its Mac's directory, the
/// keyboard, the terminal's ground, an activity's Reply).
extension Conversation {
    /// A conversation of `ref`, followed once started.
    static func phone(_ ref: PaneRef) -> Conversation {
        let phone = VigilPhone.shared
        let receipts = phone.receipts
        let device = ref.host.id
        return Conversation(key: Self.key(ref), pane: ref.pane, source: ConversationSource(
            follow: {
                let steps = phone.feed(ref)
                return AsyncStream { continuation in
                    let task = Task {
                        for await step in steps {
                            switch step {
                            case .message(let message): continuation.yield(.message(message))
                            case .waiting(let why): continuation.yield(.waiting(why))
                            }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            earlier: { request in try await phone.feedEarlier(ref, request) },
            press: { key in try await phone.press(key, in: ref) },
            say: { text in try await phone.say(text, to: ref) },
            authz: ConversationAuthz(
                read: { id in await VigilAuthz.shared.request(device: device, id: id) },
                answer: { id, decision in
                    await VigilAuthz.shared.answer(device: device, request: id, decision).map { .refused($0) } ?? .taken
                }),
            log: ConversationLog(
                info: { receipts.info($0, $1, $2) }, warn: { receipts.warn($0, $1, $2) }, error: { receipts.error($0, $1, $2) }),
            reason: { VigilLink.reason($0) },
            here: "this iPhone"))
    }

    /// Its Mac and its pane: the conversation a pane screen holds.
    static func key(_ ref: PaneRef) -> String { "\(ref.host.id)/\(ref.pane)" }
}

/// A conversation on the phone's pane screen: the shared screen, given the
/// pane's state from its Mac's directory (the seen rule), the keyboard as a
/// fact (`KeyboardState`), the terminal's ground in dark (the app's
/// appearance) and the system's in light, and an activity's Reply.
struct PhoneConversationView: View {
    @ObservedObject var conversation: Conversation
    let ref: PaneRef
    let showTerminal: () -> Void
    @ObservedObject private var phone = VigilPhone.shared
    @ObservedObject private var keyboard = KeyboardState.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ConversationView(
            conversation: conversation,
            shown: phone.directories[ref.host.id]?.panes[ref.pane]?.shown,
            ground: scheme == .dark ? Color(VigilTheme.background) : Color(.systemBackground),
            keyboard: ConversationKeyboard(up: keyboard.inset > 0, lift: keyboard.aboveSafeArea),
            showTerminal: showTerminal)
        // An activity's Reply: the box takes the keyboard.
        .onReceive(phone.$typeInto) { asked in
            guard asked == ref else { return }
            phone.typeInto = nil
            conversation.askReply()
        }
    }
}
