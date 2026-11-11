import AppKit
import Ink
import SwiftUI
import VigilWire

/// The two copies of a conversation written on two Macs, side by side: for
/// each, where it is, when it was last written, what it holds past what the
/// two share (how often the person asked, the last thing asked, the last
/// thing said). What a person tells them apart by, with no file opened.
struct ConflictColumns: View {
    static let width: CGFloat = 520
    let conflict: PaneConflict

    var body: some View {
        HStack(alignment: .top, spacing: .inkBlock) {
            column("This Mac", conflict.here, whole: true)
            column(conflict.mac, conflict.there, whole: conflict.whole)
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func column(_ name: String, _ side: PaneConflict.Side, whole: Bool) -> some View {
        VStack(alignment: .leading, spacing: .inkGap) {
            Text(name).inkText(.eyebrow)
            Text(wrote(side)).inkText(.detail)
            fact("Last asked", side.prompt)
            fact("Last said", side.said)
            if !whole {
                Label("Not all of it has arrived here: it does when \(name) is back.", systemImage: "exclamationmark.triangle.fill")
                    .inkText(.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func fact(_ name: String, _ words: String?) -> some View {
        if let words {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).inkText(.detail)
                Text(words).inkText(.body).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func wrote(_ side: PaneConflict.Side) -> String {
        let turns = side.turns == 0 ? "nothing asked since they parted" : side.turns == 1 ? "1 prompt since they parted" : "\(side.turns) prompts since they parted"
        guard let written = side.written else { return turns }
        return "\(turns), written \(Self.when.localizedString(for: Date(timeIntervalSince1970: written), relativeTo: Date()))"
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
        alert.messageText = "This conversation was written on this Mac and on \(conflict.mac)"
        alert.informativeText = "Say which copy this pane goes on with. Neither is deleted: the other is kept aside (vigil conflicts --kept)."
        let columns = NSHostingView(rootView: ConflictColumns(conflict: conflict))
        columns.frame = NSRect(origin: .zero, size: NSSize(width: ConflictColumns.width, height: min(columns.fittingSize.height, 360)))
        alert.accessoryView = columns
        var choices: [ConflictKeep] = [.here, .there]
        alert.addButton(withTitle: "Continue This Mac's")
        alert.addButton(withTitle: "Continue \(conflict.mac)'s").isEnabled = conflict.whole
        if conflict.both {
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
    /// before it resumes one copy silently.
    func conflictToAsk(among panes: [String]) -> String? {
        panes.first { paneConflict($0) != nil && !Self.daemonAlive($0) }
    }
}
