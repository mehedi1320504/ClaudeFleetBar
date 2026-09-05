import Foundation

/// Decides which account to run next.
///
/// The binding constraint is whichever window is fuller, so headroom is
/// `100 - max(fiveHour, sevenDay)`. Ties break toward the lower weekly
/// number: a 5-hour window refills in hours, a weekly one in days, so
/// weekly capacity is the scarcer resource and is spent last.
enum Ranking {
    /// How old this app's own last live reading may be and still be acted
    /// on. Under a fleet, a 5-hour figure can move ten points in ten
    /// minutes; beyond this the row is still ranked and shown, but the
    /// recommendation goes to an account we can actually see.
    static let trustWindow: TimeInterval = 15 * 60

    /// How much room an account has, 0...100. Nil when it has no numbers,
    /// or none that still describe a live window.
    static func headroom(_ usage: AccountUsage, now: Date = .now) -> Double? {
        guard let worst = usage.currentWindows(now: now).map(\.utilization).max() else { return nil }
        return max(0, 100 - worst)
    }

    /// Which window is the one actually holding the account back.
    static func bindingWindow(_ usage: AccountUsage, now: Date = .now) -> (name: String, window: UsageWindow)? {
        let candidates: [(String, UsageWindow)] = [
            usage.fiveHour.map { ("5h", $0) },
            usage.sevenDay.map { ("weekly", $0) },
        ]
        .compactMap { $0 }
        .filter { !$0.1.hasRolledOver(now: now) }
        return candidates.max { $0.1.utilization < $1.1.utilization }
    }

    /// Accounts ordered best-first. Unusable ones sink to the bottom,
    /// keeping a stable order rather than disappearing.
    static func runOrder(_ usages: [AccountUsage], now: Date = .now) -> [AccountUsage] {
        usages.sorted { lhs, rhs in
            switch (headroom(lhs, now: now), headroom(rhs, now: now)) {
            case let (l?, r?):
                if l != r { return l > r }
                let lw = lhs.sevenDay?.utilization ?? 100
                let rw = rhs.sevenDay?.utilization ?? 100
                if lw != rw { return lw < rw }
                return lhs.account.label < rhs.account.label
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.account.label < rhs.account.label
            }
        }
    }

    /// Whether a reading is current enough to act on: live, or this app's
    /// own last live read from inside `trustWindow`. The CLI's file cache
    /// never qualifies — it dates from whenever that account last ran a
    /// session, which can be days.
    static func isActionable(_ usage: AccountUsage, now: Date = .now) -> Bool {
        switch usage.origin {
        case .live: true
        case .stale(let fetchedAt): now.timeIntervalSince(fetchedAt) <= trustWindow
        case .cache, nil: false
        }
    }

    /// The account to reach for right now — best headroom, not exhausted,
    /// and a reading we can trust. A throttled read of an account that was
    /// at 86% headroom two minutes ago still recommends that account.
    static func recommended(_ usages: [AccountUsage], now: Date = .now) -> AccountUsage? {
        runOrder(usages, now: now).first {
            guard let h = headroom($0, now: now), h > 0 else { return false }
            return isActionable($0, now: now)
        }
    }
}
