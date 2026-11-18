import AppKit
import Combine
import SwiftUI
import VigilWire

/// The dialog of a move (PORTABILITY.md "Before anything moves, what it
/// depends on"): what stands between a workspace and the Mac it moves to,
/// each thing said once for all the panes it holds back and with what
/// settles it beside it, then the panes and what opening each does there.
/// A Bring Here is the move to this Mac; a Move to names another, which
/// reads the sheet itself (`Open.bringSheet`).
///
/// Nothing in it waits for a button. Its facts are two Macs': the
/// workspace's own Mac says what its panes depend on (their work, in the
/// directory this Mac follows), and the Mac it moves to says what it lacks.
/// The sheet is read again whenever either moves: the source's directory
/// changing (`sources`, followed from `VigilRemote`), and on this Mac what
/// the sheet reads changing (`changes`, vigil-agent's `BringWatch`: a
/// checkout, a folder arriving, a transcript). Opening it asks the source
/// to read its panes' work now (`work-read`, said in both Macs' logs), so
/// the sheet says as of when, not as of the last change. A source with an
/// older vigil is said to be one, and never asked.
///
/// What can be settled where is the need's own fact (`Bring.Need.Kind`): a
/// repository the target lacks is cloned there, a commit it lacks is fetched
/// there, a clean checkout behind is moved forward there (from this dialog
/// only when the target is this Mac: on another Mac it is its person's to
/// start), and work that exists only on the workspace's own Mac
/// (uncommitted, unpushed, a stash) is settled on it, so its row opens a
/// pane of that repository there.
@MainActor
final class BringDialogModel: ObservableObject {
    let workspace: String
    let anchor: String
    let part: Registry.Workspace.Part?
    /// The workspace's own Mac, by name ("this Mac" when it is this one).
    let mac: String
    /// The Mac it moves to; nil: this Mac (a Bring Here).
    let target: String?
    let what: String
    /// The target's home folder, how its lines name folders.
    let home: String

    /// Where the sheet's facts come from (`BringDialogModel.Sources`).
    let sources: Sources

    /// Whether this dialog settles anything (only on this Mac).
    var settles: Bool { target == nil }
    /// The move's verb, on its button.
    var verb: String { target.map { "Move to \($0)" } ?? "Bring Here" }
    /// The Mac the lines' "this Mac" is, in a sentence.
    var destination: String { target ?? "this Mac" }

    @Published private(set) var lines: [Bring.Line] = []
    /// The workspace's Mac as this Mac hears it now.
    @Published private(set) var source: Standing = .live
    /// A need being settled, by its text: what is being done.
    @Published private(set) var working: [String: String] = [:]
    /// A need whose settling failed, by its text: why.
    @Published private(set) var failed: [String: String] = [:]
    @Published private(set) var readError: String?
    /// The last read asked of the source, and how it went.
    @Published private(set) var asked: Asked?

    /// How the dialog ends: brought or not, or toward a pane on the other Mac.
    var close: (Outcome) -> Void = { _ in }
    /// `bring` carries the checkout differences the person saw and accepts
    /// (`Bring.checkoutRevision` of the sheet on screen; empty when none
    /// stood), which the commit checks its own sheet against.
    enum Outcome { case cancel, bring(checkoutRevision: String), open(pane: String) }

    /// The workspace's Mac, as heard: here (live), out of reach since when
    /// (what it said then is what the sheet holds), or this Mac itself.
    enum Standing: Equatable { case live, away(since: String), here }

    /// A read asked of the source (`work-read`): answered when, changing
    /// what; refused and why; or not asked, and why not.
    enum Asked: Equatable {
        case asking
        case answered(at: Date, changed: Int)
        case failed(String)
        case older
    }

