import AppKit
import SwiftUI
import VigilWire

/// The dialog of a Bring Here (PORTABILITY.md "Before anything moves, what it
/// depends on"): what stands between a workspace of another Mac and this
/// one, each thing said once for all the panes it holds back and with what
/// settles it beside it, then the panes and what opening each does here.
///
/// What can be settled where is the need's own fact (`Bring.Need.Kind`): a
/// repository this Mac lacks is cloned here, a commit it lacks is fetched
/// here, and work that exists only on the other Mac (uncommitted, unpushed,
/// a stash) is settled there, so its row opens a pane of that repository on
/// that Mac. After any of them the sheet is read again from what that Mac
/// publishes; nothing here is remembered.
@MainActor
final class BringDialogModel: ObservableObject {
    let device: String
    let workspace: String
    let anchor: String
    let part: Registry.Workspace.Part?
    let mac: String
    let what: String
    let away: String?

    @Published private(set) var lines: [Bring.Line]
    /// A need being settled, by its text: what is being done.
    @Published private(set) var working: [String: String] = [:]
    /// A need whose settling failed, by its text: why.
    @Published private(set) var failed: [String: String] = [:]
    @Published private(set) var readError: String?

    /// How the dialog ends: brought or not, or toward a pane on the other Mac.
    var close: (Outcome) -> Void = { _ in }
    enum Outcome { case cancel, bring, open(pane: String) }

    init(device: String, workspace: String, anchor: String, part: Registry.Workspace.Part?, mac: String, what: String,
         away: String?, lines: [Bring.Line]) {
        self.device = device
        self.workspace = workspace
        self.anchor = anchor
        self.part = part
        self.mac = mac
        self.what = what
        self.away = away
        self.lines = lines
    }

    /// Every distinct need with the panes it holds back, in the order a
    /// person settles them (`Bring.standing`, the command line's order too).
    var standing: [Bring.Standing] { Bring.standing(lines) }

    var unknown: Bool { lines.contains { $0.work == nil } }

    /// The sheet read again, from what this Mac holds and that Mac publishes
    /// now; with `settling`, vigil-agent first does those (a clone, a fetch:
    /// the one place they are done, `vigil move --settle` too). Asked off the
    /// main thread: a clone takes as long as it takes.
    func reload(settling needs: [Bring.Need] = [], saying: String = "") {
        guard let host = VigilRemote.shared.host(device), let directory = host.directory,
              let whole = directory.live.first(where: { $0.name == workspace }),
              let source = part.map({ whole.only($0, of: anchor) }) ?? whole else {
            readError = "\(mac) no longer lists it."
            return
        }
        let question = Bring.Question(
            panes: directory.bringing(source, here: FileManager.default.homeDirectoryForCurrentUser.path), commit: false,
            settle: needs.isEmpty ? nil : needs)
        for need in needs {
            working[need.text] = saying
            failed[need.text] = nil
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Local.Client(socket: VigilPaths.hub).bring(question) }
            DispatchQueue.main.async {
                for need in needs { self.working[need.text] = nil }
                switch result {
                case .success(let answer):
                    self.lines = answer.lines
                    self.failed.merge(answer.failed) { _, new in new }
                    self.readError = nil
                case .failure(let error):
                    self.readError = "vigil-agent did not answer: \(error)"
                }
            }
        }
    }

    /// What this Mac does about a need by itself, as its button says it; nil:
    /// nothing here does.
    func action(for need: Bring.Need) -> String? {
        switch need.kind {
        case .clone: need.remote != nil && need.root != nil ? "Clone Here" : nil
        case .fetch: need.root != nil ? "Fetch" : nil
        case .thereOnly: away == nil ? "Open on \(mac)" : nil
        case .folder, .transcript, .running: nil
        }
    }

    func settle(_ standing: Bring.Standing) {
        let need = standing.need
        switch need.kind {
        case .clone:
            reload(settling: [need], saying: "Cloning…")
        case .fetch:
            reload(settling: [need], saying: "Fetching…")
        case .thereOnly:
            // Settled where it is: a pane of that repository, on its Mac.
            guard let pane = standing.panes.first?.pane else { return }
            lifecycleLog.info("bring: opening the pane that holds what is only there", ["pane": pane, "mac": mac, "need": need.text])
            close(.open(pane: pane))
        case .folder, .transcript, .running:
            break
        }
    }

    /// Everything this Mac can do by itself, at once (`vigil move --settle`).
    var settledHere: [Bring.Need] { standing.map(\.need).filter(\.settledHere) }
    func settleAllHere() { reload(settling: settledHere, saying: "Working…") }
}

