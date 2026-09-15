#if os(macOS)
import AppKit
import AskKit
import AuthzUI
import AuthzClient
import AuthzProtocol
import Face
import Ink
import Say
import SwiftUI
import VigilHarness

/// The settings window: authz.space's enrollment surface, then vigil's own
/// diagnostics. Debug capture is a developer choice and lives here, never
/// in the daily footer; secret-bearing requests stay excluded regardless.
private struct VigilAuthorizationSettings: View {
    let close: () -> Void
    @ObservedObject private var remote = VigilRemote.shared
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
            EnrollmentView(destinations: remote.hosts.filter { !$0.isSelf }.map {
                PairingDestination(name: $0.directory?.host ?? $0.alias, route: $0.alias)
            })
                .scrollContentBackground(.hidden)
            Rectangle().fill(.inkRest).frame(height: 1).padding(.horizontal, 20)
            Form {
                Section {
                    LanguagesEditor()
                } header: {
                    Text("Languages")
                } footer: {
                    Text("What this Mac listens and speaks in. The default is the Mac's own languages; a language is never assumed. Several race per phrase; the footer's picker pins one.")
                }
                Section("Voice") {
                    VoiceEngineRow(.init(
                        name: "Kokoro",
                        detail: "Natural English narration, local, ~99 MB. Until installed, the system voice reads your prompts.",
                        installed: { KokoroBackend.downloaded },
                        download: { progress in
                            try KokoroBackend.download(progress: progress)
                            KokoroBackend.warm()
                        }))
                }
                Section {
                    Toggle("Record authorization debug captures", isOn: $debugCapture)
                        .help("Capture audio, motion and ordinary dictated answers for local debugging. Requests marked secret are excluded. Applies to the next input session.")
                    LabeledContent("Prompt preview") {
                        Button("Preview an ask") { VigilAsk.demo() }
                            .help("Fires a demo prompt through your armed channels - narration, evidence block, yes/no. Nothing real behind it, nothing recorded.")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Off by default. Secret-bearing requests are never captured, toggle or not.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 380)
        }
        .frame(width: 640, height: 754)
        // The pane IS the glass: a borderless panel with nothing but this
        // shape (Face's FloatingHUD pattern), so the material hugs the
        // content and no window chrome doubles it.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: .inkPanel, style: .continuous))
        .onExitCommand(perform: close)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in close() }
    }
}

