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
        holdOffAppNap()
        restartTimer()
        Task { await refresh() }
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

    /// Refreshes every account in parallel. One slow or broken account
    /// never holds up the rest of the board.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let accounts = AccountDiscovery.discover()
        let api = self.api

        let resolved = await withTaskGroup(of: AccountUsage.self) { group in
            for account in accounts {
                group.addTask { await Self.resolve(account, api: api) }
            }
            var out: [AccountUsage] = []
            for await result in group { out.append(result) }
            return out
        }

        let ordered = resolved.sorted { $0.account.label < $1.account.label }
        let previous = usages
        usages = ordered
        lastRefresh = .now
        SnapshotExporter.write(ordered)
        notifier.reportTransitions(from: previous, to: ordered)
    }

    /// Live API first; the CLI's own cache only as a labelled fallback.
    private nonisolated static func resolve(_ account: Account, api: UsageAPI) async -> AccountUsage {
        let credentials: KeychainCredentials.Credentials
        do {
            credentials = try KeychainCredentials.load(for: account)
        } catch KeychainCredentials.Failure.notFound {
            return fallback(account, failure: .noCredentials)
        } catch {
            return fallback(account, failure: .credentialsUnreadable)
        }

        guard !credentials.isExpired else {
            return fallback(account, failure: .credentialsExpired)
        }

        do {
            let response = try await api.fetch(token: credentials.accessToken)
            return AccountUsage(
                account: account,
                fiveHour: response.fiveHour,
                sevenDay: response.sevenDay,
                origin: .live,
                failure: nil,
                plan: credentials.subscriptionType
            )
        } catch {
            return fallback(account, failure: .network(Self.describe(error)))
        }
    }

    /// A failed live read still shows numbers when the CLI cached some —
    /// clearly marked as cached, with its age, so it is never mistaken
    /// for the current truth.
    private nonisolated static func fallback(_ account: Account, failure: UsageFailure) -> AccountUsage {
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
