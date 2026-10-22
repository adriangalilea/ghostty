import AuthzGlance
import SwiftUI
import VigilWire

/// Creating from the phone: a workspace on a Mac (its folder, its program,
/// its label), a tab or a split beside a pane. Every creation is a
/// `WorkspaceCommand` to the pane's home Mac (`VigilPhone.create`), and the
/// new pane opens full screen with the keyboard up, at the phone's size.
///
/// Where it is offered, so creating is one or two taps from anywhere:
///  - the home's `+` (a terminal on the Mac you last used, now; a Claude;
///    or the sheet),
///  - each Mac's row (its own `+`),
///  - a workspace's, tab's or pane's long press (a tab or split beside it,
///    or a workspace in its folder),
///  - the pane screen's stack menu (the same, beside the pane you are in).
enum Create {
    /// What a new pane may run besides a shell, by name: Claude through
    /// `c`, the agent-hud router (the one Claude entrypoint on Adrian's
    /// Macs: it picks the account; bare `claude` pins the default one).
    static let presets: [(name: String, command: String)] = [("Claude", "c")]

    /// A preset's name for a command (the command itself otherwise).
    static func name(of command: String?) -> String {
        guard let command else { return "Shell" }
        return presets.first { $0.command == command }?.name ?? command
    }

    /// The folder as a row names it: its last component (`~` for a home
    /// folder given as `~`), the whole path beneath.
    static func caption(_ path: String) -> String {
        path == "~" ? "Home" : URL(fileURLWithPath: path).lastPathComponent
    }
}

/// The items that create beside a pane (a tab, a split) or in its folder
/// (a workspace): one list for a tree row's long press and the pane
/// screen's menu. `landed` opens the new pane.
struct CreateItems: View {
    let host: VigilPhone.Host
    /// The pane a tab or split stands beside (nil: a dock tenant, which
    /// anchors neither; only a workspace is offered).
    let anchor: String?
    /// The folder a new workspace starts in.
    let folder: String?
    let landed: @MainActor (PaneRef) -> Void
    @EnvironmentObject private var model: VigilPhone

    var body: some View {
        if let anchor {
            Button { model.begin(.tab(beside: anchor, command: nil), on: host, landed: landed) } label: {
                Label("New tab", systemImage: "plus.rectangle.on.rectangle")
            }
            ForEach(Create.presets, id: \.command) { preset in
                Button { model.begin(.tab(beside: anchor, command: preset.command), on: host, landed: landed) } label: {
                    Label("New \(preset.name) tab", systemImage: "sparkle")
                }
            }
            Button { model.begin(.split(beside: anchor, direction: "right", command: nil), on: host, landed: landed) } label: {
                Label("Split right", systemImage: "rectangle.split.2x1")
            }
            Button { model.begin(.split(beside: anchor, direction: "down", command: nil), on: host, landed: landed) } label: {
                Label("Split down", systemImage: "rectangle.split.1x2")
            }
        }
        Button { model.composing = .init(host: host, folder: folder) } label: {
            Label("New workspace…", systemImage: "macwindow.badge.plus")
        }
    }
}

/// A Mac's quick creations: a terminal or a Claude in its home folder,
/// now, and the sheet for anything else. The home's `+` (on the Mac you
/// last used) and each Mac's row.
struct QuickCreateItems: View {
    let host: VigilPhone.Host
    @EnvironmentObject private var model: VigilPhone

    var body: some View {
        Button { open(nil) } label: {
            Label("Terminal on \(host.name)", systemImage: "terminal")
        }
        ForEach(Create.presets, id: \.command) { preset in
            Button { open(preset.command) } label: {
                Label("\(preset.name) on \(host.name)", systemImage: "sparkle")
            }
        }
        Button { model.composing = .init(host: host, folder: nil) } label: {
            Label("New workspace…", systemImage: "macwindow.badge.plus")
        }
    }

    /// A workspace in the Mac's home folder, opened as soon as it runs.
    private func open(_ command: String?) {
        model.begin(.workspace(cwd: "~", command: command, label: nil), on: host) { ref in
            model.typeInto = ref
            model.opening = ref
        }
    }
}

/// A new workspace, said in full before it is sent: which Mac, which
/// folder (where that Mac's panes work, most recent first; its home; or
/// a path typed), what it runs (a shell, a preset, a program that Mac's
/// panes were born with, or one typed) and an optional label.
struct NewWorkspaceSheet: View {
    let compose: VigilPhone.Compose
    let landed: @MainActor (PaneRef) -> Void
    @EnvironmentObject private var model: VigilPhone
    @Environment(\.dismiss) private var dismiss
    @State private var hostId: String = ""
    @State private var folder: String = "~"
    @State private var typedFolder = ""
    @State private var command: String?
    @State private var typedCommand = ""
    @State private var label = ""
    @FocusState private var typing: Field?

    enum Field { case folder, command, label }

    private var host: VigilPhone.Host? { model.hosts.first { $0.id == hostId } }

    /// The folder sent: the typed one while there is one.
    private var chosenFolder: String {
        let typed = typedFolder.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? folder : typed
    }
    /// The command sent: the typed one while there is one.
    private var chosenCommand: String? {
        let typed = typedCommand.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? command : typed
    }
    private var chosenLabel: String? {
        let typed = label.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? nil : typed
    }
    private var request: VigilPhone.Birth { .workspace(cwd: chosenFolder, command: chosenCommand, label: chosenLabel) }

