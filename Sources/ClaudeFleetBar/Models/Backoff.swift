import Foundation

/// How long to leave an account alone after the usage API throttles it.
///
/// The endpoint answers 429 with `Retry-After: 0`, which is no guidance at
/// all, so the wait is ours. The first throttle waits one regular cycle —
/// most are brief — and each consecutive one doubles it, capped, because a
/// board that stops asking for an hour is as useless as one that hammers.
/// A success resets the count.
enum Backoff {
    static let ceiling: TimeInterval = 10 * 60
    static let floor: TimeInterval = 30
    /// The longest server `Retry-After` we will honour.
    static let longestRetryAfter: TimeInterval = 60 * 60

    /// - Parameters:
    ///   - failures: consecutive throttles so far, this one included (≥ 1).
    ///   - interval: the regular refresh interval.
    ///   - retryAfter: the server's `Retry-After`, honoured when it is longer.
    static func delay(failures: Int, interval: TimeInterval, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let exponent = max(0, min(failures - 1, 10))
        let doubled = max(interval, floor) * pow(2, Double(exponent))
        let ours = min(doubled, ceiling)
        let theirs = min(retryAfter ?? 0, longestRetryAfter)
        return max(ours, theirs)
    }
}
