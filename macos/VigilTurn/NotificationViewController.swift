import MarkdownText
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI
import VigilActivity
import VigilWire

/// A turn's notification, expanded (pulled down or pressed): what the agent
/// said, set as the conversation sets it (its markdown drawn: lists, code,
/// emphasis), under the pane and its Mac. The system's own title and body
/// are hidden (Info.plist): this is the whole of what shows above the
/// replies, which stay the system's buttons (`TurnNotification.categories`).
///
/// It opens the note itself, with the turn key in its keychain group,
/// as the notification extension did: a note it cannot open is drawn from
/// the words that extension already wrote. A reply chosen under it is
/// said here ("Sending …") and handed to the app, which types it into the
/// pane and says so if it did not land (`VigilTurnReply`): an extension
/// holds no connection to a Mac.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let shown = TurnShown()
    private var host: UIHostingController<TurnView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: TurnView(shown: shown))
        host.view.backgroundColor = .clear
        host.sizingOptions = [.preferredContentSize]
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    /// The view is as tall as what it says, up to what a notification may be.
    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        preferredContentSize = CGSize(width: view.bounds.width, height: container.preferredContentSize.height)
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        if let note = TurnNotification.note(of: content) {
            shown.set(
                title: [note.emoji, note.label].compactMap { $0 }.joined(separator: " "), mac: note.mac, asked: note.asked,
                said: note.said, at: Date(timeIntervalSince1970: note.at))
        } else {
            shown.set(title: content.title, mac: content.subtitle, asked: false, said: content.body, at: notification.date)
        }
    }

    func didReceive(
        _ response: UNNotificationResponse, completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void
    ) {
        if let line = TurnNotification.read(response)?.line { shown.sending = line }
        // Seen for a moment, then the app has it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { completion(.dismissAndForwardAction) }
    }
}

/// What the expanded view draws.
final class TurnShown: ObservableObject {
    @Published var title = ""
    @Published var mac = ""
    @Published var asked = false
    @Published var said: String?
    @Published var at = Date()
    /// The line being handed to the app.
    @Published var sending: String?

    func set(title: String, mac: String, asked: Bool, said: String?, at: Date) {
        self.title = title
        self.mac = mac
        self.asked = asked
        self.said = said
        self.at = at
    }
}

struct TurnView: View {
    @ObservedObject var shown: TurnShown

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.title).font(.headline).lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: "laptopcomputer")
                    Text(shown.mac).fontWeight(.semibold)
                    Text("·")
                    Image(systemName: shown.asked ? "hand.raised.fill" : "checkmark")
                        .foregroundStyle(shown.asked ? Color.orange : Color.teal)
                    Text(shown.asked ? "Asked you" : "Done")
                    Text("·")
                    Text(shown.at, style: .relative)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if let said = shown.said, !said.isEmpty {
                MarkdownView(said)
            } else {
                Text(shown.asked ? "It asked you something." : "Its turn ended.").foregroundStyle(.secondary)
            }
            if let sending = shown.sending {
                Label("Sending “\(sending)”…", systemImage: "paperplane.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
