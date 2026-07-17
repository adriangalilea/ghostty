import AppKit

/// Menu bar presence for vigil: list sessions with their state, open/detach/
/// forget them, adopt the front window. The menu is rebuilt on every open so
/// it never shows stale state.
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
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = VigilSessionManager.shared
        manager.reconcile()

        if manager.sessions.isEmpty {
            let item = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for session in manager.sessions.values.sorted(by: { $0.name < $1.name }) {
            let label: String
            switch session.state {
            case .embedded: label = "● \(session.name)"
            case .detached: label = "◌ \(session.name)"
            case .asleep: label = "○ \(session.name)"
            }
            // A parent item with a submenu never fires its own action on click,
            // so every verb lives in the submenu.
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let open = NSMenuItem(title: "Open", action: #selector(openSession(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = session.name
            submenu.addItem(open)
            if case .embedded = session.state {
                let detach = NSMenuItem(title: "Detach (keep running)", action: #selector(detachSession(_:)), keyEquivalent: "")
                detach.target = self
                detach.representedObject = session.name
                submenu.addItem(detach)
            }
            let forget = NSMenuItem(title: "Forget (kill if alive)", action: #selector(forgetSession(_:)), keyEquivalent: "")
            forget.target = self
            forget.representedObject = session.name
            submenu.addItem(forget)
            item.submenu = submenu

            menu.addItem(item)
        }

        menu.addItem(.separator())
        let adopt = NSMenuItem(title: "Adopt Front Window…", action: #selector(adoptFrontWindow(_:)), keyEquivalent: "")
        adopt.target = self
        menu.addItem(adopt)
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

    @objc private func adoptFrontWindow(_ sender: NSMenuItem) {
        guard let controller = TerminalController.preferredParent else { return }

        let alert = NSAlert()
        alert.messageText = "Adopt window as vigil session"
        alert.informativeText = "Name this workspace. It becomes detachable and survives restarts."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "session name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Adopt")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        VigilSessionManager.shared.adopt(controller: controller, name: name)
    }
}
