import AppKit
import SwiftUI

/// The tab's face control: the SAME shape as the sidebar's (face, hairline,
/// chevron, one rounded container that lights under the cursor), sitting at
/// the LEADING edge of the tab, before the name, exactly where every
/// sidebar row puts it. Mounted as an AppKit subview of the tab button -
/// the same pattern upstream's own inline rename uses (it injects its
/// NSTextField into the very same view), and AppKit deliberately: SwiftUI
/// buttons do not receive clicks inside the tab strip (upstream's comment
/// on the tab accessory records it; our own attempt confirmed it live).
/// An NSButton subclass ON PURPOSE: the inline editor hides all NSButtons
/// in the tab while renaming, so this control disappears and reappears
/// with the rest of the chrome for free.
final class VigilTabFaceControl: NSButton {
    private(set) var currentEmoji: String?
    var onPick: ((String?) -> Void)?
    private var popover: NSPopover?
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    private let faceLabel = NSTextField(labelWithString: "")
    private let hairline = NSView()
    private let chevron = NSImageView()

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        target = self
        action = #selector(openPicker)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5

        faceLabel.font = .systemFont(ofSize: 10.5)
        faceLabel.alignment = .center
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        chevron.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Pick a face")?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor

        let stack = NSStackView(views: [faceLabel, hairline, chevron])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            hairline.heightAnchor.constraint(equalToConstant: 9),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        toolTip = "Pick this tab's face"
        update(emoji: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func update(emoji: String?) {
        currentEmoji = emoji
        if let emoji, !emoji.isEmpty {
            faceLabel.stringValue = emoji
            faceLabel.alphaValue = 1.0
        } else {
            faceLabel.stringValue = "😶"
            faceLabel.alphaValue = 0.55
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(hovering ? 0.14 : 0.06).cgColor
        layer?.borderColor = NSColor.labelColor
            .withAlphaComponent(hovering ? 0.25 : 0.10).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// One click opens the picker even when the window is not focused.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    @objc func openPicker() {
        popover?.close()
        let controller = NSHostingController(
            rootView: VigilEmojiPickerView(selected: currentEmoji) { [weak self] picked in
                guard let self else { return }
                self.onPick?(picked)
                self.popover?.close()
                self.popover = nil
            })
        controller.preferredContentSize = NSSize(width: 300, height: 320)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = controller
        pop.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        popover = pop
    }
}

/// Keeps every tab wearing its face control. Idempotent and cheap; runs at
/// the same chokepoint as the other window marks, so a regroup that
/// rebuilds AppKit's tab buttons just gets fresh controls on the next sync.
@MainActor
enum VigilTabFaces {
    /// The tab strip swallows mouse events before subviews ever see them:
    /// upstream's inline rename has the same problem and solves it the same
    /// way, forwarding clicks from its event monitor by hand. Ours
    /// hit-tests the mounted controls and triggers the picker directly.
    private static var monitor: Any?

    private static func installMonitorOnce() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated {
                handleClick(event) ? nil : event
            }
        }
    }

    private static func handleClick(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let buttons = window.tabButtonsInVisualOrder()
        guard !buttons.isEmpty else { return false }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        for tabButton in buttons {
            guard let control = tabButton.subviews
                .compactMap({ $0 as? VigilTabFaceControl }).first,
                !control.isHidden,
                let controlWindow = control.window
            else { continue }
            let local = control.convert(
                controlWindow.convertPoint(fromScreen: screen), from: nil)
            if control.bounds.contains(local) {
                control.openPicker()
                return true
            }
        }
        return false
    }

    static func sync(_ window: NSWindow) {
        installMonitorOnce()
        guard window.tabGroup != nil else { return }
        let host = window.tabGroup?.selectedWindow ?? window
        let buttons = host.tabButtonsInVisualOrder()
        guard !buttons.isEmpty else { return }
        for (index, tabButton) in buttons.enumerated() {
            guard let tabWindow = host.tabbedWindows?[safe: index],
                  let controller = tabWindow.windowController as? TerminalController,
                  let key = VigilSessionManager.shared.tabIdentityKey(for: controller)
            else { continue }

            let control: VigilTabFaceControl
            if let existing = tabButton.subviews
                .compactMap({ $0 as? VigilTabFaceControl }).first {
                control = existing
            } else {
                control = VigilTabFaceControl()
                control.translatesAutoresizingMaskIntoConstraints = false
                // LEFT of the name, after the native close button's slot,
                // mirroring the sidebar rows.
                tabButton.addSubview(control)
                NSLayoutConstraint.activate([
                    control.leadingAnchor.constraint(
                        equalTo: tabButton.leadingAnchor, constant: 22),
                    control.centerYAnchor.constraint(equalTo: tabButton.centerYAnchor),
                ])
            }
            control.update(emoji: VigilSessionManager.shared.customIdentity(key)?.emoji)
            control.onPick = { [weak controller] picked in
                guard let controller,
                      let key = VigilSessionManager.shared.tabIdentityKey(for: controller)
                else { return }
                VigilSessionManager.shared.setCustomIdentity(
                    key: key,
                    label: VigilSessionManager.shared.customIdentity(key)?.label,
                    emoji: picked)
            }
        }
    }
}
