import Foundation

/// Finds the Codex seats on this machine and reads what can be known about them
/// WITHOUT spending an API call.
///
/// Everything here is read-only and local: the fleet's own state directory, the
/// probe cache `codex-fleet check` writes, and Codex's own session files. The
/// menu bar must never be the thing that burns a seat's quota to display it.
enum CodexDiscovery {
    /// `~/.codex-fleet` — the launcher's state: `<name>.pid`, `.acct`, `.rc`.
    static var fleetState: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_FLEET_STATE"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-fleet")
    }

    static func discover(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [CodexAccount] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        return entries
            .filter { $0.hasPrefix(".codex-account-") }
            // Same guard as the Claude side, for the same reason: a stray
            // argument where a name belongs creates a directory that can never
            // be signed in and shows forever as a dead row.
            .filter { AccountDiscovery.isPlausibleAccountSuffix(String($0.dropFirst(".codex-account-".count))) }
            .sorted()
            .map { name -> CodexAccount in
                let dir = home.appendingPathComponent(name).path
                let claims = authClaims(configDir: dir)
                return CodexAccount(
                    configDir: dir,
                    label: String(name.dropFirst(".codex-account-".count)),
                    email: claims?.email,
                    plan: claims?.plan
                )
            }
    }

    // MARK: - identity

    /// Decode `auth.json` → `tokens.id_token` → its claims.
    ///
    /// Identity is `chatgpt_user_id`, never `chatgpt_account_id`: two fleet seats
    /// are two SEATS OF ONE workspace and share the account id exactly, so
    /// comparing that would call two independent limit pools "the same account".
    static func authClaims(configDir: String) -> (email: String?, plan: String?, userID: String?)? {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String
        else { return nil }

        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return (
            email: claims["email"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String,
            userID: (auth?["chatgpt_user_id"] as? String) ?? (auth?["user_id"] as? String)
        )
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: - live state

    /// How many lanes are running on a seat.
    ///
    /// A pid alone is NOT liveness — pids are recycled, and on a Mac up for days
    /// they recycle fast. MEASURED 2026-09-29: a session dispatched on 1 September
    /// recorded pid 86147, which by then belonged to `sociallayerd`; `kill -0`
    /// said yes and a month-dead lane counted as live. The `.rc` file the launcher
    /// writes after the process exits is the witness that cannot be fooled, so it
    /// is checked FIRST and overrides any pid.
    static func liveLanes(account: CodexAccount) -> Int {
        let fm = FileManager.default
        let state = fleetState
        guard let entries = try? fm.contentsOfDirectory(atPath: state.path) else { return 0 }
        var n = 0
        for entry in entries where entry.hasSuffix(".pid") {
            let name = String(entry.dropLast(4))
            // 1. An exit code exists ⇒ the process is gone. Nothing overrides this.
            if fm.fileExists(atPath: state.appendingPathComponent("\(name).rc").path) { continue }
            let acct = (try? String(contentsOf: state.appendingPathComponent("\(name).acct"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard acct == account.label else { continue }
            guard let raw = try? String(contentsOf: state.appendingPathComponent(entry), encoding: .utf8),
                  let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
            else { continue }
            if kill(pid, 0) == 0 { n += 1 }
        }
        return n
    }

    /// What `codex-fleet check` last learned, from the marker it writes.
    /// Only honoured inside its TTL — a stale refusal must not blockade a seat
    /// that has since recovered.
    static func probeFailure(account: CodexAccount, ttlMinutes: Double = 20) -> String? {
        let marker = fleetState.appendingPathComponent("probe-cache/probe-fail-\(account.label)")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path),
              let modified = attrs[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) < ttlMinutes * 60,
              let text = try? String(contentsOf: marker, encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
    }

    /// The provider's own words in a RUNNING lane's log tail.
    ///
    /// Tail only, and only for live lanes: these phrases matter when they are the
    /// last thing that happened. A log that retried past a 429 an hour ago is not
    /// blocked now, and a finished lane's log says nothing about the seat today.
    static func liveRefusal(account: CodexAccount) -> String? {
        let fm = FileManager.default
        let state = fleetState
        let logs = state.appendingPathComponent("logs")
        guard let entries = try? fm.contentsOfDirectory(atPath: state.path) else { return nil }
        let needles = ["out of credits", "insufficient_quota", "insufficient quota",
                       "rate limit", "rate_limit", "quota exceeded", "usage limit"]
        for entry in entries where entry.hasSuffix(".pid") {
            let name = String(entry.dropLast(4))
            if fm.fileExists(atPath: state.appendingPathComponent("\(name).rc").path) { continue }
            let acct = (try? String(contentsOf: state.appendingPathComponent("\(name).acct"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard acct == account.label else { continue }
            guard let tail = tailString(logs.appendingPathComponent("\(name).log"), bytes: 16_384) else { continue }
            let lower = tail.lowercased()
            if let hit = needles.first(where: { lower.contains($0) }) { return hit }
        }
        return nil
    }

    private static func tailString(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - the rate-limit reading Codex itself recorded

    /// The newest `rate_limits` payload in this seat's session rollouts.
    ///
    /// ═══ READ THE AGE, ALWAYS ═══
    ///
    /// `codex exec` writes one of these per turn, so a seat with a running lane
    /// has a reading seconds old — a genuinely live headroom figure. But the
    /// reading only ADVANCES while a lane runs: an idle seat's newest rollout is
    /// as old as its last lane. So this is returned with `takenAt` and the view
    /// shows the age beside the number, always. A 7-day window read a week late
    /// is not a smaller number, it is a meaningless one.
    static func lastRateLimit(account: CodexAccount)
        -> (usedPercent: Double, windowMinutes: Int, resetsAt: Date?, takenAt: Date, hasCredits: Bool?)? {
        let fm = FileManager.default
        let sessions = URL(fileURLWithPath: account.configDir).appendingPathComponent("sessions")
        guard let walker = fm.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        var newest: (url: URL, at: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let at else { continue }
            if newest == nil || at > newest!.at { newest = (url, at) }
        }
        guard let newest else { return nil }

        // ═══ TAIL FIRST — NEVER READ THE WHOLE FILE ═══
        //
        // A running lane's rollout grows without bound: this one was 10.4 MB and
        // climbing while its lane worked. Reading it whole and splitting it cost
        // ~19 ms per call, and this is called from a view body driven by a
        // one-second clock — so the menu bar spent ~2% of every second, on the
        // MAIN THREAD, re-reading a file to find its last line. The panel felt
        // slow, and got slower the longer a lane ran.
        //
        // The newest reading is at the END, so a tail is the whole answer:
        // measured 19.3 ms → 0.2 ms, same value (65%), an 83x cut.
        //
        // The fallback is what makes the tail SAFE rather than merely fast. If a
        // window holds no reading — a long turn with no rate_limits line in it —
        // it widens rather than reporting "no reading", which would render as a
        // seat nobody has measured. A faster wrong answer is worth less than the
        // slow right one.
        var text: String?
        for window in [64 * 1024, 1024 * 1024, Int.max] {
            guard let chunk = tailString(newest.url, bytes: window) else { break }
            if chunk.contains("rate_limits") { text = chunk; break }
            // The whole file was already read and still had nothing — stop.
            if window == Int.max || chunk.utf8.count < window { break }
        }
        guard let text else { return nil }

        // Scan backwards: the LAST reading in the file is the most recent.
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let limits = findDict(obj, key: "rate_limits"),
                  let primary = limits["primary"] as? [String: Any],
                  let used = primary["used_percent"] as? Double
            else { continue }
            let window = (primary["window_minutes"] as? Int) ?? 0
            var resets: Date?
            if let epoch = primary["resets_at"] as? Double { resets = Date(timeIntervalSince1970: epoch) }
            let credits = (limits["credits"] as? [String: Any])?["has_credits"] as? Bool
            return (used, window, resets, newest.at, credits)
        }
        return nil
    }

    private static func findDict(_ o: Any, key: String) -> [String: Any]? {
        if let d = o as? [String: Any] {
            if let hit = d[key] as? [String: Any] { return hit }
            for v in d.values { if let r = findDict(v, key: key) { return r } }
        } else if let a = o as? [Any] {
            for v in a { if let r = findDict(v, key: key) { return r } }
        }
        return nil
    }

    // MARK: - assembly

    /// ═══ CACHED, BECAUSE THE CALLER ASKS EVERY SECOND ═══
    ///
    /// `FleetBoardView` recomputes its rows from a one-second clock, so without a
    /// cache every tick walked 92 files, decoded a JWT per account, tailed each
    /// live lane's log and parsed a rollout — on the main thread, inside a view
    /// body. That is what made the panel feel slow.
    ///
    /// The underlying facts change at most once per lane turn, so a few seconds
    /// of staleness is invisible and the work drops by ~15x. `ttl: 0` forces a
    /// fresh read for the `--codex-report` diagnostic, which must never show a
    /// cached answer.
    @MainActor private static var cached: (rows: [CodexUsage], at: Date)?

    @MainActor
    static func rows(now: Date = .now, ttl: TimeInterval = 8) -> [CodexUsage] {
        if ttl > 0, let hit = cached, now.timeIntervalSince(hit.at) < ttl, now >= hit.at {
            return hit.rows
        }
        let fresh = compute()
        cached = (fresh, now)
        return fresh
    }

    private static func compute() -> [CodexUsage] {
        discover().map { account in
            let refusal = liveRefusal(account: account)
            let probe = probeFailure(account: account)
            let signedIn = authClaims(configDir: account.configDir) != nil

            let state: CodexState
            if let probe { state = .blocked(probe) }
            else if let refusal { state = .refusing(refusal) }
            else if !signedIn { state = .notLoggedIn }
            else { state = .ok }

            let reading = lastRateLimit(account: account)
            return CodexUsage(
                account: account,
                state: state,
                liveLanes: liveLanes(account: account),
                usedPercent: reading?.usedPercent,
                windowMinutes: reading?.windowMinutes,
                resetsAt: reading?.resetsAt,
                readingTakenAt: reading?.takenAt,
                hasCredits: reading?.hasCredits
            )
        }
        .sorted { ($0.state, $0.account.label) < ($1.state, $1.account.label) }
    }
}
