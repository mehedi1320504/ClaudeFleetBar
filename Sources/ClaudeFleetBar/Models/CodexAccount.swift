import Foundation

/// A Codex config directory — `~/.codex-account-{a,b}`, the exact analogue of a
/// Claude `~/.claude-account-*`, selected per dispatch with `CODEX_HOME`.
///
/// ═══ WHY CODEX IS ITS OWN SECTION AND NOT A ROW IN THE CLAUDE LIST ═══
///
/// The board's ranked list answers one question: which Claude account should the
/// next `claude-fleet run` go to. A Codex seat cannot answer that question — it
/// is a different provider, a different limit pool, and `codex-fleet` picks it.
/// Ranking the two together would put a number in the "RUN NEXT" slot that the
/// launch command it copies cannot use.
///
/// They belong on the same screen for the reason the operator asked for it: when
/// four Claude accounts are blocked, the only thing that matters is whether a
/// Codex seat can still take work.
struct CodexAccount: Sendable, Equatable, Identifiable, Hashable {
    /// Absolute path, e.g. `~/.codex-account-a`.
    let configDir: String
    /// Short label: `a`, `b`, …
    let label: String
    /// Decoded out of `auth.json`'s id_token, when readable.
    let email: String?
    /// ChatGPT plan, e.g. "team".
    let plan: String?

    var id: String { configDir }
}

/// What a Codex seat can do RIGHT NOW.
///
/// Ordered worst-first so `<` sorts the section with the problems at the top,
/// matching the Claude list's attention-first convention.
enum CodexState: Sendable, Equatable, Comparable {
    /// The provider refused the last live probe. Carries its own words.
    case blocked(String)
    /// Signed in, but a RUNNING lane's log carries a refusal right now.
    case refusing(String)
    /// No credentials in this directory.
    case notLoggedIn
    /// Usable.
    case ok

    var rank: Int {
        switch self {
        case .blocked: 0
        case .refusing: 1
        case .notLoggedIn: 2
        case .ok: 3
        }
    }

    static func < (l: CodexState, r: CodexState) -> Bool { l.rank < r.rank }

    var isUsable: Bool { self == .ok }

    var headline: String {
        switch self {
        case .blocked: "blocked"
        case .refusing: "refusing"
        case .notLoggedIn: "not signed in"
        case .ok: "ready"
        }
    }

    /// The provider's own words, never a paraphrase — "workspace is out of
    /// credits" and "rate limited" want different actions from the operator.
    var detail: String? {
        switch self {
        case .blocked(let why), .refusing(let why): why
        case .notLoggedIn: "codex-fleet login"
        case .ok: nil
        }
    }
}

/// One Codex seat's row.
struct CodexUsage: Sendable, Equatable, Identifiable {
    let account: CodexAccount
    let state: CodexState
    /// Lanes running on this seat right now.
    let liveLanes: Int
    /// The last rate-limit reading Codex itself recorded, and WHEN.
    ///
    /// `codex exec` — the mode every fleet lane runs in — DOES write these, once
    /// per turn, into `$CODEX_HOME/sessions/<date>/rollout-*.jsonl`. A seat with a
    /// lane running therefore has a genuinely LIVE figure, seconds old. Measured
    /// 2026-09-29: the lane dispatched at 04:38 had written 99 readings by 05:07.
    ///
    /// ★ I first recorded the opposite here — "exec writes no rollout" — on the
    /// strength of `find -newermt`, which BSD find does not support: it matched
    /// nothing, and NOTHING-MATCHED looked exactly like NO-SUCH-FILES. The same
    /// collapsed-value shape as every other false signal in this estate, in the
    /// probe rather than in the product.
    ///
    /// It stays optional and always carries its age, because the reading only
    /// advances while a lane runs: a seat idle for a week has a week-old number,
    /// and a 7-day window read a week late says nothing useful.
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
    let readingTakenAt: Date?
    /// From the same reading: whether the workspace had purchasable credits.
    let hasCredits: Bool?

    var id: String { account.id }

    /// True when the only numbers we have are too old to steer a decision by.
    /// Twelve hours is deliberately short: these readings describe a 7-day
    /// window, so a day-old one can be badly wrong about what is left today.
    func readingIsStale(now: Date = .now) -> Bool {
        guard let readingTakenAt else { return true }
        return now.timeIntervalSince(readingTakenAt) > 12 * 3600
    }

    var ageLabel: String? {
        guard let readingTakenAt else { return nil }
        let secs = Date.now.timeIntervalSince(readingTakenAt)
        if secs < 3600 { return "\(Int(secs / 60))m old" }
        if secs < 86_400 { return "\(Int(secs / 3600))h old" }
        return "\(Int(secs / 86_400))d old"
    }
}
