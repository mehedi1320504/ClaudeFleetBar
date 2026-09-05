import Foundation

/// Reads the bits of `<configDir>/.claude.json` we care about.
///
/// This file is the CLI's, not ours — everything here is read-only.
enum ConfigFile {
    struct Profile: Sendable {
        let email: String?
        let displayName: String?
        let plan: String?
    }

    private static func json(configDir: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func profile(configDir: String) -> Profile? {
        guard let root = json(configDir: configDir),
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return Profile(
            email: oauth["emailAddress"] as? String,
            displayName: oauth["displayName"] as? String,
            plan: oauth["organizationType"] as? String
        )
    }

    /// The CLI's own last-known utilization, written when that account last
    /// ran a session. Used only as a labelled fallback: it can be days old,
    /// and on an account that has not run recently it is absent entirely.
    static func cachedUsage(configDir: String) -> (five: UsageWindow?, seven: UsageWindow?, fetchedAt: Date)? {
        guard let root = json(configDir: configDir),
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let util = cached["utilization"] as? [String: Any]
        else { return nil }

        let fetchedMs = (cached["fetchedAtMs"] as? Double) ?? 0
        let fetchedAt = Date(timeIntervalSince1970: fetchedMs / 1000)

        func window(_ key: String) -> UsageWindow? {
            guard let raw = util[key] as? [String: Any],
                  let u = raw["utilization"] as? Double else { return nil }
            return UsageWindow(utilization: u, resetsAt: ISO8601.date(raw["resets_at"] as? String))
        }
        return (window("five_hour"), window("seven_day"), fetchedAt)
    }
}

/// The API stamps fractional seconds; the plain ISO8601 formatter rejects those.
///
/// `ISO8601DateFormatter` is not `Sendable`, so formatters are built per call
/// rather than shared across the concurrent per-account refreshes.
enum ISO8601 {
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
