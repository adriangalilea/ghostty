import GhosttyKit
import Log
import SwiftUI
import UIKit

/// The phone's libghostty: one core app for every surface, over the C API
/// (`ghostty.h`) and nothing else. The phone is a viewport onto panes that
/// live on the Macs, so of the core's actions it consumes only the facts
/// about a surface (cell metrics, title, renderer health, the stream's
/// end); window management, clipboards and quitting are not the phone's.
@MainActor
final class TerminalCore: ObservableObject {
    let app: ghostty_app_t
    /// The terminal's ground, from the theme: what every screen around a
    /// surface paints so the edges never flash another color.
    let background: Color
    /// Kept for the app's lifetime: the core reads it as it makes surfaces.
    private let config: ghostty_config_t

    nonisolated private static let log = Log.log.scope("terminal")

    init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            preconditionFailure("ghostty_init failed")
        }
        guard let config = ghostty_config_new() else { preconditionFailure("ghostty_config_new failed") }
        // The Mac's theme, written into the sandbox (VigilTheme).
        if let path = VigilTheme.configPath() { ghostty_config_load_file(config, path) }
        ghostty_config_finalize(config)
        for at in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, UInt32(at))
            Self.log.warn("config diagnostic", ["message": String(cString: diagnostic.message)])
        }
        self.config = config
        background = Self.background(of: config)

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in TerminalCore.wakeup() },
            action_cb: { _, target, action in TerminalCore.action(target, action) },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in })
        guard let app = ghostty_app_new(&runtime, config) else { preconditionFailure("ghostty_app_new failed") }
        self.app = app
        Self.shared = self
    }

    /// The one app the callbacks tick.
    private static weak var shared: TerminalCore?

    private static func background(of config: ghostty_config_t) -> Color {
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else {
            return Color(UIColor.systemBackground)
        }
        return Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }

    /// The core's mailbox drains on the app tick (a surface's messages, a
    /// child exit among them, ride it): a wakeup that ticks nothing leaves
    /// them queued forever.
    nonisolated private static func wakeup() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let app = shared?.app else { return }
                ghostty_app_tick(app)
            }
        }
    }

    /// A surface's facts go to its view, on the main thread; everything
    /// else is refused, by name.
    nonisolated private static func action(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return false }
        let view = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
        switch action.tag {
        case GHOSTTY_ACTION_CELL_SIZE:
            let size = CGSize(width: Double(action.action.cell_size.width), height: Double(action.action.cell_size.height))
            DispatchQueue.main.async { view.cellMetricsDidChange(px: size) }
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title.flatMap({ String(cString: $0, encoding: .utf8) }) else {
                return false
            }
            DispatchQueue.main.async { view.title = title }
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            let healthy = action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY
            DispatchQueue.main.async { view.rendererHealth(healthy) }
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let exited = action.action.child_exited
            DispatchQueue.main.async {
                view.streamDidEnd(exitCode: Int(exited.exit_code), runtimeMs: Int(exited.timetime_ms))
            }
        case GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_MOUSE_SHAPE, GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_RING_BELL, GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_VIGIL_TRANSPORT:
            return false
        default:
            log.info("action refused", ["tag": Int(action.tag.rawValue)])
            return false
        }
        return true
    }
}
