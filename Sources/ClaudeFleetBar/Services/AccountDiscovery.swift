import Foundation

/// Finds the Claude Code config dirs on this machine.
///
/// Auto-detection means a sixth account works the moment it is created —
/// there is no list to keep in sync.
enum AccountDiscovery {
    static func discover(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [Account] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []

        var dirs: [String] = entries
            .filter { $0.hasPrefix(".claude-account-") }
            // A suffix that is not a plausible account name is not an account.
            // `~/.claude-account---help` exists on this machine because a stray
            // `--help` was once passed where an account letter belongs, and the
            // CLI happily made the directory. It rendered as a permanent
            // "not signed in" row that no login could ever fix. This filter can
            // never hide a real account: a real suffix is alphanumeric.
            .filter { isPlausibleAccountSuffix(String($0.dropFirst(".claude-account-".count))) }
            .map { home.appendingPathComponent($0).path }
            .sorted()

        // The default dir counts too, WHEN IT IS ACTUALLY SIGNED IN — which is
        // what this comment always claimed and what the code did not check. The
        // presence of `.claude.json` proves only that the CLI has run here; the
        // desktop app's own `~/.claude` has one and has no fleet credentials, so
        // it showed up forever as a row that said "not signed in" and could not
        // be acted on. `oauthAccount` is the real signal.
        let base = home.appendingPathComponent(".claude").path
        if fm.fileExists(atPath: base + "/.claude.json"),
           ConfigFile.profile(configDir: base) != nil {
            dirs.append(base)
        }

        return dirs.compactMap { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return nil }
            let profile = ConfigFile.profile(configDir: dir)
            return Account(
                configDir: dir,
                label: label(for: dir),
                email: profile?.email,
                displayName: profile?.displayName
            )
        }
    }

    /// A real account directory is `~/.claude-account-<name>` where <name> is
    /// alphanumeric — `a`…`g` today, but not assumed to be a single letter so a
    /// future `.claude-account-ops` still works. Anything that starts with `-`,
    /// or is empty, came from an argument landing where a name belongs.
    static func isPlausibleAccountSuffix(_ suffix: String) -> Bool {
        guard !suffix.isEmpty else { return false }
        return suffix.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func label(for dir: String) -> String {
        let name = (dir as NSString).lastPathComponent
        if let range = name.range(of: ".claude-account-") {
            return String(name[range.upperBound...])
        }
        return name == ".claude" ? "default" : name
    }
}
