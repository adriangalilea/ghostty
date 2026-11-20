import Ink
import SwiftUI
import VigilWire

/// Creating a workspace, one part on every device (PORTABILITY.md "Move to",
/// New Pane): which Mac (the place it runs; the phone is never one), which
/// folder, what it runs, or a conversation it resumes, and a label. Each app
/// only says where its facts come from (`CreationModel`): the phone over its
/// tether node, the Mac over its own registry and the others' hubs.
///
/// What the chosen Mac lacks is said before Create: a resumed conversation
/// whose history is not on that Mac yet, or that runs elsewhere, which is
/// never a silent second writer (Move it there instead). Every fact appears
/// as it arrives; Create stays disabled while one is out, saying which.
enum Create {
    /// What a new pane may run besides a shell, by name: Claude through
    /// `c`, the agent-hud router (the one Claude entrypoint on Adrian's
    /// Macs: it picks the account; bare `claude` pins the default one).
    static let presets: [(name: String, command: String)] = [("Claude", "c")]

    /// A preset's name for a command (the command itself otherwise).
    static func name(of command: String?) -> String {
        guard let command else { return "Shell" }
        return presets.first { $0.command == command }?.name ?? command
    }

    /// The folder as a row names it: its last component (`~` for a home
    /// folder given as `~`), the whole path beneath.
    static func caption(_ path: String) -> String {
        path == "~" ? "Home" : URL(fileURLWithPath: path).lastPathComponent
    }
}

extension ConversationRow {
    /// Every place it is, the best first.
    var holdings: [Holding] { [holding] + (others ?? []) }
}

/// A Mac a workspace may be created on, as the asking device sees it.
struct CreationMac: Identifiable, Hashable {
    let id: String
    let name: String
    let reachable: Bool
}

/// What is created: a program (nil: a shell) in a folder, or a pane that
/// resumes a conversation in the folder it ran in.
enum CreationPlan: Equatable {
    case run(cwd: String, command: String?, label: String?)
    case resume(ConversationRef, folder: String, label: String?)

    var request: WorkspaceCommand.Request {
        switch self {
        case .run(let cwd, let command, let label): .create(cwd: cwd, command: command, label: label)
        case .resume(let ref, let folder, let label): .create(resuming: ref, folder: folder, label: label)
        }
    }
}

/// Where one device's creation facts come from.
@MainActor
protocol CreationModel: ObservableObject {
    var creationMacs: [CreationMac] { get }
    func recentFolders(onMac id: String) -> [String]
    func knownCommands(onMac id: String) -> [String]
    /// A creation is in flight (one at a time).
    var creationBusy: Bool { get }
    /// Why the last creation did not happen, said on the sheet.
    var creationProblem: String? { get set }
    /// Sent to `mac`; `done` once its pane runs (the sheet closes).
    func create(_ plan: CreationPlan, onMac id: String, done: @escaping @MainActor () -> Void)
    /// Every conversation the Mac `id` knows of, its own and the copies
    /// another Mac's sync left there, as its conversation engine lists them.
    func conversations(onMac id: String) async throws -> [ConversationRow]
    /// What the Mac `id` lacks for it (`Open.startCheck`, answered there).
    func startCheck(_ ask: StartCheck.Ask, onMac id: String) async throws -> StartCheck.Answer
    /// The move of the pane that runs `card` (`holding`) to the Mac `id`.
    func move(_ card: ConversationRow, running holding: Holding, toMac id: String)
}

/// The sheet: said in full before it is sent.
struct NewWorkspaceSheet<Model: CreationModel>: View {
    @ObservedObject var model: Model
    /// The Mac and folder of the context it was asked from, if any.
    let startMac: String?
    let startFolder: String?
    let close: () -> Void

