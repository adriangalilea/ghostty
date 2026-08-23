import AppKit

/// The summon's media courtesy (sub-toggle of summon mode): the panel
/// auto-appearing pauses whatever the system is playing; the flow ending
/// resumes it — only if hush paused it AND Adrian has not touched
/// playback since. The contract is enforced by OBSERVATION, not just an
/// end-check: MediaRemote's isPlaying-did-change notification fires on
/// every transition, and a flip to PLAYING while hush holds the pause
/// means Adrian resumed himself — the claim clears, and his later pause
/// is his to keep (resume() additionally re-checks state as a belt).
/// MediaRemote over dlopen: private, but it answers unentitled on this
/// machine (probed 2026-08-23) and the stack already lives on private
/// seams (ReminderKit precedent). The one forbidden fallback is a blind
/// HID play/pause keypress: without a state query it can START playback,
/// worse than doing nothing — if MediaRemote ever stops answering, hush
/// goes inert with one vlog scream.
@MainActor
enum VigilHush {
    static let key = "vigil.summon.hush"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    private static var wePaused = false

    // MRMediaRemoteGetNowPlayingApplicationIsPlaying(queue, block) +
    // MRMediaRemoteSendCommand(command, userInfo); kMRPlay = 0, kMRPause = 1.
    // MRMediaRemoteRegisterForNowPlayingNotifications(queue) arms the
    // kMRMediaRemote… NSNotifications.
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, AnyObject?) -> Bool
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    private static let remote: (isPlaying: IsPlayingFn, send: SendCommandFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
            let playing = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"),
            let send = dlsym(handle, "MRMediaRemoteSendCommand") else {
            VigilSessionManager.shared.vlog("hush: MediaRemote unavailable - hush inert")
            return nil
        }
        // Playback-state observation: registration + the notification are
        // best-effort (the query/command pair above is the load-bearing
        // half); a macOS that stops delivering them degrades hush to the
        // end-check alone, never to silence or a blind toggle.
        if let register = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            unsafeBitCast(register, to: RegisterFn.self)(DispatchQueue.main)
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(
                    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
                object: nil, queue: .main
            ) { notification in
                let playing = notification.userInfo?[
                    "kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey"] as? Bool
                MainActor.assumeIsolated {
                    guard wePaused, playing == true else { return }
                    // Adrian resumed while hush held the pause: the claim
                    // is his now, hush never touches playback again this
                    // flow (his subsequent pause included).
                    wePaused = false
                    VigilSessionManager.shared.vlog("hush: playback resumed externally - claim released")
                }
            }
        }
        return (unsafeBitCast(playing, to: IsPlayingFn.self),
                unsafeBitCast(send, to: SendCommandFn.self))
    }()

    static func pause() {
        guard enabled, let remote else { return }
        remote.isPlaying(DispatchQueue.main) { playing in
            MainActor.assumeIsolated {
                guard playing else { return }
                wePaused = remote.send(1, nil) // kMRPause
                if wePaused { VigilSessionManager.shared.vlog("hush: paused playback") }
            }
        }
    }

    static func resume() {
        guard wePaused, let remote else { return }
        wePaused = false
        remote.isPlaying(DispatchQueue.main) { playing in
            MainActor.assumeIsolated {
                guard !playing else { return }
                _ = remote.send(0, nil) // kMRPlay
                VigilSessionManager.shared.vlog("hush: resumed playback")
            }
        }
    }
}
