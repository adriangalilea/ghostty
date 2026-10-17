import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
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

    private static let idAdjectives = [
        "amber", "bold", "brave", "bright", "calm", "clever", "cosmic", "crisp",
        "daring", "eager", "gentle", "jolly", "keen", "lively", "lucid", "merry",
        "mighty", "nimble", "noble", "proud", "quiet", "rapid", "royal", "sage",
        "sleek", "snowy", "solar", "spry", "stark", "sunny", "swift", "tidal",
        "vivid", "witty", "zesty",
    ]
    private static let idNouns = [
        "otter", "panda", "falcon", "heron", "lynx", "badger", "cedar", "maple",
        "willow", "river", "harbor", "comet", "ember", "quartz", "canyon",
        "meadow", "glacier", "summit", "delta", "fjord", "grove", "dune", "reef",
        "tundra", "aurora", "nebula", "pulsar", "zephyr", "cobalt", "indigo",
        "onyx", "topaz", "raven", "sparrow", "marten",
    ]

    /// A fresh session id — the identity, the source of truth. A pronounceable
    /// adjective-noun (e.g. `brave-panda`) so we can refer to a session out
    /// loud; NOT derived from the cwd (that named everything in $HOME "adrian-N"
    /// and made real workspaces look like cruft). The human label is a separate
    /// device. The daemon id is `vigil-<id>-<index>`, split on the LAST dash, so
    /// the dash in the id is safe.
    func newWorkspaceId() -> String {
        func taken(_ s: String) -> Bool {
            workspaces[s] != nil || graveyard[s] != nil
                || FileManager.default.fileExists(atPath: dumpsDir(s).path)
        }
        func gen() -> String {
            "\(Self.idAdjectives.randomElement()!)-\(Self.idNouns.randomElement()!)"
        }
        var id = gen()
        var tries = 0
        while taken(id) {
            tries += 1
            id = tries < 40 ? gen() : "\(gen())-\(Int.random(in: 2...999))"
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
    @discardableResult
    func setTabLabel(_ controller: TerminalController, _ label: String?) -> Bool {
        guard let key = tabIdentityKey(for: controller) else { return false }
        setCustomIdentity(key: key, label: label, emoji: customIdentity(key)?.emoji)
        return true
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
        var out: [String] = []
        for pane in panes.sorted() {
            let asks = agentAsks(ofPane: pane, limit: 6)
            guard !asks.isEmpty else { continue }
            out.append("- pane \(pane):\n  " + asks.joined(separator: "\n  "))
        }
        return out.joined(separator: "\n")
    }

    /// Opening ask + latest asks for one pane. Current adapters write this
    /// bounded cache from their stable prompt hook, so Vigil never depends on
    /// an agent vendor's private transcript schema.
    private func agentAsks(ofPane pane: String, limit: Int) -> [String] {
        let dir = VigilPaths.conversations
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        for entry in entries where entry.hasSuffix("--\(pane).json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(entry)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let asks = json["asks"] as? [String], !asks.isEmpty {
                if asks.count <= limit { return asks }
                return [asks[0]] + asks.suffix(limit - 1)
            }
        }
        return []
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

}
