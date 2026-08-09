import AppKit

/// Delegate used by ``TabTitleEditor`` to resolve tab-specific behavior.
protocol TabTitleEditorDelegate: AnyObject {
    /// Returns whether inline rename should be allowed for the given tab window.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        canRenameTabFor targetWindow: NSWindow
    ) -> Bool

    /// Returns the current title value to seed into the inline editor.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        titleFor targetWindow: NSWindow
    ) -> String

    /// Called when inline editing commits a title for a target tab window.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        didCommitTitle editedTitle: String,
        for targetWindow: NSWindow
    )

    /// Called when inline editing could not start and the host should show a fallback flow.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        performFallbackRenameFor targetWindow: NSWindow
    )

    /// Called after inline editing finishes (whether committed or cancelled).
    /// Use this to restore focus to the appropriate responder.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        didFinishEditing targetWindow: NSWindow)

    /// The tab's face, shown as a button inside the inline editor. nil means
    /// this tab has no notion of a face and no button is drawn.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        emojiFor targetWindow: NSWindow
    ) -> String?

    /// Commit a face picked inside the inline editor.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        didPickEmoji emoji: String?,
        for targetWindow: NSWindow
    )

    /// The picker UI to show when the face button is clicked. Returning nil
    /// draws no button at all.
    func tabTitleEditorEmojiPicker(
        _ editor: TabTitleEditor,
        for targetWindow: NSWindow,
        onPick: @escaping (String?) -> Void
    ) -> NSViewController?
}

extension TabTitleEditorDelegate {
    func tabTitleEditor(_ editor: TabTitleEditor, emojiFor targetWindow: NSWindow) -> String? { nil }
    func tabTitleEditor(_ editor: TabTitleEditor, didPickEmoji emoji: String?, for targetWindow: NSWindow) {}
    func tabTitleEditorEmojiPicker(
        _ editor: TabTitleEditor,
        for targetWindow: NSWindow,
        onPick: @escaping (String?) -> Void
    ) -> NSViewController? { nil }
}

/// Handles inline tab title editing for native AppKit window tabs.
final class TabTitleEditor: NSObject, NSTextFieldDelegate {
    /// Host window containing the tab bar where editing occurs.
    private weak var hostWindow: NSWindow?
    /// Delegate that provides and commits title data for target tab windows.
    private weak var delegate: TabTitleEditorDelegate?
    /// Local event monitor so fullscreen titlebar-window clicks can also trigger rename.
    private var eventMonitor: Any?

    /// Active inline editor view, if editing is in progress.
    private weak var inlineTitleEditor: NSTextField?
    /// Tab window currently being edited.
    private weak var inlineTitleTargetWindow: NSWindow?
    /// Original state of the tab bar.
    private var previousTabState: TabUIState?
    /// Deferred begin-editing work used to avoid visual flicker on double-click.
    private var pendingEditWorkItem: DispatchWorkItem?
    /// The face button drawn inside the inline editor, and its open picker.
    private weak var emojiButton: NSButton?
    private var emojiPopover: NSPopover?
    /// True from the mousedown on the face button until its picker closes.
    /// Clicking the button pulls first responder off the text field, which
    /// ends editing, which tears the button down before the click can even
    /// land: the picker was unopenable no matter where you clicked. While
    /// this is set, the rename stays open.
    private var faceInteraction = false

