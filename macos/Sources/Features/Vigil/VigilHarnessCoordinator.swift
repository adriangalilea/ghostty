#if os(macOS)
import AppKit
import AskKit
import AuthzUI
import AuthzClient
import AuthzProtocol
import Face
import Ink
import SwiftUI
import VigilHarness

/// The settings window: authz.space's enrollment surface, then vigil's own
/// diagnostics. Debug capture is a developer choice and lives here, never
/// in the daily footer; secret-bearing requests stay excluded regardless.
private struct VigilAuthorizationSettings: View {
    let close: () -> Void
    @AppStorage(VigilAsk.debugCaptureKey) private var debugCapture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                AskMark(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("authz.space")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(0.3)
                    Text("Who may ask, who may answer, and how a request reaches you.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close (esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 4)
            EnrollmentView()
                .scrollContentBackground(.hidden)
            Rectangle().fill(.inkRest).frame(height: 1).padding(.horizontal, 20)
            Form {
                Section {
                    Toggle("Record authorization debug captures", isOn: $debugCapture)
                        .help("Capture audio, motion and ordinary dictated answers for local debugging. Requests marked secret are excluded. Applies to the next input session.")
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Off by default. Secret-bearing requests are never captured, toggle or not.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 118)
        }
        .frame(width: 640, height: 600)
        // The pane IS the glass: a borderless panel with nothing but this
        // shape (Face's FloatingHUD pattern), so the material hugs the
        // content and no window chrome doubles it.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: .inkPanel, style: .continuous))
        .onExitCommand(perform: close)
    }
}

/// The review surface's chrome: the brand header (the mark wearing the
/// current request's level), authz.space's inbox card as content, one
/// pane of Liquid Glass hugging it. esc or × = Later.
private struct VigilRequestsPane: View {
    @ObservedObject var inbox: InboxModel
    let tint: () -> Color?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AskMark(size: 16, tint: tint())
                Text("ask").font(.system(size: 12, weight: .semibold)).tracking(0.4)
                Text("authz.space").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Later (esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            AuthzInbox(model: inbox)
        }
        .frame(width: 560)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: .inkPanel, style: .continuous))
        .onExitCommand(perform: close)
    }
}

