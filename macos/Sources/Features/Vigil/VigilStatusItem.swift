import AppKit

/// Menu bar presence for vigil: list sessions with their state, open/detach/
/// rename/forget them, persist the front window. The menu is rebuilt on
/// every open so it never shows stale state.
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
    let menuPersist = NSMenuItem(title: "Persist Front Window", action: #selector(persistFrontWindow(_:)), keyEquivalent: "")
    let menuDetach = NSMenuItem(title: "Detach Front Window", action: #selector(detachFrontWindow(_:)), keyEquivalent: "")

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        // variableLength always: flipping square<->variable on badge changes
        // makes menu bar managers (thaw) re-slot the item and its click
        // tracking goes dead. The button hugs its content either way.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        VigilSessionManager.shared.ghosttyApp = ghostty

        // Let macOS persist the item's menu-bar position across launches
        // (the Apple-standard mechanism; without it the item jumps around).
        statusItem.autosaveName = "com.mitchellh.ghostty.vigil"
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
        for item in [menuNext, menuNextFloating, menuCycle, menuOverview, .separator(), menuNewSession, menuPersist, menuDetach] {
            item.target = self
            item.menu?.removeItem(item)
            menu.addItem(item)
        }

        let holder = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        holder.submenu = menu
        // Before the Help menu, the conventional spot for app-domain menus.
        mainMenu.insertItem(holder, at: max(0, mainMenu.items.count - 1))
    }

    /// The eye opens when sessions want you: filled symbol + count. The image
    /// is a TEMPLATE so the menu bar tints it correctly for light/dark and the
    /// open-menu highlight (the Apple-clean way; a raw colour would not adapt).
    private func updateBadge() {
        guard let button = statusItem.button else { return }
        let count = VigilSessionManager.shared.pendingCount
        let eye = NSImage(
            systemSymbolName: count > 0 ? "eye.fill" : "eye",
            accessibilityDescription: "vigil sessions")
        eye?.isTemplate = true
        button.image = eye
        button.title = count > 0 ? "\(count)" : ""
        button.setAccessibilityLabel(
            count > 0 ? "vigil sessions, \(count) pending" : "vigil sessions")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = VigilSessionManager.shared
        manager.reconcile()

        if manager.pendingCount > 0 {
            let next = NSMenuItem(title: "Next (\(manager.pendingCount) pending)", action: #selector(nextSession(_:)), keyEquivalent: "")
            next.target = self
            next.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
            menu.addItem(next)
            menu.addItem(.separator())
        }

        if manager.sessions.isEmpty {
            let item = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for session in manager.sessions.values.sorted(by: { $0.label < $1.label }) {
            let verb: String
            switch session.state {
            case .embedded: verb = "Focus"
            case .floating: verb = "Focus (in the Quick Terminal)"
            case .detached: verb = "Open (re-embed, still running)"
            case .asleep: verb = "Open (resurrect)"
            }

            // A parent item with a submenu never fires its own action on click,
            // so every verb lives in the submenu. The row's icon carries the
            // state: shape = lifecycle, colour = attention (see stateImage);
            // the emoji face rides the title, never the icon slot.
            let title = [session.emoji, session.label].compactMap { $0 }.joined(separator: " ")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = Self.stateImage(session.state, session.attention)
            let submenu = NSMenu()
            submenu.addItem(sessionItem(verb, #selector(openSession(_:)), session.name, "macwindow"))
            if case .embedded = session.state {
                submenu.addItem(sessionItem("Detach (keep running)", #selector(detachSession(_:)), session.name, "rectangle.portrait.and.arrow.right"))
                if session.persistent {
                    submenu.addItem(sessionItem("Make Ephemeral", #selector(makeEphemeral(_:)), session.name, "hourglass"))
                } else {
                    submenu.addItem(sessionItem("Persist (survive quit)", #selector(persistSession(_:)), session.name, "infinity"))
                }
            }
            submenu.addItem(sessionItem("Rename…", #selector(renameSession(_:)), session.name, "pencil"))
            submenu.addItem(.separator())
            let removal: String
            let removalSymbol: String
            switch session.state {
            case .embedded: removal = "Forget (window stays)"; removalSymbol = "xmark.circle"
            case .floating, .detached: removal = "Kill (processes die)"; removalSymbol = "trash"
            case .asleep: removal = "Forget"; removalSymbol = "xmark.circle"
            }
            submenu.addItem(sessionItem(removal, #selector(forgetSession(_:)), session.name, removalSymbol))
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let create = NSMenuItem(title: "New Session", action: #selector(newSession(_:)), keyEquivalent: "")
        create.target = self
        create.image = NSImage(systemSymbolName: "plus.rectangle", accessibilityDescription: nil)
        menu.addItem(create)
        let persist = NSMenuItem(title: "Persist Front Window", action: #selector(persistFrontWindow(_:)), keyEquivalent: "")
        persist.target = self
        persist.image = NSImage(systemSymbolName: "infinity", accessibilityDescription: nil)
        menu.addItem(persist)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ghostty (kill all sessions)", action: #selector(quitForReal(_:)), keyEquivalent: "")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    @objc private func quitForReal(_ sender: NSMenuItem) {
        VigilSessionManager.shared.quitForReal()
    }

    private func sessionItem(_ title: String, _ action: Selector, _ name: String, _ symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    /// One SF Symbol per session row: SHAPE is the lifecycle state, COLOUR is
    /// attention (red = needs input, green = turn done, none = template so the
    /// menu tints it). A coloured symbol must be non-template for the palette
    /// colour to survive; a monochrome one stays template to adapt to the menu.
    private static func stateImage(
        _ state: VigilSessionManager.State,
        _ attention: VigilSessionManager.Attention
    ) -> NSImage? {
        let symbol: String
        switch state {
        case .embedded: symbol = "macwindow"
        case .floating: symbol = "macwindow.on.rectangle"
        case .detached: symbol = "pause.circle"
        case .asleep: symbol = "moon.zzz"
        }
        let colour: NSColor?
        switch attention {
        case .input: colour = .systemRed
        case .done: colour = .systemGreen
        case .none: colour = nil
        }
        var config = NSImage.SymbolConfiguration(scale: .medium)
        if let colour { config = config.applying(.init(paletteColors: [colour])) }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = colour == nil
        return image
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

    @objc private func persistSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.setPersistent(name: name, true)
    }

    @objc private func makeEphemeral(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.setPersistent(name: name, false)
    }

    @objc private func forgetSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilSessionManager.shared.forget(name: name)
    }

    @objc private func renameSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        VigilIdentity.editModal(name: name)
    }

    @objc private func detachFrontWindow(_ sender: NSMenuItem) {
        VigilSessionManager.shared.detachFrontWindow()
    }

    @objc private func newSession(_ sender: NSMenuItem) {
        let cwd = TerminalController.preferredParent?.focusedSurface?.pwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        VigilSessionManager.shared.create(cwd: cwd)
    }

    @objc private func persistFrontWindow(_ sender: NSMenuItem) {
        guard let controller = TerminalController.preferredParent else { return }
        VigilSessionManager.shared.persistFully(controller: controller)
    }
}
