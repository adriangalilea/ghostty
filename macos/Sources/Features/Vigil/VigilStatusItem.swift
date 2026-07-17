import AppKit

/// Menu bar presence for vigil: list sessions with their state, open/detach/
/// rename/forget them, adopt the front window (zero friction, auto-named).
/// The menu is rebuilt on every open so it never shows stale state.
@MainActor
class VigilStatusItem: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let ghostty: Ghostty.App

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        VigilSessionManager.shared.ghosttyApp = ghostty

        statusItem.button?.image = NSImage(
            systemSymbolName: "eye",
            accessibilityDescription: "vigil sessions")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        VigilSessionManager.shared.onAttentionChange = { [weak self] in
            self?.updateBadge()
        }
        updateBadge()
    }

    /// The eye opens when sessions want you: count as badge, filled symbol.
    private func updateBadge() {
        let count = VigilSessionManager.shared.pendingCount
        statusItem.length = count > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        statusItem.button?.image = NSImage(
            systemSymbolName: count > 0 ? "eye.fill" : "eye",
            accessibilityDescription: "vigil sessions")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = VigilSessionManager.shared
        manager.reconcile()

        if manager.pendingCount > 0 {
            let next = NSMenuItem(title: "Next (\(manager.pendingCount) pending)", action: #selector(nextSession(_:)), keyEquivalent: "")
            next.target = self
            menu.addItem(next)
            menu.addItem(.separator())
        }

        if manager.sessions.isEmpty {
            let item = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for session in manager.sessions.values.sorted(by: { $0.label < $1.label }) {
            var glyph: String
            let verb: String
            switch session.state {
            case .embedded:
                glyph = "●"
                verb = "Focus"
            case .detached:
                glyph = "◌"
                verb = "Open (re-embed, still running)"
            case .asleep:
                glyph = "○"
                verb = "Open (resurrect)"
            }
            switch session.attention {
            case .input: glyph = "🔔 \(glyph)"
            case .done: glyph = "✓ \(glyph)"
            case .none: break
            }

            // A parent item with a submenu never fires its own action on click,
            // so every verb lives in the submenu.
            let item = NSMenuItem(title: "\(glyph) \(session.label)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(sessionItem(verb, #selector(openSession(_:)), session.name))
            if case .embedded = session.state {
                submenu.addItem(sessionItem("Detach (keep running)", #selector(detachSession(_:)), session.name))
            }
            submenu.addItem(sessionItem("Rename…", #selector(renameSession(_:)), session.name))
            submenu.addItem(.separator())
            submenu.addItem(sessionItem("Forget (kill if alive)", #selector(forgetSession(_:)), session.name))
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let adopt = NSMenuItem(title: "Adopt Front Window", action: #selector(adoptFrontWindow(_:)), keyEquivalent: "")
        adopt.target = self
        menu.addItem(adopt)
    }

    private func sessionItem(_ title: String, _ action: Selector, _ name: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    @objc private func nextSession(_ sender: NSMenuItem) {
        VigilSessionManager.shared.next()
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.open(name: name)
    }

    @objc private func detachSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.detach(name: name)
    }

    @objc private func forgetSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.forget(name: name)
    }

    @objc private func renameSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        guard let session = VigilSessionManager.shared.sessions[name] else { return }

        let alert = NSAlert()
        alert.messageText = "Rename session"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = session.label
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        VigilSessionManager.shared.rename(name: name, label: label)
    }

    @objc private func adoptFrontWindow(_ sender: NSMenuItem) {
        guard let controller = TerminalController.preferredParent else { return }
        VigilSessionManager.shared.adopt(controller: controller)
    }
}
