import AppKit

/// The summon's media courtesy (sub-toggle of summon mode): the panel
/// auto-appearing pauses whatever the system is playing; the flow ending
/// resumes it — only if hush paused it AND playback was untouched since
/// (resume re-checks state, so a manual resume makes ours a no-op).
///
/// Mechanism: the `media-control` CLI (brew, github.com/ungive/media-control),
/// which rides the Apple-signed-host adapter technique. Direct MediaRemote
/// over dlopen was built first and is DELETED, not kept as fallback: on
/// this macOS the gate answers unentitled queries with "nothing playing"
/// even mid-video (proven 2026-08-23 — the probe with silence was falsely
/// reassuring; only a probe WITH media playing tells the truth). The one
/// forbidden fallback remains a blind HID play/pause keypress: without a
/// state query it can START playback, worse than doing nothing. Missing
/// binary → hush inert with one vlog scream.
///
/// Known corner accepted with the CLI (snapshot, not a stream): a manual
/// resume-then-pause DURING one flow reads as "not playing" at drain and
/// gets resumed against intent; the old streaming observation died with
/// the direct framework path. Revisit with `media-control stream` if it
/// ever bites in practice.
///
/// FIXME(official-api): the CLI is a MEANTIME dependency, not the end
/// state. Apple shipped a new `NowPlaying.framework` (Beta this SDK
/// cycle — /documentation/nowplaying: MediaSession, MediaPlaybackSnapshot,
/// RemoteMediaSession; checked 2026-08-23, not yet in the installed SDK).
/// When the SDK lands, evaluate whether it grants third parties
/// SYSTEM-WIDE observe + pause/play (vs the MPNowPlayingInfoCenter
/// own-app-publishing limitation). If it does: delete this file's CLI
/// plumbing, adopt the framework (a real stream also restores the
/// resume-then-pause contract), and drop media-control from the Brewfile.
@MainActor
enum VigilHush {
    static let key = "vigil.summon.hush"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    private static var wePaused = false
    private static var screamed = false

    /// The app launches env-scrubbed (vigil-dev's `env -i`), so PATH never
    /// finds brew; the binary is addressed absolutely.
    private static let cli: String? = [
        "/opt/homebrew/bin/media-control",
        "/usr/local/bin/media-control",
    ].first { FileManager.default.fileExists(atPath: $0) }

    private static func run(_ args: [String], done: ((String) -> Void)? = nil) {
        guard let cli else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let done else { return }
            DispatchQueue.main.async { done(String(decoding: data, as: UTF8.self)) }
        }
        do { try proc.run() } catch {
            VigilSessionManager.shared.vlog("hush: media-control failed to run - \(error)")
        }
    }

    private static func isPlaying(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["playing"] as? Bool ?? false
    }

    static func pause() {
        // Every decision is auditable: "hush did nothing" must name WHY
        // from the log alone (disabled / no binary / nothing playing).
        guard enabled else { VigilSessionManager.shared.vlog("hush: disabled - skip"); return }
        guard cli != nil else {
            if !screamed {
                screamed = true
                VigilSessionManager.shared.vlog("hush: media-control not installed (brew install media-control) - hush inert")
            }
            return
        }
        run(["get"]) { json in
            MainActor.assumeIsolated {
                guard isPlaying(json) else {
                    VigilSessionManager.shared.vlog("hush: nothing playing - skip")
                    return
                }
                wePaused = true
                run(["pause"])
                VigilSessionManager.shared.vlog("hush: paused playback")
            }
        }
    }

    static func resume() {
        guard wePaused, cli != nil else { return }
        wePaused = false
        run(["get"]) { json in
            MainActor.assumeIsolated {
                guard !isPlaying(json) else {
                    VigilSessionManager.shared.vlog("hush: already playing - claim moot")
                    return
                }
                run(["play"])
                VigilSessionManager.shared.vlog("hush: resumed playback")
            }
        }
    }
}
