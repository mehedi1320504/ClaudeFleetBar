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
            .map { home.appendingPathComponent($0).path }
            .sorted()

        // The default dir counts too, when it is actually signed in.
        let base = home.appendingPathComponent(".claude").path
        if fm.fileExists(atPath: base + "/.claude.json") { dirs.append(base) }

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

    private static func label(for dir: String) -> String {
        let name = (dir as NSString).lastPathComponent
        if let range = name.range(of: ".claude-account-") {
            return String(name[range.upperBound...])
        }
        return name == ".claude" ? "default" : name
    }
}
