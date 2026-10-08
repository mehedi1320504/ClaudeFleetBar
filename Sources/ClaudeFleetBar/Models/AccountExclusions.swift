import Foundation

/// Accounts that may be observed but must never be recommended for work.
///
/// The policy is shared with claude-fleet: the union of the environment value
/// and a durable config file. `nil` means the policy was malformed or
/// unreadable, so callers fail closed by offering no dispatch order.
enum AccountExclusions {
    static let environmentName = "FLEET_EXCLUDE_ACCOUNTS"
    static let fileEnvironmentName = "FLEET_EXCLUDE_ACCOUNTS_FILE"

    static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/claude-fleet/exclude-accounts")
    }

    static var current: Set<String>? { load() }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) -> Set<String>? {
        guard var result = parse(environment[environmentName] ?? "", comments: false) else {
            return nil
        }
        let durable = fileURL ?? defaultFile(environment: environment)
        guard let fromDurable = loadFile(durable) else { return nil }
        result.formUnion(fromDurable)

        if let override = environment[fileEnvironmentName], !override.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
            if url.standardizedFileURL != durable.standardizedFileURL {
                guard let fromOverride = loadFile(url) else { return nil }
                result.formUnion(fromOverride)
            }
        }
        return result
    }

    private static func loadFile(_ url: URL) -> Set<String>? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let parsed = parse(raw, comments: true), !parsed.isEmpty
        else { return nil }
        return parsed
    }

    private static func parse(_ raw: String, comments: Bool) -> Set<String>? {
        let text: String
        if comments {
            text = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0] }
                .joined(separator: "\n")
        } else {
            text = raw
        }
        let tokens = text.split { $0 == "," || $0.isWhitespace }.map(String.init)
        guard tokens.allSatisfy({ token in
            token.unicodeScalars.count == 1 && token >= "a" && token <= "z"
        }) else { return nil }
        return Set(tokens)
    }
}
