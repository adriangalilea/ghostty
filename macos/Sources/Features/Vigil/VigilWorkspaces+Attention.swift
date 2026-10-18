import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Recency (the successor order when the session you are in dies)

    func touchRecent(_ name: String) {
        guard recent.first != name else { return }
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
    }

    /// The session that takes a viewport when its occupant dies: the most
    /// recently active one that can be MOUNTED (background; windowed and
    /// floating already live elsewhere), else manual order.
    func successor(excluding dying: String) -> String? {
        func mountable(_ session: Workspace) -> Bool {
            guard session.name != dying else { return false }
            return place(session.name) == .background
        }
        if let hit = recent.compactMap({ workspaces[$0] }).first(where: mountable) { return hit.name }
        return workspaces.values.filter(mountable)
            .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            .first?.name
    }

    // MARK: Attention (fed by agent adapters through the wake events log)

    private var eventsURL: URL {
        VigilPaths.events
    }


    /// The drain offset survives relaunches: attention that fired while the
    /// app was CLOSED (a watcher verdict, a headless agent finishing in its
    /// daemon) is exactly the attention a relaunch must surface. Only ancient
    /// history (pre-truncation) is not pending.
    private var eventsOffsetURL: URL {
        VigilPaths.root.appendingPathComponent("events.offset")
    }

    private struct WakeEvent: Decodable {
        let container: String
        let event: String
        /// The permission notification's text, forwarded by the claude hook so
        /// the ask gate can SPEAK the request instead of a generic bell.
        let msg: String?
        /// An AskUserQuestion's payload (Question events): the ask gate
        /// narrates the question and offers the options.
        let q: WakeQuestion?
        /// Hook-stamped time. The events log is offset-tailed and REPLAYS at
        /// launch; attention wants that (it queues), the ask gate must not: a
        /// spoken ask for a prompt answered hours ago is a ghost.
        let ts: String?
        /// The vigild pane daemon the agent lives in. Ground truth for
        /// ownership: VIGIL_WORKSPACE in the process env is stamped at birth
        /// and goes stale when a tab is dragged into another session.
        let pane: String?
    }

    struct WakeQuestion: Decodable {
        let question: String
        let header: String
        let options: [String]
        let multi: Bool
        let count: Int
    }

    /// The session owning this pane daemon right now (live surfaces or
    /// captured sentinels). Ownership is derived, never parsed from the id.
    private func workspaceOwning(pane: String) -> String? {
        workspaces.first { ownedPaneIds($0.value).contains(pane) }?.key
    }

    /// The cortex read (grounding keywords) for the session owning this
    /// pane; nil while no read exists yet.
    func cortexIdentity(ofPane pane: String) -> VigilCortex.Read? {
        guard let name = workspaceOwning(pane: pane) else { return nil }
        return VigilCortex.identity(session: name)
    }

    /// Tail the events log agent adapters append to. A 1s poll is honest
    /// enough for human attention; the log is small and offset-read.
    func startEventWatcher() {
        // Bound the attention log: it is append-only and offset-tailed, so
        // launch is the one safe moment to truncate (the saved offset is
        // reset below when we do). The ms-wide race with a concurrent hook
        // append is accepted.
        var truncated = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: eventsURL.path),
           let size = attrs[.size] as? UInt64, size > 1024 * 1024,
           let handle = try? FileHandle(forReadingFrom: eventsURL) {
            handle.seek(toFileOffset: size - 128 * 1024)
            let tail = handle.readDataToEndOfFile()
            try? handle.close()
            // Cut at a line boundary so the first record parses.
            if let nl = tail.firstIndex(of: 0x0a) {
                try? tail.suffix(from: tail.index(after: nl)).write(to: eventsURL, options: .atomic)
                truncated = true
            }
        }

        // Resume from the last drained position: attention that fired while
        // the app was closed replays now (presence/ownership filters still
        // apply). After a truncation the saved offset points into the old
        // file; the whole bounded tail replays instead.
        let size = (try? FileManager.default.attributesOfItem(atPath: eventsURL.path))
            .flatMap { $0[.size] as? UInt64 } ?? 0
        let saved = (try? String(contentsOf: eventsOffsetURL, encoding: .utf8))
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        eventsOffset = truncated ? 0 : min(saved ?? size, size)
        drainEvents()
        watchEvents()
        // Seen = a pane's newest state under the eyes: re-checked whenever a
        // state lands or what is in front of the human changes, never on a
        // clock. Owner grids follow the facts and the remote directories.
        Self.onPresenceInputs { VigilWorkspaces.shared.ackVisiblePanes() }
    }

    /// The attention log is append-only and every writer appends a whole
    /// line, so a vnode watch on the file IS the event; the drain runs on
    /// the write, not on a clock. A truncation replaces the inode
    /// (atomic write) and re-arms.
    private func watchEvents() {
        eventsWatch?.cancel(); eventsWatch = nil
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        let fd = Darwin.open(eventsURL.path, O_EVTONLY)
        guard fd >= 0 else { attentionLog.error("events not watched", ["path": eventsURL.path]); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            MainActor.assumeIsolated { self.drainEvents() }
            if flags.contains(.delete) || flags.contains(.rename) {
                MainActor.assumeIsolated { self.watchEvents() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        eventsWatch = source
    }

    /// A surface whose pane's pty is OWNED by another client (the phone
    /// in OWN) renders that client's grid letterboxed. `<pane>.size` is
    /// "rows cols <owner hello>", the daemon's fact; this app's own
    /// surfaces hello as `ghostty:<pid>`. Ownership is never inferred from
    /// a grid difference: a surface framed at the owner's grid would flip
    /// it on every layout. Runs when its inputs change: the local facts
    /// (`<pane>.size`, `<pane>.screen`, renamed into place by vigild), a
    /// remote directory, a surface's stream opening or ending.
    func syncOwnerGrids() {
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects {
            guard let id = view.vigilAttachId, view.surface != nil else { continue }
            if view.vigilHost != nil, view.vigilTransportState == 2 { continue }
            // A remote pane's size fact rides the host's directory (the file
            // is on the other Mac); a mirror that never claims would otherwise
            // paint the owner's narrow bytes into its own wide grid.
            let raw: String
            if let device = view.vigilHost {
                raw = VigilRemote.shared.host(device)?.directory?.panes[id]?.size ?? ""
            } else {
                raw = facts.files["panes/\(id).size"]?.text ?? ""
            }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: " ", maxSplits: 2)
            let rows = parts.count >= 2 ? Int(parts[0]) ?? 0 : 0
            let cols = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
            // Missing/in-flight directory data is not an ownership change.
            guard rows > 0, cols > 0 else { continue }
            let owner = parts.count == 3 ? String(parts[2]) : ""
            view.vigilUpdateSizeOwner(owner)
            let mine = view.vigilOwnsSize(owner: owner)
            // A remote viewport starts as a mirror even if nobody owns the
            // pty. An explicit gesture selects its own layout immediately;
            // directory delivery may still describe the previous owner.
            let mirror = !view.vigilWantsSize && (view.vigilHost != nil || !owner.isEmpty && !mine)
            let grid: Ghostty.SurfaceView.VigilGrid? = mirror && rows > 0 && cols > 0 ? .init(rows: rows, cols: cols) : nil
            if grid != view.vigilOwnerGrid {
                view.vigilOwnerGrid = grid
                // An ownership change is a legitimate resync window: the
                // content receipt starts over (strikes counted across a
                // takeover would silence the pane it exists for).
                view.vigilScreenStrikes = -3
                view.vigilScreenResyncs = 0
                if let grid {
                    sizeLog.info("letterboxed to the owner's grid", ["pane": id, "rows": grid.rows, "cols": grid.cols, "owner": owner])
                } else {
                    sizeLog.info("own grid", ["pane": id])
                }
                // The frame lands on the next runloop; then re-sync the
                // screen from the daemon: a non-owner that reflowed bytes
                // parsed at the old grid shows garbage otherwise.
                if grid != nil, let surface = view.surface {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in
                        guard let view, view.surface == surface else { return }
                        ghostty_surface_vigil_dump(surface)
                        sizeLog.info("letterbox re-synced from the daemon", ["pane": id])
                    }
                }
            }
            fitLetterbox(view, grid: grid)
            // The content receipt compares against the local daemon's hash file.
            if view.vigilHost == nil { checkScreen(view, id: id) }
        }
    }

    /// The content receipt: the daemon publishes the FNV-1a of its
    /// viewport's plain text (`<pane>.screen`); this surface hashes its
    /// own the same way. A difference counts only while the daemon's hash
    /// held still across two ticks (a spinning TUI is not a desync); two
    /// strikes log `!! screen mismatch` and re-sync from the daemon. The
    /// first agreement per surface logs once, proving the mechanism.
    /// One look at `id`'s content receipt a second from now (replacing any
    /// pending one): a hash that held still that long is a verdict.
    private func settleScreen(_ view: Ghostty.SurfaceView, id: String) {
        screenSettle[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.screenSettle[id] = nil
                guard view.surface != nil, view.vigilAttachId == id, view.vigilHost == nil else { return }
                self.checkScreen(view, id: id)
            }
        }
        screenSettle[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func checkScreen(_ view: Ghostty.SurfaceView, id: String) {
        guard let surface = view.surface,
              let daemon = facts.files["panes/\(id).screen"]?.text
                .trimmingCharacters(in: .whitespacesAndNewlines), !daemon.isEmpty else { return }
        let stable = daemon == view.vigilScreenSeen
        view.vigilScreenSeen = daemon
        // A moving daemon hash is a moving screen: no verdict is possible, so
        // no viewport hash is computed; it is judged once it held still for a
        // second (the settle check below). A hash already proven equal and
        // still published has nothing to re-prove. An idle fleet hashes nothing.
        guard stable else { return settleScreen(view, id: id) }
        if view.vigilScreenStrikes == 0, view.vigilScreenProvenHash == daemon { return }
        // A verdict still pending (a strike, the grace after a re-sync) is
        // looked at again a second later, until proven or silenced.
        defer { if view.vigilScreenStrikes != 0, view.vigilScreenResyncs < 3 { settleScreen(view, id: id) } }
        let mine = String(ghostty_surface_vigil_screen_hash(surface), radix: 16)
        if mine == daemon {
            view.vigilScreenStrikes = 0
            view.vigilScreenProvenHash = daemon
            if !view.vigilScreenProven { view.vigilScreenProven = true; sizeLog.info("screen in sync", ["pane": id, "hash": mine]) }
            return
        }
        view.vigilScreenStrikes += 1
        if view.vigilScreenStrikes == 2 {
            view.vigilScreenResyncs += 1
            if view.vigilScreenResyncs <= 2 {
                sizeLog.error("screen mismatch; re-syncing", [
                    "pane": id, "daemon": daemon, "view": mine, "resync": view.vigilScreenResyncs,
                ])
                ghostty_surface_vigil_dump(surface)
            } else if view.vigilScreenResyncs == 3 {
                // Leave the evidence: this view's text on disk, the
                // daemon's one command away.
                let out = VigilPaths.dumps.appendingPathComponent("\(id).view.txt")
                var s = ghostty_surface_vigil_screen_text(surface)
                if let p = s.ptr { try? String(cString: p).write(to: out, atomically: true, encoding: .utf8) }
                ghostty_string_free(s)
                s = .init()
                sizeLog.error("screen mismatch persists after re-syncs; silenced", [
                    "pane": id, "diff": "vigild screen \(id) | diff - \(out.path)",
                ])
            }
            view.vigilScreenStrikes = -3 // grace for the dump to land
        }
    }

    /// The letterboxed grid must be WHOLLY visible: a render-side scale
    /// (ghostty's own font-size steps), never a layer transform (a
    /// scaleEffect on the Metal layer flashed at frame rate). One step
    /// per tick: shrink while the grid overflows the view, grow back
    /// while the next step still fits, reset when this surface owns.
    private func fitLetterbox(_ view: Ghostty.SurfaceView, grid: Ghostty.SurfaceView.VigilGrid?) {
        guard let surface = view.surface else { return }
        func act(_ a: String) { _ = a.withCString { ghostty_surface_binding_action(surface, $0, UInt(a.utf8.count)) } }
        guard let grid else {
            if view.vigilFontStep != 0 { act("reset_font_size"); view.vigilFontStep = 0; sizeLog.info("letterbox font reset", ["pane": view.vigilAttachId]) }
            return
        }
        guard let pts = view.vigilPoints(for: grid) else { return }
        let b = view.vigilViewportSize == .zero ? view.bounds.size : view.vigilViewportSize
        if pts.width > b.width || pts.height > b.height {
            guard view.vigilFontStep > -8 else { return }
            act("decrease_font_size:1"); view.vigilFontStep -= 1
            sizeLog.info("letterbox font down", [
                "pane": view.vigilAttachId, "points": "\(Int(pts.width))x\(Int(pts.height))",
                "view": "\(Int(b.width))x\(Int(b.height))", "step": view.vigilFontStep,
            ])
        } else if view.vigilFontStep < 0 {
            // Would one step up still fit? Cells scale ~linearly in points.
            let base: CGFloat = 13, cur = base + CGFloat(view.vigilFontStep)
            let f = (cur + 1) / cur
            if pts.width * f <= b.width && pts.height * f <= b.height {
                act("increase_font_size:1"); view.vigilFontStep += 1
                sizeLog.info("letterbox font up", ["pane": view.vigilAttachId, "step": view.vigilFontStep])
            }
        }
    }

    private func drainEvents() {
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        if size < eventsOffset { eventsOffset = 0 } // log was pruned/rotated
        guard size > eventsOffset else { return }
        handle.seek(toFileOffset: eventsOffset)
        let data = handle.readDataToEndOfFile()
        eventsOffset = size
        try? "\(size)".write(to: eventsOffsetURL, atomically: true, encoding: .utf8)

        var changed = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let event = try? JSONDecoder().decode(WakeEvent.self, from: Data(line.utf8)) else { continue }
            changed = attend(event: event.event, pane: event.pane, container: event.container) || changed
        }
        if changed { attentionChanged() }
    }

    func attentionChanged() {
        onAttentionChange?()
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// One thing that may need you, from an agent's hook, the daemon (a
    /// bell) or a command's end: whether it changed anything.
    func attend(event: String, pane: String?, container: String) -> Bool {
        // Ownership resolution, strongest first: the pane daemon the
        // agent lives in (survives drag-out; env container goes
        // stale), then the birth container.
        let name: String
        if let pane, !pane.isEmpty, let owner = workspaceOwning(pane: pane) {
            name = owner
        } else if workspaces[container] != nil {
            name = container
        } else {
            return false
        }
        // Presence beats attention, PANE-granular: only an event whose
        // console is actually on screen is already answered. A watched
        // workspace's hidden tab queues like any other. Pane-less events
        // keep the workspace-level rule (nothing finer to check).
        if let pane, !pane.isEmpty {
            if paneVisible(pane) {
                markSeen(pane)
                return true
            }
        } else if isWatching(name) {
            return true
        }
        // Notification = permission prompt, Question = AskUserQuestion
        // (both mid-turn, the agent is stalled); Ask = the adapter
        // classifier found a question at turn end. Distinct ranks:
        // the summon and ⌘⇧J serve mid-turn blockers first.
        let attention: Attention = switch event {
        case "Notification", "Question": .midTurn
        case "Ask": .input
        default: .done
        }
        // Escalate only: an input request is not downgraded by a later Stop.
        guard attention.rawValue > workspaces[name]!.attention.rawValue else { return false }
        workspaces[name]!.attention = attention
        workspaces[name]!.attentionSince = Date()
        return true
    }

    /// Panes whose command ended between two fact revisions, long enough to
    /// be news (`CommandFact.endIsNews`).
    static func commandsEnded(from old: VigilFacts.Snapshot, to new: VigilFacts.Snapshot) -> [String] {
        new.files.compactMap { key, file -> String? in
            guard key.hasPrefix("panes/"), key.hasSuffix(".command"), old.files[key]?.text != file.text,
                  let fact = CommandFact(file.text), fact.endIsNews,
                  CommandFact(old.files[key]?.text ?? "")?.ended != fact.ended
            else { return nil }
            return String(key.dropFirst("panes/".count).dropLast(".command".count))
        }
    }

    /// True when Adrian is looking at this session right now: its window
    /// (or the quick terminal hosting it) is key and the app is active.
    private func isWatching(_ name: String) -> Bool {
        guard NSApp.isActive else { return false }
        if panelWorkspace == name,
           quickController(create: false)?.window?.isKeyWindow == true { return true }
        guard let window = focusWindow(of: name) else { return false }
        return window.isKeyWindow
    }

    /// A pane is under the eyes RIGHT NOW: its view (or its mirror) sits
    /// in the key window's hierarchy, unhidden (a collapsed dock hides its
    /// tenants), app active.
    private func paneVisible(_ pane: String) -> Bool {
        guard NSApp.isActive else { return false }
        if mirror?.pane == pane,
           quickController(create: false)?.window?.isKeyWindow == true { return true }
        guard let view = liveView(attachId: pane),
              let window = view.window, window.isKeyWindow else { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }

    /// THE seen-rule, one chokepoint, pane-granular: stamp every pane
    /// visible in the key window; the key session's queued attention
    /// resolves only once no blocked pane remains unseen - focusing tab 1
    /// never forgives an ask living in captured tab 4 (its dot holds, follow
    /// still targets it). Fired by key-window changes and focus syncs
    /// (instant) and the 1s events tick (presence is continuous; the tick
    /// is its pulse).
    /// Whether a person touched this Mac's keyboard, mouse or trackpad after
    /// `moment` (the HID system's own clock of the last input). A key window
    /// on a Mac nobody sits at (one served only remotely, its display kept
    /// awake) shows a pane no one sees: seen needs a person here since the
    /// pane changed, or every question that lands on screen there reads as
    /// answered-by-eye and nothing rings anywhere.
    nonisolated static func personActed(after moment: Date) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        return Date(timeIntervalSinceNow: -idle) > moment
    }

    func ackVisiblePanes() {
        guard NSApp.isActive, let window = NSApp.keyWindow else { return }
        var name: String?
        var views: [Ghostty.SurfaceView] = []
        if let controller = window.windowController as? TerminalController {
            name = workspaceName(of: controller)
            views = Array(controller.surfaceTree)
            if let dock = dockMap.object(forKey: controller) { views += dock.views }
        } else if let quick = window.windowController as? QuickTerminalController {
            name = panelWorkspace
            views = Array(quick.surfaceTree)
        } else {
            return
        }
        if let name { touchRecent(name) }
        var changed = false
        for view in views {
            guard let pane = view.vigilAttachId,
                  view.window === window,
                  !view.isHiddenOrHasHiddenAncestor else { continue }
            if let device = view.vigilHost {
                // A remote console under the eyes: the ack is ITS Mac's fact.
                VigilRemote.shared.seen(device: device, pane: pane)
                continue
            }
            if let s = paneAgentState(pane),
               s.state == .blocked || s.state == .done,
               (lastAck(pane) ?? .distantPast) < s.since,
               Self.personActed(after: s.since) {
                // Written off main: the seen file landing is the change (the
                // facts reload posts it). Posting here too re-entered this
                // function through `onPresenceInputs` before the mark existed,
                // recursing until the stack ran out.
                markSeen(pane, revision: s.revision)
            }
        }
        if let name, let session = workspaces[name],
           session.attention != .none, !blockedUnseen(name) {
            workspaces[name]!.attention = .none
            workspaces[name]!.attentionSince = nil
            changed = true
            onAttentionChange?()
        }
        if changed {
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }

    /// The head of the attention FIFO: what it asks (`Need`, the one
    /// ranking the phone's board orders by too), oldest first within it.
    struct AttentionEntry {
        let candidate: SummonCandidate
        let need: Need
    }
    /// One queue across homes: the need first, then this endpoint's arrival
    /// order. Home timestamps never compete with a different machine's clock.
    func attentionQueue() -> [AttentionEntry] {
        var entries: [AttentionEntry] = []
        for session in workspaces.values {
            for pane in ownedPaneIds(session) {
                guard let state = paneAgentState(pane), let need = Need(state.state, flavor: state.flavor),
                      (lastAck(pane) ?? .distantPast) < state.since else { continue }
                entries.append(AttentionEntry(candidate: SummonCandidate(name: session.name, pane: pane, since: state.since), need: need))
            }
        }
        for candidate in remoteAttention() {
            guard let state = paneAgentState(candidate.pane), let need = Need(state.state, flavor: state.flavor) else { continue }
            entries.append(AttentionEntry(candidate: candidate, need: need))
        }
        return entries.sorted {
            $0.need != $1.need ? $0.need > $1.need : $0.candidate.since < $1.candidate.since
        }
    }

    /// The attention FIFO: open the most urgent session. IDEMPOTENT:
    /// with the FIFO drained, fall back to STATE
    /// truth - any session still asking (even one already seen/acked)
    /// stays reachable, rotating past the current one so repeated
    /// presses walk every open ask.
    func next() {
        let controller = NSApp.keyWindow?.windowController as? TerminalController
        let current = controller.flatMap { mirroredWorkspace(of: $0) ?? workspaceName(of: $0) }
        guard let target = attentionQueue().first(where: { $0.candidate.name != current }) else { return }
        follow(target.candidate.name, in: controller)
    }

    /// The head of the attention FIFO by name (the sidebar's direct-access
    /// key shapeshifts to it).
    var mostUrgentName: String? { attentionQueue().first?.candidate.name }

    // MARK: Summon (mid-turn blockers pull the quick terminal in)

    struct SummonCandidate: Equatable {
        let name: String
        let pane: String
        let since: Date
    }

    /// The summon's queue, DERIVED on every read (state files + ownership,
    /// no second store to go stale): panes stalled MID-TURN (permission or
    /// question flavor), unseen, in any session state, oldest first:
    /// windowed panes MIRROR into the panel (their placement is never
    /// touched), background/captured ones resurrect their tab into it
    /// ("background never summons" meant the whole fleet was MUTE after every
    /// app restart).
    /// Eligibility is ATTENDED-truth alone: unseen per the ack ledger
    /// (key-window visibility, the one presence chokepoint). "Some pixels
    /// of the prompt exist on some monitor" is not attention: a vigil window
    /// standing beside a video in Safari is visible and unattended.
    /// On ANY screen, not just the key window: a pane whose console is
    /// visibly on a display is answerable in place (the ask gate speaks it,
    /// eyes and keyboard are already there if wanted). Ripping its tab into
    /// the floating panel takes glass Adrian can SEE and moves it somewhere
    /// else. Distinct from the seen-rule on purpose: presence/acks stay
    /// key-window (attention must not be forgiven sight-unseen); this gates
    /// only whether the summon MOVES glass. Chime, eye, gate all still fire.
    func paneOnAnyScreen(_ pane: String) -> Bool {
        // Ghostty frontmost + pane visible = Adrian can see it: answer in
        // place. Ghostty NOT frontmost = float, ALWAYS - summoning over other
        // apps is the point. occlusionState LIES (it reports a window
        // covered by another app as visible); NSApp activity is the only
        // honest signal for "is the terminal his view".
        guard NSApp.isActive else { return false }
        guard let view = liveView(attachId: pane), let window = view.window,
              window.isVisible, !window.isMiniaturized else { return false }
        // A background NATIVE TAB's window still reports isVisible and its
        // views un-hidden (it is "part of the visible tab group") - but the
        // pane is behind another tab and Adrian cannot see it. Not the
        // selected tab = not on screen.
        if let group = window.tabGroup, group.selectedWindow !== window { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }

    /// Why paneOnAnyScreen answered what it answered, as one log-ready
    /// string. Never used for the decision itself: same inputs, spelled out.
    func paneOnScreenReceipt(_ pane: String) -> String {
        var parts: [String] = ["appActive=\(NSApp.isActive)"]
        guard let view = liveView(attachId: pane) else { return parts.joined(separator: " ") + " view=GONE" }
        guard let window = view.window else { return parts.joined(separator: " ") + " window=nil (no window)" }
        parts.append("winVisible=\(window.isVisible)")
        parts.append("mini=\(window.isMiniaturized)")
        parts.append("key=\(window.isKeyWindow)")
        parts.append("hidden=\(view.isHiddenOrHasHiddenAncestor)")
        if let group = window.tabGroup {
            parts.append("frontTab=\(group.selectedWindow === window)")
        }
        if let controller = window.windowController as? TerminalController {
            parts.append("mounted='\(workspaceName(of: controller) ?? "stray")'")
        }
        return parts.joined(separator: " ")
    }

    /// Remote identities remain namespaced. Arrival order uses this endpoint's
    /// clock; home clocks are used only for home facts, never local snooze time.
    func remoteAttention(midTurn: Bool? = nil) -> [SummonCandidate] {
        var result: [SummonCandidate] = []
        for host in VigilRemote.shared.hosts where host.error == nil {
            guard let directory = host.directory else { continue }
            for session in directory.live {
                for pane in session.paneIds {
                    guard let truth = directory.panes[pane], truth.alive,
                          let revision = truth.unseenRevision, let token = truth.token else { continue }
                    let isMidTurn = token.state == .blocked && token.flavor?.midTurn == true
                    if let midTurn, midTurn != isMidTurn { continue }
                    result.append(SummonCandidate(name: VigilRemote.compositeId(host.device, session.name),
                        pane: VigilRemote.compositeId(host.device, pane), since: VigilRemote.shared.arrival(device: host.device, pane: pane, revision: revision)))
                }
            }
        }
        return result.sorted { $0.since < $1.since }
    }

    func summonQueue() -> [SummonCandidate] {
        midTurnAsks { session in
            if session.float != nil, session.name != floatingName { return false }
            return true
        }
        .filter { VigilRemote.split($0.pane) != nil || (lastAck($0.pane) ?? .distantPast) < $0.since }
    }

    /// Panes whose TURN ENDED, any session: the soft-chime feed. Both
    /// endings count — done, and a turn-end question (blocked/ask) —
    /// because the sound answers "is claude waiting on me", and the
    /// vocabulary is the interruption axis, not the state name: `waiting`
    /// = stalled MID-work, `ended` = your turn. A turn end rings softer,
    /// lights the eye and stays summonable (⌘⇧H), but never moves glass;
    /// only mid-turn blockers float.
    func turnEnds() -> [SummonCandidate] {
        var out: [SummonCandidate] = remoteAttention(midTurn: false)
        for session in workspaces.values {
            for pane in ownedPaneIds(session) {
                guard let s = paneAgentState(pane) else { continue }
                let ended = s.state == .done || (s.state == .blocked && s.flavor?.midTurn != true)
                guard ended else { continue }
                out.append(SummonCandidate(name: session.name, pane: pane, since: s.since))
            }
        }
        return out.sorted { $0.since < $1.since }
    }

    /// EVERY mid-turn blocker, seen or not, any session state: the chime
    /// feed. A prompt landing under Adrian's eyes still dings once —
    /// noise is the contract; presence only decides whether anything
    /// MOVES.
    func midTurnAsks(_ include: (Workspace) -> Bool = { _ in true }) -> [SummonCandidate] {
        var out: [SummonCandidate] = remoteAttention(midTurn: true)
        for session in workspaces.values where include(session) {
            for pane in ownedPaneIds(session) {
                guard let s = paneAgentState(pane), s.state == .blocked,
                      s.flavor?.midTurn == true else { continue }
                out.append(SummonCandidate(name: session.name, pane: pane, since: s.since))
            }
        }
        return out.sorted { $0.since < $1.since }
    }

    /// Quick-terminal facts the summon engine drives its flow by; the
    /// mechanics stay in here, the policy lives in VigilSummon.
    var quickTerminalVisible: Bool { quickController(create: false)?.visible ?? false }
    var quickTerminalWindow: NSWindow? { quickController(create: false)?.window }
    func dismissQuickTerminal() { quickController(create: false)?.animateOut() }

    // MARK: Asking (who asks, where, and what ⌘⇧J and follow land on)

    /// Is any pane's blocked state FRESH (a real unanswered ask)? A long
    /// tool approved through a hook confirmation leaves blocked STALE (no
    /// hook fires between the approval and the tool's end), so blocked is
    /// only trusted briefly.
    /// A session with any raw-blocked pane, at any age: still asking (or
    /// mid-approved-tool). Used for the auto-follow veto (never yank
    /// while the current session may be mid-answer) and ⌘⇧J's rotation
    /// (every ask stays reachable, seen or not).
    func asking(_ name: String) -> Bool {
        guard let session = workspaces[name] else { return false }
        return ownedPaneIds(session).contains { pane in
            paneAgentState(pane)?.state == .blocked
        }
    }

    /// Asking AND not yet seen: the ask fired after its PANE was last on
    /// screen. Auto-follow's herdr seen-flip - visiting the asking console
    /// releases it; only a NEW ask (fresh state mtime) re-targets.
    func blockedUnseen(_ name: String) -> Bool {
        guard let session = workspaces[name] else { return false }
        return ownedPaneIds(session).contains { pane in
            guard let s = paneAgentState(pane) else { return false }
            return s.state == .blocked && (lastAck(pane) ?? .distantPast) < s.since
        }
    }

    /// WHERE the ask lives: the most recently blocked pane in the session
    /// (state-file truth; session attention only knows WHO asked). Nil
    /// when nothing is blocked (a done, or the ask was answered since).
    func askingPane(_ name: String) -> String? {
        guard let session = workspaces[name] else { return nil }
        return ownedPaneIds(session)
            .compactMap { pane -> (pane: String, since: Date)? in
                guard let s = paneAgentState(pane), s.state == .blocked else { return nil }
                return (pane, s.since)
            }
            .max { $0.since < $1.since }?
            .pane
    }

    /// Attention-driven landing, ONE primitive for every path that grabs
    /// focus because a session asked (auto-follow, ⌘⇧J, the sidebar's ;):
    /// land on the ASKING PANE (its tab mounts, it takes focus), not the
    /// session: a session-level landing mounts the anchored tab, and an ask
    /// in tab 4 would arrive at tab 1's console.
    func follow(_ name: String, in controller: TerminalController?) {
        if let remote = VigilRemote.split(name), let candidate = remoteAttention().first(where: { $0.name == name }),
           let pane = VigilRemote.split(candidate.pane) {
            if let controller { mountRemote(controller, composite: name, anchor: candidate.pane) } else { openRemotePane(device: remote.device, pane: pane.name) }
            return
        }
        if let pane = askingPane(name) {
            followLog.info("to the asking pane", ["workspace": name, "pane": pane])
            activatePane(name: name, paneId: pane, in: controller)
        } else if let controller {
            shapeshift(in: controller, to: name)
        } else {
            open(name: name)
        }
    }

    /// The manual-follow affordance: what ⌘⇧J would do RIGHT NOW.
    struct AskHint: Equatable {
        let name: String
        let label: String
        let emoji: String?
        /// The asking pane follow() would land on (nil for a done-head:
        /// session-level landing). The sidebar co-locates the keycap on
        /// this pane's row.
        let pane: String?
        /// Sessions still waiting beyond the head (the queue's depth).
        let more: Int
    }

    /// Mirrors next() exactly (attention FIFO head, else the rotation's
    /// next asking session relative to the key window) WITHOUT executing:
    /// the sidebar renders it as the ⌘⇧J affordance when auto-follow is
    /// off, and visiting the head re-derives the next - the hint IS the
    /// queue, one head at a time.
    func nextAskHint() -> AskHint? {
        let controller = NSApp.keyWindow?.windowController as? TerminalController
        let current = controller.flatMap { mirroredWorkspace(of: $0) ?? workspaceName(of: $0) }
        let queue = attentionQueue().filter { $0.candidate.name != current }
        guard let head = queue.first?.candidate else { return nil }
        let remote = VigilRemote.shared.session(head.name)?.1
        let label = workspaces[head.name]?.label ?? remote?.label ?? head.name
        let emoji = workspaces[head.name]?.emoji ?? remote?.emoji
        return AskHint(name: head.name, label: label, emoji: emoji, pane: head.pane,
                       more: max(0, Set(queue.map { $0.candidate.name }).count - 1))
    }

    /// Auto-follow's target: the attention FIFO's input head, else the
    /// first session (overview order) asking AND unseen. Seen asks never
    /// re-yank (clicking away is respected); they stay reachable through
    /// ⌘⇧J.
    var followTarget: String? {
        attentionQueue().first(where: { $0.need >= .asked })?.candidate.name
    }

}