    /// Where its facts come from, each event-driven:
    /// - `question`: the panes as the source's directory says them now, or
    ///   nil when that Mac no longer lists the workspace; with whether it is
    ///   heard, as `VigilRemote` holds them.
    /// - `heard`: an element each time the source's directory changes.
    /// - `read`: the sheet for a question, with what to settle here first.
    /// - `changes`: the watch of what the sheet reads on the Mac it moves to
    ///   (this Mac's `BringWatch`): `ready` once it stands, `changed` at each
    ///   fact that may have moved, `ended` with why; nil: that Mac is
    ///   another, which keeps no watch for this dialog.
    /// - `askSource`: a read asked of the source (nil: the source is this
    ///   Mac, whose work book keeps its facts current).
    struct Sources {
        var question: @MainActor () -> (question: Bring.Question, standing: Standing)?
        var heard: AnyPublisher<Void, Never>
        var read: @Sendable (Bring.Question, [Bring.Need]) throws -> Bring.Answer
        var changes: (@Sendable (Bring.Question) -> AsyncStream<Local.BringStep>)?
        var askSource: (@Sendable ([String]) throws -> WorkRead.Answer)?
    }

    /// The repository whose changes the dialog shows in the list's place;
    /// nil: the list.
    @Published var showing: Bring.Group?
    /// A repository's top level as its own Mac names it, from this Mac's
    /// name for it.
    var there: (String) -> String = { $0 }
    /// The view of what a repository holds there, from whoever can read it
    /// (the app: the Changes view over the hub).
    var changes: ((Bring.Group) -> AnyView)?

    private var question: Bring.Question?
    /// What the watch on the Mac it moves to watches: a new set of folders
    /// and conversations is a new watch.
    private var watching: Set<String>?
    private var watch: Task<Void, Never>?
    private var heard: AnyCancellable?
    /// One read in flight; another asked meanwhile runs after it.
    private var reading = false
    private var again = false

    init(workspace: String, anchor: String, part: Registry.Workspace.Part?, mac: String, target: String?, what: String,
         home: String, sources: Sources) {
        self.workspace = workspace
        self.anchor = anchor
        self.part = part
        self.mac = mac
        self.target = target
        self.what = what
        self.home = home
        self.sources = sources
    }

    /// The sheet as it stands now, then followed until the dialog closes;
    /// false when the source no longer lists the workspace.
    func open() -> Bool {
        guard let now = sources.question() else { return false }
        source = now.standing
        question = now.question
        heard = sources.heard.receive(on: DispatchQueue.main).sink { [weak self] in
            MainActor.assumeIsolated { self?.sourceMoved() }
        }
        // Read now, and again once the watch here stands (`ready`): what
        // moves in between is in the second read. Nothing can be brought
        // until a read has answered (`sheetRead`).
        rewatch()
        reload()
        askSourceNow()
        return true
    }

    /// What the source answered when asked to read again, by pane: a receipt
    /// only. The sheet reads the directory, as the move itself does, so the
    /// two never judge different facts; the answer says whether the
    /// directory has caught up with it (`caughtUp`).
    private var answers: [String: PaneWork] = [:]

    /// Every answered pane's work is what the directory now carries.
    var caughtUp: Bool {
        guard let question else { return false }
        return answers.allSatisfy { pane, answered in
            question.panes.first { $0.pane == pane }?.work.map { $0.same(as: answered) || $0.at > answered.at } ?? false
        }
    }

    /// A sheet has been read for this dialog and the last read answered:
    /// until then nothing can be brought (Return takes nothing).
    @Published private(set) var sheetRead = false

    /// The move can be asked: a sheet read, its last read answered.
    var canMove: Bool { sheetRead && readError == nil }

    /// The watch here ended (the hub went, or refused): why, until it is
    /// made again.
    @Published private(set) var watchLost: String?

    /// Everything it follows let go (the dialog closed).
    func stop() {
        heard?.cancel()
        heard = nil
        watch?.cancel()
        watch = nil
    }