struct BringDialog: View {
    @ObservedObject var model: BringDialogModel
    static let width: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bring \(model.what) here from \(model.mac)").font(.system(size: 14, weight: .semibold))
                Text("Nothing runs until you open a pane." + (model.away.map { " \(model.mac) is away: this is as of \($0)." } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.readError {
                        Label(error, systemImage: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(.red)
                    }
                    let standing = model.standing
                    if !standing.isEmpty {
                        section("Before it moves", "What this Mac lacks, or \(model.mac) alone has. Bringing it anyway leaves these as they are.") {
                            ForEach(standing) { row($0) }
                        }
                    }
                    section(standing.isEmpty ? "Nothing stands in the way" : "Its panes", nil) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in pane(line) }
                        if model.unknown {
                            Label(Bring.Line.workNotKnown, systemImage: "questionmark.circle")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 14)
            }
            .frame(maxHeight: 420)

            Divider()
            HStack(spacing: 10) {
                Button { model.reload() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .help("Read again what this Mac holds and what \(model.mac) publishes")
                if model.settledHere.count > 1 {
                    Button { model.settleAllHere() } label: { Label("Settle What This Mac Can", systemImage: "arrow.down.circle") }
                        .help("Clone and fetch everything listed that this Mac can get by itself")
                        .disabled(!model.working.isEmpty)
                }
                Spacer()
                Button("Cancel") { model.close(.cancel) }.keyboardShortcut(.cancelAction)
                if model.standing.isEmpty {
                    Button("Bring Here") { model.close(.bring) }.keyboardShortcut(.defaultAction)
                } else {
                    // Never the default while something stands: Return must
                    // not leave work behind on the other Mac.
                    Button("Bring Anyway") { model.close(.bring) }
                        .help("Bring it though this Mac lacks what is listed")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: Self.width)
    }

    private func section<Rows: View>(_ title: String, _ about: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let about {
                    Text(about).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            rows()
        }
    }

    /// One need: its mark, its sentence, the panes it holds back, and what
    /// settles it.
    private func row(_ standing: Bring.Standing) -> some View {
        let need = standing.need
        let working = model.working[need.text]
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(need.kind)).font(.system(size: 11)).foregroundStyle(Self.tint(need.kind)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(need.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text(Self.held(standing.panes)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                if need.kind == .thereOnly, let away = model.away {
                    Text("\(model.mac) is away since \(away): it is settled there when it is back.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let problem = model.failed[need.text] {
                    Text(problem).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let action = model.action(for: need) {
                Button(action) { model.settle(standing) }.controlSize(.small)
            }
        }
    }

    private func pane(_ line: Bring.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let agent = line.agent, AgentMark.knows(agent) {
                    AgentMark(agent: agent, size: 12)
                } else {
                    Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.name ?? Directory.folder(line.folder, home: NSHomeDirectory()))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(line.opens).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !line.needs.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    .help(line.lacks.joined(separator: "\n"))
            }
        }
    }

    private static func held(_ panes: [Bring.Line]) -> String {
        let names = panes.map { $0.name ?? Directory.folder($0.folder, home: NSHomeDirectory()) }
        return names.count <= 3
            ? "For " + names.joined(separator: ", ")
            : "For \(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more panes"
    }

    private static func symbol(_ kind: Bring.Need.Kind) -> String {
        switch kind {
        case .clone: "arrow.down.circle.fill"
        case .fetch: "arrow.triangle.2.circlepath.circle.fill"
        case .thereOnly: "exclamationmark.triangle.fill"
        case .folder: "folder.badge.questionmark"
        case .transcript: "text.bubble"
        case .running: "bolt.fill"
        }
    }

    private static func tint(_ kind: Bring.Need.Kind) -> Color {
        switch kind {
        case .clone, .fetch, .thereOnly, .folder: .orange
        case .transcript, .running: .secondary
        }
    }
}
