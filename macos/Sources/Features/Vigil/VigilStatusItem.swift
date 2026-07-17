import AppKit

/// Menu bar presence for vigil: list sessions with their state, open/detach/
/// rename/forget them, adopt the front window (zero friction, auto-named).
/// The menu is rebuilt on every open so it never shows stale state.
@MainActor
class VigilStatusItem: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let ghostty: Ghostty.App

    /// Sessions menu items. Shortcuts come from the ghostty config (the
    /// `vigil_*` keybind actions) via AppDelegate.syncMenuShortcuts, never
    /// hardcoded: the user binds them, so conflicts are impossible here.
    let menuNext = NSMenuItem(title: "Next", action: #selector(nextSession(_:)), keyEquivalent: "")
    let menuCycle = NSMenuItem(title: "Cycle", action: #selector(cycleSession(_:)), keyEquivalent: "")
    let menuNextFloating = NSMenuItem(title: "Next Floating", action: #selector(nextFloating(_:)), keyEquivalent: "")
    let menuOverview = NSMenuItem(title: "Overview", action: #selector(overview(_:)), keyEquivalent: "")
    let menuNewSession = NSMenuItem(title: "New Session", action: #selector(newSession(_:)), keyEquivalent: "")
    let menuAdopt = NSMenuItem(title: "Adopt Front Window", action: #selector(adoptFrontWindow(_:)), keyEquivalent: "")
    let menuDetach = NSMenuItem(title: "Detach Front Window", action: #selector(detachFrontWindow(_:)), keyEquivalent: "")

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        // variableLength always: flipping square<->variable on badge changes
        // makes menu bar managers (thaw) re-slot the item and its click
        // tracking goes dead. The button hugs its content either way.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        installMainMenu()

        // Any window becoming key while in service mode (AppleScript, dock,
        // whatever) brings back the regular app presence.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                // The overview panel is a peek, not a return from service mode.
                if notification.object is VigilOverviewPanel { return }
                if NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
            }
        }
    }

    /// Native "Sessions" menu in the menu bar. Shortcuts are synced from the
    /// ghostty config exactly like every other menu item. Idempotent and
    /// re-callable: the app's main menu can be rebuilt after launch, wiping
    /// a menu installed at init.
    func installMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard !mainMenu.items.contains(where: { $0.title == "Sessions" }) else { return }

        let menu = NSMenu(title: "Sessions")
        for item in [menuNext, menuNextFloating, menuCycle, menuOverview, .separator(), menuNewSession, menuAdopt, menuDetach] {
            item.target = self
            item.menu?.removeItem(item)
            menu.addItem(item)
        }

        let holder = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        holder.submenu = menu
        // Before the Help menu, the conventional spot for app-domain menus.
        mainMenu.insertItem(holder, at: max(0, mainMenu.items.count - 1))
    }

    /// The eye opens when sessions want you: count as badge, filled symbol.
    private func updateBadge() {
        let count = VigilSessionManager.shared.pendingCount
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
            case .floating:
                glyph = "◍"
                verb = "Focus (in the quick terminal)"
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
                if !manager.daemonBacked(session: session) {
                    submenu.addItem(sessionItem("Upgrade (survive quit)", #selector(upgradeSession(_:)), session.name))
                }
            }
            submenu.addItem(sessionItem("Rename…", #selector(renameSession(_:)), session.name))
            submenu.addItem(.separator())
            let removal: String
            switch session.state {
            case .embedded: removal = "Unadopt (window stays)"
            case .floating, .detached: removal = "Kill (processes die)"
            case .asleep: removal = "Forget"
            }
            submenu.addItem(sessionItem(removal, #selector(forgetSession(_:)), session.name))
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let create = NSMenuItem(title: "New Session", action: #selector(newSession(_:)), keyEquivalent: "")
        create.target = self
        menu.addItem(create)
        let adopt = NSMenuItem(title: "Adopt Front Window", action: #selector(adoptFrontWindow(_:)), keyEquivalent: "")
        adopt.target = self
        menu.addItem(adopt)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ghostty (kill all sessions)", action: #selector(quitForReal(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func quitForReal(_ sender: NSMenuItem) {
        VigilSessionManager.shared.quitForReal()
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

    @objc private func cycleSession(_ sender: NSMenuItem) {
        VigilSessionManager.shared.cycle()
    }

    @objc private func nextFloating(_ sender: NSMenuItem) {
        VigilSessionManager.shared.nextFloating()
    }

    @objc private func overview(_ sender: NSMenuItem) {
        VigilOverview.shared.toggle()
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.open(name: name)
    }

    @objc private func detachSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.detach(name: name)
    }

    @objc private func upgradeSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.upgrade(name: name)
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

    @objc private func detachFrontWindow(_ sender: NSMenuItem) {
        VigilSessionManager.shared.detachFrontWindow()
    }

    @objc private func newSession(_ sender: NSMenuItem) {
        let cwd = TerminalController.preferredParent?.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        VigilSessionManager.shared.create(cwd: cwd)
    }

    @objc private func adoptFrontWindow(_ sender: NSMenuItem) {
        guard let controller = TerminalController.preferredParent else { return }
        VigilSessionManager.shared.adopt(controller: controller)
    }
}
