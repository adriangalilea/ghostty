import AppKit
import AskKit
import SwiftUI
import VigilHarness

/// AskKit owns the human-input race. The broker owns requests and delivery.
/// No answer path in this coordinator writes to a terminal.
@MainActor
final class VigilHarnessCoordinator: ObservableObject {
    static let shared = VigilHarnessCoordinator()
    @Published private(set) var requests: [Interaction] = []
    @Published private(set) var current: Interaction?
    @Published private(set) var error: String?
    @Published private(set) var brokerAvailable = false
    @Published private(set) var spokenAnswers: [String: QuestionAnswer] = [:]
    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VIGIL_HARNESS_ENABLED"] == "1" ||
            FileManager.default.fileExists(atPath: HarnessPaths.root.appendingPathComponent("enabled").path)
    }
    private var queue = PresentationQueue()
    private var timer: Timer?
    private var panel: NSPanel?
    private var refreshing = false
    private var preferredPane: String?
    private var presentedAt = Date()
    private var brokerStarter: Process?
    private var nextBrokerStart = Date.distantPast

    func pump(preferredPane: String?) {
        guard isEnabled else {
            stopObserving()
            return
        }
        self.preferredPane = preferredPane
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        guard isEnabled else { stopObserving(); return }
        guard !refreshing else { return }
        refreshing = true
        Task {
            let snapshots: [SessionSnapshot]? = await Task.detached(priority: .utility) {
                // RPC also establishes broker liveness: stale persisted requests never arm AskKit.
                guard let response = try? HarnessWire.call(RPCRequest("list")), response.ok else { return nil as [SessionSnapshot]? }
                return try? response.value.decode([SessionSnapshot].self)
            }.value
            refreshing = false
            guard isEnabled else { stopObserving(); return }
            let available = snapshots != nil
            if !available { recoverBroker() }
            if brokerAvailable != available {
                brokerAvailable = available
                NotificationCenter.default.post(name: VigilSessionManager.stateDidChange, object: nil)
            }
            requests = (snapshots ?? []).flatMap(\.pending).sorted { $0.evidence.observedAt < $1.evidence.observedAt }
            if queue.synchronize(requests) {
                if let current { VigilAsk.cancel(pane: current.paneID, reason: "superseded") }
                current = nil
            }
            // Bound automatic presentation occupancy, even without voice hardware.
            if let current, Date().timeIntervalSince(presentedAt) > 60, panel?.isKeyWindow != true { later(current) }
            guard current == nil, !VigilAsk.inFlight else { return }
            if let next = queue.next(requests, preferredPane: preferredPane) { present(next) } else if requests.isEmpty { panel?.orderOut(nil) }
        }
    }

    private func stopObserving() {
        timer?.invalidate(); timer = nil
        if let current {
            VigilAsk.cancel(pane: current.paneID, reason: "harness-disabled")
            queue.finish(PresentationQueue.Ticket(current))
        }
        current = nil; requests = []; brokerAvailable = false
        panel?.orderOut(nil)
    }

    /// Service recovery is independent of AskKit. Only an enabled, installed
    /// deployment may start the broker; development build products are ignored.
    private func recoverBroker() {
        guard isEnabled, brokerStarter == nil, Date() >= nextBrokerStart else { return }
        nextBrokerStart = Date().addingTimeInterval(10)
        let binary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/vigil-agent")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            VigilSessionManager.shared.vlog("harness service: installed broker missing; native prompts retain attention")
            return
        }
        let process = Process()
        process.executableURL = binary; process.arguments = ["ensure"]
        process.environment = AgentEnvironment.scrub(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { process in
            Task { @MainActor in
                VigilHarnessCoordinator.shared.brokerStarter = nil
                VigilSessionManager.shared.vlog("harness service: ensure exited \(process.terminationStatus)")
            }
        }
        do { try process.run(); brokerStarter = process } catch {
            VigilSessionManager.shared.vlog("harness service: ensure launch failed \(error.localizedDescription)")
        }
    }

    func select(_ request: Interaction) {
        guard request.phase == .pending, request.transport != .manualOnly else { return }
        if let current {
            VigilAsk.cancel(pane: current.paneID, reason: "preempted")
            queue.finish(PresentationQueue.Ticket(current))
        }
        queue.select(request)
        present(request)
    }

    private func present(_ request: Interaction) {
        current = request; error = nil; spokenAnswers = [:]; presentedAt = Date()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Vigil requests"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: VigilHarnessInbox(coordinator: self))
            panel.center()
            self.panel = panel
        }
        panel?.orderFront(nil)
        // Plans require reading the full review surface. Voice never approves an unread plan.
        if request.kind == .questionnaire { speakQuestion(request, index: 0) } else if request.kind == .permission,
            request.actions.contains(where: { $0.id == "allow-once" && $0.kind == .approveOnce && $0.effects.isEmpty }),
            request.actions.contains(where: { $0.id == "deny" && $0.kind == .reject }),
            VigilAsk.armed, !VigilVoice.isActive, !VigilAsk.inFlight {
            VigilAsk.ask(request.attentionSummary, pane: request.paneID) { [weak self] answer, source in
                guard let self, self.sameRequest(request) else { return }
                switch answer {
                case .yes: self.submit(request, .action("allow-once", feedback: nil), source: source)
                case .no: self.submit(request, .action("deny", feedback: nil), source: source)
                default: break
                }
            }
        }
    }

    private func sameRequest(_ request: Interaction) -> Bool {
        current.map(PresentationQueue.Ticket.init) == PresentationQueue.Ticket(request)
    }

    private func speakQuestion(_ request: Interaction, index: Int) {
        guard sameRequest(request), index < request.questions.count,
              VigilAsk.armed, !VigilVoice.isActive, !VigilAsk.inFlight else { return }
        let question = request.questions[index]
        guard question.isSecret != true, question.kind == .singleChoice || question.kind == .multipleChoice else { return }
        let choices = question.choices.map { choice in
            choice.label + (choice.description.map { ". " + $0 } ?? "")
        } + (question.allowOther ? ["Other answer"] : [])
        VigilAsk.ask(question.title, options: choices,
                     textOptions: question.allowOther ? [question.choices.count] : [],
                     multi: question.kind == .multipleChoice, pane: request.paneID) { [weak self] answer, source in
            guard let self, self.sameRequest(request) else { return }
            let value: QuestionAnswer
            switch answer {
            case .option(let chosen) where question.choices.indices.contains(chosen):
                value = .choices([question.choices[chosen].id], other: nil)
            case .options(let chosen) where chosen.allSatisfy({ question.choices.indices.contains($0) }):
                value = .choices(chosen.map { question.choices[$0].id }, other: nil)
            case .text(let text, let option) where question.allowOther && option == question.choices.count:
                value = .choices([], other: text)
            default: return
            }
            self.spokenAnswers[question.id] = value
            if index + 1 == request.questions.count {
                self.submit(request, .questionnaire(self.spokenAnswers), source: source)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.speakQuestion(request, index: index + 1) }
            }
        }
    }

    func submit(_ request: Interaction, _ answer: InteractionAnswer, source: String = "surface") {
        guard sameRequest(request), HarnessReducer.valid(answer, for: request) else { return }
        let command = RespondCommand(request: request, answer: answer, source: source)
        VigilAsk.cancel(pane: request.paneID, reason: "submitted")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    let challenge = try HarnessWire.call(RPCRequest("humanChallenge"))
                    guard challenge.ok, let nonce = challenge.value.string else { return RPCResponse(false, .string("Human authorization is unavailable.")) }
                    let signed = try HumanAuthorization.sign(RPCRequest("respond", try .from(command)), challenge: nonce, key: HumanAuthorization.loadKey())
                    return try HarnessWire.call(signed)
                } catch { return RPCResponse(false, .string("Human authorization is unavailable or receipt was not confirmed. Refresh before retrying.")) }
            }.value
            guard sameRequest(request) else { return }
            if result.ok {
                queue.finish(PresentationQueue.Ticket(request))
                current = nil
                refresh()
            } else {
                error = result.value.string ?? "The request changed. Refresh before answering."
                refresh()
            }
        }
    }

    func later(_ request: Interaction) {
        guard sameRequest(request) else { return }
        VigilAsk.cancel(pane: request.paneID, reason: "deferred")
        queue.finish(PresentationQueue.Ticket(request), dismissed: true)
        current = nil
    }

    func provisionHumanApprovals() {
        guard isEnabled else { return }
        let ui = Bundle.main.bundleURL
        let broker = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/vigil-agent")
        Task {
            let message = await Task.detached(priority: .userInitiated) {
                do {
                    try HumanAuthorization.provision(ui: ui, broker: broker)
                    return "Human approval authority created. Review the pending request before submitting."
                } catch {
                    return "Human approval setup failed or already exists. Review the Keychain entry and installed signing identities; no existing authority was replaced."
                }
            }.value
            error = message
        }
    }
}

