import ActivityKit
import Foundation
import VigilActivity
import VigilLink
import VigilWire

/// A followed session's Live Activity: started here when the session is
/// followed (its name, face and Mac are the phone's own attributes), kept
/// current by the session's Mac (the hub pushes `session-update` to the
/// activity's token, which this app hands it with a `follow` call, again
/// whenever iOS rotates it), ended here when it is no longer followed.
@MainActor
enum VigilFollow {
    /// Starts (or finds) the activity of a followed session.
    static func start(_ session: VigilPhone.Node, mac: VigilPhone.Host) {
        if activity(of: session.id) != nil { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return VigilPhone.shared.log("follow: Live Activities are off for vigil (Settings > vigil)")
        }
        let name = String(session.id.split(separator: "/", maxSplits: 1).last ?? "")
        let attributes = SessionActivity(mac: mac.name, device: mac.id, session: name, label: session.title, emoji: session.emoji)
        let content = ActivityContent(state: SessionActivity.ContentState(state: .idle, since: Date().timeIntervalSince1970), staleDate: nil)
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
            VigilPhone.shared.log("follow: \(session.title) on the Lock Screen (\(activity.id.prefix(8)))")
            observe(activity)
        } catch {
            VigilPhone.shared.log("follow: \(session.title): no Live Activity (\(error))")
        }
    }

    /// Ends a session's activity and tells its Mac to stop.
    static func end(_ sessionID: String) {
        guard let activity = activity(of: sessionID) else { return }
        Task {
            if let token = tokens[activity.id] { await tell(activity.attributes, token: token, following: false) }
            await activity.end(nil, dismissalPolicy: .immediate)
            VigilPhone.shared.log("follow: \(activity.attributes.label) left the Lock Screen")
        }
    }

    /// At launch: every activity still running is adopted again (its token
    /// re-sent: the Mac may have restarted, iOS may have rotated it), and
    /// one whose session is no longer followed ends.
    static func adopt(followed: Set<String>) {
        for activity in Activity<SessionActivity>.activities {
            let id = "\(activity.attributes.device)/\(activity.attributes.session)"
            if followed.contains(id) { observe(activity) } else { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    private static var observed = Set<String>()
    private static var tokens: [String: String] = [:]

    private static func activity(of sessionID: String) -> Activity<SessionActivity>? {
        Activity<SessionActivity>.activities.first { "\($0.attributes.device)/\($0.attributes.session)" == sessionID }
    }

    private static func observe(_ activity: Activity<SessionActivity>) {
        guard observed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                tokens[activity.id] = token
                await tell(activity.attributes, token: token, following: true)
            }
        }
    }

    /// Tells the session's Mac where its updates go (or that they stop).
    private static func tell(_ attributes: SessionActivity, token: String, following: Bool) async {
        let follow = Follow(session: attributes.session, token: token, environment: VigilAuthz.apns.rawValue)
        do {
            guard let node = VigilAuthz.shared.runtime.node else { throw WireError.refused("vigil is not connected to tether yet") }
            _ = try await VigilLink.call(node, device: attributes.device, following ? .follow(follow) : .unfollow(follow))
            VigilPhone.shared.log("follow: \(attributes.mac) \(following ? "updates" : "no longer updates") \(attributes.label)")
        } catch {
            VigilPhone.shared.log("follow: \(attributes.mac) not told about \(attributes.label): \(VigilLink.reason(error))")
        }
    }
}
