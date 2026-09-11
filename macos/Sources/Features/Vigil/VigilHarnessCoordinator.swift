#if os(macOS)
import AppKit
import AskKit
import AuthzUI
import AuthzClient
import AuthzProtocol
import SwiftUI
import VigilHarness

/// Vigil supplies presence and provider handoff. authz.space owns requests,
/// device pickup and receipts; swift-senses owns only this device's input race.
@MainActor
final class VigilHarnessCoordinator: ObservableObject {
    static let shared = VigilHarnessCoordinator()
    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VIGIL_HARNESS_ENABLED"] == "1" ||
            FileManager.default.fileExists(atPath: HarnessPaths.root.appendingPathComponent("enabled").path)
    }
    private var inbox: InboxModel?
    private var panel: NSPanel?
    private var enrollmentPanel: NSPanel?
    private let panelDelegate = AuthorizationPanelDelegate()
    private var current: RequestSnapshot?
    private var preparing: Task<Void, Never>?
    private var preferredPane: String?
    private var visible: [String] = []
    private var nextStart = Date.distantPast
    private var starters: [Process] = []
    private var hushOwner: String?
    private var inputGeneration = 0
    private var deferredForDictation = false
    private var nextServiceCheck = Date.distantPast

    func pump(preferredPane: String?) {
        guard isEnabled else { stop(); return }
        if inbox == nil { connect() }
        let panes = inbox?.requests.map { $0.request.context }.filter { VigilSessionManager.shared.paneOnAnyScreen($0) } ?? []
        let focused = NSApp.isActive ? preferredPane : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if self.preferredPane != focused || panes != visible {
            self.preferredPane = focused; visible = panes
            Task { await inbox?.presence(focusedContext: focused, visibleContexts: panes) }
        }
        if deferredForDictation, !VigilVoice.isActive {
            deferredForDictation = false
            clear(releaseHush: false)
        }
        if let selected = inbox?.selected, current?.handle != selected.handle { present(selected) }
    }
    private func connect() {
        guard Date() >= nextStart else { return }
        nextStart = Date().addingTimeInterval(10)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/authz-space")
        do {
            let configuration = try LocalAuthority.open(Data(contentsOf: root.appendingPathComponent("configuration.json")), as: Configuration.self, key: LocalAuthority.load())
            let key = try DeviceIdentity.key()
            let id = Canonical.digest(key.publicKey.rawRepresentation)
            guard configuration.endpoints.contains(where: { $0.id == id && $0.enabled }) else { return }
            let transport = EndpointTransport(endpointID: id, key: key,
                underlying: SocketTransport(path: root.appendingPathComponent("service.sock").path, verifyServer: PlatformTrust.verifyService))
            let model = InboxModel(transport: transport)
            model.onPresentation = { [weak self] request in
                if let request { self?.present(request) } else { self?.clear() }
            }
            model.onHandoff = { pane in
                if let view = VigilSessionManager.shared.liveView(attachId: pane) { view.window?.makeKeyAndOrderFront(nil); view.window?.makeFirstResponder(view) }
            }
            model.onHush = { held in if held { Hush.claim("authz-endpoint") } else { Hush.release("authz-endpoint") } }
            model.onDictate = { [weak self] snapshot, finished in self?.dictate(snapshot, finished: finished) }
            model.onConnectionFailure = { [weak self] in self?.startServices() }
            inbox = model; model.start(focusedContext: preferredPane)
            startServices()
            VigilSessionManager.shared.vlog("authz endpoint: connected; addressed event stream enabled")
        } catch { VigilSessionManager.shared.vlog("authz endpoint: enrollment unavailable; native attention remains active") }
    }
    private func startServices() {
        guard isEnabled, Date() >= nextServiceCheck else { return }
        nextServiceCheck = Date().addingTimeInterval(10)
        Task { [weak self] in
            guard let self else { return }
            let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/authz-space/service.sock").path
            let healthy = (try? await SocketTransport(path: socket, verifyServer: PlatformTrust.verifyService).call(RPC("health")))?.ok == true
            guard self.isEnabled else { return }
            self.launchServices(startAuthorization: !healthy)
        }
    }
    private func launchServices(startAuthorization: Bool) {
        // Installed binaries only. No development build is launched implicitly.
        for (binary, arguments) in [("authz", ["serve"]), ("vigil-agent", ["ensure"])] {
            if binary == "authz", !startAuthorization { continue }
            if starters.contains(where: { $0.executableURL?.lastPathComponent == binary && $0.isRunning }) { continue }
            let process = Process()
            process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/" + binary)
            process.arguments = arguments; process.environment = AgentEnvironment.scrub(ProcessInfo.processInfo.environment)
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self else { return }
                    self.starters.removeAll { $0 === process }
                    VigilSessionManager.shared.vlog("authz service: \(binary) exited \(process.terminationStatus)")
                    if binary == "authz", process.terminationStatus != 0 {
                        self.stop(); self.nextStart = Date().addingTimeInterval(10)
                    }
                }
            }
            do { try process.run(); starters.append(process) } catch { VigilSessionManager.shared.vlog("authz service: installed \(binary) unavailable") }
        }
    }
    private func present(_ snapshot: RequestSnapshot) {
        guard isEnabled, current?.handle != snapshot.handle, let inbox else { return }
        // The summon owns interruption/veto policy. Showing an independent
        // answer panel must not sneak around it for a background pane.
        guard canPresent(snapshot) else {
            if current != nil { clear() }
            return
        }
        clear(releaseHush: false); current = snapshot
        let generation = inputGeneration
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Requests"; panel.isReleasedWhenClosed = false; panel.center(); self.panel = panel
            panelDelegate.onClose = { [weak self] in
                guard let self, let current = self.current, let inbox = self.inbox else { return }
                self.clear()
                Task { await inbox.later(current) }
            }
            panel.delegate = panelDelegate
        }
        panel?.contentView = NSHostingView(rootView: AuthzInbox(model: inbox))
        panel?.orderFront(nil)
        preparing = Task { [weak self] in
            guard await inbox.presented(snapshot, claim: true), let self, self.current?.handle == snapshot.handle else { return }
            if self.hushOwner == nil { self.hushOwner = UUID().uuidString }
            if let owner = self.hushOwner { await inbox.hush(owner: owner, acquire: true) }
            while VigilAsk.inFlight || VigilVoice.isActive {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, self.current?.handle == snapshot.handle else { return }
            }
            guard !Task.isCancelled, self.current?.handle == snapshot.handle, VigilAsk.armed else { return }
            let request = snapshot.request
            guard request.kind == .permission, request.requirement.minimum == .intent,
                  request.privacy.narration, !request.containsSecrets, !request.safeGist.isEmpty,
                  let yes = request.actions.first(where: { $0.effect == .approveOnce }),
                  let no = request.actions.first(where: { $0.effect == .reject }) else { return }
            let voice = yes.channels.contains(.voice) && no.channels.contains(.voice)
            let nod = yes.channels.contains(.nod) && no.channels.contains(.nod)
            guard voice || nod else { return }
            VigilAsk.ask(request.safeGist, request: snapshot,
                         allowVoice: voice, allowNod: nod) { [weak self] answer, source in
                guard let self, self.current?.handle == snapshot.handle, self.inputGeneration == generation else { return }
                Task { @MainActor in
                    if answer == .yes || answer == .no {
                        let channel: InputChannel = source == "nod" ? .nod : source == "surface" ? .surface : .voice
                        await inbox.submit(snapshot, answer: .action(answer == .yes ? yes.id : no.id, feedback: nil), channel: channel)
                    } else { await inbox.later(snapshot) }
                    // Completion is after channel teardown. Next presentation
                    // arrives from the service stream, including timeout/Later.
                    VigilSessionManager.shared.pumpAskGate()
                }
            }
        }
    }
    private func canPresent(_ snapshot: RequestSnapshot) -> Bool {
        guard !VigilBars.shared.controlMode else { return false }
        if NSApp.isActive, let key = NSApp.keyWindow {
            if key is NSPanel, key !== panel, !(key.windowController is QuickTerminalController) { return false }
            if let controller = key.windowController as? TerminalController,
               let pane = controller.focusedSurface?.vigilAttachId, pane != snapshot.request.context,
               VigilSessionManager.shared.paneAgentState(pane)?.state == .blocked { return false }
        }
        if snapshot.request.requester == "vigil" {
            return VigilSessionManager.shared.paneOnAnyScreen(snapshot.request.context) ||
                VigilSummon.shared.currentAskPane == snapshot.request.context
        }
        return true
    }
    private func clear(releaseHush: Bool = true) {
        inputGeneration += 1
        preparing?.cancel(); preparing = nil
        if let current { VigilAsk.cancel(pane: current.request.context, reason: "authz-presentation-closed") }
        current = nil; panel?.orderOut(nil)
        if releaseHush, let inbox, let owner = hushOwner {
            hushOwner = nil
            Task { await inbox.hush(owner: owner, acquire: false) }
        }
    }
    private func stop() {
        guard inbox != nil || current != nil else { return }
        clear(); inbox?.stop(); inbox?.onHush = nil; inbox = nil
        Hush.release("authz-endpoint")
        VigilSessionManager.shared.vlog("authz endpoint: stopped")
    }
    func showEnrollment() {
        if let enrollmentPanel { enrollmentPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Authorization settings"; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: EnrollmentView()); panel.center(); panel.makeKeyAndOrderFront(nil)
        enrollmentPanel = panel
    }
    private func dictate(_ snapshot: RequestSnapshot, finished: @escaping (String) -> Void) {
        guard current?.handle == snapshot.handle, !snapshot.request.containsSecrets, !VigilVoice.isActive else { return }
        inputGeneration += 1
        let generation = inputGeneration
        VigilAsk.cancel(pane: snapshot.request.context, reason: "edit-request-draft")
        preparing?.cancel()
        preparing = Task { [weak self] in
            while VigilAsk.inFlight {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard let self, self.current?.handle == snapshot.handle, !Task.isCancelled else { return }
            VigilAsk.ask("Dictate your answer", options: ["Answer"], textOptions: [0], request: snapshot,
                enterText: true) { [weak self] answer, _ in
                guard self?.current?.handle == snapshot.handle, self?.inputGeneration == generation,
                      case .text(let text, _) = answer else { return }
                finished(text)
            }
        }
    }
    func pauseForTerminalDictation() {
        guard let current else { return }
        inputGeneration += 1; deferredForDictation = true
        preparing?.cancel(); preparing = nil
        VigilAsk.cancel(pane: current.request.context, reason: "terminal-dictation")
    }
}

@MainActor
private final class AuthorizationPanelDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}
#endif
