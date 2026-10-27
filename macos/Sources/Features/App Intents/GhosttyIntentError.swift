enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound
    case permissionDenied
    /// vigil: closing a pane ends its processes, a person's gesture only
    /// (NSScriptCommand.refusesScriptedClose says the same to AppleScript).
    case vigilPaneClose

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: "The Ghostty app isn't properly initialized."
        case .surfaceNotFound: "The terminal no longer exists."
        case .permissionDenied: "Ghostty doesn't allow Shortcuts."
        case .vigilPaneClose: "Closing a Vigil pane ends its processes, which only you do (⌘W, the sidebar's Kill…)."
        }
    }
}
