import ActivityKit
import Foundation
import VigilActivity
import VigilLink
import VigilWire

/// A followed session, tab or pane as a Live Activity: started here with
/// the state the phone's directory already shows, kept current here while
/// vigil is open and by its Mac otherwise (the hub pushes `session-update`
/// to the activity's token, which this app hands it with a `follow` call,
/// again whenever iOS rotates it), ended here when it is no longer
/// followed. Both writers read the same directory with
/// `SessionState.lead`, so they say the same thing.
@MainActor
enum VigilFollow {
    /// Starts (or finds) the activity of a follow.
    static func start(_ attributes: SessionActivity, state: SessionState, since: Double) {
        if activity(of: attributes.key) != nil { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return VigilPhone.shared.log("follow: Live Activities are off for vigil (Settings > vigil)")
        }
        let content = ActivityContent(state: SessionActivity.ContentState(state: state, since: since), staleDate: nil)
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
            VigilPhone.shared.log("follow: \(name(attributes)) on the Lock Screen, \(state.rawValue) (\(activity.id.prefix(8)))")
            observe(activity)
        } catch {
            VigilPhone.shared.log("follow: \(name(attributes)): no Live Activity (\(error))")
        }
    }

    /// The directory moved: the activity says so now (vigil is open).
    static func update(_ key: String, state: SessionState, since: Double) {
        guard let activity = activity(of: key) else { return }
        let content = SessionActivity.ContentState(state: state, since: since)
        guard activity.content.state != content else { return }
        Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
    }

    /// Ends a follow's activity and tells its Mac to stop.
    static func end(_ key: String) {
        guard let activity = activity(of: key) else { return }
        Task {
            if let token = tokens[activity.id] { await tell(activity.attributes, token: token, following: false) }
            await activity.end(nil, dismissalPolicy: .immediate)
            VigilPhone.shared.log("follow: \(name(activity.attributes)) left the Lock Screen")
        }
    }

    /// At launch: every activity still running is adopted again (its token
    /// re-sent: the Mac may have restarted, iOS may have rotated it), and
    /// one no longer followed ends.
    static func adopt(followed: Set<String>) {
        for activity in Activity<SessionActivity>.activities {
            if followed.contains(activity.attributes.key) { observe(activity) } else { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    private static var observed = Set<String>()
    private static var tokens: [String: String] = [:]

    private static func activity(of key: String) -> Activity<SessionActivity>? {
        Activity<SessionActivity>.activities.first { $0.attributes.key == key }
    }

    private static func name(_ a: SessionActivity) -> String {
        [a.label, a.detail].compactMap { $0 }.joined(separator: " · ")
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

    /// Tells the Mac where its updates go (or that they stop).
    private static func tell(_ attributes: SessionActivity, token: String, following: Bool) async {
        let follow = Follow(scope: attributes.scope, token: token, environment: VigilAuthz.apns.rawValue)
        do {
            guard let node = VigilAuthz.shared.runtime.node else { throw WireError.refused("vigil is not connected to tether yet") }
            _ = try await VigilLink.call(node, device: attributes.device, following ? .follow(follow) : .unfollow(follow))
            VigilPhone.shared.log("follow: \(attributes.mac) \(following ? "updates" : "no longer updates") \(name(attributes))")
        } catch {
            VigilPhone.shared.log("follow: \(attributes.mac) not told about \(name(attributes)): \(VigilLink.reason(error))")
        }
    }
}
