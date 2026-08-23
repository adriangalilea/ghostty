import AppKit

/// The summon's media courtesy (sub-toggle of summon mode): the panel
/// auto-appearing pauses whatever the system is playing; the flow ending
/// resumes it - only if hush paused it AND Adrian has not touched playback
/// since (resume re-checks state, so a manual resume makes ours a no-op
/// and a manual pause is never fought). MediaRemote over dlopen: private,
/// but it answers unentitled on this machine (probed 2026-08-23) and the
/// stack already lives on private seams (ReminderKit precedent). The one
/// forbidden fallback is a blind HID play/pause keypress: without a state
/// query it can START playback, worse than doing nothing - if MediaRemote
/// ever stops answering, hush goes inert with one vlog scream.
@MainActor
enum VigilHush {
    static let key = "vigil.summon.hush"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    private static var wePaused = false

    // MRMediaRemoteGetNowPlayingApplicationIsPlaying(queue, block) +
    // MRMediaRemoteSendCommand(command, userInfo); kMRPlay = 0, kMRPause = 1.
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, AnyObject?) -> Bool

    private static let remote: (isPlaying: IsPlayingFn, send: SendCommandFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
            let playing = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"),
            let send = dlsym(handle, "MRMediaRemoteSendCommand") else {
            VigilSessionManager.shared.vlog("hush: MediaRemote unavailable - hush inert")
            return nil
        }
        return (unsafeBitCast(playing, to: IsPlayingFn.self),
                unsafeBitCast(send, to: SendCommandFn.self))
    }()

    static func pause() {
        guard enabled, let remote else { return }
        remote.isPlaying(DispatchQueue.main) { playing in
            MainActor.assumeIsolated {
                guard playing else { return }
                wePaused = remote.send(1, nil)
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
                _ = remote.send(0, nil)
                VigilSessionManager.shared.vlog("hush: resumed playback")
            }
        }
    }
}
