import Foundation

/// Decides which account to run next.
///
/// The binding constraint is whichever window is fuller, so headroom is
/// `100 - max(fiveHour, sevenDay)`. Ties break toward the lower weekly
/// number: a 5-hour window refills in hours, a weekly one in days, so
/// weekly capacity is the scarcer resource and is spent last.
enum Ranking {
    /// How much room an account has, 0...100. Nil when it has no numbers.
    static func headroom(_ usage: AccountUsage) -> Double? {
        let used = [usage.fiveHour?.utilization, usage.sevenDay?.utilization]
            .compactMap { $0 }
        guard let worst = used.max() else { return nil }
        return max(0, 100 - worst)
    }

    /// Which window is the one actually holding the account back.
    static func bindingWindow(_ usage: AccountUsage) -> (name: String, window: UsageWindow)? {
        let candidates: [(String, UsageWindow)] = [
            usage.fiveHour.map { ("5h", $0) },
            usage.sevenDay.map { ("weekly", $0) },
        ].compactMap { $0 }
        return candidates.max { $0.1.utilization < $1.1.utilization }
    }

    /// Accounts ordered best-first. Unusable ones sink to the bottom,
    /// keeping a stable order rather than disappearing.
    static func runOrder(_ usages: [AccountUsage]) -> [AccountUsage] {
        usages.sorted { lhs, rhs in
            switch (headroom(lhs), headroom(rhs)) {
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

    /// The account to reach for right now — best headroom, and not exhausted.
    static func recommended(_ usages: [AccountUsage]) -> AccountUsage? {
        runOrder(usages).first {
            guard let h = headroom($0), h > 0 else { return false }
            return $0.failure == nil
        }
    }
}
