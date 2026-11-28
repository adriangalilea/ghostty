#if os(macOS)
import AppKit
import AskKit
import Foundation
import VigilHarness
import VigilWire

/// What the Vigil app does for the broker and for Authz:
/// - starts the broker (`vigil-agent ensure`), the one writer of every
///   pane's state and the one service the host asks the person through;
/// - reports the screen: the focused pane and the panes on screen here, to
///   this Mac's broker and, for another Mac's panes, to that Mac's hub
///   (`Asks.Showing`), which the broker keeps for Authz's presence once
///   Authz takes it;
/// - "Go there": a request's `vigil://pane/<id>` link lands on the pane,
///   here or on the other Mac whose directory lists it.
@MainActor
final class VigilHarnessCoordinator {
    static let shared = VigilHarnessCoordinator()
    private init() {}

    private var started = false
    private var starters: [Process] = []
    private var reported: Asks.Showing?
    private var renewal: Timer?

    /// Once, at launch: the broker, the context's chokepoints, the link.
    func start() {
        guard !started else { return }
        started = true
        launch("vigil-agent", ["ensure"])
        // Read a turn later: a window posts these as it starts to change (a
        // close, a resign before the cover lands); the turn after is the fact.
        VigilWorkspaces.onPresenceInputs { VigilHarnessCoordinator.shared.scheduleReport() }
        // A report lapses 90 s after it is made. Renewed while this app runs,
        // so a closed app's report lapses on its own (nobody else renews it).
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
        let manager = VigilWorkspaces.shared
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

    private var reportPending = false

    /// One report on the next turn for any burst of screen events.
    func scheduleReport() {
        guard !reportPending else { return }
        reportPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                VigilHarnessCoordinator.shared.reportPending = false
                VigilHarnessCoordinator.shared.report()
            }
        }
    }

    func report(renew: Bool = false) {
        var homes = screen()
        let mine = homes.removeValue(forKey: "") ?? Open.Screen(focused: nil, visible: [], expiresAt: 0)
        if renew || reported?.focused != mine.focused || reported?.visible != mine.visible {
            let context = Asks.Showing(focused: mine.focused, visible: mine.visible, expires: mine.expiresAt)
            reported = context
            // The broker's socket is local and quick; never on the main thread.
            DispatchQueue.global(qos: .utility).async {
                do {
                    let response = try HarnessWire.call(RPCRequest("context", .from(context)))
                    if !response.ok { authzLog.warn("context refused by the broker", ["reply": "\(response.value)"]) }
                } catch {
                    authzLog.error("context not sent: broker unreachable", ["err": error])
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
                    authzLog.warn("context not sent to a home", ["home": String(home.prefix(10)), "err": error])
                }
            }
        }
    }

    // MARK: summon

    /// Whether Authz carries this pane's blocker, so the summon's own
    /// `waiting` cue stays silent (one cue per moment): Authz is ready as
    /// the broker last read its health (`AuthzStanding`; away, or vigil
    /// switched off in Authz › Apps, the Vigil app holds the ask and the cue
    /// is vigil's), and the pane is not on screen (on screen, it is answered
    /// at the pane). Authz is not yet told which panes are on screen, so it
    /// may card one in front of the person too.
    func carries(pane: String) -> Bool {
        guard case .ready? = AuthzStanding.read() else { return false }
        return !VigilWorkspaces.shared.paneOnAnyScreen(pane)
    }

    // MARK: Go there

    /// `vigil://pane/<id>`: the pane where it lives. A local session owns it
    /// (the registry says which), else a remote Mac's directory lists it.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "vigil"
        else {
            handoffLog.warn("unreadable link")
            return
        }
        let ref = VigilRef(url: url)
        guard ref?.kind == .pane || (url.host == "pane" && url.pathComponents.count == 2) else {
            return handoffLog.warn("link names no pane")
        }
        let pane = url.lastPathComponent
        guard Open.validPane(pane) else { return }
        if let ref {
            Task {
                let here = await Task.detached { try? Local.Client(socket: VigilPaths.hub).me() }.value
                guard let here else { return handoffLog.warn("local device identity unavailable") }
                openLinkedPane(pane, local: ref.home == here, home: ref.home)
            }
        } else {
            openLinkedPane(pane, local: true, home: nil)
        }
    }

    private func openLinkedPane(_ pane: String, local: Bool, home: String?) {
        let manager = VigilWorkspaces.shared
        let name = local ? manager.owner(ofPane: pane) : nil
        let hosts = VigilRemote.shared.hosts.filter {
            (home == nil || home == $0.device) && $0.directory?.place(of: pane) != nil
        }
        guard hosts.count + (name == nil ? 0 : 1) == 1 else {
            return handoffLog.warn("pane link has no unique destination", ["pane": pane])
        }
        NSApp.activate()
        if let name {
            let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.lastMain
            manager.activatePane(name: name, paneId: pane, in: controller)
            handoffLog.info("link to a local pane", ["workspace": name, "pane": pane])
            return
        }
        if let host = hosts.first {
            handoffLog.info("link to a remote pane", ["host": host.device, "pane": pane])
            manager.openRemotePane(device: host.device, pane: pane)
            return
        }
        handoffLog.warn("link to a pane no Mac lists", ["pane": pane])
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
                daemonLog.info("agent process exited", ["binary": binary, "arguments": arguments, "status": process.terminationStatus])
            }
        }
        do {
            try process.run()
            starters.append(process)
        } catch {
            daemonLog.error("agent binary unavailable", ["binary": binary, "err": error])
        }
    }
}
#endif