    /// Open the face picker anchored to the button, without ending the
    /// rename: picking a face and typing a name are the same edit.
    @objc private func emojiButtonClicked(_ sender: NSButton) {
        guard let targetWindow = inlineTitleTargetWindow else { return }
        emojiPopover?.close()
        guard let controller = delegate?.tabTitleEditorEmojiPicker(
            self, for: targetWindow, onPick: { [weak self] emoji in
                guard let self else { return }
                self.delegate?.tabTitleEditor(self, didPickEmoji: emoji, for: targetWindow)
                sender.title = (emoji?.isEmpty == false) ? emoji! : "🙂"
                sender.alphaValue = (emoji?.isEmpty == false) ? 1.0 : 0.45
                self.emojiPopover?.close()
                self.emojiPopover = nil
                self.faceInteraction = false
                // Straight back to the name field: one gesture, not two.
                if let editor = self.inlineTitleEditor {
                    editor.window?.makeFirstResponder(editor)
                }
            }) else { return }

        let popover = NSPopover()
        popover.contentViewController = controller
        // NOT .transient: a transient popover anchored in the titlebar dies
        // on the first stray event on the way to it (a focus-follows-mouse
        // move, the field editor blinking) - it vanished as you reached for
        // it. This one closes when you pick, when you press esc, or when
        // the rename ends.
        popover.behavior = .applicationDefined
        // Below the button in AppKit's unflipped titlebar space; .maxY put
        // it a titlebar's height away with dead space in between.
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        emojiPopover = popover
    }

    /// Dismiss the picker and return the keyboard to the name field.
    private func closeFacePicker() {
        emojiPopover?.close()
        emojiPopover = nil
        faceInteraction = false
        if let editor = inlineTitleEditor {
            editor.window?.makeFirstResponder(editor)
        }
    }

    /// Creates a coordinator bound to a host window and rename delegate.
    init(hostWindow: NSWindow, delegate: TabTitleEditorDelegate) {
        super.init()

        self.hostWindow = hostWindow
        self.delegate = delegate

        // This is needed so that fullscreen clicks can register since they won't
        // event on the NSWindow. We may want to tighten this up in the future by
        // only doing this if we're fullscreen.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return handleMouseDown(event) ? nil : event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    /// Handles leftMouseDown events from the host window and begins inline edit if possible. If this
    /// returns true then the event was handled by the coordinator.
    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }

        // The picker holds the rename open, so it MUST have a way out: any
        // click that is not inside it (its own window) dismisses it and
        // hands the keyboard back to the name field. Without this, opening
        // the picker and clicking away would wedge the editor open forever.
        if let popover = emojiPopover, popover.isShown,
           event.window !== popover.contentViewController?.view.window {
            let onButton = emojiButton.map { button -> Bool in
                guard let window = button.window else { return false }
                let screen = (event.window ?? window).convertPoint(toScreen: event.locationInWindow)
                let local = button.convert(window.convertPoint(fromScreen: screen), from: nil)
                return button.bounds.contains(local)
            } ?? false
            if !onButton { closeFacePicker() }
        }

        // If we don't have a host window to look up the click, we do nothing.
        guard let hostWindow else { return false }

        // In native fullscreen, AppKit can route titlebar clicks through a detached
        // NSToolbarFullScreenWindow. Only allow clicks from the host window or its
        // fullscreen tab bar window so rename handling stays scoped to this tab strip.
        let sourceWindow = event.window ?? hostWindow
        guard sourceWindow === hostWindow || sourceWindow === hostWindow.tabBarView?.window
        else { return false }

        // Find the tab window that is being clicked.
        let locationInScreen = sourceWindow.convertPoint(toScreen: event.locationInWindow)
        guard let tabIndex = hostWindow.tabIndex(atScreenPoint: locationInScreen),
              let targetWindow = hostWindow.tabbedWindows?[safe: tabIndex],
              delegate?.tabTitleEditor(self, canRenameTabFor: targetWindow) == true
        else { return false }

        // The face button is part of the editor, not the tab: let AppKit
        // deliver the click to it. Without this the monitor swallowed the
        // event and the picker could never be opened.
        if let button = emojiButton, button.window != nil {
            let inButton = button.convert(
                button.window!.convertPoint(fromScreen: locationInScreen), from: nil)
            if button.bounds.contains(inButton) {
                faceInteraction = true
                return false
            }
        }

