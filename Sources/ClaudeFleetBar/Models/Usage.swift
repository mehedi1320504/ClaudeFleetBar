import Foundation

/// One rate-limit window as reported by `/api/oauth/usage`.
struct UsageWindow: Sendable, Equatable {
    /// Percent of the window consumed, 0...100+.
    let utilization: Double
    /// When the window rolls over. Nil when the API omits it.
    let resetsAt: Date?

    var isExhausted: Bool { utilization >= 100 }

    /// Seconds until reset, or nil when unknown / already past.
    func secondsUntilReset(now: Date = .now) -> TimeInterval? {
        guard let resetsAt else { return nil }
        let delta = resetsAt.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }
}

/// Where a snapshot's numbers came from. Surfaced in the UI so a stale
/// read is never mistaken for a live one.
enum UsageOrigin: Sendable, Equatable {
    /// Fetched from the API just now.
    case live
    /// Read from the CLI's own `cachedUsageUtilization`, written the last
    /// time that account ran a session.
    case cache(fetchedAt: Date)

    var isLive: Bool { if case .live = self { return true }; return false }
}

/// Why an account has no numbers at all.
enum UsageFailure: Sendable, Equatable {
    case noCredentials
    case credentialsExpired
    case credentialsUnreadable
    case network(String)

    var summary: String {
        switch self {
        case .noCredentials: "not signed in"
        case .credentialsExpired: "auth expired"
        case .credentialsUnreadable: "keychain unreadable"
        case .network(let detail): detail
        }
    }

    /// What the operator should actually do about it.
    var remedy: String {
        switch self {
        case .noCredentials, .credentialsExpired, .credentialsUnreadable:
            "Run any `claude` command with this account's CLAUDE_CONFIG_DIR to re-auth."
        case .network:
            "Retry — the usage API did not answer."
        }
    }
}

/// A single account's resolved state.
struct AccountUsage: Sendable, Equatable, Identifiable {
    let account: Account
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let origin: UsageOrigin?
    let failure: UsageFailure?
    let plan: String?

    var id: String { account.id }

    var hasNumbers: Bool { fiveHour != nil || sevenDay != nil }

    static func failed(_ account: Account, _ failure: UsageFailure) -> AccountUsage {
        AccountUsage(account: account, fiveHour: nil, sevenDay: nil,
                     origin: nil, failure: failure, plan: nil)
    }
}
