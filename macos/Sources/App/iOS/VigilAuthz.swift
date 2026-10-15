import AuthzEndpoint
import AuthzProtocol
import OSLog
import SwiftUI
import UIKit
import UserNotifications

private let authzLog = Logger(subsystem: "com.adriangalilea.vigil", category: "authz")

/// vigil for iPhone as an authz endpoint ("vigil on <phone>"), beside Authz
/// for iPhone on the same device. It presents only what it claims: the
/// panes of the sessions you follow, whose questions it shows in their own
/// session Live Activity and answers through authz. Everything else stays
/// Authz's (authz.space README "Context claims: one presenter per device").
@MainActor final class VigilAuthz: ObservableObject {
    static let shared = VigilAuthz()

    let runtime = EndpointRuntime(
        .init(
            tetherApp: "vigil", keyGroup: "G387QW47LV.com.adriangalilea.vigil.keys",
            sealGroup: "G387QW47LV.com.adriangalilea.vigil.notify",
            name: "vigil on \(UIDevice.current.name)", relayApp: "vigil", presents: .claimed))

    /// Starts (or, back on screen, resumes) the app's tether node: it joins
    /// the homes, and the phone model reaches the Macs' sessions through
    /// it. Asks APNs for this app's push address: a claim counts only
    /// while its holder can be reached.
    func start() {
        Task {
            await runtime.start()
            authzLog.notice("authz: \(self.runtime.status, privacy: .public)")
            if let node = runtime.node {
                VigilPhone.shared.attach(node: node)
                VigilPhone.shared.wake()
            }
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs gave this app its push address (a development build: sandbox).
    func pushToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        do {
            try runtime.setPush(token: hex, environment: .sandbox, activityToken: nil)
        } catch {
            authzLog.notice("authz: push route: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The app delegate: APNs answers here (a SwiftUI app has no other door).
final class VigilAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in VigilAuthz.shared.pushToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        authzLog.notice("authz: APNs registration failed: \(String(describing: error), privacy: .public)")
    }
}
