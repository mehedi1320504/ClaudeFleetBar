import Foundation

/// Publishes the board as JSON so other tooling can rank accounts by real
/// headroom instead of probing blind.
///
/// Written to `~/.cache/claude-fleet-bar/usage.json`.
enum SnapshotExporter {
    static var path: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/claude-fleet-bar/usage.json")
    }

    /// One account's last live reading, as kept across a relaunch.
    struct Reading: Sendable, Equatable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let plan: String?
        let at: Date
    }

    static func write(_ usages: [AccountUsage], now: Date = .now, to url: URL = path) {
        let ordered = Ranking.runOrder(usages, now: now)
        let payload: [String: Any] = [
            "generated_at": ISO8601.string(now),
            "recommended": Ranking.recommended(usages, now: now)?.account.label as Any? ?? NSNull(),
            "run_order": ordered.map(\.account.label),
            "accounts": ordered.map { usage in
                var row: [String: Any] = [
                    "label": usage.account.label,
                    "config_dir": usage.account.configDir,
                    "live": usage.origin?.isLive ?? false,
                    // "live" | "stale" (this app's last live read) | "cache"
                    // (the CLI's file) | null. `actionable` is the rule the
                    // recommendation uses: live, or stale but recent.
                    "origin": originName(usage.origin) as Any? ?? NSNull(),
                    "actionable": Ranking.isActionable(usage, now: now),
                ]
                let fetchedAt = usage.origin.map { $0.fetchedAt ?? now }
                row["fetched_at"] = fetchedAt.map { ISO8601.string($0) } as Any? ?? NSNull()
                row["age_seconds"] = fetchedAt.map { Int(now.timeIntervalSince($0)) } as Any? ?? NSNull()
                row["email"] = usage.account.email as Any? ?? NSNull()
                row["headroom"] = Ranking.headroom(usage, now: now) as Any? ?? NSNull()
                row["five_hour"] = window(usage.fiveHour)
                row["seven_day"] = window(usage.sevenDay)
                row["plan"] = usage.plan as Any? ?? NSNull()
                row["error"] = usage.failure?.summary as Any? ?? NSNull()
                row["retry_at"] = usage.failure?.retryAt.map { ISO8601.string($0) } as Any? ?? NSNull()
                return row
            },
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// The last live readings this app exported, by config dir — what a
    /// relaunch starts from. Without it an update or restart blanked every
    /// account whose token had since expired: the numbers lived only in
    /// memory, and on 2026-10-04 the 1.1.1 update wiped A, F, J and K.
    ///
    /// Only this app's own readings ("live", or "stale" carrying its original
    /// fetch time) come back. A "cache" row is the CLI's file, which the
    /// fallback reads first-hand anyway.
    static func lastLiveReadings(from url: URL = path) -> [String: Reading] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["accounts"] as? [[String: Any]]
        else { return [:] }

        var out: [String: Reading] = [:]
        for row in rows {
            guard let origin = row["origin"] as? String, origin == "live" || origin == "stale",
                  let dir = row["config_dir"] as? String,
                  let at = ISO8601.date(row["fetched_at"] as? String)
            else { continue }
            let five = readWindow(row["five_hour"])
            let seven = readWindow(row["seven_day"])
            guard five != nil || seven != nil else { continue }
            out[dir] = Reading(fiveHour: five, sevenDay: seven, plan: row["plan"] as? String, at: at)
        }
        return out
    }

    private static func readWindow(_ raw: Any?) -> UsageWindow? {
        guard let raw = raw as? [String: Any], let u = raw["utilization"] as? Double else { return nil }
        return UsageWindow(utilization: u, resetsAt: ISO8601.date(raw["resets_at"] as? String))
    }

    private static func originName(_ origin: UsageOrigin?) -> String? {
        switch origin {
        case .live: "live"
        case .stale: "stale"
        case .cache: "cache"
        case nil: nil
        }
    }

    private static func window(_ w: UsageWindow?) -> Any {
        guard let w else { return NSNull() }
        return [
            "utilization": w.utilization,
            "resets_at": w.resetsAt.map { ISO8601.string($0) } as Any? ?? NSNull(),
        ]
    }
}