/// The review surface's chrome: the brand header (the mark wearing the
/// current request's level), authz.space's inbox card as content, one
/// pane of Liquid Glass hugging it. esc or × = Later. The header is pinned
/// and the card scrolls under it, capped to the screen: a card taller than
/// the display once grew off the top and took its close button with it.
private struct VigilRequestsPane: View {
    @ObservedObject var inbox: InboxModel
    let tint: () -> Color?
    let close: () -> Void
    let maxBodyHeight: CGFloat
    @State private var bodyHeight: CGFloat = 0

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
            ScrollView {
                AuthzInbox(model: inbox)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .frame(height: min(max(bodyHeight, 80), maxBodyHeight))
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
        NotificationCenter.default.addObserver(forName: Notification.Name("authz.peers.changed"), object: nil, queue: .main) { _ in
            Task { @MainActor in VigilHarnessCoordinator.shared.configureRemoteHomes() }
        }
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
    private var brokerEnsured = false
    private var remoteHomes: [String: TrustedHome] = [:]
    private var remotePresenceMemo: [String: [String]] = [:]

    func pump(preferredPane: String?) {
        // The broker is the one writer of every pane's state: it runs on
        // every Mac, enrolled or not. Started once here; a hook event that
        // finds none starts it again. authz enrollment only decides whether
        // requests can be answered away from the terminal.
        if !brokerEnsured { brokerEnsured = true; launch("vigil-agent", ["ensure"]) }
        guard enrolled else { stop(); return }
        if inbox == nil { connect() }
        let panes = inbox?.requests.filter { inbox?.isRemote($0) != true }.map { $0.request.context }.filter { VigilSessionManager.shared.paneOnAnyScreen($0) } ?? []
        let remoteFocus = (NSApp.keyWindow?.windowController as? TerminalController)?.focusedSurface?.vigilHost != nil
        let focused = NSApp.isActive && !remoteFocus ? preferredPane : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if self.preferredPane != focused || panes != visible {
            self.preferredPane = focused; visible = panes
            Task { await inbox?.presence(focusedContext: focused, visibleContexts: panes) }
        }
        if let inbox {
            let views = (NSApp.keyWindow?.windowController as? TerminalController).map { Array($0.surfaceTree) } ?? []
            for (id, home) in remoteHomes {
                let visible = NSApp.isActive ? views.filter { $0.vigilHost == home.route && !$0.isHiddenOrHasHiddenAncestor }.compactMap(\.vigilAttachId) : []
                let focused = visible.contains(preferredPane ?? "") ? preferredPane : nil
                let memo = visible + [focused ?? ""]
                if remotePresenceMemo[id] != memo {
                    remotePresenceMemo[id] = memo
                    Task { await inbox.remotePresence(id, focusedContext: visible.contains(preferredPane ?? "") ? preferredPane : nil, visibleContexts: visible) }
                }
            }
            if let current, inbox.isRemote(current), !inbox.remoteAutomaticAllowed(current), !inbox.manualSelection { clear() }
            inbox.reconsider()
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
            model.onRequestsChanged = { [weak self] in self?.objectWillChange.send() }
            model.onPresentation = { [weak self] request in
                if let request { self?.present(request) } else { self?.clear() }
            }
            model.onRequestHandoff = { [weak self] request in
                guard let self else { return }
                let pane = request.request.context
                let manager = VigilSessionManager.shared
                if self.inbox?.isRemote(request) == true {
                    guard let id = request.handle.homeID, let home = self.remoteHomes[id] else {
                        manager.vlog("handoff: remote request \(request.request.id) has no enrolled route")
                        return
                    }
                    guard manager.openRemotePane(alias: home.route, pane: pane) != nil else {
                        let alert = NSAlert()
                        alert.messageText = "This remote pane is unavailable"
                        alert.informativeText = "Reconnect to \(home.route) and try again."
                        alert.runModal()
                        return
                    }
                } else if let view = VigilSessionManager.shared.liveView(attachId: pane) {
                    view.window?.makeKeyAndOrderFront(nil); view.window?.makeFirstResponder(view)
                } else {
                    manager.vlog("handoff: request \(request.request.id) pane \(pane) unavailable")
                    return
                }
                // The request still stands at its provider. Only the card's
                // presentation gets out of the terminal's way.
                self.panel?.orderOut(nil)
            }
            model.automaticEligibility = { [weak self] request in
                guard let id = request.handle.homeID, let home = self?.remoteHomes[id] else { return true }
                guard let truth = VigilRemote.shared.hosts.first(where: { $0.alias == home.route })?.directory?.panes[request.request.context],
                      truth.alive, truth.stateRevision != nil,
                      (truth.seen ?? 0) < (truth.since ?? 0) else { return false }
                return true
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
            configureRemoteHomes()
            startServices()
            VigilSessionManager.shared.vlog("authz endpoint: connected; addressed event stream enabled")
        } catch { VigilSessionManager.shared.vlog("authz endpoint: enrollment unavailable; native attention remains active") }
    }
    func configureRemoteHomes() {
        guard let inbox, let key = try? DeviceIdentity.key() else { return }
        let routes = Set(VigilRemote.shared.hosts.map(\.alias))
        let homes = ((try? PeerTrust.homes()) ?? []).filter { routes.contains($0.route) }
        let wanted = Set(homes.map(\.id))
        for id in inbox.homeIDs.subtracting(wanted) { inbox.removeHome(id); remotePresenceMemo[id] = nil }
        for home in homes where remoteHomes[home.id] != home {
            inbox.removeHome(home.id); remotePresenceMemo[home.id] = nil
        }
        remoteHomes = Dictionary(uniqueKeysWithValues: homes.map { ($0.id, $0) })
        for home in homes where !inbox.homeIDs.contains(home.id) {
            let id = Canonical.digest(key.publicKey.rawRepresentation)
            let connection = RemoteTransport.ssh(home: home, endpointID: id, key: key)
            inbox.addHome(home, transport: EndpointTransport(endpointID: id, key: key, underlying: connection), connection: connection)
        }
    }

    private func startServices() {
        guard enrolled, Date() >= nextServiceCheck else { return }
        nextServiceCheck = Date().addingTimeInterval(10)
        Task { [weak self] in
            guard let self else { return }
            let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/authz-space/service.sock").path
            let healthy = (try? await SocketTransport(path: socket, verifyServer: PlatformTrust.verifyService).call(RPC("health")))?.ok == true
            guard self.enrolled else { return }
            if !healthy { self.launch("authz", ["serve"]) }
            self.launch("vigil-agent", ["ensure"])
        }
    }
    /// Installed binaries only. No development build is launched implicitly.
    private func launch(_ binary: String, _ arguments: [String]) {
        if starters.contains(where: { $0.executableURL?.lastPathComponent == binary && $0.isRunning }) { return }
        let process = Process()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/" + binary)
        process.arguments = arguments; process.environment = AgentEnvironment.scrub(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                self.starters.removeAll { $0 === process }
                VigilSessionManager.shared.vlog("authz service: \(binary) exited \(process.terminationStatus)")
                if binary == "authz" {
                    // Exit 0 is the service asking to be relaunched on a
                    // changed configuration (it reads the file once);
                    // non-zero is a fault. Either way the endpoint is
                    // gone: drop it, reconnect at once for a reload,
                    // after a breath for a fault.
                    self.stop()
                    let delay: TimeInterval = process.terminationStatus == 0 ? 0 : 10
                    self.nextStart = Date().addingTimeInterval(delay)
                    self.nextServiceCheck = Date().addingTimeInterval(delay)
                }
            }
        }
        do { try process.run(); starters.append(process) } catch { VigilSessionManager.shared.vlog("authz service: installed \(binary) unavailable") }
    }
    private func presentationPane(_ snapshot: RequestSnapshot) -> String {
        if let id = snapshot.handle.homeID, let home = remoteHomes[id] {
            return VigilRemote.compositeId(home.route, snapshot.request.context)
        }
        return snapshot.request.context
    }

    private func present(_ snapshot: RequestSnapshot) {
        guard current?.handle != snapshot.handle, let inbox else { return }
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
        // The fast lane (narration + keys/nod/voice on the HUD) carries every
        // answerable kind: a permission as yes/no, a questionnaire one
        // question at a time, a plan review as its verbs. The card opens
        // itself only for what no ask shape can carry, and otherwise waits
        // behind the plate's pending badge.
        let steps = inbox.manualSelection ? nil : VigilAskPlan.steps(for: snapshot.request)
        if steps == nil { showPanel() } else { panel?.orderOut(nil) }
        preparing = Task { [weak self] in
            guard let self, self.current?.handle == snapshot.handle else { return }
            guard let steps, VigilAsk.armed else {
                _ = await inbox.presented(snapshot, claim: false)
                return
            }
            while VigilAsk.inFlight || VigilVoice.isActive {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, self.current?.handle == snapshot.handle else { return }
            }
            guard !Task.isCancelled, self.current?.handle == snapshot.handle, VigilAsk.armed else { return }
            guard !inbox.manualSelection else { return }
            if inbox.isRemote(snapshot), !inbox.remoteAutomaticAllowed(snapshot) { return }
            guard await inbox.presented(snapshot, claim: true), !Task.isCancelled,
                  self.current?.handle == snapshot.handle else { return }
            if self.hushOwner == nil { self.hushOwner = UUID().uuidString }
            if let owner = self.hushOwner { await inbox.hush(owner: owner, acquire: true) }
            let request = snapshot.request
            // Never solicit an answer nowhere can deliver: a manual-only
            // request is announced, not raced.
            guard request.responseMode == .interactive else {
                VigilAsk.announce(request.safeGist.isEmpty ? "Answer this one in the terminal" : request.safeGist + ". Answer it in the terminal", pane: request.context)
                return
            }
            self.run(steps, at: 0, answers: [:], snapshot: snapshot, generation: generation)
        }
    }

    /// One HUD ask per step, in order; a questionnaire's answers collect
    /// across steps and submit once, a verb submits at its step. Every exit
    /// that is not an answer is the human's (esc = Later) or the channel's
    /// (retry); an answer the request refuses on its channel (a scoped grant
    /// or a plan approval spoken rather than seen) opens the card instead
    /// of vanishing.
    private func run(_ steps: [VigilAskPlan.Step], at index: Int, answers: [String: QuestionAnswer],
                     snapshot: RequestSnapshot, generation: Int) {
        guard let inbox, current?.handle == snapshot.handle, inputGeneration == generation else { return }
        let request = snapshot.request
        guard index < steps.count else {
            deliver(.questionnaire(answers), channel: .surface, snapshot: snapshot)
            return
        }
        let step = steps[index]
        // Spoken channels answer only what the contract lets them: a narrated
        // request with a gist. The face answers everything.
        let spoken = request.privacy.narration && !request.safeGist.isEmpty
        let home = inbox.homeName(snapshot)
        VigilAsk.ask([home, step.spoken].compactMap { $0 }.joined(separator: ": "), detail: step.detail,
                     options: step.options, textOptions: step.textOptions, multi: step.multi,
                     request: snapshot, paneIdentity: presentationPane(snapshot), timeout: step.timeout,
                     enterText: step.enterText, allowVoice: spoken, allowNod: spoken) { [weak self] answer, source, reason in
            guard let self, self.current?.handle == snapshot.handle, self.inputGeneration == generation else { return }
            Task { @MainActor in
                guard let answer else {
                    if reason.contains("esc") {
                        // A human dismissal is Later, never the auto-retry
                        // lane: an esc'd ask re-presenting 11s later taught
                        // the difference (2026-09-13). It waits in the inbox.
                        await inbox.later(snapshot)
                    } else { await inbox.retry(snapshot) }
                    // Completion is after channel teardown. Next presentation
                    // arrives from the service stream, including timeout/Later.
                    VigilSessionManager.shared.pumpAskGate()
                    return
                }
                let channel: InputChannel = source == "nod" ? .nod : source == "surface" ? .surface : .voice
                guard let part = step.resolve(answer, Ask.currentPicks) else {
                    VigilSessionManager.shared.vlog("authz present: \(request.context) answer \(answer) fits no outcome of \(request.kind.rawValue) - the card takes it")
                    self.showPanel()
                    return
                }
                switch part {
                case .decision(let decision):
                    self.deliver(decision, channel: channel, snapshot: snapshot)
                case .answer(let id, let value):
                    var answers = answers
                    answers[id] = value
                    self.run(steps, at: index + 1, answers: answers, snapshot: snapshot, generation: generation)
                }
            }
        }
    }

    private func deliver(_ decision: Decision, channel: InputChannel, snapshot: RequestSnapshot) {
        guard let inbox else { return }
        let request = snapshot.request
        // The HUD showed the review body as its evidence block, so a
        // decision made on the surface has seen the digest it approves.
        let reviewed = channel == .surface ? request.reviewDigest : nil
        guard request.accepts(decision, channel: channel, reviewedDigest: reviewed) else {
            VigilSessionManager.shared.vlog("authz present: \(request.context) refuses \(decision) over \(channel.rawValue) - the card takes it")
            showPanel()
            return
        }
        Task { @MainActor in
            await inbox.submit(snapshot, answer: decision, channel: channel, reviewedDigest: reviewed)
            VigilSessionManager.shared.pumpAskGate()
        }
    }
    var pendingCount: Int { inbox?.requests.count ?? 0 }
    /// The plate's badge: open the review surface for whatever is waiting.
    func showInbox() { guard inbox != nil else { return }; showPanel() }
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
            // The panel follows its content's size; whatever size that is,
            // the whole pane stays on the screen it was summoned to.
            panelDelegate.onResize = { [weak self] in self?.keepPanelOnScreen() }
            panel.delegate = panelDelegate
            let host = NSHostingView(rootView: VigilRequestsPane(inbox: inbox, tint: { [weak self] in self?.plateTint },
                                                                 close: { [weak self] in self?.panelDelegate.onClose?() },
                                                                 maxBodyHeight: Self.maxCardBodyHeight))
            host.sizingOptions = .preferredContentSize
            panel.contentView = host
            self.panel = panel
        }
        guard let panel else { return }
        if !panel.isVisible {
            let screen = NSApp.keyWindow?.screen ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            }
        }
        panel.orderFront(nil)
        keepPanelOnScreen()
    }
    /// The tallest card body any display here allows: the visible frame
    /// minus the header and a margin. Measured once per show, on the
    /// display the key window sits on.
    private static var maxCardBodyHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        return max(200, (screen?.visibleFrame.height ?? 800) - 140)
    }
    private func keepPanelOnScreen() {
        guard let panel, let screen = panel.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - panel.frame.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }
    private func canPresent(_ snapshot: RequestSnapshot) -> Bool {
        let refuse: (String) -> Bool = { why in
            VigilSessionManager.shared.vlog("authz present refused: \(snapshot.request.context) \(why)")
            return false
        }
        guard !VigilBars.shared.controlMode else { return refuse("control mode") }
        if NSApp.isActive, let key = NSApp.keyWindow {
            if key is NSPanel, key !== panel, !(key.windowController is QuickTerminalController) { return false }
            if let controller = key.windowController as? TerminalController,
               let pane = controller.focusedSurface?.vigilAttachId, pane != snapshot.request.context,
               VigilSessionManager.shared.paneAgentState(pane)?.state == .blocked { return false }
        }
        // Where the pane is does not decide whether you are TOLD: an ask you
        // cannot see is the one the spoken channel exists for. Presence decides
        // what MOVES (the summon's glass), never what speaks; requiring the
        // pane on screen meant every prompt in a session you were not looking
        // at stayed silent, which is the whole point of the gate.
        return true
    }
    private func clear(releaseHush: Bool = true) {
        inputGeneration += 1
        preparing?.cancel(); preparing = nil
        if let current { VigilAsk.cancel(pane: presentationPane(current), reason: "authz-presentation-closed") }
        current = nil; panel?.orderOut(nil)
        if releaseHush, let inbox, let owner = hushOwner {
            hushOwner = nil
            Task { await inbox.hush(owner: owner, acquire: false) }
        }
    }
    private func stop() {
        guard inbox != nil || current != nil else { return }
        clear(); inbox?.stop(); inbox?.onHush = nil; inbox = nil
        remoteHomes = [:]; remotePresenceMemo = [:]
        Hush.release("authz-endpoint")
        VigilSessionManager.shared.vlog("authz endpoint: stopped")
    }
    /// The plate's two live facts. Health is alpha (enrolled and answering,
    /// or the reason it is not); level is hue, the one axis BRAND.md reserves
    /// it for: the in-flight request's urgency, worn while it stands.
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
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // NSHostingView has no SwiftUI Scene: its default scenePhase is
        // background. This visible AppKit panel owns the presentation lifetime.
        // Removing its root on close cancels discovery and withdraws pairing.
        panel.contentView = NSHostingView(rootView: VigilAuthorizationSettings(close: { [weak self] in self?.closeEnrollment() })
            .environment(\.scenePhase, .active))
        panel.center(); panel.makeKeyAndOrderFront(nil)
        enrollmentPanel = panel
        VigilSessionManager.shared.vlog("authz settings: visible; pairing discovery enabled")
    }
    private func closeEnrollment() {
        guard let panel = enrollmentPanel else { return }
        panel.contentView = nil
        panel.close()
        enrollmentPanel = nil
        VigilSessionManager.shared.vlog("authz settings: closed; pairing presentation ended")
    }
    private func dictate(_ snapshot: RequestSnapshot, finished: @escaping (String) -> Void) {
        guard current?.handle == snapshot.handle, !snapshot.request.containsSecrets, !VigilVoice.isActive else { return }
        inputGeneration += 1
        let generation = inputGeneration
        VigilAsk.cancel(pane: presentationPane(snapshot), reason: "edit-request-draft")
        preparing?.cancel()
        preparing = Task { [weak self] in
            while VigilAsk.inFlight {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard let self, self.current?.handle == snapshot.handle, !Task.isCancelled else { return }
            VigilAsk.ask("Dictate your answer", options: ["Answer"], textOptions: [0], request: snapshot, paneIdentity: self.presentationPane(snapshot),
                enterText: true) { [weak self] answer, _, _ in
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
        VigilAsk.cancel(pane: presentationPane(current), reason: "terminal-dictation")
    }
}

@MainActor
private final class AuthorizationPanelDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
    func windowDidResize(_ notification: Notification) { onResize?() }
}
#endif
