import AppKit
import AskKit
import Listen
import Say
import SwiftUI
import GhosttyKit
import Log
import VigilHarness
import VigilWire

// The app's record: every event is one line of Apple's unified log
// (subsystem the bundle id, category the scope), written synchronously on
// the calling thread, so a stalled or dying main still leaves its line.
// Read it with `mise run log`. One scope per area:
let lifecycleLog = Log.log.scope("lifecycle")
let registryLog = Log.log.scope("registry")
let moveLog = Log.log.scope("move")
let graveyardLog = Log.log.scope("graveyard")
let daemonLog = Log.log.scope("daemon")
let viewportLog = Log.log.scope("viewport")
let sizeLog = Log.log.scope("size")
let sidebarLog = Log.log.scope("sidebar")
let overviewLog = Log.log.scope("overview")
let attentionLog = Log.log.scope("attention")
let summonLog = Log.log.scope("summon")
let followLog = Log.log.scope("follow")
let dockLog = Log.log.scope("dock")
let sessionLog = Log.log.scope("session")
let remoteLog = Log.log.scope("remote")
let handoffLog = Log.log.scope("handoff")
let authzLog = Log.log.scope("authz")
let factsLog = Log.log.scope("facts")
let voiceLog = Log.log.scope("voice")
let cortexLog = Log.log.scope("cortex")
let sayLog = Log.log.scope("say")
let watchdogLog = Log.log.scope("watchdog")
let invariantsLog = Log.log.scope("invariants")

extension VigilWorkspaces {
    // MARK: Instrumentation

    /// Scream (loudly, in the log) when a session is in a state that must never
    /// exist, so the impossible state is caught the moment it appears instead
    /// of guessed at. Does not crash: the app stays usable for repeated repro.
    func assertInvariants(_ site: String) {
        #if DEBUG
        // Display is derived, so "windowed with no members" cannot exist;
        // what CAN still lie is the cache: a warm tab must never share a
        // surface with a window's tree (two owners render one surface), and
        // a floating session's warm tabs live in its float.
        for (name, s) in workspaces {
            let shown = Set(members(of: name).flatMap { $0.surfaceTree.map(ObjectIdentifier.init) })
            for runtime in s.held where runtime.tree.contains(where: { shown.contains(ObjectIdentifier($0)) }) {
                invariantsLog.error("warm tab also on screen", ["site": site, "workspace": name, "panes": runtime.tree.compactMap(\.vigilAttachId)])
            }
            if s.float != nil, !s.held.isEmpty {
                invariantsLog.error("floating with held runtimes", ["site": site, "workspace": name, "held": s.held.count])
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
            invariantsLog.error("surface registered nowhere", ["site": site, "pane": id, "leaked": view.window == nil])
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
            invariantsLog.error("window leak", ["site": site, "resident": resident, "visible": visible])
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
                invariantsLog.error("twin surfaces on one daemon", ["site": site, "pane": id])
            }
        }
        #endif
    }

    /// Membership vs tabGroup divergence, and empty-tree windows left open,
    /// closed here.
    func reconcile() {
        reconcileTabs()
        for controller in TerminalController.all
        where controller.surfaceTree.isEmpty && controller.window?.isVisible == true {
            viewportLog.warn("zombie window closed: empty surface tree")
            controller.window?.close()
        }
    }

}
