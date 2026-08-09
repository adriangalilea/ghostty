import AppKit
import SwiftUI

/// The tab's face, on Apple's PUBLIC per-tab surface: NSWindowTab's
/// accessoryView, the same stack ghostty already uses for the ⌘N label and
/// the reset-zoom button. Every tab gets one, face or not - the control IS
/// how a tab gets its first face. AppKit deliberately: upstream's comment
/// on that stack records that SwiftUI buttons do not receive clicks there,
/// which is exactly why its own reset-zoom is an NSButton. Same shape as
/// the sidebar's face control: face, then chevron, one bordered container.
final class VigilTabFaceControl: NSButton {
    private(set) var currentEmoji: String?
    var onPick: ((String?) -> Void)?
    private var popover: NSPopover?

    init() {
        super.init(frame: .zero)
        bezelStyle = .recessed
        showsBorderOnlyWhileMouseInside = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageTrailing
        imageHugsTitle = true
        image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Pick a face")?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .semibold))
        font = .systemFont(ofSize: 10)
        target = self
        action = #selector(openPicker)
        refusesFirstResponder = true
        isHidden = true // shown by the first sync of a vigil-backed window
        update(emoji: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func update(emoji: String?) {
        currentEmoji = emoji
        title = (emoji?.isEmpty == false) ? emoji! : "😶"
        alphaValue = (emoji?.isEmpty == false) ? 1.0 : 0.6
        toolTip = "Pick this tab's face"
    }

    @objc private func openPicker() {
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