    /// The source's directory moved: the sheet is read again when what it
    /// says of these panes did.
    private func sourceMoved() {
        guard let now = sources.question() else {
            readError = "\(mac) no longer lists it"
            lifecycleLog.warn("bring: the source no longer lists the workspace", ["workspace": workspace, "mac": mac])
            return
        }
        let wasAway = source != .live
        source = now.standing
        // Back in reach: the facts it publishes from now are current; ask
        // once more for when.
        if wasAway, source == .live { askSourceNow() }
        let next = now.question
        // A watch here that ended is made again at the next word of the
        // hubs (this Mac's hub back up republishes its Macs).
        let rewatched = rewatch(for: next)
        guard next.panes != question?.panes else { return }
        // A pane's last activity moves with every turn there and is no fact
        // this Mac reads: it is carried onto the lines, never a re-read (a
        // sheet read is a few git runs per repository, ~3 s measured on a
        // busy Mac, 2026-11-18).
        let still = { (panes: [Bring.Pane]) in panes.map { var pane = $0; pane.active = nil; return pane } }
        let onlyActivity = question.map { still($0.panes) == still(next.panes) } ?? false
        question = next
        if onlyActivity {
            let active = Dictionary(next.panes.map { ($0.pane, $0.active) }, uniquingKeysWith: { first, _ in first })
            lines = lines.map { var line = $0; line.active = active[line.pane] ?? line.active; return line }
            return
        }
        if !rewatched { reload() }
    }

    /// The watch on the Mac it moves to, made again when what it watches
    /// changes (a repository, a folder, a conversation of another pane) or
    /// after it ended; whether one was made (its `ready` reads the sheet).
    @discardableResult
    private func rewatch(for asked: Bring.Question? = nil) -> Bool {
        guard let changes = sources.changes, let question = asked ?? question else { return false }
        var wanted = Set<String>()
        for pane in question.panes {
            wanted.insert(pane.cwd)
            if let conversation = pane.conversation { wanted.insert(conversation) }
            let repos: [String] = pane.work?.repos.map(\.root) ?? []
            let unread: [String] = pane.work?.unread?.map(\.root) ?? []
            wanted.formUnion(repos + unread)
        }
        guard wanted != watching || watchLost != nil else { return false }
        watching = wanted
        watch?.cancel()
        watchLost = nil
        // Followed on the main actor: each step reads the sheet again for
        // the question as it stands then; an end is said and kept until the
        // watch is made again.
        let stream = changes(question)
        let named = workspace
        watch = Task { [weak self] in
            for await step in stream {
                guard let self else { return }
                switch step {
                case .ready, .changed:
                    self.reload()
                case .ended(let why):
                    self.watchLost = why
                    lifecycleLog.warn("bring: this Mac's facts are no longer followed", ["workspace": named, "why": why])
                }
            }
        }
        return true
    }

    /// Every distinct need with the panes it holds back, in the order a
    /// person settles them (`Bring.standing`, the command line's order too).
    var standing: [Bring.Standing] { Bring.standing(lines) }

    var unknown: Bool { lines.contains { $0.work == nil } }

    /// What the source's facts are worth (`Bring.Currency`).
    var currency: Bring.Currency { Bring.Currency.of(lines) }