private struct VigilHarnessInbox: View {
    @ObservedObject var coordinator: VigilHarnessCoordinator
    var body: some View {
        HStack(spacing: 0) {
            List(coordinator.requests) { request in
                Button { coordinator.select(request) } label: {
                    VStack(alignment: .leading) {
                        Text(request.title).lineLimit(2)
                        Text(request.paneID + " · " + request.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                        if request.transport == .manualOnly { Text("Continue in terminal").font(.caption) }
                    }
                }.buttonStyle(.plain)
            }.frame(width: 210)
            Divider()
            if let request = coordinator.current {
                VigilHarnessRequestView(request: request, coordinator: coordinator)
                    .id(request.instanceID + request.id + String(request.revision))
            } else {
                VStack(spacing: 12) {
                    Text("Choose a pending request").foregroundStyle(.secondary)
                    Button("Set up human approvals…") { coordinator.provisionHumanApprovals() }
                    if let error = coordinator.error { Text(error).font(.caption) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 680, minHeight: 420)
    }
}

private struct VigilHarnessRequestView: View {
    let request: Interaction
    @ObservedObject var coordinator: VigilHarnessCoordinator
    @State private var selections: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var feedback = ""
    private var answers: InteractionAnswer {
        .questionnaire(Dictionary(uniqueKeysWithValues: request.questions.compactMap { question -> (String, QuestionAnswer)? in
            // Secret/text input must retain intentional whitespace.
            let text = other[question.id, default: ""]
            switch question.kind {
            case .text:
                if text.isEmpty && !question.required { return nil }
                return (question.id, .text(text))
            case .number:
                if text.isEmpty { return nil }
                guard let number = Double(text), number.isFinite else { return (question.id, .text(text)) }
                return (question.id, .number(number))
            case .boolean:
                guard text == "true" || text == "false" else { return nil }
                return (question.id, .boolean(text == "true"))
            case .singleChoice, .multipleChoice:
                let ids = Array(selections[question.id, default: []]).sorted()
                if ids.isEmpty && text.isEmpty && !question.required { return nil }
                return (question.id, .choices(ids, other: text.isEmpty ? nil : text))
            }
        }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let plan = request.plan { Text(plan).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if request.kind == .permission || request.kind == .changeReview { Text(request.input.formatted).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    ForEach(request.questions) { question in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(question.title).font(.headline)
                            if let header = question.header { Text(header).font(.caption).foregroundStyle(.secondary) }
                            if !question.required { Text("Optional").font(.caption).foregroundStyle(.secondary) }
                            if question.kind == .text || question.kind == .number {
                                if question.isSecret == true {
                                    SecureField("Answer", text: textBinding(question.id))
                                } else {
                                    TextField(question.kind == .number ? "Number" : "Answer", text: textBinding(question.id))
                                }
                            }
                            if question.kind == .boolean {
                                Picker("Answer", selection: textBinding(question.id)) {
                                    Text("Choose").tag("")
                                    Text("Yes").tag("true")
                                    Text("No").tag("false")
                                }
                            }
                            ForEach(question.choices) { choice in
                                Toggle(isOn: Binding(get: { selections[question.id, default: []].contains(choice.id) }, set: { enabled in
                                    if question.kind == .singleChoice { selections[question.id] = enabled ? [choice.id] : []; other[question.id] = "" } else if enabled { selections[question.id, default: []].insert(choice.id) } else { selections[question.id, default: []].remove(choice.id) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(choice.label)
                                        if let description = choice.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            if question.allowOther {
                                let binding = Binding<String>(get: { other[question.id, default: ""] }, set: {
                                    other[question.id] = $0
                                    if question.kind == .singleChoice && !$0.isEmpty { selections[question.id] = [] }
                                })
                                if question.isSecret == true { SecureField("Other answer", text: binding) } else {
                                    TextField("Other answer", text: binding)
                                }
                            }
                        }
                    }
                    ForEach(request.actions) { action in
                        ForEach(action.effects, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    }
                    if request.providerMethod == nil && request.actions.contains(where: { $0.kind == .revise || $0.kind == .reject }) {
                        TextField("Feedback (required for changes)", text: $feedback, axis: .vertical).lineLimit(2...5)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = coordinator.error {
                Text(error).foregroundStyle(.red).font(.caption)
                if error.contains("Human authorization") { Button("Set up human approvals…") { coordinator.provisionHumanApprovals() } }
            }
            HStack {
                Button("Later") { coordinator.later(request) }
                Spacer()
                if request.kind == .questionnaire {
                    Button("Submit answers") { coordinator.submit(request, answers) }.disabled(!HarnessReducer.valid(answers, for: request))
                }
                ForEach(request.actions) { action in
                    Button(action.label) { coordinator.submit(request, .action(action.id, feedback: feedback.isEmpty ? nil : feedback)) }
                        .disabled(action.kind == .revise && feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(16)
            .onReceive(coordinator.$spokenAnswers) { answers in
                for (id, value) in answers {
                    if case .choices(let ids, let text) = value {
                        selections[id] = Set(ids)
                        other[id] = text ?? ""
                    }
                }
            }
    }
    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { other[id, default: ""] }, set: { other[id] = $0 })
    }
}
