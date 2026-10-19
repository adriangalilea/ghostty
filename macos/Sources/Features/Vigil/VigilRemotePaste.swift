#if os(macOS)
import AppKit
import VigilWire

/// Pasting an image into a pane that lives on another Mac. Text pastes
/// travel as typed bytes and need nothing; an image cannot: the pane's
/// program (Claude Code's image paste) reads ITS Mac's clipboard. So a ⌘V or
/// ⌃V into a remote pane while this Mac's clipboard holds an image first
/// puts that image on the home Mac's clipboard (the hub's `clipboard` call
/// over `vigil/1`), then sends ⌃V, Claude's image key, to the pane. ⌘V with
/// text on the clipboard is Ghostty's own text paste, untouched.
@MainActor
enum VigilRemotePaste {
    private static var monitor: Any?
    private nonisolated static let hub = Local.Client(socket: VigilPaths.hub)

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            intercept(event) ? nil : event
        }
    }

    /// Whether `event` is an image paste into a remote pane, taken over here.
    private static func intercept(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command || modifiers == .control,
              event.charactersIgnoringModifiers?.lowercased() == "v",
              let surface = event.window?.firstResponder as? Ghostty.SurfaceView,
              let device = surface.vigilHost,
              let png = clipboardImage()
        else { return false }
        // ⌘V over an image that also carries text (a web page's copy) is a
        // text paste, as everywhere.
        if modifiers == .command, NSPasteboard.general.string(forType: .string) != nil { return false }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String?
            do {
                _ = try hub.call(device: device, .clipboard(png: png))
                failure = nil
            } catch {
                failure = "\(error)"
            }
            Task { @MainActor in
                if let failure {
                    remoteLog.warn("image not on the remote clipboard; pasting anyway", ["device": device, "err": failure])
                } else {
                    remoteLog.info("image on the remote clipboard", [
                        "device": device, "bytes": png.count, "ms": Int(Date().timeIntervalSince(started) * 1000),
                    ])
                }
                pasteKey(into: surface, like: event)
            }
        }
        return true
    }

    /// This Mac's clipboard image as PNG (screenshots are PNG, other apps
    /// often TIFF), nil when it holds none or one too large to carry.
    private static func clipboardImage() -> Data? {
        let board = NSPasteboard.general
        if let png = board.data(forType: .png), Open.isPNG(png) { return png }
        guard let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]), Open.isPNG(png) else { return nil }
        return png
    }

    /// ⌃V to the pane, as the keyboard would send it.
    private static func pasteKey(into surface: Ghostty.SurfaceView, like event: NSEvent) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let key = NSEvent.keyEvent(
                with: type, location: event.locationInWindow, modifierFlags: .control,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: "\u{16}", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: event.keyCode)
            else { continue }
            if type == .keyDown { surface.keyDown(with: key) } else { surface.keyUp(with: key) }
        }
    }
}
#endif
