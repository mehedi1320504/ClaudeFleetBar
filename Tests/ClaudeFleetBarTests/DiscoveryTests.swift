import Testing
import Foundation
@testable import ClaudeFleetBar

/// Guards for the two rows that sat permanently dead at the bottom of the board,
/// and for the liveness rule that decides what counts as a running Codex lane.
///
/// Each assertion exists because the opposite was OBSERVED on this machine.

@Suite("Account discovery rejects what is not an account")
struct AccountSuffixTests {

    @Test("a stray argument is not an account name")
    func strayArgument() {
        // OBSERVED 2026-09-29: `~/.claude-account---help` existed, created when
        // `--help` landed where an account letter belongs. It rendered as row 8,
        // permanently "not signed in", and no login could ever fix it because
        // there is no such account to log in to.
        #expect(AccountDiscovery.isPlausibleAccountSuffix("-help") == false)
        #expect(AccountDiscovery.isPlausibleAccountSuffix("--help") == false)
        #expect(AccountDiscovery.isPlausibleAccountSuffix("") == false)
        #expect(AccountDiscovery.isPlausibleAccountSuffix("-") == false)
    }

    @Test("a lock file beside an account is not an account")
    func lockFile() {
        // Also on this machine: `~/.claude-account-f.lock`, which is account f's
        // lock, not an eighth account. It would have rendered as a tenth dead
        // row. A dot is not part of an account name.
        #expect(AccountDiscovery.isPlausibleAccountSuffix("f.lock") == false)
        #expect(AccountDiscovery.isPlausibleAccountSuffix("a.tmp") == false)
    }

    @Test("every real account name still passes")
    func realNamesPass() {
        // The filter must never be able to hide a real account — that failure
        // would be silent and far worse than the dead row it removes.
        for label in ["a", "b", "c", "d", "e", "f", "g"] {
            #expect(AccountDiscovery.isPlausibleAccountSuffix(label), "\(label) must survive")
        }
    }

    @Test("a future multi-character account name is allowed")
    func futureNames() {
        // Not assumed to be one letter: an eighth account called `ops` or `ci2`
        // must work the day it is created, with no code change.
        #expect(AccountDiscovery.isPlausibleAccountSuffix("ops"))
        #expect(AccountDiscovery.isPlausibleAccountSuffix("ci2"))
        #expect(AccountDiscovery.isPlausibleAccountSuffix("team_b"))
    }
}

@Suite("Codex state ordering")
struct CodexStateTests {

    @Test("the worst state sorts first, so problems are at the top")
    func attentionFirst() {
        var states: [CodexState] = [.ok, .notLoggedIn, .refusing("rate limit"),
                                    .blocked("out of credits")]
        states.sort()
        #expect(states.first == .blocked("out of credits"))
        #expect(states.last == .ok)
    }

    @Test("only ok is usable")
    func usability() {
        #expect(CodexState.ok.isUsable)
        #expect(CodexState.blocked("x").isUsable == false)
        #expect(CodexState.refusing("x").isUsable == false)
        #expect(CodexState.notLoggedIn.isUsable == false)
    }

    @Test("blocked and refusing carry the provider's own words, not a paraphrase")
    func keepsProviderWords() {
        // "out of credits" is a billing problem; "rate limited" is a waiting
        // problem. Collapsing them into one label would hide which action to take.
        #expect(CodexState.blocked("workspace is out of credits").detail
                == "workspace is out of credits")
        #expect(CodexState.refusing("usage limit").detail == "usage limit")
    }
}

@Suite("A Codex reading is never presented as live")
struct CodexReadingTests {

    private func row(takenAt: Date?) -> CodexUsage {
        CodexUsage(
            account: CodexAccount(configDir: "/tmp/.codex-account-a", label: "a",
                                  email: nil, plan: nil),
            state: .ok, liveLanes: 0,
            usedPercent: 70, windowMinutes: 10_080, resetsAt: nil,
            readingTakenAt: takenAt, hasCredits: false
        )
    }

    @Test("no reading at all counts as stale, never as fine")
    func absenceIsStale() {
        // The failure mode this whole app keeps guarding against: absence
        // rendering as health. A seat nobody has measured is not a healthy seat.
        #expect(row(takenAt: nil).readingIsStale())
    }

    @Test("a day-old reading of a 7-day window is stale")
    func dayOldIsStale() {
        // `codex exec` records no rate limits, so on a fleet-only seat this
        // reading comes from some past interactive session and can be weeks old.
        #expect(row(takenAt: Date.now.addingTimeInterval(-26 * 3600)).readingIsStale())
    }

    @Test("a reading from minutes ago is current")
    func freshIsCurrent() {
        #expect(row(takenAt: Date.now.addingTimeInterval(-300)).readingIsStale() == false)
    }

    @Test("the age label is always available when a reading exists")
    func ageAlwaysShown() {
        // A percentage may never be rendered without its age beside it.
        #expect(row(takenAt: Date.now.addingTimeInterval(-7200)).ageLabel == "2h old")
        #expect(row(takenAt: Date.now.addingTimeInterval(-3 * 86_400)).ageLabel == "3d old")
        #expect(row(takenAt: nil).ageLabel == nil)
    }
}
