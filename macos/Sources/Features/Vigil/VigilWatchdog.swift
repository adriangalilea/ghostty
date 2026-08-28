import AppKit
import Foundation

/// The main thread's own witness. Two facts the log could not state on
/// 2026-08-28, when a 6s main-thread stall inside an audio-engine start
/// ended in an uncaught NSException and vigil.log showed NOTHING between
/// the hook line and the relaunch:
///
/// 1. `breadcrumb`: what main was doing. Hot paths mark before a call that
///    can block ("ask gate: prewarm"); the watchdog names it when main
///    stalls, so a stall is attributed, never guessed.
/// 2. The uncaught-exception handler: AVFoundation, AppKit and friends
///    assert by NSException, which Swift cannot catch and breakpad does
///    not record (no signal, no minidump, no .ips). The last act of a
///    dying process is one vigil.log line with name, reason and the stack.
///
/// The stall detector pings main every 250ms from a utility thread; a
/// ping unanswered past `stallFloor` logs `!! main stalled` with the
/// breadcrumb WHILE still stalled (the line must exist even if the stall
/// ends in death), and the recovery logs the measured length.
enum VigilWatchdog {
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    static let stallFloor: TimeInterval = 0.5

    private static let lock = NSLock()
    nonisolated(unsafe) private static var crumb = "idle"
    nonisolated(unsafe) private static var armed = false

    /// Name the blocking call main is about to make. Cheap; call freely.
    static func breadcrumb(_ what: String) {
        lock.withLock { crumb = what }
    }

    static func arm() {
        assert(Thread.isMainThread)
        assert(!armed, "watchdog armed twice")
        armed = true
        // A C function pointer: fully qualified statics, no implicit self.
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n    ")
            let crumb = VigilWatchdog.lock.withLock { VigilWatchdog.crumb }
            VigilWatchdog.trace?(
                "!! UNCAUGHT NSException \(exception.name.rawValue): \(exception.reason ?? "no reason")"
                    + " (main was: \(crumb))\n    \(stack)")
        }
        let thread = Thread {
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                var reported = false
                while answered.wait(timeout: .now() + .milliseconds(Int(stallFloor * 1000))) == .timedOut {
                    if !reported {
                        reported = true
                        trace?("!! main stalled >\(Int(stallFloor * 1000))ms during '\(lock.withLock { crumb })'")
                    }
                }
                if reported {
                    trace?(String(format: "main recovered after %.0fms", Date().timeIntervalSince(sent) * 1000))
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        thread.name = "vigil.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
