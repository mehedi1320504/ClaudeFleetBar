import SwiftUI

/// The Codex seats, as their own section under the Claude accounts.
///
/// ═══ WHAT THIS SECTION PROMISES, AND WHAT IT REFUSES TO ═══
///
/// It answers exactly one question: **can a Codex seat take work right now.**
/// That is what matters when the Claude accounts are spent, which is the moment
/// this section was asked for.
///
/// It deliberately does NOT show a headroom percentage in the same visual weight
/// as the Claude rows, because there is no live one to show. `codex exec` — the
/// mode every fleet lane runs in — writes no rollout file and reports no rate
/// limits, so the only percentage available comes from a past INTERACTIVE
/// session and can be weeks old. Rendering that as a live gauge beside a live
/// one would be a number standing for two different things, which is the exact
/// defect class this estate keeps paying for. So the reading appears small,
/// always with its age, and greyed once it is too old to steer by.
struct CodexSection: View {
    let rows: [CodexUsage]
    let now: Date

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("CODEX")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(Palette.subtle)
                    Text("different provider · different limit pool")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.subtle.opacity(0.7))
                }

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        CodexRow(row: row, now: now)
                        if index < rows.count - 1 {
                            Divider().overlay(Palette.hairline)
                        }
                    }
                }
            }
        }
    }
}

struct CodexRow: View {
    let row: CodexUsage
    let now: Date

    private var stateTint: Color {
        switch row.state {
        case .ok: Palette.tint(forUsed: 0)
        case .refusing: Palette.tint(forUsed: 90)
        case .blocked: Palette.tint(forUsed: 100)
        case .notLoggedIn: Palette.subtle
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(row.account.label.uppercased())
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(stateTint)
                .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.state.headline)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(stateTint)
                    if row.liveLanes > 0 {
                        Text("· \(row.liveLanes) lane\(row.liveLanes == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.subtle)
                    }
                }
                // The provider's own words, never a paraphrase: "out of credits"
                // and "rate limited" want different actions — one is billing,
                // the other is waiting.
                if let detail = row.state.detail {
                    Text(detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.subtle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let email = row.account.email {
                    Text(email)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.subtle.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            // The recorded reading — small, and never without its age.
            VStack(alignment: .trailing, spacing: 1) {
                if let used = row.usedPercent {
                    let stale = row.readingIsStale(now: now)
                    Text(Format.percent(used))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(stale ? Palette.subtle : Palette.tint(forUsed: used))
                    HStack(spacing: 3) {
                        if let w = row.windowMinutes, w > 0 {
                            Text(w >= 1440 ? "\(w / 1440)d" : "\(w / 60)h")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Palette.subtle)
                        }
                        if let age = row.ageLabel {
                            Text(age)
                                .font(.system(size: 9, weight: stale ? .semibold : .medium))
                                .foregroundStyle(stale ? Palette.tint(forUsed: 90) : Palette.subtle)
                        }
                    }
                } else {
                    // Absence is stated, not left blank — a blank cell reads as
                    // "fine" and this one means "nobody has measured it".
                    Text("no reading")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.subtle.opacity(0.7))
                    Text("codex exec records none")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.subtle.opacity(0.55))
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
