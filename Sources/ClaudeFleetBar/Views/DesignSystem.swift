import SwiftUI

/// Formatting helpers shared by the UI and the notifier.
enum Format {
    /// Compact, human countdown: `3h 31m`, `52m`, `40s`.
    static func countdown(to date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// A window's rollover: counts down while ahead, reads `now` in the
    /// minute around it, and `passed` once the reading describes a window
    /// that has already rolled over — so a stale row cannot show a countdown
    /// that is really a reset from yesterday.
    static func resetCountdown(to date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) > 60 { return "passed" }
        return countdown(to: date, now: now)
    }

    /// Wall-clock reset time in the viewer's own timezone.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d, HH:mm"
        return f.string(from: date)
    }

    /// "updated just now" rather than "updated now ago", which is what a plain
    /// countdown produces in the second after a refresh lands.
    static func since(_ date: Date, now: Date = .now) -> String {
        let elapsed = countdown(to: now, now: date)
        return elapsed == "now" ? "updated just now" : "updated \(elapsed) ago"
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

/// Visual tokens. Every colour is defined once here so the whole app
/// reads as one system in both light and dark.
enum Palette {
    /// Utilization drives the colour: calm while there is room, warm as
    /// it tightens, red once it is effectively gone.
    static func tint(forUsed used: Double) -> Color {
        switch used {
        case ..<60: Color(red: 0.16, green: 0.70, blue: 0.51)   // teal-green
        case ..<85: Color(red: 0.85, green: 0.63, blue: 0.22)   // amber
        case ..<100: Color(red: 0.88, green: 0.42, blue: 0.24)  // ember
        default: Color(red: 0.83, green: 0.29, blue: 0.33)      // red
        }
    }

    static let track = Color.primary.opacity(0.10)
    static let hairline = Color.primary.opacity(0.08)
    static let subtle = Color.secondary
    static let cardFill = Color.primary.opacity(0.045)
}

extension Font {
    /// Tabular figures keep countdowns from shifting as they tick.
    static func numeric(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}
