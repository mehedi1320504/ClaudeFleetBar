import Foundation

/// Accounts that may be observed but must never be recommended for work.
///
/// The policy is shared with claude-fleet: the union of the environment value
/// and a durable config file. `nil` means the policy was malformed or
/// unreadable, so callers fail closed by offering no dispatch order.
enum AccountExclusions {
    static let environmentName = "FLEET_EXCLUDE_ACCOUNTS"
    static let fileEnvironmentName = "FLEET_EXCLUDE_ACCOUNTS_FILE"

    /// The policy split by where each exclusion comes from. The board may
    /// edit only `durable`; the other two are set outside this app, so an
    /// account they exclude cannot be activated from here.
    struct Breakdown: Equatable, Sendable {
        /// `FLEET_EXCLUDE_ACCOUNTS` in this app's own environment.
        let environment: Set<String>
        /// `~/.config/claude-fleet/exclude-accounts`.
        let durable: Set<String>
        /// The additive file named by `FLEET_EXCLUDE_ACCOUNTS_FILE`.
        let override: Set<String>

        var all: Set<String> { environment.union(durable).union(override) }
    }

    /// Why an excluded account cannot be activated from the board.
    enum Lock: Equatable, Sendable {
        case environment
        case overrideFile
        /// The shared policy reads an empty file as unreadable and stops
        /// every dispatch, so its one remaining entry cannot be lifted.
        case lastEntry

        /// One line, for a menu item.
        var summary: String {
            switch self {
            case .environment: "Excluded by FLEET_EXCLUDE_ACCOUNTS"
            case .overrideFile: "Excluded by FLEET_EXCLUDE_ACCOUNTS_FILE"
            case .lastEntry: "Last entry in the policy file"
            }
        }

        /// The reason and what to do about it.
        var explanation: String {
            switch self {
            case .environment:
                "Excluded by FLEET_EXCLUDE_ACCOUNTS in this app's environment, which the board can't change."
            case .overrideFile:
                "Excluded by the file in FLEET_EXCLUDE_ACCOUNTS_FILE, which the board doesn't edit."
            case .lastEntry:
                "It's the only entry in the policy file, and an empty file stops every dispatch. Exclude another account first."
            }
        }
    }

    /// What the board may offer for one account.
    enum Toggle: Equatable, Sendable {
        /// Dispatchable now. Excluding adds it to the durable file.
        case exclude
        /// Excluded by the durable file alone. Activating removes it.
        case activate
        /// Excluded, but not by anything the board may change.
        case locked(Lock)
        /// The policy cannot name it (`default`, a multi-letter dir), or
        /// cannot be read at all.
        case unavailable
    }

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
        breakdown(environment: environment, fileURL: fileURL)?.all
    }

    /// The policy by source, or nil when any part of it cannot be read.
    static func breakdown(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) -> Breakdown? {
        guard let fromEnvironment = parse(environment[environmentName] ?? "", comments: false) else {
            return nil
        }
        let durable = fileURL ?? defaultFile(environment: environment)
        guard let fromDurable = loadFile(durable) else { return nil }

        var fromOverride: Set<String> = []
        if let override = environment[fileEnvironmentName], !override.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
            if url.standardizedFileURL != durable.standardizedFileURL {
                guard let parsed = loadFile(url) else { return nil }
                fromOverride = parsed
            }
        }
        return Breakdown(environment: fromEnvironment, durable: fromDurable, override: fromOverride)
    }

    /// A single lower-case letter: the only account name the policy accepts.
    static func isToken(_ label: String) -> Bool {
        label.unicodeScalars.count == 1 && label >= "a" && label <= "z"
    }

    static func loadFile(_ url: URL) -> Set<String>? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let parsed = parse(raw, comments: true), !parsed.isEmpty
        else { return nil }
        return parsed
    }

    /// Splits lines on every line break Python's `splitlines()` honours, as
    /// claude-fleet's parser does. Splitting on "\n" alone missed CRLF: Swift
    /// reads "\r\n" as one character, so the whole file was one line and its
    /// first `#` commented out every entry after it.
    static func parse(_ raw: String, comments: Bool) -> Set<String>? {
        let text: String
        if comments {
            text = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0] }
                .joined(separator: "\n")
        } else {
            text = raw
        }
        let tokens = text.split { $0 == "," || $0.isWhitespace }.map(String.init)
        guard tokens.allSatisfy(isToken) else { return nil }
        return Set(tokens)
    }
}

extension AccountExclusions.Breakdown {
    /// Whether the board may exclude or activate this account, and if it may
    /// not, why. The environment and the override file are checked first:
    /// removing an account from the durable file would not activate it while
    /// either of them still names it.
    func toggle(for label: String) -> AccountExclusions.Toggle {
        guard AccountExclusions.isToken(label) else { return .unavailable }
        if environment.contains(label) { return .locked(.environment) }
        if override.contains(label) { return .locked(.overrideFile) }
        guard durable.contains(label) else { return .exclude }
        return durable.count > 1 ? .activate : .locked(.lastEntry)
    }
}
