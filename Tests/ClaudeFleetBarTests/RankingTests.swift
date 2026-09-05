import Testing
import Foundation
@testable import ClaudeFleetBar

private func account(_ label: String) -> Account {
    Account(configDir: "/tmp/.claude-account-\(label)", label: label, email: nil, displayName: nil)
}

private func usage(_ label: String, five: Double?, seven: Double?) -> AccountUsage {
    AccountUsage(
        account: account(label),
        fiveHour: five.map { UsageWindow(utilization: $0, resetsAt: nil) },
        sevenDay: seven.map { UsageWindow(utilization: $0, resetsAt: nil) },
        origin: .live,
        failure: nil,
        plan: nil
    )
}

@Suite("Ranking")
struct RankingTests {
    @Test("headroom is limited by the fuller window, not the average")
    func headroomUsesWorstWindow() {
        // Averaging would call this 55% free; the weekly window is what blocks it.
        #expect(Ranking.headroom(usage("a", five: 10, seven: 80)) == 20)
    }

    @Test("an account with no numbers has no headroom")
    func noNumbers() {
        #expect(Ranking.headroom(usage("a", five: nil, seven: nil)) == nil)
    }

    @Test("headroom never goes negative when a window is over 100")
    func overspentClampsToZero() {
        #expect(Ranking.headroom(usage("a", five: 120, seven: 10)) == 0)
    }

    @Test("ties break toward the account with more weekly capacity left")
    func tieBreaksOnWeekly() {
        // Both are blocked at 40% used, but `b` spends the scarcer weekly budget.
        let ordered = Ranking.runOrder([
            usage("b", five: 10, seven: 40),
            usage("a", five: 40, seven: 10),
        ])
        #expect(ordered.map(\.account.label) == ["a", "b"])
    }

    @Test("accounts with no numbers sort last but are not dropped")
    func unusableSinksWithoutVanishing() {
        let ordered = Ranking.runOrder([
            usage("a", five: nil, seven: nil),
            usage("b", five: 50, seven: 50),
        ])
        #expect(ordered.map(\.account.label) == ["b", "a"])
    }

    @Test("an exhausted account is never recommended")
    func exhaustedIsNotRecommended() {
        let best = Ranking.recommended([
            usage("a", five: 100, seven: 10),
            usage("b", five: 70, seven: 70),
        ])
        #expect(best?.account.label == "b")
    }

    @Test("recommendation is nil when every account is spent")
    func allSpent() {
        #expect(Ranking.recommended([usage("a", five: 100, seven: 100)]) == nil)
    }

    @Test("the binding window is the fuller one")
    func bindingWindow() {
        let binding = Ranking.bindingWindow(usage("a", five: 12, seven: 91))
        #expect(binding?.name == "weekly")
    }
}

@Suite("Keychain key derivation")
struct AccountTests {
    /// Claude Code derives the service name as
    /// `Claude Code-credentials-<first 8 hex of sha256(configDir)>`. If this
    /// drifts, every account silently reads as "not signed in" — a failure that
    /// looks like a logged-out account rather than a bug — so the derivation is
    /// pinned here. The formula itself was confirmed against a real login
    /// Keychain; these vectors use placeholder paths.
    @Test("service name matches the CLI's derivation", arguments: [
        ("/Users/example/.claude-account-a", "f21e4959"),
        ("/Users/example/.claude-account-b", "73601a86"),
        ("/Users/example/.claude-account-c", "0deb5a81"),
        ("/Users/example/.claude-account-d", "edca4f90"),
        ("/Users/example/.claude-account-e", "64cf470a"),
    ])
    func keychainService(dir: String, hash: String) {
        let account = Account(configDir: dir, label: "x", email: nil, displayName: nil)
        #expect(account.keychainService == "Claude Code-credentials-\(hash)")
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test("countdown drops to the two most significant units")
    func countdownUnits() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(Format.countdown(to: Date(timeIntervalSince1970: 45), now: now) == "45s")
        #expect(Format.countdown(to: Date(timeIntervalSince1970: 3_000), now: now) == "50m")
        #expect(Format.countdown(to: Date(timeIntervalSince1970: 12_600), now: now) == "3h 30m")
        #expect(Format.countdown(to: Date(timeIntervalSince1970: 180_000), now: now) == "2d 2h")
    }

    @Test("a reset already in the past reads as now, never as a negative")
    func pastReset() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(Format.countdown(to: Date(timeIntervalSince1970: 0), now: now) == "now")
    }
}