/// Vigil supplies presence and provider handoff. authz.space owns requests,
/// device pickup and receipts; swift-senses owns only this device's input race.
@MainActor
final class VigilHarnessCoordinator: ObservableObject {
    static let shared = VigilHarnessCoordinator()
    private init() {
        // The plate's master switch lives in the suite's defaults; a flip
        // re-pumps so an ask waiting behind "off" presents the moment it is on.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in VigilSessionManager.shared.pumpAskGate() }
        }
    }
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
        if !isEnabled { activateIfEnrolled() }
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
            // An uncertain application is a receipt, not an interruption: it
            // is logged and shown inside the card whenever the card is open,
            // never by opening the card itself.
            model.onApplicationFailure = { request in
                VigilSessionManager.shared.vlog("authz application failed: request=\(request.id) revision=\(request.handle.revision) outcome=\(request.receipt?.application.rawValue ?? "unknown")")
            }
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
        // ask off: this Mac never asks. The request stays offered (another
        // device may claim it), the terminal prompt stands, the plate's
        // badge is the only door. Flipping the switch back re-pumps.
        guard AskSettings.enabled else {
            if current != nil { clear() }
            return
        }
        clear(releaseHush: false); current = snapshot
        let generation = inputGeneration
        // The fast lane (narration + nod/voice/keys) carries a plain
        // allow-once permission on its own; the review surface opens itself
        // only for what the fast lane cannot faithfully carry, and otherwise
        // waits behind the plate's pending badge.
        if needsSurface(snapshot.request) { showPanel() } else { panel?.orderOut(nil) }
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
            // Never solicit an answer nowhere can deliver: a manual-only
            // request is announced, not raced.
            guard request.responseMode == .interactive else {
                VigilAsk.announce(request.safeGist.isEmpty ? "Answer this one in the terminal" : request.safeGist + ". Answer it in the terminal", pane: request.context)
                return
            }
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
                    } else { await inbox.retry(snapshot) }
                    // Completion is after channel teardown. Next presentation
                    // arrives from the service stream, including timeout/Later.
                    VigilSessionManager.shared.pumpAskGate()
                }
            }
        }
    }
    /// What the fast lane cannot carry: anything but a plain allow-once
    /// permission with narration, or a permission when no spoken channel is
    /// armed to answer it. Everything else reaches the surface on demand.
    private func needsSurface(_ request: AskRequest) -> Bool {
        guard request.responseMode == .interactive, request.kind == .permission,
              request.requirement.minimum == .intent, request.privacy.narration,
              !request.containsSecrets, !request.safeGist.isEmpty, VigilAsk.armed,
              let yes = request.actions.first(where: { $0.effect == .approveOnce }),
              let no = request.actions.first(where: { $0.effect == .reject }) else { return true }
        let spoken: (Action) -> Bool = { $0.channels.contains(.voice) || $0.channels.contains(.nod) }
        return !(spoken(yes) && spoken(no))
    }
    var pendingCount: Int { inbox?.requests.count ?? 0 }
    /// The plate's badge: open the review surface for whatever is waiting.
    func showInbox() { guard isEnabled, inbox != nil else { return }; showPanel() }
    private func showPanel() {
        guard let inbox else { return }
        if panel == nil {
            // Face's FloatingHUD shape: a borderless keyable panel with a clear
            // body, the glass hugging the content as its only visible shape.
            // Shown, not made key: keys typed at the terminal stay there; a
            // click into the card gives it the keyboard (y / n / esc).
            let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Requests"; panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true; panel.level = .floating
            // No window shadow: it is computed for the rectangular frame, not
            // the glass, and paints a second frame around the pane.
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Closing always hides the pane; a request on show is deferred (Later).
            panelDelegate.onClose = { [weak self] in
                guard let self else { return }
                let request = self.current
                self.clear()
                self.panel?.orderOut(nil)
                if let request, let inbox = self.inbox { Task { await inbox.later(request) } }
            }
            panel.delegate = panelDelegate
            let host = NSHostingView(rootView: VigilRequestsPane(inbox: inbox, tint: { [weak self] in self?.plateTint },
                                                                 close: { [weak self] in self?.panelDelegate.onClose?() }))
            host.sizingOptions = .preferredContentSize
            panel.contentView = host
            panel.center()
            self.panel = panel
        }
        panel?.orderFront(nil)
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
    /// The plate's two live facts. Health is alpha (enrolled and answering,
    /// or the reason it is not); level is hue, the one axis BRAND.md reserves
    /// it for: the in-flight request's urgency, worn while it stands.
    /// Enrollment is the one click; the gate follows it. A kit installs every
    /// component, so the only thing between "enrolled" and "answering" was a
    /// file a stranger would never know to create. Created once, here, with
    /// a receipt; services start through the usual recovery.
    private func activateIfEnrolled() {
        guard enrolled, !isEnabled,
              FileManager.default.isExecutableFile(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/vigil-agent").path)
        else { return }
        let root = HarnessPaths.root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: root.appendingPathComponent("enabled"), options: .atomic)
            VigilSessionManager.shared.vlog("authz: enrolled on this Mac; harness gate created, services start on recovery")
        } catch {
            VigilSessionManager.shared.vlog("authz: enrolled but the gate could not be created: \(error.localizedDescription)")
        }
    }
    /// This Mac has the service installed and a sealed enrollment on disk:
    /// the plate shows its controls only then. Enrollment is the human's one
    /// click in the settings pane (the gear); everything else is derived.
    var enrolled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.isExecutableFile(atPath: home.appendingPathComponent(".local/bin/authz").path)
            && FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/state/authz-space/configuration.json").path)
    }
    var plateHealth: AskPanelHealth {
        guard enrolled else { return .off("not set up: open the gear and enroll this Mac") }
        guard isEnabled else { return .off("gate off: prompts stay on the terminal") }
        guard inbox != nil else { return .off("service unreachable") }
        return .ready
    }
    var plateTint: Color? {
        switch current?.request.urgency {
        case .critical: AskLevelRamp.critical
        case .timeSensitive: AskLevelRamp.high
        default: nil
        }
    }
    func showEnrollment() {
        if let enrollmentPanel { enrollmentPanel.makeKeyAndOrderFront(nil); return }
        // A floating glass pane, Face's FloatingHUD shape: a borderless
        // keyable panel with a clear body, so the only visible thing is the
        // glass hugging the content. Dragged by its body, closed by × or esc.
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Authorization settings"; panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true; panel.level = .floating
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VigilAuthorizationSettings(close: { [weak panel] in panel?.orderOut(nil) }))
        panel.center(); panel.makeKeyAndOrderFront(nil)
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
