import AppKit
import SwiftUI

/// Click the FACE in a tab to change it: the picker opens right on the tab,
/// the exact same mechanism as ghostty's double-click rename. No view is
/// ever injected into Apple's private tab strip (a guest view there
/// overlapped the close button and never received a click); ONE local event
/// monitor hit-tests single clicks against the emoji glyph at the start of
/// the tab's rendered title and anchors the picker to that glyph. The tab's
/// views are only READ, never mutated.
@MainActor
enum VigilTabFacePicker {
    private static var monitor: Any?
    private static var popover: NSPopover?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated {
                handle(event) ? nil : event
            }
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1,
              let window = event.window,
              window.tabGroup != nil
        else { return false }

        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        guard let index = window.tabIndex(atScreenPoint: screenPoint),
              let tabButton = window.tabButtonsInVisualOrder()[safe: index],
              let tabWindow = window.tabbedWindows?[safe: index],
              let controller = tabWindow.windowController as? TerminalController,
              let key = VigilSessionManager.shared.tabIdentityKey(for: controller),
              let emoji = VigilSessionManager.shared.customIdentity(key)?.emoji,
              !emoji.isEmpty
        else { return false }

        // The face is the first grapheme of the rendered title: find the
        // visible label showing it and measure where the glyph sits. A
        // hidden label means an inline rename is in progress - the editor
        // owns the strip then.
        guard let label = tabButton.descendants(withClassName: "NSTextField")
            .compactMap({ $0 as? NSTextField })
            .first(where: { !$0.isHidden && $0.stringValue.hasPrefix(emoji) })
        else { return false }

        let font = label.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let full = (label.stringValue as NSString).size(withAttributes: [.font: font]).width
        let glyph = (emoji as NSString).size(withAttributes: [.font: font]).width
        let start: CGFloat
        switch label.alignment {
        case .center: start = max((label.bounds.width - full) / 2, 0)
        case .right: start = max(label.bounds.width - full, 0)
        default: start = 0
        }
        let region = NSRect(x: start - 2, y: 0, width: glyph + 4, height: label.bounds.height)
        guard let labelWindow = label.window else { return false }
        let inLabel = label.convert(labelWindow.convertPoint(fromScreen: screenPoint), from: nil)
        guard region.contains(inLabel) else { return false }

        open(anchor: region, of: label, key: key, selected: emoji)
        return true
    }

    private static func open(anchor: NSRect, of view: NSView, key: String, selected: String?) {
        popover?.close()
        let manager = VigilSessionManager.shared
        let controller = NSHostingController(
            rootView: VigilEmojiPickerView(selected: selected) { picked in
                manager.setCustomIdentity(
                    key: key,
                    label: manager.customIdentity(key)?.label,
                    emoji: picked)
                popover?.close()
                popover = nil
            })
        controller.preferredContentSize = NSSize(width: 300, height: 320)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = controller
        pop.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        popover = pop
    }
}