        guard !isMouseEventWithinEditor(event) else {
            // If the click lies within the editor,
            // we should forward the event to the editor
            inlineTitleEditor?.mouseDown(with: event)
            return true
        }
        // We only want double-clicks to enable editing
        guard event.clickCount == 2 else { return false }
        // We need to start editing in a separate event loop tick, so set that up.
        pendingEditWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak targetWindow] in
            guard let self, let targetWindow else { return }
            if self.beginEditing(for: targetWindow) {
                return
            }

            // Inline editing failed, so trigger fallback rename whatever it is.
            self.delegate?.tabTitleEditor(self, performFallbackRenameFor: targetWindow)
        }

        pendingEditWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
        return true
    }

    /// Handles rightMouseDown events from the host window.
    ///
    /// If this returns true then the event was handled by the coordinator.
    func handleRightMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .rightMouseDown else { return false }
        if isMouseEventWithinEditor(event) {
            inlineTitleEditor?.rightMouseDown(with: event)
            return true
        } else {
            return false
        }
    }

    /// Begins editing the given target tab window title. Returns true if we're able to start the
    /// inline edit.
    @discardableResult
    func beginEditing(for targetWindow: NSWindow) -> Bool {
        // Resolve the visual tab button for the target tab window. We rely on visual order
        // since native tab view hierarchy order does not necessarily match what is on screen.
        guard let hostWindow,
              let tabbedWindows = hostWindow.tabbedWindows,
              let tabIndex = tabbedWindows.firstIndex(of: targetWindow),
              let tabButton = hostWindow.tabButtonsInVisualOrder()[safe: tabIndex],
              delegate?.tabTitleEditor(self, canRenameTabFor: targetWindow) == true
        else { return false }

        // If we have a pending edit, we need to cancel it because we got
        // called to start edit explicitly.
        pendingEditWorkItem?.cancel()
        pendingEditWorkItem = nil
        finishEditing(commit: true)

        let tabState = TabUIState(tabButton: tabButton)

        // Build the editor using title text and style derived from the tab's existing label.
        let editedTitle = delegate?.tabTitleEditor(self, titleFor: targetWindow) ?? targetWindow.title
        let sourceLabel = sourceTabTitleLabel(from: tabState.labels.map(\.label), matching: editedTitle)

        let editor = NSTextField(frame: .zero)
        editor.delegate = self
        editor.stringValue = editedTitle
        editor.alignment = sourceLabel?.alignment ?? .center
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.lineBreakMode = .byClipping
        if let editorCell = editor.cell as? NSTextFieldCell {
            editorCell.wraps = false
            editorCell.usesSingleLineMode = true
            editorCell.isScrollable = true
        }
        if let sourceLabel {
            applyTextStyle(to: editor, from: sourceLabel, title: editedTitle)
        }

        // Hide it until the tab button has finished layout so we can avoid flicker.
        editor.isHidden = true

        inlineTitleEditor = editor
        inlineTitleTargetWindow = targetWindow
        previousTabState = tabState
        // Temporarily hide native title label views while editing so only the text field is visible.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tabState.hide()

        tabButton.layoutSubtreeIfNeeded()
        tabButton.displayIfNeeded()
        tabButton.addSubview(editor)
        editor.translatesAutoresizingMaskIntoConstraints = false
        let horizontalInset: CGFloat = 6
        let editorHeight = sourceLabel?.bounds.height ?? tabButton.bounds.height

        // The face lives WHERE THE NAME IS: renaming a tab and giving it a
        // face are one gesture, so the picker sits inside the inline editor
        // instead of hiding behind a context menu.
        // The text field stays EXACTLY as vanilla ghostty lays it out: same
        // anchors, same alignment, no shift. The face is an INDEPENDENT
        // control floating at the leading edge, so the rename you already
        // know is untouched and the picker is simply there.
        NSLayoutConstraint.activate([
            editor.centerYAnchor.constraint(equalTo: tabButton.centerYAnchor),
            editor.leadingAnchor.constraint(equalTo: tabButton.leadingAnchor, constant: horizontalInset),
            editor.trailingAnchor.constraint(equalTo: tabButton.trailingAnchor, constant: -horizontalInset),
            editor.heightAnchor.constraint(equalToConstant: editorHeight),
        ])

        let face = delegate?.tabTitleEditor(self, emojiFor: targetWindow)
        if delegate?.tabTitleEditorEmojiPicker(self, for: targetWindow, onPick: { _ in }) != nil {
            let button = NSButton(frame: .zero)
            button.title = (face?.isEmpty == false) ? face! : "🙂"
            // The face, then a chevron: the classic "there are others"
            // affordance, so it reads as a picker and not as decoration.
            button.image = NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: "Pick a face")?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))
            button.imagePosition = .imageTrailing
            button.imageHugsTitle = true
            button.alphaValue = (face?.isEmpty == false) ? 1.0 : 0.7
            // A real control: the bezel appears under the cursor so the
            // whole emoji-plus-chevron reads as one clickable thing, and
            // you can see exactly where it triggers before you click.
            button.isBordered = true
            button.bezelStyle = .roundRect
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = #selector(emojiButtonClicked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.toolTip = "Pick a face for this tab"
            tabButton.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: tabButton.centerYAnchor),
                button.leadingAnchor.constraint(
                    equalTo: tabButton.leadingAnchor, constant: horizontalInset),
                button.heightAnchor.constraint(equalToConstant: 18),
            ])
            emojiButton = button
        }
        CATransaction.commit()

        // Focus after insertion so AppKit has created the field editor for this text field.
        DispatchQueue.main.async { [weak hostWindow, weak editor] in
            guard let editor else { return }
            let responderWindow = editor.window ?? hostWindow
            guard let responderWindow else { return }
            editor.isHidden = false
            responderWindow.makeFirstResponder(editor)
            if let fieldEditor = editor.currentEditor() as? NSTextView,
               let editorFont = editor.font {
                fieldEditor.font = editorFont
                var typingAttributes = fieldEditor.typingAttributes
                typingAttributes[.font] = editorFont
                fieldEditor.typingAttributes = typingAttributes
            }
            editor.currentEditor()?.selectAll(nil)
        }

        return true
    }

    /// Finishes any in-flight inline edit and optionally commits the edited title.
    func finishEditing(commit: Bool) {
        // If we're pending starting a new edit, cancel it.
        pendingEditWorkItem?.cancel()
        pendingEditWorkItem = nil

        // To finish editing we need a current editor.
        guard let editor = inlineTitleEditor else { return }
        let editedTitle = editor.stringValue
        let targetWindow = inlineTitleTargetWindow

        // Clear coordinator references first so re-entrant paths don't see stale state.
        editor.delegate = nil
        inlineTitleEditor = nil
        inlineTitleTargetWindow = nil

        // Make sure the window grabs focus again
        if let responderWindow = editor.window ?? hostWindow {
            if let currentEditor = editor.currentEditor(), responderWindow.firstResponder === currentEditor {
                responderWindow.makeFirstResponder(nil)
            } else if responderWindow.firstResponder === editor {
                responderWindow.makeFirstResponder(nil)
            }
        }

        // Picking a face is part of THIS rename, not the end of it.
        if faceInteraction { return }

        editor.removeFromSuperview()
        emojiPopover?.close()
        emojiPopover = nil
        emojiButton?.removeFromSuperview()
        emojiButton = nil

        previousTabState?.restore()
        previousTabState = nil

        // Delegate owns title persistence semantics (including empty-title handling).
        guard let targetWindow else { return }

        if commit {
            delegate?.tabTitleEditor(self, didCommitTitle: editedTitle, for: targetWindow)
        }

        // Notify delegate that editing is done so it can restore focus.
        delegate?.tabTitleEditor(self, didFinishEditing: targetWindow)
    }

    /// Selects the best title label candidate from private tab button subviews.
    private func sourceTabTitleLabel(from labels: [NSTextField], matching title: String) -> NSTextField? {
        let expected = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expected.isEmpty {
            // Prefer a visible exact title match when we can find one.
            if let exactVisible = labels.first(where: {
                !$0.isHidden &&
                $0.alphaValue > 0.01 &&
                $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }) {
                return exactVisible
            }

            // Fall back to any exact match, including hidden labels.
            if let exactAny = labels.first(where: {
                $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }) {
                return exactAny
            }
        }

        // Otherwise heuristically choose the largest visible, centered label first.
        let visibleNonEmpty = labels.filter {
            !$0.isHidden &&
            $0.alphaValue > 0.01 &&
            !$0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if let centeredVisible = visibleNonEmpty
            .filter({ $0.alignment == .center })
            .max(by: { $0.bounds.width < $1.bounds.width }) {
            return centeredVisible
        }

        if let visible = visibleNonEmpty.max(by: { $0.bounds.width < $1.bounds.width }) {
            return visible
        }

        return labels.max(by: { $0.bounds.width < $1.bounds.width })
    }

    /// Copies text styling from the source tab label onto the inline editor.
    private func applyTextStyle(to editor: NSTextField, from label: NSTextField, title: String) {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if label.attributedStringValue.length > 0 {
            attributes = label.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        }

        if attributes[.font] == nil, let font = label.font {
            attributes[.font] = font
        }

        if attributes[.foregroundColor] == nil {
            attributes[.foregroundColor] = label.textColor
        }

        if let font = attributes[.font] as? NSFont {
            editor.font = font
        }

        if let textColor = attributes[.foregroundColor] as? NSColor {
            editor.textColor = textColor
        }

        if !attributes.isEmpty {
            editor.attributedStringValue = NSAttributedString(string: title, attributes: attributes)
        } else {
            editor.stringValue = title
        }
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === inlineTitleEditor else { return false }

        // Enter commits and exits inline edit.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(commit: true)
            return true
        }

        // Escape cancels and restores the previous tab title.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }

        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let inlineTitleEditor,
              let finishedEditor = obj.object as? NSTextField,
              finishedEditor === inlineTitleEditor
        else { return }

        // Blur/end-edit commits, matching standard NSTextField behavior.
        finishEditing(commit: true)
    }
}

