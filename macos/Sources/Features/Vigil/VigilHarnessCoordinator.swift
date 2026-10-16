#if os(macOS)
import AppKit
import AskKit
import AuthzProtocol
import Foundation
import VigilHarness
import VigilWire

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

    /// What is in front of the human here, by the Mac each pane lives on
    /// ("" = this Mac): the focused pane (only while this app is active)
    /// and every pane shown in a visible window. A pane of another Mac on
    /// screen here is in front of you for THAT Mac's requests too.
    private func screen() -> [String: Open.Screen] {
        let manager = VigilSessionManager.shared
        let key = NSApp.keyWindow?.windowController as? TerminalController
        let focusedView = NSApp.isActive ? key?.focusedSurface : nil
        let expires = Date().timeIntervalSince1970 + 90
        var homes: [String: Open.Screen] = ["": Open.Screen(focused: nil, visible: [], expiresAt: expires)]
        if let view = focusedView, let pane = view.vigilAttachId {
            homes[view.vigilHost ?? "", default: Open.Screen(focused: nil, visible: [], expiresAt: expires)].focused = pane
        }
        for window in NSApp.windows where window.isVisible && window.occlusionState.contains(.visible) {
            guard let controller = window.windowController as? TerminalController else { continue }
            for view in controller.surfaceTree where !view.isHiddenOrHasHiddenAncestor {
                guard let pane = view.vigilAttachId else { continue }
                let home = view.vigilHost ?? ""
                if home.isEmpty, !manager.paneOnAnyScreen(pane) { continue }
                homes[home, default: Open.Screen(focused: nil, visible: [], expiresAt: expires)].visible.append(pane)
            }
        }
        return homes.mapValues { Open.Screen(focused: $0.focused, visible: Array(Set($0.visible)).sorted(), expiresAt: $0.expiresAt) }
    }

    /// What each other Mac was last told (cleared there with an empty view
    /// the moment its panes leave the screen here).
    private var reportedRemote: [String: Open.Screen] = [:]

    func report(renew: Bool = false) {
        var homes = screen()
        let mine = homes.removeValue(forKey: "") ?? Open.Screen(focused: nil, visible: [], expiresAt: 0)
        if renew || reported?.focusedContext != mine.focused || reported?.visibleContexts != mine.visible {
            let context = RequesterContext(focusedContext: mine.focused, visibleContexts: mine.visible, expiresAt: mine.expiresAt)
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
        for home in Set(homes.keys).union(reportedRemote.keys) {
            let now = homes[home] ?? Open.Screen(focused: nil, visible: [], expiresAt: Date().timeIntervalSince1970 + 90)
            let before = reportedRemote[home]
            guard renew || before?.focused != now.focused || before?.visible != now.visible else { continue }
            reportedRemote[home] = now.visible.isEmpty && now.focused == nil ? nil : now
            // Through this Mac's hub to that Mac's; a blocking call, off main.
            DispatchQueue.global(qos: .utility).async {
                do { _ = try Local.Client(socket: VigilPaths.hub).call(device: home, .context(now)) } catch {
                    VigilSessionManager.vlogSync("authz context: \(home.prefix(10)) not told what is on screen here (\(error))")
                }
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
