import Testing
import Foundation
@testable import ClaudeFleetBar

/// What the board does when the usage API will not answer for an account —
/// the case the 2026-09-05 screenshot showed: `HTTP 429`, `0% headroom`,
/// two blank rings, and the account sunk to the bottom of the run order,
/// two minutes after it had read 86% headroom.

private func account(_ label: String) -> Account {
    Account(configDir: "/tmp/.claude-account-\(label)", label: label, email: nil, displayName: nil)
}

private func reading(
    _ label: String, five: Double?, seven: Double?,
    origin: UsageOrigin?, failure: UsageFailure? = nil,
    fiveResets: Date? = nil, sevenResets: Date? = nil
) -> AccountUsage {
    AccountUsage(
        account: account(label),
        fiveHour: five.map { UsageWindow(utilization: $0, resetsAt: fiveResets) },
        sevenDay: seven.map { UsageWindow(utilization: $0, resetsAt: sevenResets) },
        origin: origin,
        failure: failure,
        plan: nil
    )
}

@Suite("Backoff")
struct BackoffTests {
    @Test("the first throttle waits one regular cycle, then each one doubles")
    func doubles() {
        #expect(Backoff.delay(failures: 1, interval: 120) == 120)
        #expect(Backoff.delay(failures: 2, interval: 120) == 240)
        #expect(Backoff.delay(failures: 3, interval: 120) == 480)
    }

    @Test("the wait is capped, so a long outage still gets polled")
    func capped() {
        #expect(Backoff.delay(failures: 8, interval: 120) == Backoff.ceiling)
        #expect(Backoff.delay(failures: 40, interval: 900) == Backoff.ceiling)
    }

    @Test("a server Retry-After longer than ours wins, up to an hour")
    func retryAfter() {
        #expect(Backoff.delay(failures: 1, interval: 120, retryAfter: 900) == 900)
        #expect(Backoff.delay(failures: 1, interval: 120, retryAfter: 86_400) == Backoff.longestRetryAfter)
    }

    /// The endpoint literally answers `Retry-After: 0`.
    @Test("a Retry-After of zero is no guidance")
    func zeroIsIgnored() {
        #expect(Backoff.delay(failures: 1, interval: 120, retryAfter: 0) == 120)
    }

    @Test("a very short interval still waits at least the floor")
    func floor() {
        #expect(Backoff.delay(failures: 1, interval: 5) == Backoff.floor)
    }
}