    /// Why it cannot be sent as it stands (nil: it can).
    private var problem: String? {
        guard let host else { return "Choose a Mac." }
        guard model.reachable(host) else { return "\(host.name) can't be reached right now." }
        return WorkspaceRules.refusal(cwd: chosenFolder, command: chosenCommand, label: chosenLabel)
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.hosts.count > 1 {
                    Section("Mac") {
                        Picker("Mac", selection: $hostId) {
                            ForEach(model.hosts) { host in
                                Text(host.name).tag(host.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                folderSection
                commandSection
                Section {
                    TextField("Label (optional)", text: $label)
                        .focused($typing, equals: .label)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit(create)
                } footer: {
                    Text("Shown in every sidebar; its random name otherwise.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { createBar }
        }
        .presentationDetents([.large])
        .onAppear {
            model.failure = nil
            hostId = compose.host?.id ?? model.scratchMac?.id ?? model.hosts.first?.id ?? ""
            if let start = compose.folder { folder = start }
        }
        // A failure said here is read here: it does not follow you out.
        .onDisappear { if model.creating == nil { model.failure = nil } }
        .onChange(of: hostId) { old, _ in
            // Another Mac's folders are its own: a folder picked from the
            // last one's list goes back to home.
            if !old.isEmpty { folder = "~" }
        }
    }

    @ViewBuilder private var folderSection: some View {
        Section {
            folderRow("~", detail: nil)
            if let start = compose.folder, compose.host?.id == hostId, start != "~" {
                folderRow(start, detail: start)
            }
            ForEach(recent, id: \.self) { path in folderRow(path, detail: path) }
            TextField("Another folder: /path or ~/path", text: $typedFolder)
                .focused($typing, equals: .folder)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Folder")
        } footer: {
            if let host { Text("Recent folders are where \(host.name)'s panes work. A folder that is gone starts in its nearest parent.") }
        }
    }

    /// The Mac's recent folders, without the ones already shown above.
    private var recent: [String] {
        guard let host else { return [] }
        return Array(model.recentFolders(on: host).filter { $0 != compose.folder }.prefix(6))
    }

    private func folderRow(_ path: String, detail: String?) -> some View {
        choiceRow(selected: typedFolder.isEmpty && folder == path) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Create.caption(path))
                if let detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        } action: {
            folder = path
            typedFolder = ""
            typing = nil
        }
    }

    @ViewBuilder private var commandSection: some View {
        Section {
            commandRow(nil)
            ForEach(commands, id: \.self) { commandRow($0) }
            TextField("Another program", text: $typedCommand)
                .focused($typing, equals: .command)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Runs")
        } footer: {
            if let chosenCommand {
                Text("The pane runs `\(chosenCommand)` in a login shell and closes when it exits.")
            } else {
                Text("A login shell.")
            }
        }
    }

    /// The presets, then what this Mac's panes were born running.
    private var commands: [String] {
        let presets = Create.presets.map(\.command)
        let known = host.map { model.knownCommands(on: $0) } ?? []
        return presets + known.filter { !presets.contains($0) }.prefix(4)
    }

    private func commandRow(_ value: String?) -> some View {
        choiceRow(selected: typedCommand.isEmpty && command == value) {
            HStack {
                Text(Create.name(of: value))
                if let value, Create.name(of: value) != value {
                    Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        } action: {
            command = value
            typedCommand = ""
            typing = nil
        }
    }

    private func choiceRow<Content: View>(selected: Bool, @ViewBuilder content: () -> Content,
                                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                content()
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Hue.yes).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What will happen, said whole, and the one button that does it.
    private var createBar: some View {
        VStack(spacing: 6) {
            if let failure = model.failure {
                Text(failure.message).font(.caption).foregroundStyle(Hue.care).multilineTextAlignment(.center)
            } else if let problem {
                Text(problem).font(.caption).foregroundStyle(Hue.care)
            } else if let host {
                Text("\(host.name) · \(chosenFolder) · \(Create.name(of: chosenCommand))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(action: create) {
                HStack(spacing: 8) {
                    if model.creating != nil { ProgressView().tint(.white) }
                    Text(model.creating != nil ? "Creating…" : "Create and open")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Hue.yes)
            .disabled(problem != nil || model.creating != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // The form scrolls under it: the bar keeps its own ground.
        .background(.bar)
    }

    private func create() {
        guard problem == nil, let host else { return }
        model.failure = nil
        let landed = self.landed
        model.begin(request, on: host) { ref in
            dismiss()
            landed(ref)
        }
    }
}

/// The request rules the Mac applies (`WorkspaceCommand.Request.refusal`),
/// asked before sending so the sheet says what is wrong as it is typed.
enum WorkspaceRules {
    static func refusal(cwd: String, command: String?, label: String?) -> String? {
        let request = WorkspaceCommand.Request.create(cwd: cwd, command: command, label: label)
        guard let why = request.refusal else { return nil }
        return why.prefix(1).uppercased() + why.dropFirst() + "."
    }
}