private extension TabTitleEditor {
    func isMouseEventWithinEditor(_ event: NSEvent) -> Bool {
        guard let editor = inlineTitleEditor?.currentEditor() else {
            return false
        }
        return editor.convert(editor.bounds, to: nil).contains(event.locationInWindow)
    }
}

private extension TabTitleEditor {
    struct TabUIState {
        /// Original hidden state for title labels that are temporarily hidden while editing.
        let labels: [(label: NSTextField, wasHidden: Bool)]
        /// Original hidden state for buttons that are temporarily hidden while editing.
        let buttons: [(button: NSButton, wasHidden: Bool)]
        /// Original button title state restored once editing finishes.
        let titleButton: (button: NSButton, title: String, attributedTitle: NSAttributedString?)?

        init(tabButton: NSView) {
            labels = tabButton
                .descendants(withClassName: "NSTextField")
                .compactMap { $0 as? NSTextField }
                .map { ($0, $0.isHidden) }
            buttons = tabButton
                .descendants(withClassName: "NSButton")
                .compactMap { $0 as? NSButton }
                .map { ($0, $0.isHidden) }
            if let button = tabButton as? NSButton {
                titleButton = (button, button.title, button.attributedTitle)
            } else {
                titleButton = nil
            }
        }

        func hide() {
            for (label, _) in labels {
                label.isHidden = true
            }
            for (btn, _) in buttons {
                btn.isHidden = true
            }
            titleButton?.button.title = ""
            titleButton?.button.attributedTitle = NSAttributedString(string: "")
        }

        func restore() {
            for (label, wasHidden) in labels {
                label.isHidden = wasHidden
            }
            for (btn, wasHidden) in buttons {
                btn.isHidden = wasHidden
            }
            if let titleButton {
                titleButton.button.title = titleButton.title
                if let attributedTitle = titleButton.attributedTitle {
                    titleButton.button.attributedTitle = attributedTitle
                }
            }
        }
    }
}
