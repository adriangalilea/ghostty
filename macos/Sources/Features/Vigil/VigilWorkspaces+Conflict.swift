import AppKit
import Ink
import SwiftUI
import VigilWire

/// The two copies of a conversation written on two Macs, side by side: for
/// each, where it is, when it was last written, what it holds past what the
/// two share (how often the person asked, the last thing asked, the last
/// thing said). What a person tells them apart by, with no file opened.
///
/// Drawn as what happened: one line for what the two share, and a branch
/// from its end for each copy. A copy that went on with the conversation is
/// a solid branch as long as what it added (against the other's); one that
/// ends with its agent's own records is a short dashed stub.
struct ConflictColumns: View {
    static let width: CGFloat = 520
    let conflict: PaneConflict

    private static let gutter: CGFloat = 26
    private static let longest: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Capsule().fill(.secondary).frame(width: Self.gutter + Self.longest, height: 3)
                Text("The same on both").inkText(.eyebrow)
                Text(PaneConflict.size(conflict.shared)).inkText(.detail)
            }
            .padding(.bottom, 2)
            branch("This Mac", conflict.here, whole: true, last: false)
            branch(conflict.mac, conflict.there, whole: conflict.whole, last: true)
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// How long a copy's branch is drawn: its bytes past the shared part
    /// against the longer of the two, never too short to see.
    private func reach(_ side: PaneConflict.Side) -> CGFloat {
        let most = max(conflict.here.length, conflict.there.length) - conflict.shared
        guard most > 0 else { return 10 }
        return max(10, Self.longest * CGFloat(max(0, side.length - conflict.shared)) / CGFloat(most))
    }

    private func branch(_ name: String, _ side: PaneConflict.Side, whole: Bool, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // The turn off the shared line, then the copy's own stretch.
            Canvas { context, size in
                let ink = GraphicsContext.Shading.style(side.silent ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                var turn = Path()
                turn.move(to: CGPoint(x: Self.gutter / 2, y: 0))
                turn.addLine(to: CGPoint(x: Self.gutter / 2, y: 12))
                turn.addQuadCurve(to: CGPoint(x: Self.gutter, y: 20), control: CGPoint(x: Self.gutter / 2, y: 20))
                turn.addLine(to: CGPoint(x: Self.gutter + reach(side), y: 20))
                context.stroke(turn, with: ink, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: side.silent ? [2, 5] : []))
                if !last {
                    var trunk = Path()
                    trunk.move(to: CGPoint(x: Self.gutter / 2, y: 0))
                    trunk.addLine(to: CGPoint(x: Self.gutter / 2, y: size.height))
                    context.stroke(trunk, with: .style(.secondary), lineWidth: 3)
                }
            }
            .frame(width: Self.gutter + Self.longest)
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: .inkGap) {
                Text(name).inkText(.eyebrow)
                Text(wrote(side)).inkText(.detail).fixedSize(horizontal: false, vertical: true)
                fact("Last asked", side.prompt)
                fact("Last said", side.said)
                if !whole {
                    Label("Not all of it has arrived here: it does when \(name) is back.", systemImage: "exclamationmark.triangle.fill")
                        .inkText(.detail).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // As tall as its words, the drawing beside them the same height.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func fact(_ name: String, _ words: String?) -> some View {
        if let words {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).inkText(.detail)
                Text(words).inkText(.body).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func wrote(_ side: PaneConflict.Side) -> String {
        let tail = conflict.tail(side)
        guard let written = side.written else { return tail }
        return "\(tail). Written \(Self.when.localizedString(for: Date(timeIntervalSince1970: written), relativeTo: Date()))."
    }

    private static let when = RelativeDateTimeFormatter()
}

/// A conversation written on this Mac and on another (`PaneConflict`,
/// vigil-agent's): the pane's mark opens one sheet with both copies and the
/// ways to go on. vigil-agent settles it (`Local.Client.settle`); no choice
/// deletes a copy.
extension VigilWorkspaces {
    /// The sheet for the conflict `pane` wears. True when the person chose
    /// and it was settled: the pane may open on what goes on. False for Not
    /// Now, and for a settle that was refused (said in its own alert).
    @discardableResult
    func conflictSheet(pane: String) -> Bool {
        guard let conflict = paneConflict(pane) else { return true }
        let alert = NSAlert()
        alert.messageText = conflict.headline()
        alert.informativeText = conflict.meaning() + " Whichever goes on, the other is kept aside (vigil conflicts --kept)."
        let columns = NSHostingView(rootView: ConflictColumns(conflict: conflict))
        columns.frame = NSRect(origin: .zero, size: NSSize(width: ConflictColumns.width, height: min(columns.fittingSize.height, 380)))
        alert.accessoryView = columns
        // The first button is what Return takes: the copy that went on,
        // when only one did.
        var choices: [ConflictKeep] = conflict.obvious == .there ? [.there, .here] : [.here, .there]
        for keep in choices {
            switch keep {
            case .here: alert.addButton(withTitle: "Continue This Mac's")
            default: alert.addButton(withTitle: "Continue \(conflict.mac)'s").isEnabled = conflict.whole
            }
        }
        // Two conversations can both be kept; a copy with nothing more of
        // the conversation would be the same one filed twice.
        if conflict.both, conflict.writers == .both {
            alert.addButton(withTitle: "Keep Both").isEnabled = conflict.whole
            choices.append(.both)
        }
        alert.addButton(withTitle: "Not Now")
        let answer = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(answer) else {
            lifecycleLog.info("conflict left standing", ["pane": pane, "conversation": conflict.conversation])
            return false
        }
        let keep = choices[answer]
        let outcome: ConflictSettle.Outcome
        do {
            outcome = try Local.Client(socket: VigilPaths.hub).settle(ConflictSettle(conversation: conflict.conversation, keep: keep))
        } catch {
            lifecycleLog.error("conflict not settled", ["pane": pane, "conversation": conflict.conversation, "keep": keep.rawValue, "err": error])
            let failed = NSAlert()
            failed.messageText = "Nothing was changed"
            failed.informativeText = "\(error)"
            failed.runModal()
            return false
        }
        lifecycleLog.info("conflict settled", ["pane": pane, "conversation": conflict.conversation, "keep": keep.rawValue, "aside": outcome.aside, "forked": outcome.forked])
        // Both: that Mac's copy, a conversation of its own now, opens in a
        // tab beside this pane's.
        if let line = outcome.opens, let workspace = owner(ofPane: pane) {
            refreshWorkspaceRevisions()
            let reply = applySessionCommand(.birth(
                in: workspace, revision: workspaces[workspace]?.layoutRevision ?? "", anchor: pane, split: nil, command: line))
            if !reply.ok {
                lifecycleLog.error("the kept conversation's tab was not opened", ["conversation": outcome.forked, "why": reply.message])
                let failed = NSAlert()
                failed.messageText = "Both are kept; its tab did not open"
                failed.informativeText = "\(reply.message)\n\nOpen it yourself: \(line)"
                failed.runModal()
            }
        }
        return true
    }

    /// The first pane among `panes` whose conversation is in conflict and
    /// whose opening would start it (no daemon holds it): the sheet is asked
    /// before it resumes one copy silently. Not asked when this Mac's copy
    /// is the only one that went on: resuming it is what there is to do.
    func conflictToAsk(among panes: [String]) -> String? {
        panes.first { pane in paneConflict(pane).map { $0.obvious != .here } == true && !Self.daemonAlive(pane) }
    }
}
