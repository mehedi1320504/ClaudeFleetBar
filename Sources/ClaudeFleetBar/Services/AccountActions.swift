import AppKit

/// What you can do with an account from the board.
///
/// Everything here is a convenience around the config dir — the app never
/// launches Claude itself, so nothing can start a session you did not ask for.
@MainActor
enum AccountActions {
    /// The shell command that runs Claude Code under this account.
    ///
    /// Written with `$HOME` rather than the expanded path so it stays portable
    /// and does not paste a username into a terminal someone is sharing.
    static func launchCommand(for account: Account) -> String {
        let home = NSHomeDirectory()
        let dir = account.configDir.hasPrefix(home)
            ? "$HOME" + account.configDir.dropFirst(home.count)
            : account.configDir
        return "CLAUDE_CONFIG_DIR=\"\(dir)\" claude"
    }

    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func revealConfigDir(_ account: Account) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: account.configDir)
    }
}
