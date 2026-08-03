import AppKit
import SwiftUI

/// One tab's dock: the right bar, a resizable stack of ordinary
/// daemon-backed tool panes (lazygit, a dev server, anything) with ONE
/// visible at a time. Collapse hides the surface while the tenant's daemon
/// keeps running (the detach mechanism, nothing new); capture and
/// resurrection ride the session's `Tab.dock`. The runtime strongly owns
/// its SurfaceViews; whoever holds the runtime holds the tenants alive.
@MainActor
final class VigilDockRuntime {
    var views: [Ghostty.SurfaceView]
    var active: Int
    var width: CGFloat
    var collapsed: Bool

    init(views: [Ghostty.SurfaceView], active: Int, width: CGFloat, collapsed: Bool) {
        self.views = views
        self.active = active
        self.width = width
        self.collapsed = collapsed
    }

    /// Pull every tenant surface out of whatever window is dying around it
    /// (detach, tab close): the views live on, held here.
    func unmount() {
        for view in views { view.removeFromSuperview() }
    }
}

/// The dock's chrome inside a window: a slim tenant strip on top, the
/// active tenant's surface below, a drag handle on the leading edge.
@MainActor
final class VigilDockHost: NSView {
    var widthConstraint: NSLayoutConstraint!
    private weak var controller: TerminalController?
    private var strip: NSHostingView<VigilDockStrip>?
    private let content = NSView()
    private var handle: VigilDragHandle!
    private weak var mounted: Ghostty.SurfaceView?

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        handle = VigilDragHandle(
            base: { [weak controller] in
                controller.flatMap { VigilSessionManager.shared.dock(for: $0)?.width } ?? 340
            },
            apply: { [weak controller] width in
                guard let controller else { return }
                VigilSessionManager.shared.setDockWidth(controller, width: width)
            },
            flip: true) // the dock grows when its left edge drags LEFT
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)

        // The same divider every split wears: the dock is a pane.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])

        // Fallback top for the strip-less moment; the strip's required
        // constraint overrides it once present() builds the chrome.
        let fallbackTop = content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor)
        fallbackTop.priority = .defaultLow
        NSLayoutConstraint.activate([
            fallbackTop,
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Idempotent: (re)build the strip for the runtime's tenants and mount
    /// the active tenant's surface.
    func present(runtime: VigilDockRuntime, controller: TerminalController) {
        let stripView = VigilDockStrip(
            tenants: runtime.views,
            active: runtime.active,
            onSelect: { [weak controller] index in
                guard let controller else { return }
                VigilSessionManager.shared.setDockActive(controller, index: index)
            },
            onAdd: { [weak controller] in
                guard let controller else { return }
                VigilSessionManager.shared.addDockTenant(controller)
            },
            onClose: { [weak controller] index in
                guard let controller else { return }
                VigilSessionManager.shared.closeDockTenant(controller, index: index)
            })

        if let strip {
            strip.rootView = stripView
        } else {
            let hosting = NSHostingView(rootView: stripView)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.heightAnchor.constraint(equalToConstant: 26),
                content.topAnchor.constraint(equalTo: hosting.bottomAnchor),
            ])
            strip = hosting
        }

        let target = runtime.views.indices.contains(runtime.active)
            ? runtime.views[runtime.active] : runtime.views.first
        guard mounted !== target else { return }
        mounted?.removeFromSuperview()
        mounted = nil
        guard let target else { return }
        target.removeFromSuperview() // in case it was mounted elsewhere
        target.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(target)
        NSLayoutConstraint.activate([
            target.topAnchor.constraint(equalTo: content.topAnchor),
            target.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            target.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            target.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        mounted = target
    }

    /// Collapse/teardown: unmount the visible tenant (it lives on in the
    /// runtime) so a hidden dock holds no view in the window's hierarchy.
    func unmountActive() {
        mounted?.removeFromSuperview()
        mounted = nil
    }
}

/// The tenant strip: one chip per tenant (live title via the surface's
/// published title), a close on the active chip, and a + spawning a fresh
/// tenant shell in the tab's cwd.
struct VigilDockStrip: View {
    let tenants: [Ghostty.SurfaceView]
    let active: Int
    var onSelect: (Int) -> Void
    var onAdd: () -> Void
    var onClose: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(tenants.enumerated()), id: \.1.id) { index, view in
                        chip(index: index, view: view)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("New dock pane (a shell in this tab's directory).")
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
    }

    private func chip(index: Int, view: Ghostty.SurfaceView) -> some View {
        let on = index == active
        return HStack(spacing: 3) {
            VigilDockTenantLabel(surface: view)
            if on {
                Button { onClose(index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close this dock pane (its process dies).")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(on ? 0.14 : 0.05)))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }
}

/// The chip's label: the pane's program (argv truth from its daemon's tree
/// file) when it runs something, else its live surface title.
private struct VigilDockTenantLabel: View {
    @ObservedObject var surface: Ghostty.SurfaceView

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .frame(maxWidth: 120)
    }

    private var label: String {
        if let pane = surface.vigilAttachId,
           let program = VigilSessionManager.shared.paneProgram(pane) {
            return program
        }
        let title = surface.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "shell" : title
    }
}

/// A vertical drag handle: resizes whichever bar owns it. `base` reads the
/// width at drag start; `apply` receives the live target width. flip=true
/// for right-side bars (dragging LEFT grows them).
final class VigilDragHandle: NSView {
    private let base: () -> CGFloat
    private let apply: (CGFloat) -> Void
    private let flip: Bool
    private var startWidth: CGFloat = 0
    private var startX: CGFloat = 0

    init(base: @escaping () -> CGFloat, apply: @escaping (CGFloat) -> Void, flip: Bool) {
        self.base = base
        self.apply = apply
        self.flip = flip
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startWidth = base()
        startX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = NSEvent.mouseLocation.x - startX
        apply(startWidth + (flip ? -dx : dx))
    }
}