    @State private var macId: String?
    @State private var folder = "~"
    @State private var typedFolder = ""
    @State private var command: String?
    @State private var typedCommand = ""
    @State private var label = ""
    @State private var resuming: ConversationRow?
    @State private var cards: [ConversationRow]?
    @State private var cardsProblem: String?
    @State private var search = ""
    /// The chosen Mac's answer for what is chosen now, and for which ask.
    @State private var checked: (ask: StartCheck.Ask, answer: StartCheck.Answer)?
    @State private var checkProblem: String?

    private var checkAsk: StartCheck.Ask {
        if let resuming { return StartCheck.Ask(folder: resuming.folder ?? "~", resume: resuming.ref) }
        let program = chosenCommand?.split(separator: " ").first.map(String.init)
        return StartCheck.Ask(folder: chosenFolder, program: program)
    }
    private var answer: StartCheck.Answer? { checked?.ask == checkAsk ? checked?.answer : nil }

    private var mac: CreationMac? { model.creationMacs.first { $0.id == macId } }
    private var chosenFolder: String {
        let typed = typedFolder.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? folder : typed
    }
    private var chosenCommand: String? {
        let typed = typedCommand.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? command : typed
    }
    private var chosenLabel: String? {
        let typed = label.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? nil : typed
    }

    private var plan: CreationPlan {
        if let resuming { return .resume(resuming.ref, folder: resuming.folder ?? "~", label: chosenLabel) }
        return .run(cwd: chosenFolder, command: chosenCommand, label: chosenLabel)
    }

    /// Who writes the resumed conversation now, on any Mac.
    private var writer: Holding? { resuming?.holdings.first { $0.how.running } }

