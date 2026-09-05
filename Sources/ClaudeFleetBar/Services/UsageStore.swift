import Foundation
import Observation

/// Owns the fleet's live state and the refresh loop.
@MainActor
@Observable
final class UsageStore {
    private(set) var usages: [AccountUsage] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    /// False until the first pass finishes. Without it an in-flight first load
    /// is indistinguishable from "there are no accounts", and the empty state
    /// tells you to go sign in while it is busy reading the accounts you have.
    var hasLoaded: Bool { lastRefresh != nil }

    /// Seconds between automatic refreshes.
    var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: Self.intervalKey)
            restartTimer()
        }
    }

    private static let intervalKey = "refreshInterval"
    private let api = UsageAPI()
    private let notifier: Notifier
    private var timerTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var didStart = false

    /// The last reading the API actually returned, per account. When a
    /// refresh fails this is what the row keeps showing — labelled with its
    /// age — instead of blanking an account that read 86% headroom two
    /// minutes ago and sinking it to the bottom of the run order.
    private var lastLive: [Account.ID: (usage: AccountUsage, at: Date)] = [:]

    /// Per-account throttle state: consecutive 429s and when to ask again.
    /// The usage endpoint limits reads per account, so one throttled account
    /// backs off alone while the others keep refreshing on schedule.
    private var throttle: [Account.ID: (failures: Int, until: Date)] = [:]

    init(notifier: Notifier = Notifier()) {
        self.notifier = notifier
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        self.refreshInterval = stored > 0 ? stored : 120
    }

    /// Idempotent: `.task` on the menu bar label can run more than once, and
    /// each call used to restart the timer from zero. A label that re-appeared
    /// often enough would push the next fire forever into the future and the
    /// board would silently stop updating.
    func start() {
        guard !didStart else { return }
        didStart = true
        // A background refresh must never put a Keychain dialog on screen.
        // Reads that would need one go through `security`, or surface a row
        // with a "Grant access" button that asks on purpose.
        KeychainCredentials.silenceDialogs()
        holdOffAppNap()
        restartTimer()
        Task { await refresh() }
    }

    /// The one deliberate Keychain dialog: the operator clicked "Grant
    /// access" on a row, so asking is what they want. "Always Allow" puts this
    /// app on the item for good; the refresh right after shows the result.
    func grantKeychainAccess(_ account: Account) async {
        _ = try? KeychainCredentials.grant(for: account)
        await refresh(force: true)
    }

    /// A menu bar app with no windows is exactly what App Nap targets: macOS
    /// throttles its timers, so the first refresh lands and every scheduled one
    /// after it is deferred indefinitely. The board then sits there looking
    /// current while going quietly stale — the failure this app exists to avoid.
    ///
    /// `userInitiatedAllowingIdleSystemSleep` opts out of the throttling while
    /// still letting the Mac sleep normally.
    private func holdOffAppNap() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Polling Claude account usage"
        )
    }

    private func restartTimer() {
        timerTask?.cancel()
        let interval = refreshInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    /// Refreshes only when the current numbers are older than `age`.
    /// Opening the panel should show something current without hammering the
    /// API each time it is opened and closed.
    func refreshIfStale(olderThan age: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        await refresh()
    }

    /// The scheduled refresh: every account not currently in backoff.
    func refresh() async { await refresh(force: false) }

    /// What one account's fetch came back as.
    private enum Fetch: Sendable {
        case live(AccountUsage)
        case throttled(retryAfter: TimeInterval?)
        case failed(UsageFailure)
    }

    /// Refreshes the due accounts in parallel. One slow or broken account
    /// never holds up the rest of the board.
    ///
    /// `force` ignores per-account backoff — it is the manual refresh button,
    /// where the operator has decided one more request is worth it.
    func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let accounts = AccountDiscovery.discover()
        let api = self.api
        let now = Date()
        let due = accounts.filter { account in
            force || (throttle[account.id].map { $0.until <= now } ?? true)
        }

        let fetched = await withTaskGroup(of: (Account.ID, Fetch).self) { group in
            for (index, account) in due.enumerated() {
                group.addTask {
                    // Stagger, so five identical requests do not land at the
                    // edge in the same instant.
                    try? await Task.sleep(for: .milliseconds(200 * index))
                    return (account.id, await Self.resolve(account, api: api))
                }
            }
            var out: [Account.ID: Fetch] = [:]
            for await (id, fetch) in group { out[id] = fetch }
            return out
        }

        var rows: [AccountUsage] = []
        for account in accounts {
            switch fetched[account.id] {
            case .live(let usage)?:
                lastLive[account.id] = (usage, now)
                throttle[account.id] = nil
                rows.append(usage)
            case .throttled(let retryAfter)?:
                let failures = (throttle[account.id]?.failures ?? 0) + 1
                let wait = Backoff.delay(failures: failures, interval: refreshInterval, retryAfter: retryAfter)
                let until = now.addingTimeInterval(wait)
                throttle[account.id] = (failures, until)
                rows.append(degraded(account, failure: .rateLimited(retryAt: until)))
            case .failed(let failure)?:
                // A plain network or credential failure retries on the next tick.
                rows.append(degraded(account, failure: failure))
            case nil:
                // Still inside this account's backoff; nothing was asked.
                rows.append(degraded(account, failure: .rateLimited(retryAt: throttle[account.id]?.until)))
            }
        }

        let ordered = rows.sorted { $0.account.label < $1.account.label }
        let previous = usages
        usages = ordered
        lastRefresh = .now
        SnapshotExporter.write(ordered)
        notifier.reportTransitions(from: previous, to: ordered)
    }

    /// Live API only. Fallbacks are decided on the main actor, where the
    /// last-live table lives.
    private nonisolated static func resolve(_ account: Account, api: UsageAPI) async -> Fetch {
        let credentials: KeychainCredentials.Credentials
        do {
            credentials = try await KeychainCredentials.load(for: account)
        } catch KeychainCredentials.Failure.notFound {
            return .failed(.noCredentials)
        } catch KeychainCredentials.Failure.needsGrant {
            return .failed(.keychainDenied)
        } catch {
            return .failed(.credentialsUnreadable)
        }

        guard !credentials.isExpired else { return .failed(.credentialsExpired) }

        do {
            let response = try await api.fetch(token: credentials.accessToken)
            return .live(AccountUsage(
                account: account,
                fiveHour: response.fiveHour,
                sevenDay: response.sevenDay,
                origin: .live,
                failure: nil,
                plan: credentials.subscriptionType
            ))
        } catch UsageAPI.Failure.rateLimited(let retryAfter) {
            return .throttled(retryAfter: retryAfter)
        } catch {
            return .failed(.network(Self.describe(error)))
        }
    }

    /// What a row shows when the live read failed: this app's own last live
    /// reading if it has one, then the CLI's file cache, then nothing — each
    /// labelled with its origin and age, so a stale number is never mistaken
    /// for the current truth.
    private func degraded(_ account: Account, failure: UsageFailure) -> AccountUsage {
        if let last = lastLive[account.id] {
            return AccountUsage(
                account: account,
                fiveHour: last.usage.fiveHour,
                sevenDay: last.usage.sevenDay,
                origin: .stale(fetchedAt: last.at),
                failure: failure,
                plan: last.usage.plan
            )
        }
        return Self.fromCliCache(account, failure: failure)
    }

    /// The CLI's own `cachedUsageUtilization`, written the last time that
    /// account ran a session. Days old is normal; the badge says so.
    private nonisolated static func fromCliCache(_ account: Account, failure: UsageFailure) -> AccountUsage {
        guard let cached = ConfigFile.cachedUsage(configDir: account.configDir) else {
            return .failed(account, failure)
        }
        return AccountUsage(
            account: account,
            fiveHour: cached.five,
            sevenDay: cached.seven,
            origin: .cache(fetchedAt: cached.fetchedAt),
            failure: failure,
            plan: nil
        )
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if case UsageAPI.Failure.http(let code) = error { return "HTTP \(code)" }
        if error is UsageAPI.Failure { return "bad response" }
        return (error as NSError).localizedDescription
    }
}
