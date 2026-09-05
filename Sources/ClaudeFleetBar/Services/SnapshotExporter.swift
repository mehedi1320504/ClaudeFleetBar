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

    static func write(_ usages: [AccountUsage], now: Date = .now) {
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
                row["error"] = usage.failure?.summary as Any? ?? NSNull()
                row["retry_at"] = usage.failure?.retryAt.map { ISO8601.string($0) } as Any? ?? NSNull()
                return row
            },
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: path, options: .atomic)
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
