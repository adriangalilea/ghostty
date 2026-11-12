import SwiftUI

// A tree that folds by its thread lines, as a comment thread does (ui's
// `comment-thread`): a row is its face, its name and whatever its owner puts
// after them, with no column for a fold control. An open row's line runs
// under its face through its children's indent, and a press on it folds the
// row; a folded row says how many it hides.
//
// Three pieces and nothing of the rows themselves: the tree's columns
// (`ThreadTreeMetrics`), an open row's children with their line
// (`ThreadChildren`), a folded row's count (`ThreadFolded`). The rows, what
// folds them and what they hold are their owner's: the Mac's sidebar and the
// phone's tree draw different rows over different models and share these.
// It imports SwiftUI alone, so it moves to swift-utils' Ink as it stands
// when a third tree wants it.

/// The tree's columns. A row at a level starts `leading(level)` in; its
/// face is `face` wide; the line of a row runs under the middle of its face,
/// which the next level's `step` leaves clear of the faces below.
struct ThreadTreeMetrics: Equatable {
    /// A row's face column.
    var face: CGFloat
    /// What each level steps in by.
    var step: CGFloat
    /// From a row's edge to its first glyph and its last.
    var edge: CGFloat
    /// How wide a line is to a press, the line in its middle.
    var lineHit: CGFloat

    func leading(_ level: Int) -> CGFloat { edge + step * CGFloat(level) }

    /// A pointer's tree, at `scale` of its compact size: a line 10 wide to a
    /// press is easy to hit and clear of the rows beside it.
    static func pointer(scale: CGFloat) -> ThreadTreeMetrics {
        .init(face: 18 * scale, step: 16 * scale, edge: 6, lineHit: 10)
    }

    /// A finger's tree: a wider line to press, a wider step so that line
    /// does not lie over the faces of the rows it folds.
    static let touch = ThreadTreeMetrics(face: 22, step: 22, edge: 8, lineHit: 22)
}

/// An open row's children with its thread line over them. `level` is the
/// row's own. A press on the line calls `fold`.
///
/// Under a pointer the line says what a press does before it is made: it
/// thickens into the accent and the rows it would fold dim. `hovering` tells
/// the owner, which then lights no row behind the line (a press there folds,
/// it does not open that row).
struct ThreadChildren<Content: View>: View {
    let level: Int
    let metrics: ThreadTreeMetrics
    var hovering: (Bool) -> Void = { _ in }
    let fold: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var lit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .opacity(lit ? 0.4 : 1)
            .animation(.easeOut(duration: 0.12), value: lit)
            .overlay(alignment: .leading) { line }
    }

    private var line: some View {
        Button {
            light(false)
            fold()
        } label: {
            Capsule().fill(lit ? Color.accentColor : Color.primary.opacity(0.16))
                .frame(width: lit ? 2 : 1)
                .padding(.vertical, 2)
                .frame(width: metrics.lineHit, alignment: .center)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .threadPressable()
        .onHover(perform: light)
        .accessibilityLabel("Fold")
        .padding(.leading, metrics.leading(level) + (metrics.face - metrics.lineHit) / 2)
    }

    private func light(_ on: Bool) {
        guard on != lit else { return }
        lit = on
        hovering(on)
    }
}

/// What a folded row hides, counted, after its name: the row's sign that it
/// is folded, and a press on it opens the row (`open`; its owner may open it
/// from a press anywhere on the row as well). Lit under a pointer as a
/// thread line is, with the same word to its owner.
struct ThreadFolded: View {
    let count: Int
    /// The point size of its digits.
    var size: CGFloat = 9
    var hovering: (Bool) -> Void = { _ in }
    let open: () -> Void

    @State private var lit = false

    var body: some View {
        Button {
            light(false)
            open()
        } label: {
            ThreadFoldedCount(count: count, size: size)
                .overlay(Capsule().fill(Color.accentColor.opacity(lit ? 0.45 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .threadPressable()
        .onHover(perform: light)
        .accessibilityLabel("Unfold, \(count) inside")
    }

    private func light(_ on: Bool) {
        guard on != lit else { return }
        lit = on
        hovering(on)
    }
}

/// The count alone, for a row that is itself the thing to press (a header
/// that folds on a press anywhere).
struct ThreadFoldedCount: View {
    let count: Int
    var size: CGFloat = 9

    var body: some View {
        Text("+\(count)")
            .font(.system(size: size, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .fixedSize()
    }
}

extension View {
    /// The hand of a thing to press, where there is a pointer to wear it.
    @ViewBuilder fileprivate func threadPressable() -> some View {
        #if os(macOS)
            pointerStyle(.link)
        #else
            self
        #endif
    }
}
