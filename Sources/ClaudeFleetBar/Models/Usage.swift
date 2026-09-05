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

    /// True once the window has rolled over since this reading was taken:
    /// its utilization describes a window that no longer exists. A reading
    /// kept through an outage would otherwise report an account as spent
    /// for hours after its limit actually reset. A minute of grace covers
    /// clock skew and the seconds around a live rollover.
    func hasRolledOver(now: Date = .now) -> Bool {
        guard let resetsAt else { return false }
        return now.timeIntervalSince(resetsAt) > 60
    }
}

/// Where a snapshot's numbers came from. Surfaced in the UI so a stale
/// read is never mistaken for a live one.
enum UsageOrigin: Sendable, Equatable {
    /// Fetched from the API just now.
    case live
    /// This app's own last successful live read, kept when a later refresh
    /// failed. Trustworthy for a while — the API was answering minutes ago.
    case stale(fetchedAt: Date)
    /// Read from the CLI's own `cachedUsageUtilization`, written the last
    /// time that account ran a session. Can be days old.
    case cache(fetchedAt: Date)

    var isLive: Bool { if case .live = self { return true }; return false }

    /// When the numbers were actually read. Nil for a live read.
    var fetchedAt: Date? {
        switch self {
        case .live: nil
        case .stale(let at), .cache(let at): at
        }
    }
}

/// Why an account has no live numbers.
enum UsageFailure: Sendable, Equatable {
    case noCredentials
    case credentialsExpired
    case credentialsUnreadable
    /// The login Keychain wants the operator's permission before this app
    /// may read the token, and this app refuses to pop that dialog from a
    /// background refresh. The row offers a button that asks exactly once.
    case keychainDenied
    /// The usage endpoint answered 429 for this account. That is the
    /// endpoint throttling reads, not the account being out of quota.
    /// `retryAt` is when this app will ask again.
    case rateLimited(retryAt: Date?)
    case network(String)

    var summary: String {
        switch self {
        case .noCredentials: "not signed in"
        case .credentialsExpired: "auth expired"
        case .credentialsUnreadable: "keychain unreadable"
        case .keychainDenied: "keychain locked"
        case .rateLimited: "rate limited"
        case .network(let detail): detail
        }
    }

    /// What the operator should actually do about it.
    var remedy: String {
        switch self {
        case .noCredentials, .credentialsExpired, .credentialsUnreadable:
            "Run any `claude` command with this account's CLAUDE_CONFIG_DIR to re-auth."
        case .keychainDenied:
            "macOS wants your permission before this app may read this account's token. Grant it once: enter your login password and choose Always Allow."
        case .rateLimited:
            "The usage API is throttling reads for this account — not a spent quota. Showing the last live reading."
        case .network:
            "Retry — the usage API did not answer."
        }
    }

    var needsGrant: Bool { self == .keychainDenied }

    var retryAt: Date? {
        if case .rateLimited(let at) = self { return at }
        return nil
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

    /// The windows whose reading still describes a window that exists.
    func currentWindows(now: Date = .now) -> [UsageWindow] {
        [fiveHour, sevenDay].compactMap { $0 }.filter { !$0.hasRolledOver(now: now) }
    }

    static func failed(_ account: Account, _ failure: UsageFailure) -> AccountUsage {
        AccountUsage(account: account, fiveHour: nil, sevenDay: nil,
                     origin: nil, failure: failure, plan: nil)
    }
}
