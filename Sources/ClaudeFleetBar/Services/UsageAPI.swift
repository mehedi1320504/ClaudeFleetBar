import Foundation

/// Calls the same endpoint the CLI uses to fill its own usage cache.
struct UsageAPI: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Response: Sendable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
    }

    enum Failure: Error {
        case http(Int)
        /// 429. The endpoint is rate-limited per account, and it says so
        /// from the edge with `Retry-After: 0` — so the header is passed up
        /// only when it actually carries a number.
        case rateLimited(retryAfter: TimeInterval?)
        case malformed
    }

    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func fetch(token: String) async throws -> Response {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-fleet-bar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 429 {
                let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
                throw Failure.rateLimited(retryAfter: (seconds ?? 0) > 0 ? seconds : nil)
            }
            throw Failure.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed
        }

        func window(_ key: String) -> UsageWindow? {
            guard let raw = root[key] as? [String: Any],
                  let u = raw["utilization"] as? Double else { return nil }
            return UsageWindow(utilization: u, resetsAt: ISO8601.date(raw["resets_at"] as? String))
        }
        return Response(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
    }
}
