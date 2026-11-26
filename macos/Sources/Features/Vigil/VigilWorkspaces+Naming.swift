import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import Log
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Cycle / ordering / naming

    /// Modal-less cycling, cmd+backtick with the overview's order: focus
    /// moves through LIVE windows only (windowed workspaces by manual order,
    /// stray windows last), wrapping. Opening a background session
    /// is a deliberate act (overview, Next, the menu); a focus cycle key
    /// must never resurrect windows as a side effect.
    func cycle() {
        reconcile()
        let sessionWindows = workspaces.values
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .compactMap { session in focusWindow(of: session.name) }
        let strays = strayControllers().compactMap(\.window)
        let ring = sessionWindows + strays
        guard !ring.isEmpty else { return }

        var current = -1
        if let key = NSApp.keyWindow {
            current = ring.firstIndex { $0 === key || $0.tabGroup === key.tabGroup } ?? -1
        }
        let target = ring[(current + 1) % ring.count]
        becomeRegular()
        if target.isMiniaturized { target.deminiaturize(nil) }
        target.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Manual overview ordering (drag & drop).
    func setOrder(name: String, order: Int) {
        guard workspaces[name] != nil else { return }
        workspaces[name]!.order = order
        persist()
    }

    /// A label written with its face in front ("🎚️ Ink values", as a
    /// script or an agent writes a name): the face and the name apart. The
    /// face is the label's first character when that is an emoji; a label
    /// that is only an emoji, or leads with none, is a name alone.
    static func faced(_ label: String) -> (emoji: String?, label: String) {
        guard let first = label.first, let scalar = first.unicodeScalars.first,
              scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && first.unicodeScalars.count > 1)
        else { return (nil, label) }
        let rest = label.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (nil, label) : (String(first), rest)
    }

    func rename(name: String, label: String, emoji: String?) {
        guard workspaces[name] != nil else { return }
        workspaces[name]!.label = label
        workspaces[name]!.emoji = emoji
        persist()
    }

    func strayLabel(_ controller: TerminalController) -> String? {
        strayLabels[ObjectIdentifier(controller)]
    }

    func renameStray(_ controller: TerminalController, _ label: String) {
        strayLabels[ObjectIdentifier(controller)] = label
    }

    // MARK: Naming

    private nonisolated static let idAdjectives = [
        "amber", "bold", "brave", "bright", "calm", "clever", "cosmic", "crisp",
        "daring", "eager", "gentle", "jolly", "keen", "lively", "lucid", "merry",
        "mighty", "nimble", "noble", "proud", "quiet", "rapid", "royal", "sage",
        "sleek", "snowy", "solar", "spry", "stark", "sunny", "swift", "tidal",
        "vivid", "witty", "zesty",
    ]
    private nonisolated static let idNouns = [
        "otter", "panda", "falcon", "heron", "lynx", "badger", "cedar", "maple",
        "willow", "river", "harbor", "comet", "ember", "quartz", "canyon",
        "meadow", "glacier", "summit", "delta", "fjord", "grove", "dune", "reef",
        "tundra", "aurora", "nebula", "pulsar", "zephyr", "cobalt", "indigo",
        "onyx", "topaz", "raven", "sparrow", "marten",
    ]

    nonisolated static func randomName() -> String {
        "\(idAdjectives.randomElement()!)-\(idNouns.randomElement()!)"
    }

    func newWorkspaceId() -> String {
        let fm = FileManager.default
        var id = nameCandidate()
        while workspaces[id] != nil || graveyard[id] != nil || fm.fileExists(atPath: dumpsDir(id).path) {
            id = VigilRef.mintID()
        }
        return id
    }

    /// The identity key of the tab a window currently shows: its ANCHOR
    /// pane, the same key the sidebar uses, so both surfaces name the same
    /// thing.
    func tabIdentityKey(for controller: TerminalController) -> String? {
        controller.surfaceTree.compactMap(\.vigilAttachId).first.map { "tab:\($0)" }
    }

    /// ONE name per tab. The sidebar row and the native tab bar were two
    /// independent names for the same tab: the row showed the stored
    /// identity, the tab bar showed the raw terminal title (ghostty's 👻
    /// default when a swap left it stale), and ghostty's own Change Tab
    /// Title was a THIRD, unstored one. The stored identity is the name,
    /// and ghostty's titleOverride is how it reaches the tab bar.
    /// What a tab is CALLED, one answer for every surface that shows it
    /// (the native tab bar, the sidebar row, the rename prompt's seed).
    /// Two surfaces computing this separately is how a tab ends up as
    /// "Auto-play video thumbnails" in the tab bar and "tab 3" in the
    /// sidebar at the same time.
    func tabDisplayName(anchor: String) -> (emoji: String?, label: String?) {
        let custom = customIdentity("tab:\(anchor)")
        if let label = custom?.label, !label.isEmpty {
            return (custom?.emoji, label)
        }
        // Nothing typed: the tab still knows what it IS - its anchor's
        // remembered terminal title, then the program running there.
        return (custom?.emoji, capturedTitle(ofPane: anchor) ?? paneProgram(anchor))
    }

    func syncTabTitle(_ controller: TerminalController) {
        guard let key = tabIdentityKey(for: controller) else { return }
        // The title carries the NAME alone. The face renders in the face
        // control (tab accessory, sidebar), never inline in the label: an
        // emoji inside the title text inherited the label's dimmed color
        // and washed out, and the titlebar center is session territory.
        let name = tabDisplayName(anchor: String(key.dropFirst(4)))
        controller.titleOverride = (name.label?.isEmpty == false) ? name.label : nil

        if let window = controller.window { VigilTabFaces.sync(window) }
    }

    /// The inline tab-title editor's commit, kept in the one store so it
    /// survives, shows in the sidebar, and is never clobbered by a sync.
    /// Preserves the tab's face: renaming is not un-emoji-ing.
    /// True when the name was stored; false for a window of no workspace or
    /// a tab no workspace here owns (a mirror of another Mac's).
    @discardableResult
    func setTabLabel(_ controller: TerminalController, _ label: String?) -> Bool {
        guard let key = tabIdentityKey(for: controller) else { return false }
        return setCustomIdentity(key: key, label: label, emoji: customIdentity(key)?.emoji)
    }

    /// A pane's name set from outside the identity editor (AppleScript's
    /// terminal `name override`), stored on the pane like every other pane
    /// name. False when no workspace here owns the pane.
    @discardableResult
    func setPaneLabel(_ view: Ghostty.SurfaceView, _ label: String?) -> Bool {
        guard let id = view.vigilAttachId, view.vigilHost == nil, !view.vigilMirror else { return false }
        return namePane(id, label: label, emoji: customIdentity(id)?.emoji)
    }

    /// A pane of this host is named. Where an agent sits in it the name is
    /// the agent's (the broker's `agent.name`: it goes where the agent
    /// goes, and no name takes the person's back), and the pane keeps none
    /// of its own; a pane no agent holds, or one whose broker does not
    /// answer, is named as a place. Its emoji is the pane's either way.
    @discardableResult
    func namePane(_ id: String, label: String?, emoji: String?) -> Bool {
        var payload: [String: JSONValue] = ["pane": .string(id)]
        if let label, !label.isEmpty { payload["name"] = .string(label) }
        let agent = (try? HarnessWire.call(RPCRequest("agent.name", .object(payload))))?.ok == true
        registryLog.info("pane named", ["pane": id, "to": agent ? "its agent" : "the pane"])
        return setCustomIdentity(key: id, label: agent ? nil : label, emoji: emoji)
    }

    /// Rename the TAB shown in this window, through the one identity editor
    /// (emoji picker, transcript-aware suggestion, persisted). Replaces
    /// ghostty's plain text prompt for vigil windows.
    func promptTabIdentity(_ controller: TerminalController) -> Bool {
        guard let key = tabIdentityKey(for: controller) else { return false }
        let anchor = String(key.dropFirst(4))
        let current = customIdentity(key)
        let panes = controller.surfaceTree.compactMap(\.vigilAttachId)
        VigilIdentity.editModal(
            title: "Tab identity",
            label: current?.label ?? controller.window?.title ?? "",
            emoji: current?.emoji,
            context: "a terminal tab.\n" + workContext(panes: panes)
        ) { [weak self, weak controller] label, emoji in
            self?.setCustomIdentity(key: "tab:\(anchor)", label: label, emoji: emoji)
            if let controller { self?.syncTabTitle(controller) }
        }
        return true
    }

    /// What the sparkle (and the persist refinement) reasons from: cwd,
    /// current label, what the daemons actually run, the visible screen.
    func identityContext(name: String) -> String {
        guard let session = workspaces[name] else { return "" }
        let screen = anchorController(of: name)?.focusedSurface?.cachedScreenContents.get() ?? ""
        let running = runningSummary(of: name).joined(separator: ", ")
        let work = workContext(panes: Array(ownedPaneIds(session)))
        return "cwd: \(session.cwd)\ntitle: \(session.label)\nrunning: \(running)\n"
            + (work.isEmpty ? "" : "what is being worked on:\n\(work)\n")
            + "screen:\n\(screen.suffix(1500))"
    }

    /// The ACTUAL WORK in these panes, captured by the adapter from the
    /// agent's prompt event: what was asked, in the user's own words (a
    /// screen holds only what happens to be painted, and a cwd basename
    /// names every $HOME pane "adrian").
    func workContext(panes: [String]) -> String {
        // The opening ask and the latest ones of each pane's conversation,
        // as the broker keeps them from the agents' prompt hooks: Vigil
        // never depends on an agent vendor's private transcript schema.
        let held = Dictionary(Self.heldConversations().map { ($0.pane.raw, $0.conversation.asks) }, uniquingKeysWith: { first, _ in first })
        var out: [String] = []
        for pane in panes.sorted() {
            guard let asks = held[pane], !asks.isEmpty else { continue }
            out.append("- pane \(pane):\n  " + asks.joined(separator: "\n  "))
        }
        return out.joined(separator: "\n")
    }

    /// The conversation each pane holds now or held last, by this host's
    /// broker (`agent.last`); `pane` narrows it to one. Empty when the
    /// broker does not answer.
    nonisolated static func heldConversations(pane: String? = nil) -> [Identity.Last] {
        let payload = JSONValue.object(pane.map { ["pane": .string($0)] } ?? [:])
        guard let response = try? HarnessWire.call(RPCRequest("agent.last", payload)), response.ok else { return [] }
        return (try? response.value.decode([Identity.Last].self)) ?? []
    }

    /// Emoji already chosen across workspaces, deduped: the editor's one-click
    /// reuse strip.
    func recentEmoji() -> [String] {
        var out: [String] = []
        for session in workspaces.values {
            guard let emoji = session.emoji else { continue }
            for cluster in emoji.map(String.init) where !out.contains(cluster) {
                out.append(cluster)
            }
        }
        return out
    }

    // MARK: Names that move (VigilWire NameMoves.swift is the rule)

    /// A name leaving `from` with what it described lands on `tab` of `to`
    /// (and on its pane `pane` where the tab has its own): every move puts
    /// a name here, and every name that moves is one line in scope
    /// `naming`, a name with no place the loudest.
    func wear(_ name: Registry.Name, on tab: inout Registry.Tab, pane: String? = nil, from: String, to: String, by move: String) {
        guard !name.isEmpty else { return }
        said(tab.wear(name, pane: pane), tab: tab.paneIds.first ?? "", pane: pane, from: from, to: to, by: move)
    }

    /// A name that came with a pane alone (a dock tenant joining a tab that
    /// is not its to rename) lands on the pane `pane` of `to`.
    func wear(_ name: Registry.Name, onPane pane: String, from: String, to: String, by move: String) {
        guard !name.isEmpty, let at = locate(pane), !at.buried, at.owner == to else { return }
        var tab = workspaces[to]!.tabs[at.tab]
        let landing: Registry.Landing
        if let i = tab.panes.firstIndex(where: { $0.id == pane }) {
            landing = tab.panes[i].wear(name)
        } else if let i = tab.dock?.panes.firstIndex(where: { $0.id == pane }) {
            landing = tab.dock!.panes[i].wear(name)
        } else {
            return
        }
        workspaces[to]!.tabs[at.tab] = tab
        said(landing, tab: tab.paneIds.first ?? "", pane: pane, from: from, to: to, by: move)
    }

    private func said(_ landing: Registry.Landing, tab: String, pane: String?, from: String, to: String, by move: String) {
        guard !landing.isEmpty else { return }
        var fields: LogFields = [
            "move": move, "from": from, "to": to, "tab": tab,
            "on tab": landing.tab.description, "on pane": landing.pane.description,
        ]
        if let pane { fields["pane"] = pane }
        namingLog.info("name moved with what it named", fields)
        if !landing.dropped.isEmpty {
            fields["dropped"] = landing.dropped.description
            namingLog.error("!! a moved name had no place: the tab and its pane are named otherwise", fields)
        }
    }

}
