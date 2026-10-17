import AppKit
import Darwin
import Foundation
import Log

/// The main thread's own witness: two facts a log cannot otherwise state
/// when a main-thread stall inside an audio-engine start ends in an
/// uncaught NSException and nothing is written between the last line and
/// the relaunch:
///
/// 1. WHERE main is stuck: a stall past `stallFloor` logs `!! main stalled`
///    with a BACKTRACE of the main thread taken from the watchdog thread
///    (suspend, read the register state, walk the frame-pointer chain,
///    resume, `dladdr` + swift demangle per frame - microseconds of
///    suspension, no subprocess), WHILE still stalled, so the line exists
///    even if the stall ends in death; a second backtrace at `stallDeep`
///    tells one blocking call from a runaway loop; recovery logs the
///    measured length. `mark(_:_:)` adds scoped context ("ask gate:
///    prewarm") to the line; the backtrace is the fact, the mark a label,
///    scoped, never sticky (a label that outlives its call attributes a
///    stall to the wrong code).
/// 2. The uncaught-exception handler: AVFoundation, AppKit and friends
///    assert by NSException, which Swift cannot catch and breakpad does
///    not record (no signal, no minidump, no .ips). The last act of a
///    dying process is one `watchdog` event with name, reason and the
///    stack, written synchronously from the handler's thread.
///
/// `vigil.watchdog.drill` (defaults, bool): 5s after arming, main sleeps
/// 1.2s inside `mark("watchdog drill")` - the proof that the backtrace
/// names this file and the sleep, run once per build change.
enum VigilWatchdog {
    static let stallFloor: TimeInterval = 0.5
    static let stallDeep: TimeInterval = 3

    private static let lock = NSLock()
    nonisolated(unsafe) private static var crumb = "idle"
    nonisolated(unsafe) private static var armed = false
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0
    nonisolated(unsafe) private static var mainStackLow: UInt = 0
    nonisolated(unsafe) private static var mainStackHigh: UInt = 0

    /// Run `body` under a label the stall line carries. Scoped: the label
    /// leaves with the call.
    static func mark<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
        let previous = lock.withLock { let p = crumb; crumb = what; return p }
        defer { lock.withLock { crumb = previous } }
        return try body()
    }

    static func arm() {
        assert(Thread.isMainThread)
        assert(!armed, "watchdog armed twice")
        armed = true
        mainThread = pthread_mach_thread_np(pthread_self())
        let high = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        mainStackHigh = high
        mainStackLow = high - UInt(pthread_get_stacksize_np(pthread_self()))
        // A C function pointer: fully qualified statics, no implicit self.
        NSSetUncaughtExceptionHandler { exception in
            let crumb = VigilWatchdog.lock.withLock { VigilWatchdog.crumb }
            watchdogLog.error("uncaught exception", [
                "name": exception.name.rawValue, "reason": exception.reason, "mark": crumb,
                "stack": Array(exception.callStackSymbols.prefix(24)),
            ])
            flushLog()
        }
        let thread = Thread {
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                var reported = false
                var deepened = false
                while answered.wait(timeout: .now() + .milliseconds(Int(stallFloor * 1000))) == .timedOut {
                    let stalled = Duration.seconds(Date().timeIntervalSince(sent))
                    if !reported {
                        reported = true
                        watchdogLog.error("main stalled", [
                            "stalled": stalled, "mark": lock.withLock { crumb }, "stack": mainBacktrace(),
                        ])
                    } else if !deepened, stalled >= .seconds(stallDeep) {
                        deepened = true
                        watchdogLog.error("main still stalled", ["stalled": stalled, "stack": mainBacktrace()])
                    }
                }
                if reported {
                    watchdogLog.warn("main recovered", ["stalled": Duration.seconds(Date().timeIntervalSince(sent))])
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        thread.name = "vigil.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        if UserDefaults.standard.bool(forKey: "vigil.watchdog.drill") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                mark("watchdog drill") { _ = usleep(1_200_000) }
            }
        }
    }

    /// The main thread's frames, innermost first, symbolicated. Suspends
    /// main only for the register read and the walk (bounded to its own
    /// stack, 48 frames); a walk that leaves the stack stops.
    private static func mainBacktrace() -> [String] {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return ["(thread_suspend failed)"] }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &state) { ptr in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        var addresses: [UInt] = []
        if got == KERN_SUCCESS {
            addresses.append(UInt(state.__pc))
            addresses.append(UInt(state.__lr))
            var fp = UInt(state.__fp)
            while addresses.count < 48, fp >= mainStackLow, fp + 16 <= mainStackHigh, fp & 0xF == 0 {
                let frame = UnsafePointer<UInt>(bitPattern: fp)!
                let ret = frame[1]
                let next = frame[0]
                guard ret != 0, next > fp else { break }
                addresses.append(ret)
                fp = next
            }
        }
        thread_resume(mainThread)
        guard got == KERN_SUCCESS else { return ["(thread_get_state failed: \(got))"] }
        return addresses.enumerated().map { index, address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
                return String(format: "%2d  0x%016lx", index, address)
            }
            let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
            let symbol = info.dli_sname.map { demangle(String(cString: $0)) } ?? "?"
            let offset = address - UInt(bitPattern: info.dli_saddr)
            return String(format: "%2d  %@  %@ + %lu", index, image, symbol, offset)
        }
    }

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?
    private static let swiftDemangle: Demangle? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: Demangle.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle else { return name }
        guard let out = swiftDemangle(name, name.utf8.count, nil, nil, 0) else { return name }
        defer { free(out) }
        return String(cString: out)
    }
}
