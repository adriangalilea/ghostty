import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import VigilHarness
import VigilWire

extension VigilWorkspaces {
    // MARK: Instrumentation

    /// Append-only lifecycle trace at vigil.log in vigil's folder. Every
    /// session transition is recorded so an impossible state is caught the
    /// moment it appears instead of being guessed at from a screenshot.
    /// Dev builds only: a public (Release) build writes nothing to disk.
    private nonisolated static let vlogQueue = DispatchQueue(label: "vigil.log", qos: .utility)
    func vlog(_ msg: String) { Self.vlogQueue.async { Self.vlogSync(msg) } }

    /// The append itself, callable from ANY thread with no hop: the
    /// watchdog's stall line and the uncaught-exception handler's last
    /// words must land while the process is still alive, and a main-actor
    /// hop from a dying or stalled main never runs.
    nonisolated static func vlogSync(_ msg: String) {
        #if DEBUG
        // LOCAL wall-clock time: the reader is a human cross-referencing
        // "what did I just hear" against the log; Date()'s UTC description
        // cost a 2h mental offset on every receipt read.
        let stamp = vlogStamp.string(from: Date())
        let line = "\(stamp) \(msg)\n"
        // Bounded like every append-only log: past 16 MB the file becomes
        // vigil.1.log (one generation) and a fresh one opens.
        let path = VigilPaths.root.appendingPathComponent("vigil.log").path
        var fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        var info = stat()
        if fd >= 0, fstat(fd, &info) == 0, info.st_size > 16 << 20 {
            close(fd)
            _ = Darwin.rename(path, VigilPaths.root.appendingPathComponent("vigil.1.log").path)
            fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        }
        if fd >= 0 {
            defer { close(fd) }
            let data = Data(line.utf8)
            data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        #endif
    }

    private static let vlogStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Scream (loudly, in the log) when a session is in a state that must never
    /// exist, so the impossible state is caught the moment it appears instead
    /// of guessed at. Does not crash: the caller self-heals and the app stays
    /// usable for repeated repro.
    func assertInvariants(_ site: String) {
        #if DEBUG
        // Display is derived, so "windowed with no members" cannot exist;
        // what CAN still lie is the cache: a warm tab must never share a
        // surface with a window's tree (two owners render one surface), and
        // a floating session's warm tabs live in its float.
        for (name, s) in workspaces {
            let shown = Set(members(of: name).flatMap { $0.surfaceTree.map(ObjectIdentifier.init) })
            for runtime in s.held where runtime.tree.contains(where: { shown.contains(ObjectIdentifier($0)) }) {
                vlog("!! IMPOSSIBLE [\(site)]: '\(name)' warm tab \(runtime.tree.compactMap(\.vigilAttachId)) is also on screen")
            }
            if s.float != nil, !s.held.isEmpty {
                vlog("!! IMPOSSIBLE [\(site)]: '\(name)' floating with \(s.held.count) held runtimes")
            }
        }
        // Every attach surface alive in the process must be REGISTERED (a
        // session or a burial lists its pane). A windowed one that is not
        // was stranded by a move; a WINDOWLESS one is a leak: some UI
        // object retains a view whose pane already died (the dock strip,
        // a stale focusedSurface, a titlebar closure).
        var owned = Set<String>()
        for session in workspaces.values { owned.formUnion(ownedPaneIds(session)) }
        for session in graveyard.values { owned.formUnion(ownedPaneIds(session)) }
        // A destroyed surface (its core freed at the reap) is an inert Swift
        // object, not a leak; each leaked pane is said once, not on every
        // mount (one leak printed 6,000 times buried every other alarm).
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects where !view.vigilMirror && view.surface != nil {
            guard let id = view.vigilAttachId, !owned.contains(id), reportedLeaks.insert(id).inserted else { continue }
            vlog("!! IMPOSSIBLE [\(site)]: surface for '\(id)' is \(view.window == nil ? "windowless (LEAKED)" : "live") but registered NOWHERE")
        }
        // Dead windows must actually die: a closed terminal window that
        // stays resident keeps its titlebar accessories, tab bar and
        // SwiftUI hosts alive and WindowServer compositing it. Undo-close
        // legitimately retains a few (120s), so the tripwire is a RATIO:
        // resident controllers vs windows a human can see.
        let resident = TerminalController.all.count
        let visible = TerminalController.all.filter {
            $0.window.map { $0.isVisible || $0.isMiniaturized } ?? false
        }.count
        if resident > max(20, visible * 4) {
            vlog("!! IMPOSSIBLE [\(site)]: \(resident) TerminalControllers resident for \(visible) visible windows (window leak)")
        }
        // One daemon = ONE live pane: twin surfaces on one socket replay
        // interleaved frames into garbage (the duplicated-lazygit
        // corruption).
        // Counted REGARDLESS of window: the twin that wedges panes is one
        // windowed view plus one released-but-still-attached one, so a
        // `window != nil` filter makes the very thing this check exists
        // for invisible.
        // A MIRROR is the sanctioned second client (the panel's viewport
        // onto a windowed pane): sized to the home grid, gone with the
        // panel. It is not a twin.
        var seenIds = Set<String>()
        for view in Ghostty.SurfaceView.vigilAttachSurfaces.allObjects where !view.vigilMirror {
            guard let id = view.vigilAttachId else { continue }
            if !seenIds.insert(id).inserted {
                vlog("!! IMPOSSIBLE [\(site)]: TWO surfaces attached to '\(id)' (twin clients on one daemon)")
            }
        }
        #endif
    }

    /// Self-heal: membership vs tabGroup divergence; empty-tree corpse
    /// windows. (Sessions whose member windows silently died need no
    /// healing any more: display is derived from membership, so they
    /// simply read as background.)
    func reconcile() {
        reconcileTabs()
        for controller in TerminalController.all
        where controller.surfaceTree.isEmpty && controller.window?.isVisible == true {
            NSLog("vigil: closing zombie window (empty surface tree)")
            controller.window?.close()
        }
    }

}
