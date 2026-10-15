#if os(macOS)
import AppKit
import AskKit
import AuthzProtocol
import Foundation
import VigilHarness

/// Vigil's side of authorization, now that asks are Authz.app's (its own
/// daemon, authzd, holds requests, keys and receipts; Authz.app presents
/// them). Vigil keeps three things:
/// - the broker (`vigil-agent`), the one writer of every pane's state and
///   the requester that publishes a blocked pane's question to authzd;
/// - the screen's CONTEXT for that requester: the focused pane and the
///   panes on screen, so a question whose pane is in front of the human is
///   answered at the pane and never floated over it (authzd's rule);
/// - "Go there": a request's `vigil://pane/<id>` link lands on the pane,
///   here or on the other Mac whose directory lists it.
@MainActor
final class VigilHarnessCoordinator {
    static let shared = VigilHarnessCoordinator()
    private init() {}

    private var started = false
    private var starters: [Process] = []
    private var reported: RequesterContext?
    private var renewal: Timer?

    /// Once, at launch: the broker, the context's chokepoints, the link.
    func start() {
        guard !started else { return }
        started = true
        launch("vigil-agent", ["ensure"])
        let center = NotificationCenter.default
        for name in [VigilSessionManager.focusDidChange, VigilSessionManager.stateDidChange,
                     NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { VigilHarnessCoordinator.shared.report() }
            }
        }
        // A context lives 90 s at authzd. Renewed while this app runs, so a
        // closed app's context lapses on its own (nobody else renews it).
        renewal = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { _ in
            MainActor.assumeIsolated { VigilHarnessCoordinator.shared.report(renew: true) }
        }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        report()
    }

    // MARK: context

    /// What is in front of the human here: the focused local pane (only
    /// while this app is active and the focus is not another Mac's pane),
    /// and every local pane shown in a visible window.
    private func screen() -> (focused: String?, visible: [String]) {
        let manager = VigilSessionManager.shared
        let key = NSApp.keyWindow?.windowController as? TerminalController
        let focusedView = key?.focusedSurface
        let focused = NSApp.isActive && focusedView?.vigilHost == nil ? focusedView?.vigilAttachId : nil
        var visible: [String] = []
        for window in NSApp.windows where window.isVisible && window.occlusionState.contains(.visible) {
            guard let controller = window.windowController as? TerminalController else { continue }
            for view in controller.surfaceTree where view.vigilHost == nil && !view.isHiddenOrHasHiddenAncestor {
                if let pane = view.vigilAttachId, manager.paneOnAnyScreen(pane) { visible.append(pane) }
            }
        }
        return (focused, Array(Set(visible)).sorted())
    }

    func report(renew: Bool = false) {
        let (focused, visible) = screen()
        guard renew || reported?.focusedContext != focused || reported?.visibleContexts != visible else { return }
        let context = RequesterContext(
            focusedContext: focused, visibleContexts: visible, expiresAt: Date().timeIntervalSince1970 + 90)
        reported = context
        // The broker's socket is local and quick; never on the main thread.
        DispatchQueue.global(qos: .utility).async {
            do {
                let response = try HarnessWire.call(RPCRequest("context", .from(context)))
                if !response.ok { VigilSessionManager.vlogSync("authz context: broker refused (\(response.value))") }
            } catch {
                VigilSessionManager.vlogSync("authz context: broker unreachable (\(error))")
            }
        }
    }

    // MARK: summon

    /// Whether Authz.app will ask about this pane's blocker here, so the
    /// summon's own `waiting` cue stays silent (one cue per moment). Authz
    /// asks when its switch is on, vigil's requester is not switched off
    /// there, and the pane is not on screen (on screen, it is answered at
    /// the pane and the cue is vigil's). The keys are the suite's shared
    /// vocabulary (AskSettings) and Authz's per-app switch.
    func carries(pane: String) -> Bool {
        guard let authz = UserDefaults(suiteName: "space.authz.app") else { return false }
        let asking = authz.object(forKey: AskSettings.enabledKey) as? Bool ?? true
        // AuthzAsk's AskLane.quietKey: requesters switched off in Authz.
        let quiet = Set(authz.stringArray(forKey: "authz.quietRequesters") ?? [])
        return asking && !quiet.contains(Self.requester) && !VigilSessionManager.shared.paneOnAnyScreen(pane)
    }

    /// The broker's requester name at authzd: its signing identifier.
    static let requester = "dev.vigil.harness.broker"

    // MARK: Go there

    /// `vigil://pane/<id>`: the pane where it lives. A local session owns it
    /// (the registry says which), else a remote Mac's directory lists it.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "vigil", url.host == "pane",
              let pane = url.pathComponents.dropFirst().first, !pane.isEmpty
        else {
            VigilSessionManager.vlogSync("handoff: unreadable link")
            return
        }
        let manager = VigilSessionManager.shared
        NSApp.activate()
        if let name = manager.owner(ofPane: pane) {
            let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.lastMain
            manager.activatePane(name: name, paneId: pane, in: controller)
            manager.vlog("handoff: link -> local \(name)/\(pane)")
            return
        }
        for host in VigilRemote.shared.hosts where host.directory?.panes[pane] != nil {
            manager.vlog("handoff: link -> \(host.device)/\(pane)")
            manager.openRemotePane(device: host.device, pane: pane)
            return
        }
        manager.vlog("handoff: link to \(pane), which no session here or on another Mac lists")
    }

    // MARK: broker

    /// Installed binaries only. No development build is launched implicitly.
    private func launch(_ binary: String, _ arguments: [String]) {
        if starters.contains(where: { $0.executableURL?.lastPathComponent == binary && $0.isRunning }) { return }
        let process = Process()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/" + binary)
        process.arguments = arguments
        process.environment = AgentEnvironment.scrub(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { process in
            Task { @MainActor in
                VigilHarnessCoordinator.shared.starters.removeAll { $0 === process }
                VigilSessionManager.shared.vlog("broker: \(binary) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
            }
        }
        do {
            try process.run()
            starters.append(process)
        } catch {
            VigilSessionManager.shared.vlog("broker: installed \(binary) unavailable (\(error))")
        }
    }
}
#endif
