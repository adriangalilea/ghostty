import AuthzEndpoint
import AuthzGlance
import AuthzProtocol
import OSLog
import UIKit
import UserNotifications
import VigilActivity
import VigilWire

private let authzLog = Logger(subsystem: "com.adriangalilea.vigil", category: "authz")

/// vigil for iPhone as an authz endpoint ("vigil on <phone>"), beside Authz
/// for iPhone on the same device. It presents only what it owns: the
/// panes of what you follow (a session, a tab, a pane), whose questions it
/// shows in their Live Activity and answers through authz. Everything else stays
/// Authz's (authz.space README "Owned contexts: one presenter per device").
@MainActor final class VigilAuthz {
    static let shared = VigilAuthz()

    let runtime = EndpointRuntime(
        .init(
            tetherApp: VigilWire.app, keyGroup: "G387QW47LV.com.adriangalilea.vigil.keys",
            sealGroup: "G387QW47LV.com.adriangalilea.vigil.notify", activityGroup: nil,
            name: "vigil on \(UIDevice.current.name)", presents: .owned))

    /// Starts (or, back on screen, resumes) the app's tether node: it joins
    /// the homes, and the phone model reaches the Macs' sessions through
    /// it. Asks APNs for this app's push address: owning a context counts
    /// only while its owner can be reached.
    func start() {
        Task {
            await runtime.start()
            authzLog.notice("authz: \(self.runtime.status, privacy: .public)")
            if let node = runtime.node {
                VigilPhone.shared.attach(node: node)
                VigilPhone.shared.renewOwnership()
            } else {
                // Nothing reaches a Mac without the node: said, never blank.
                VigilPhone.shared.unlinked(runtime.status)
            }
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The app leaves the screen and iOS suspends it: every connection is
    /// closed now (Authz for iPhone does the same). Held across the
    /// suspension, one looks open on return while the network under it is
    /// gone, and everything waits on it until QUIC's idle timeout; closed,
    /// the return dials fresh (the directories follow again, an open pane
    /// re-dials), on whatever network the phone is on by then.
    func leave() {
        Task {
            await runtime.leave()
            VigilPhone.shared.log("scene: background, connections closed")
        }
    }

    /// Allow or Deny under a question's notification: answered by the
    /// runtime; what happened is a receipt (an answer that failed becomes a
    /// notification saying so).
    func answer(_ target: (id: String, home: String), action: String, shown: String) async {
        switch await runtime.answer(target, action: action) {
        case .answered: VigilPhone.shared.log("authz: answered \(target.id.prefix(8)) (\(action))")
        case .alreadySettled, .gone: VigilPhone.shared.log("authz: \(target.id.prefix(8)) no longer waits")
        case .failed(let why):
            VigilPhone.shared.log("authz: \(target.id.prefix(8)) not answered: \(why)")
            let content = UNMutableNotificationContent()
            content.title = "Not answered"
            content.body = "\(why) Open vigil to answer it: \(shown)"
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "failed-\(target.id)", content: content, trigger: nil))
        }
    }

    /// Allow or Deny inside a followed session's Live Activity: the question
    /// names its Mac, whose authz home answers it (`AnswerIntent`).
    func answer(device: String, request: String, action: String, shown: String) async {
        await runtime.start()
        guard let home = runtime.macs.first(where: { $0.id == device }).flatMap({ mac -> String? in
            if case .answering(let home, _) = mac.state { home } else { nil }
        }) else {
            return VigilPhone.shared.log("authz: \(request.prefix(8)) not answered: its Mac does not let vigil answer")
        }
        await answer((request, home), action: action, shown: shown)
    }

    /// A tapped question: the pane that asks, once its home's view is current.
    func open(_ target: (id: String, home: String)) async {
        await runtime.start()
        guard case .waiting(let snapshot)? = await runtime.readStanding(target, within: .seconds(5)) else {
            return VigilPhone.shared.log("authz: \(target.id.prefix(8)) no longer waits")
        }
        VigilPhone.shared.openPane(snapshot.request.context)
    }

    /// This build's APNs environment (its entitlement: development), for
    /// every token it hands out.
    static let apns: PushRoute.Environment = .sandbox

    /// APNs gave this app its push address.
    func pushToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        do {
            try runtime.setPush(token: hex, environment: Self.apns, activityStart: nil)
        } catch {
            authzLog.notice("authz: push route: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The app delegate: APNs answers here (a SwiftUI app has no other door),
/// and so do the notifications of a followed session's questions (the
/// extension opened their sealed notes, `RequestNotification`).
final class VigilAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(RequestNotification.categories)
        // A Live Activity's Allow/Deny runs here, in the app's process.
        AnswerIntent.answer = { device, request, action, shown in
            await VigilAuthz.shared.answer(device: device, request: request, action: action, shown: shown)
        }
        OpenPaneIntent.open = { pane, keyboard in VigilPhone.shared.openPane(pane, keyboard: keyboard) }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in VigilAuthz.shared.pushToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        authzLog.notice("authz: APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    /// A question answered, withdrawn or expired elsewhere: its
    /// notification goes.
    func application(_ application: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let id = RequestNotification.retraction(info) else { return .noData }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        return .newData
    }

    /// Open, the app is the surface: the notification only joins the list.
    /// (Completion-handler forms completed on main: UIKit asserts otherwise.)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        DispatchQueue.main.async { completion([.list]) }
    }

    /// Allow or Deny answers from here; a tap opens the pane that asks.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping @Sendable () -> Void
    ) {
        let chosen = RequestNotification.read(response)
        Task { @MainActor in
            if let target = chosen.target {
                if let action = chosen.action {
                    await VigilAuthz.shared.answer(target, action: action, shown: chosen.shown)
                } else {
                    await VigilAuthz.shared.open(target)
                }
            }
            completion()
        }
    }
}
