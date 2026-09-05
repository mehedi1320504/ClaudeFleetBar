import Foundation
import UserNotifications

/// Alerts on TRANSITIONS only.
///
/// A notifier that fires every refresh is one you learn to ignore, so
/// each account carries a state and only a change of state notifies.
final class Notifier: @unchecked Sendable {
    /// Above this, an account is treated as nearly spent.
    static let warnThreshold: Double = 90
    /// Crossing back below this counts as "freed up".
    static let freeThreshold: Double = 60

    private enum Level: Equatable { case free, busy, spent, unusable }

    private var levels: [String: Level] = [:]
    private var authorized = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alertsEnabled") }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                self?.authorized = granted
            }
    }

    func reportTransitions(from previous: [AccountUsage], to current: [AccountUsage]) {
        let wasEmpty = previous.isEmpty
        for usage in current {
            let level = Self.level(for: usage)
            let old = levels[usage.id]
            levels[usage.id] = level

            // The first pass establishes a baseline; it is not a transition.
            guard !wasEmpty, let old, old != level, isEnabled else { continue }
            guard let (title, body) = Self.message(usage, from: old, to: level) else { continue }
            post(title: title, body: body, id: usage.id)
        }
    }

    private static func level(for usage: AccountUsage) -> Level {
        guard let headroom = Ranking.headroom(usage) else { return .unusable }
        let used = 100 - headroom
        if used >= 100 { return .unusable }
        if used >= warnThreshold { return .spent }
        if used <= freeThreshold { return .free }
        return .busy
    }

    private static func message(_ usage: AccountUsage, from old: Level, to new: Level) -> (String, String)? {
        let name = usage.account.label.uppercased()
        let headroom = Ranking.headroom(usage).map { Int($0.rounded()) }

        switch (old, new) {
        case (_, .free) where old == .spent || old == .unusable:
            return ("Account \(name) freed up", "\(headroom ?? 0)% headroom — good to dispatch.")
        case (_, .spent) where old == .free || old == .busy:
            let window = Ranking.bindingWindow(usage)
            let detail = window.map { "\($0.name) at \(Int($0.window.utilization.rounded()))%" } ?? "nearly spent"
            return ("Account \(name) nearly spent", "\(detail). Reach for another account.")
        case (_, .unusable):
            let resets = Ranking.bindingWindow(usage)?.window.resetsAt
            let when = resets.map { Format.countdown(to: $0) } ?? "unknown"
            return ("Account \(name) is out", "Resets in \(when).")
        default:
            return nil
        }
    }

    private func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
