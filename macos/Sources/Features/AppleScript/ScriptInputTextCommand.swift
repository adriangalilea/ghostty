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

        guard !refusesScriptedInput(surfaceView) else { return nil }

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
    /// Scripted input (`input text`, keys, the mouse, a typing `perform
    /// action`) into any Vigil pane: refused. A pane answers only the app
    /// and vigil-agent so that typing into it is a decision (vigil-agent
    /// send asks unless it runs inside that pane); a script holding the
    /// Automation grant would otherwise type into every terminal here,
    /// local, mirrored or another Mac's, with no question at all. A
    /// surface that is no pane (none in this fork today) keeps upstream's
    /// behaviour. Every scripted input path asks this.
    @MainActor func refusesScriptedInput(_ view: Ghostty.SurfaceView) -> Bool {
        guard view.vigilAttachId != nil || view.vigilHost != nil || view.vigilMirror else { return false }
        scriptErrorNumber = errAEEventFailed
        scriptErrorString = "Scripted input into a Vigil pane is refused: type into it with `vigil send <workspace> <text>`, which asks you unless it runs inside that pane."
        return true
    }
}