@Suite("Degraded readings")
struct DegradedReadingTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("a recent last-live reading is still recommended through a 429")
    func recentStaleIsActionable() {
        let e = reading("e", five: 9, seven: 14,
                        origin: .stale(fetchedAt: now.addingTimeInterval(-120)),
                        failure: .rateLimited(retryAt: now.addingTimeInterval(240)))
        let b = reading("b", five: 49, seven: 17, origin: .live)
        #expect(Ranking.recommended([b, e], now: now)?.account.label == "e")
        #expect(Ranking.headroom(e, now: now) == 86)
    }

    @Test("a last-live reading older than the trust window is ranked but not recommended")
    func oldStaleIsNotActionable() {
        let e = reading("e", five: 9, seven: 14,
                        origin: .stale(fetchedAt: now.addingTimeInterval(-(Ranking.trustWindow + 1))),
                        failure: .rateLimited(retryAt: nil))
        let b = reading("b", five: 49, seven: 17, origin: .live)
        #expect(Ranking.recommended([b, e], now: now)?.account.label == "b")
        #expect(Ranking.runOrder([b, e], now: now).map(\.account.label) == ["e", "b"])
    }

    @Test("the CLI's file cache is never recommended, however fresh")
    func cliCacheIsNeverActionable() {
        let a = reading("a", five: 10, seven: 10, origin: .cache(fetchedAt: now), failure: .network("HTTP 429"))
        #expect(Ranking.isActionable(a, now: now) == false)
        #expect(Ranking.recommended([a], now: now) == nil)
    }

    @Test("a row with no reading at all is neither ranked nor recommended")
    func failedRow() {
        let c = AccountUsage.failed(account("c"), .rateLimited(retryAt: nil))
        #expect(Ranking.headroom(c, now: now) == nil)
        #expect(Ranking.recommended([c], now: now) == nil)
    }

    /// Account E hit its session limit at 00:32 and the app kept "5h: 100%".
    /// By 08:00 the window had reset but the endpoint was throttling, so the
    /// stale figure would have shown E as spent for as long as the 429 lasted.
    @Test("a window that has rolled over since the reading no longer counts against the account")
    func rolledOverWindowIsIgnored() {
        let e = reading("e", five: 100, seven: 20,
                        origin: .cache(fetchedAt: now.addingTimeInterval(-7200)),
                        failure: .network("HTTP 429"),
                        fiveResets: now.addingTimeInterval(-3600))
        #expect(Ranking.headroom(e, now: now) == 80)
        #expect(Ranking.bindingWindow(e, now: now)?.name == "weekly")
    }

    @Test("a reset a few seconds ago is a live rollover, not a stale window")
    func recentRolloverStillCounts() {
        let e = reading("e", five: 100, seven: 20, origin: .live, fiveResets: now.addingTimeInterval(-5))
        #expect(Ranking.headroom(e, now: now) == 0)
    }

    @Test("a 429 reads as throttling, not as a spent account")
    func rateLimitedCopy() {
        let failure = UsageFailure.rateLimited(retryAt: now)
        #expect(failure.summary == "rate limited")
        #expect(failure.remedy.contains("not a spent quota"))
        #expect(failure.retryAt == now)
        #expect(UsageFailure.network("HTTP 503").retryAt == nil)
    }
}

@Suite("Reset labels")
struct ResetLabelTests {
    @Test("a reset well in the past reads as passed, the minute around it as now")
    func passed() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(Format.resetCountdown(to: Date(timeIntervalSince1970: 0), now: now) == "passed")
        #expect(Format.resetCountdown(to: Date(timeIntervalSince1970: 9_990), now: now) == "now")
        #expect(Format.resetCountdown(to: Date(timeIntervalSince1970: 13_600), now: now) == "1h 0m")
    }
}

@Suite("Notifier and failed reads")
struct NotifierTests {
    /// A throttled read used to post "Account E is out — resets in unknown",
    /// then "Account E freed up" on the next good read, for an account that
    /// never moved.
    @Test("a failed read is not a transition")
    func failedReadDoesNotNotify() {
        final class Box: @unchecked Sendable { var posted: [String] = [] }
        let box = Box()
        let notifier = Notifier(sink: { title, _ in box.posted.append(title) })
        notifier.isEnabled = true

        let good = reading("e", five: 30, seven: 20, origin: .live)
        let throttled = AccountUsage.failed(account("e"), .rateLimited(retryAt: nil))
        let stale = reading("e", five: 30, seven: 20,
                            origin: .stale(fetchedAt: .now), failure: .rateLimited(retryAt: nil))

        notifier.reportTransitions(from: [], to: [good])          // baseline
        notifier.reportTransitions(from: [good], to: [throttled])  // 429, no numbers
        notifier.reportTransitions(from: [throttled], to: [stale]) // 429, kept numbers
        notifier.reportTransitions(from: [stale], to: [good])      // back

        #expect(box.posted.isEmpty)
    }

    @Test("a real change still notifies")
    func realTransitionNotifies() {
        final class Box: @unchecked Sendable { var posted: [String] = [] }
        let box = Box()
        let notifier = Notifier(sink: { title, _ in box.posted.append(title) })
        notifier.isEnabled = true

        let free = reading("d", five: 30, seven: 20, origin: .live)
        let spent = reading("d", five: 95, seven: 20, origin: .live)
        notifier.reportTransitions(from: [], to: [free])
        notifier.reportTransitions(from: [free], to: [spent])

        #expect(box.posted == ["Account D nearly spent"])
    }
}