    /// The sheet read again, by the Mac it moves to, for the question as it
    /// stands; with `settling` (this Mac only), vigil-agent first does those
    /// (a clone, a fetch, a fast-forward: the one place they are done, `vigil
    /// workspace move --settle` too). Off the main thread: a clone takes as
    /// long as it takes.
    func reload(settling needs: [Bring.Need] = [], saying: String = "") {
        precondition(needs.isEmpty || settles, "only this Mac's own dialog settles")
        guard let question else { return }
        for need in needs {
            working[need.text] = saying
            failed[need.text] = nil
        }
        // A plain re-read waits for the one in flight, then runs once more.
        guard needs.isEmpty ? !reading : true else {
            again = true
            return
        }
        if needs.isEmpty { reading = true }
        let read = sources.read
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try read(question, needs) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.read(result, settled: needs, plain: needs.isEmpty) }
            }
        }
    }

    private func read(_ result: Result<Bring.Answer, any Error>, settled needs: [Bring.Need], plain: Bool) {
        for need in needs { working[need.text] = nil }
        switch result {
        case .success(let answer):
            took(answer.lines)
            failed.merge(answer.failed) { _, new in new }
            readError = nil
            sheetRead = true
            lastRead = Date()
        case .failure(let error):
            // Said, and nothing can be brought on a sheet that did not read.
            readError = "\(target ?? "vigil-agent") did not answer, so nothing can be moved until it does: \(error)"
            lifecycleLog.error("bring: sheet not read", ["workspace": workspace, "mac": mac, "to": destination, "err": error])
        }
        guard plain else { return }
        reading = false
        if again {
            again = false
            reload()
        }
    }

    /// A sheet that reads differently than the last: what came and went, in
    /// the log (the first one in full).
    private func took(_ now: [Bring.Line]) {
        let before = Set(lines.flatMap(\.lacks))
        let after = Set(now.flatMap(\.lacks))
        let first = lines.isEmpty && !now.isEmpty
        lines = now
        if first {
            lifecycleLog.info("bring: sheet opened", [
                "workspace": workspace, "mac": mac, "to": destination, "panes": now.count, "needs": after.sorted(),
                "unknown": now.filter { $0.work == nil }.count, "watched": currency.watched,
            ])
        } else if before != after {
            lifecycleLog.info("bring: sheet changed", [
                "workspace": workspace, "mac": mac, "came": after.subtracting(before).sorted(), "went": before.subtracting(after).sorted(),
            ])
        }
    }

    /// The source asked to read its panes' work now: only where it is heard
    /// and every pane's facts come from a vigil that answers
    /// (`PaneWork.answersReads`: a Mac that published none, or an older one,
    /// is never asked); else said why not.
    func askSourceNow() {
        guard let ask = sources.askSource, let question else { return }
        guard source == .live else { return }
        let works = question.panes.compactMap(\.work)
        guard works.count == question.panes.count, works.allSatisfy(\.answersReads) else {
            asked = .older
            lifecycleLog.info("bring: the source runs an older vigil or published no work, not asked to read again", [
                "workspace": workspace, "mac": mac, "published": works.count, "panes": question.panes.count,
            ])
            return
        }
        asked = .asking
        let panes = question.panes.map(\.pane)
        lifecycleLog.info("bring: asking the source to read its work again", ["workspace": workspace, "mac": mac, "panes": panes.count])
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ask(panes) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let answer):
                        self.asked = .answered(at: Date(timeIntervalSince1970: answer.at), changed: answer.changed.count)
                        lifecycleLog.info("bring: the source read its work again", [
                            "workspace": self.workspace, "mac": self.mac, "read": answer.works.count, "changed": answer.changed,
                        ])
                        // A receipt: the sheet stays on the directory, which
                        // the header says has, or has not yet, caught up.
                        self.answers.merge(answer.works) { _, new in new }
                    case .failure(let error):
                        let said = "\(error)"
                        self.asked = said.contains(Open.unknownOp) ? .older : .failed(said)
                        lifecycleLog.warn("bring: the source did not read its work again", ["workspace": self.workspace, "mac": self.mac, "err": said])
                    }
                }
            }
        }
    }

    /// The same needs as a person settles them: a repository once, with
    /// everything about it (`Bring.groups`, the command line's sheet too).
    var groups: [Bring.Group] { Bring.groups(lines) }

    /// What this Mac does about a repository by itself, as its button says
    /// it; nil: nothing here does.
    func hereAction(for group: Bring.Group) -> String? {
        guard settles, let need = group.here.first else { return nil }
        switch need.kind {
        case .clone: return "Clone Here"
        case .fetch: return "Fetch"
        case .submodule: return "Check Out Here"
        default: return "Fast-Forward Here"
        }
    }

    /// What is being done about a repository right now, in words.
    func working(on group: Bring.Group) -> String? {
        group.needs.lazy.compactMap { self.working[$0.text] }.first
    }

    func settleHere(_ group: Bring.Group) {
        guard let need = group.here.first else { return }
        lifecycleLog.info("bring: settling here", ["workspace": workspace, "need": need.text, "kind": need.kind.rawValue])
        let saying = switch need.kind {
        case .clone: "Cloning…"
        case .fetch: "Fetching…"
        case .submodule: "Checking out…"
        default: "Moving forward…"
        }
        reload(settling: [need], saying: saying)
    }

    /// Work that is only on its Mac is settled where it is: a pane of that
    /// repository, there.
    func openThere(_ group: Bring.Group) {
        guard let pane = group.panes.first?.pane else { return }
        lifecycleLog.info("bring: opening the pane that holds what is only there", ["pane": pane, "mac": mac, "repository": group.root ?? ""])
        answer(.open(pane: pane))
    }

    /// What a repository holds there, read from its Mac by the Changes view
    /// (the same reader the sheet's counts come from).
    func showChanges(_ group: Bring.Group) {
        guard group.root != nil, !group.panes.isEmpty else { return }
        lifecycleLog.info("bring: showing what a repository holds there", ["mac": mac, "repository": group.root ?? ""])
        showing = group
    }

    /// Everything this Mac can do by itself, at once (`vigil move --settle`):
    /// a clone and a fetch before a fast-forward, which needs the commit.
    var settledHere: [Bring.Need] { settles ? standing.map(\.need).filter { $0.settledHere && $0.kind != .fastForward } : [] }
    /// A Move to's target asked to read its sheet again (`bring-sheet`, said
    /// in its log).
    func readAgain() {
        lifecycleLog.info("bring: asking the target to read the sheet again", ["workspace": workspace, "to": destination])
        reload()
    }

    func settleAllHere() {
        lifecycleLog.info("bring: settling everything this Mac can", ["workspace": workspace, "needs": settledHere.map(\.text)])
        reload(settling: settledHere, saying: "Working…")
    }

    /// The person's answer, said in the log with what it leaves standing.
    func answer(_ outcome: Outcome) {
        switch outcome {
        case .bring(let revision):
            let standing = self.standing.map(\.need.text)
            lifecycleLog.info(standing.isEmpty ? "bring: brought" : "bring: brought anyway", [
                "workspace": workspace, "mac": mac, "to": destination, "overrides": standing,
                "unknown": lines.filter { $0.work == nil }.count, "checkout": revision,
            ])
        case .cancel:
            lifecycleLog.info("bring: cancelled", ["workspace": workspace, "mac": mac, "to": destination])
        case .open:
            break
        }
        stop()
        close(outcome)
    }

    /// Where the source's facts stand, in one sentence.
    var currencySaid: String? {
        let facts = currency
        var said = ""
        if case .away(let heard) = source { said = "\(mac) is away: this is what it said as of \(heard). " }
        if let target {
            // A Move to: the target reads the sheet itself, from what it last
            // heard of the workspace's Mac and from its own checkouts, none of
            // which this Mac follows.
            said += "\(target) reads this from what it last heard of \(mac) and from its own checkouts; this Mac asks it again when \(mac) moves as this Mac hears it, never when \(target)'s checkouts change."
            if let at = lastRead { said += " Last read there at \(Self.clock(at))." }
            return said
        }
        if source != .here, let changed = facts.changed {
            said += "\(mac): " + Bring.Currency.said(facts, since: Self.clock(Date(timeIntervalSince1970: changed))) + "."
            switch asked {
            case .answered(let at, _):
                said += caughtUp ? " Read again there at \(Self.clock(at)), and its directory carries that read."
                    : " Read again there at \(Self.clock(at)); its directory does not carry that read yet, so the sheet is as of before it."
            case .asking: said += " Asking it to read them again…"
            case .failed(let why): said += " It did not read them again: \(why)"
            case .older, nil: break
            }
        }
        // This Mac's half: followed while the watch stands, whatever the
        // source's facts say.
        if let lost = watchLost {
            said += (said.isEmpty ? "" : " ") + "What this Mac holds is no longer followed (\(lost)): as of the last read."
        }
        return said.isEmpty ? nil : said
    }

    /// When the sheet last read (a Move to's: when the target last answered).
    @Published private(set) var lastRead: Date?

    static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? Self.hour.string(from: date) : Self.day.string(from: date)
    }

    private static let hour: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("HHmmss")
        return format
    }()
    private static let day: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("dMMMHHmm")
        return format
    }()
}

