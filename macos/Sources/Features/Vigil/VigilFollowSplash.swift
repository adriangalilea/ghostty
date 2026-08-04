import AppKit
import SwiftUI

/// The auto-follow arrival splash: a pill naming the session the viewport
/// just shapeshifted to, floating top-center over the terminal. It is
/// ALSO the input-shield indicator: while it reads strong, a click/key
/// racing the swap (aimed at what was on screen milliseconds ago) is
/// swallowed instead of landing in the wrong terminal; a swallowed event
/// re-flashes the pill so the ignore is visible, never silent.
@MainActor
enum VigilFollowSplash {
    private static weak var current: NSView?
    private static var fadeWork: DispatchWorkItem?

    static func show(in window: NSWindow?, text: String) {
        guard let content = window?.contentView else { return }
        current?.removeFromSuperview()
        fadeWork?.cancel()

        let pill = ClickThroughHosting(rootView: Pill(text: text))
        pill.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pill.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 14),
        ])
        current = pill
        pill.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            pill.animator().alphaValue = 1
        }
        scheduleFade(after: 0.7)
    }

    /// A shielded event: bring the pill back to full and hold a beat, so
    /// the swallowed click reads as "cooldown, not registered".
    static func reflash() {
        guard let pill = current else { return }
        fadeWork?.cancel()
        pill.alphaValue = 1
        scheduleFade(after: 0.5)
    }

    private static func scheduleFade(after delay: TimeInterval) {
        let work = DispatchWorkItem {
            guard let pill = current else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                pill.animator().alphaValue = 0
            } completionHandler: {
                pill.removeFromSuperview()
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pill must never eat the click it exists to explain.
    private final class ClickThroughHosting<V: View>: NSHostingView<V> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct Pill: View {
        let text: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(.ultraThickMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 1))
        }
    }
}
