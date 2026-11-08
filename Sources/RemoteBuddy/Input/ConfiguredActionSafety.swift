extension ButtonAction {
    /// Actions capable of inserting or editing text require a non-secure target.
    /// Cleanup and navigation stay available; key-up recovery bypasses send().
    var requiresNonSecureInput: Bool {
        switch self {
        case .returnKey, .commandReturn, .shiftReturn, .commandCopy, .commandPaste,
             .commandCut, .commandSelectAll, .commandUndo, .commandRedo, .commandFind,
             .commandSave, .commandDelete, .deleteBackward, .customShortcut:
            return true
        default:
            return false
        }
    }
}