struct BringDialog: View {
    @ObservedObject var model: BringDialogModel
    static let width: CGFloat = 540
    static let tallest: CGFloat = 520
    /// The dialog while it shows a repository's changes: wide enough for a
    /// diff's lines in the browser's one column, no wider than a small
    /// window.
    static let changesSize = CGSize(width: 760, height: 620)
    @State private var listHeight: CGFloat = 0

    var body: some View {
        if let group = model.showing {
            changes(group)
        } else {
            sheet
        }
    }

    private var away: Bool { if case .away = model.source { true } else { false } }

    /// What a repository holds on the other Mac, in the sheet's own place:
    /// the dialog stays the dialog (wider, for a diff's lines), nothing else
    /// on screen moves, and the way back keeps the sheet as it was.
    private func changes(_ group: Bring.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { model.showing = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.title(home: model.home)) on \(model.mac)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(group.needs.compactMap(\.brief).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if group.there, !away {
                    Button("Open on \(model.mac)") { model.openThere(group) }
                        .help("Open a pane of it on \(model.mac), to commit and push there")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            (model.changes?(group) ?? AnyView(EmptyView()))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.changesSize.width, height: Self.changesSize.height)
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.target.map { "Move \(model.what) from \(model.mac) to \($0)" } ?? "Bring \(model.what) here from \(model.mac)")
                    .font(.system(size: 14, weight: .semibold))
                Text("Nothing runs until you open a pane" + (model.target.map { " on \($0)." } ?? "."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let said = model.currencySaid {
                    Label(said, systemImage: currencySymbol).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.readError {
                        Label(error, systemImage: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(.red)
                    }
                    let groups = model.groups
                    if !groups.isEmpty {
                        section("Before it moves", "What \(model.destination) lacks, or \(model.mac) alone has. Moving it anyway leaves these as they are.") {
                            ForEach(groups) { row($0) }
                        }
                    }
                    let quiet = Bring.notAtRisk(model.lines)
                    if !quiet.isEmpty {
                        section("Changed there, not at risk", "Held by another repository, or holding nothing: nothing stands in the way.") {
                            ForEach(quiet) { repo in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Bring.Group.title(repo.root, home: model.home))
                                        .font(.system(size: 12, weight: .medium))
                                    ForEach(repo.said, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary) }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    section(!model.sheetRead ? "Reading what \(model.destination) lacks…" : groups.isEmpty ? "Nothing stands in the way" : "Its panes", nil) {
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // A scroll view has no height of its own: it takes its list's,
            // up to what a sheet may stand tall.
            .frame(height: min(max(listHeight, 1), Self.tallest))

            Divider()
            HStack(spacing: 10) {
                // Asked again only after an ask that failed: otherwise the
                // facts follow by themselves.
                if case .failed = model.asked, model.source == .live {
                    Button { model.askSourceNow() } label: { Label("Ask \(model.mac) Again", systemImage: "arrow.clockwise") }
                        .help("Ask \(model.mac) to read these panes' work again now")
                }
                // A Move to's target is not followed from here: asking it to
                // read again is a real ask, answered and logged there.
                if let target = model.target {
                    Button { model.readAgain() } label: { Label("Read Again on \(target)", systemImage: "arrow.clockwise") }
                        .help("Ask \(target) to read this sheet again from what it holds now")
                }
                if model.settledHere.count > 1 {
                    Button { model.settleAllHere() } label: { Label("Settle What This Mac Can", systemImage: "arrow.down.circle") }
                        .help("Clone and fetch everything listed that this Mac can get by itself")
                        .disabled(!model.working.isEmpty)
                }
                Spacer()
                Button("Cancel") { model.answer(.cancel) }.keyboardShortcut(.cancelAction)
                if !model.canMove {
                    // No sheet read, or the last read failed: there is nothing
                    // to accept, so nothing to bring.
                    Button(model.verb) {}.disabled(true)
                        .help(model.sheetRead ? "The sheet did not read again: nothing can be moved until it does" : "Reading the sheet…")
                } else if model.standing.isEmpty {
                    Button(model.verb) { model.answer(.bring(checkoutRevision: "")) }.keyboardShortcut(.defaultAction)
                } else {
                    // Never the default while something stands: Return must
                    // not leave work behind on the other Mac.
                    Button(model.settles ? "Bring Anyway" : "Move Anyway") {
                        model.answer(.bring(checkoutRevision: Bring.checkoutRevision(model.lines)))
                    }
                        .help("Move it though \(model.destination) lacks what is listed")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: Self.width)
    }

    private var currencySymbol: String {
        switch model.source {
        case .away: "moon.zzz"
        case .here, .live: model.currency.watched && model.watchLost == nil ? "checkmark.circle" : "clock.badge.exclamationmark"
        }
    }

    private func section<Rows: View>(_ title: String, _ about: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let about {
                    Text(about).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            rows()
        }
    }

    /// One repository (or one need of none): its name, everything about it a
    /// line each, the panes it holds back, and beside it what settles it.
    private func row(_ group: Bring.Group) -> some View {
        let kind = group.here.first?.kind ?? group.needs[0].kind
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(kind)).font(.system(size: 11)).foregroundStyle(Self.tint(kind)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title(home: model.home)).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if group.root != nil {
                    ForEach(group.needs, id: \.text) { need in
                        Text(need.brief ?? need.text).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let problem = model.failed[need.text] {
                            Text(problem).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if group.there, case .away(let since) = model.source {
                    Text("\(model.mac) is away since \(since): it is settled there when it is back.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("For \(group.held)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let working = model.working(on: group) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if let action = model.hereAction(for: group) {
                        Button(action) { model.settleHere(group) }.controlSize(.small)
                    }
                    if group.there, !away {
                        Button("Show Changes") { model.showChanges(group) }.controlSize(.small)
                            .help("What it holds on \(model.mac), here in the dialog")
                        Button("Open on \(model.mac)") { model.openThere(group) }.controlSize(.small)
                            .help("Open a pane of it on \(model.mac), to commit and push there")
                    }
                }
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
                Text(line.name ?? Directory.folder(line.folder, home: model.home))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(line.opens).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let idle = line.idle() {
                Text(idle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !line.needs.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    .help(line.lacks.joined(separator: "\n"))
            }
        }
    }

    private static func symbol(_ kind: Bring.Need.Kind) -> String {
        switch kind {
        case .clone: "arrow.down.circle.fill"
        case .fetch: "arrow.triangle.2.circlepath.circle.fill"
        case .fastForward: "forward.end.circle.fill"
        case .submodule: "shippingbox"
        case .position: "arrow.triangle.branch"
        case .thereOnly: "exclamationmark.triangle.fill"
        case .folder: "folder.badge.questionmark"
        case .transcript: "text.bubble"
        case .running: "bolt.fill"
        }
    }

    private static func tint(_ kind: Bring.Need.Kind) -> Color {
        switch kind {
        case .clone, .fetch, .fastForward, .submodule, .position, .thereOnly, .folder: .orange
        case .transcript, .running: .secondary
        }
    }
}