    /// Why it cannot be sent as it stands, the fact it waits on included.
    private var problem: String? {
        guard let mac else { return "Choose a Mac." }
        guard mac.reachable else { return "\(mac.name) can't be reached right now." }
        if resuming != nil, let writer {
            return "It runs on \(writer.mac) (\(writer.how.words)): move it here instead of a second writer."
        }
        // Every check answered before Create, each fact as it arrives.
        if let checkProblem { return "\(mac.name) did not say what it lacks: \(checkProblem)" }
        guard let answer else { return "Checking \(mac.name)…" }
        if answer.blocks { return answer.lacks(on: mac.name, program: checkAsk.program).joined(separator: " ") }
        if let why = plan.request.refusal { return why.prefix(1).uppercased() + why.dropFirst() + "." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Mac") {
                    InkTabs($macId, model.creationMacs.map { InkTab($0.name, Optional($0.id)) })
                        .accessibilityLabel("Mac")
                }
                Section {
                    choice(selected: resuming == nil) { Text("A new program") } action: { resuming = nil }
                    if let cards {
                        TextField("Resume a conversation: search", text: $search)
                            .autocorrectionDisabled()
                        ForEach(shown(cards), id: \.ref) { card in
                            choice(selected: resuming?.ref == card.ref) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.name ?? String(card.ref.id.prefix(8))).lineLimit(1)
                                    Text(cardDetail(card)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } action: { resuming = card }
                        }
                    } else if let cardsProblem {
                        Text(cardsProblem).font(.caption).foregroundStyle(.orange)
                    } else if mac != nil {
                        Text("Reading \(mac?.name ?? "")'s conversations…").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What it runs")
                }
                if resuming == nil {
                    folderSection
                    commandSection
                }
                Section {
                    TextField("Label (optional)", text: $label)
                } footer: {
                    Text("Shown in every sidebar; its random name otherwise.")
                }
            }
            createBar
        }
        .onAppear {
            model.creationProblem = nil
            macId = startMac ?? model.creationMacs.filter(\.reachable).first.map(\.id)
            if let startFolder { folder = startFolder }
        }
        .task(id: macId) { await readCards() }
        .task(id: [macId ?? "", checkAsk.folder, checkAsk.program ?? "", checkAsk.resume?.id ?? ""]) { await check() }
        .onChange(of: macId) { old, _ in
            if old != nil { folder = "~"; resuming = nil }
        }
    }

    private func shown(_ cards: [ConversationRow]) -> [ConversationRow] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = cards.sorted { ($0.written ?? 0) > ($1.written ?? 0) }
        let found = words.isEmpty ? sorted : sorted.filter {
            [$0.name, $0.folder, $0.ref.id].compactMap { $0 }.joined(separator: " ").lowercased().contains(words)
        }
        return Array(found.prefix(30))
    }

    private func cardDetail(_ card: ConversationRow) -> String {
        let place = card.holdings.first.map { "\($0.how.words) · \($0.mac)" } ?? "nowhere"
        return [card.folder.map(Create.caption), place].compactMap { $0 }.joined(separator: " · ")
    }

    /// The chosen Mac asked what it lacks for what is chosen now; a newer
    /// choice supersedes it (the task is cancelled).
    private func check() async {
        checkProblem = nil
        guard let macId else { return }
        let ask = checkAsk
        do {
            let answer = try await model.startCheck(ask, onMac: macId)
            guard !Task.isCancelled else { return }
            checked = (ask, answer)
        } catch {
            guard !Task.isCancelled else { return }
            checkProblem = "\(error)"
        }
    }

    private func readCards() async {
        cards = nil
        cardsProblem = nil
        guard let macId else { return }
        do { cards = try await model.conversations(onMac: macId) } catch {
            cardsProblem = "Its conversations were not read: \(error)"
        }
    }

    @ViewBuilder private var folderSection: some View {
        Section {
            folderRow("~")
            if let startFolder, startMac == macId, startFolder != "~" { folderRow(startFolder) }
            ForEach(macId.map { model.recentFolders(onMac: $0) }?.filter { $0 != startFolder }.prefix(6).map { $0 } ?? [], id: \.self) {
                folderRow($0)
            }
            TextField("Another folder: /path or ~/path", text: $typedFolder)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
        } header: {
            Text("Folder")
        } footer: {
            if let mac { Text("Recent folders are where \(mac.name)'s panes work. A folder that is gone starts in its nearest parent.") }
        }
    }

    private func folderRow(_ path: String) -> some View {
        choice(selected: typedFolder.isEmpty && folder == path) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Create.caption(path))
                if path != "~" { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
        } action: {
            folder = path
            typedFolder = ""
        }
    }

    @ViewBuilder private var commandSection: some View {
        Section {
            commandRow(nil)
            ForEach(commands, id: \.self) { commandRow($0) }
            TextField("Another program", text: $typedCommand)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
        } header: {
            Text("Runs")
        } footer: {
            Text(chosenCommand.map { "The pane runs `\($0)` in a login shell and closes when it exits." } ?? "A login shell.")
        }
    }

    private var commands: [String] {
        let presets = Create.presets.map(\.command)
        let known = macId.map { model.knownCommands(onMac: $0) } ?? []
        return presets + known.filter { !presets.contains($0) }.prefix(4)
    }

    private func commandRow(_ value: String?) -> some View {
        choice(selected: typedCommand.isEmpty && command == value) {
            Text(Create.name(of: value))
        } action: {
            command = value
            typedCommand = ""
        }
    }

    private func choice<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content,
                                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                content()
                Spacer()
                if selected { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What will happen, said whole, and the one button that does it.
    private var createBar: some View {
        VStack(spacing: 6) {
            if let failure = model.creationProblem {
                Text(failure).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            } else if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                if let writer, let resuming, let macId {
                    Button("Move It to \(mac?.name ?? "this Mac")…") { model.move(resuming, running: writer, toMac: macId) }
                }
            } else if let answer, let mac {
                // What it lacks that does not stop it (a folder that is gone).
                ForEach(answer.lacks(on: mac.name, program: checkAsk.program), id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.creationBusy ? "Creating…" : "Create and Open", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || model.creationBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func create() {
        guard problem == nil, let macId else { return }
        model.creationProblem = nil
        model.create(plan, onMac: macId) { close() }
    }
}
