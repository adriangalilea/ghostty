import AppKit

/// Handler for the `input text` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptInputTextCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptInputTextCommand)
final class ScriptInputTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let text = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing text to input."
            return nil
        }

        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }

        guard let surfaceView = terminal.surfaceView else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard !refusesMirrored(surfaceView) else { return nil }

        guard let surface = surfaceView.surfaceModel else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface model is not available."
            return nil
        }

        surface.sendText(text)
        return nil
    }
}

extension NSScriptCommand {
    /// A pane shown here but living on another Mac (`vigilHost`), or a
    /// second view of a pane (`vigilMirror`): scripted input would reach its
    /// home without the consent `vigil-agent send` asks there, so it is
    /// refused, like `split`. Every scripted input path asks this.
    @MainActor func refusesMirrored(_ view: Ghostty.SurfaceView) -> Bool {
        guard view.vigilHost != nil || view.vigilMirror else { return false }
        scriptErrorNumber = errAEEventFailed
        scriptErrorString = "This pane lives on another Mac or is a mirror: send to it with vigil send, which asks its home."
        return true
    }
}
