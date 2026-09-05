import SwiftUI

/// The headline card: the account to reach for right now.
struct RecommendedCard: View {
    let usage: AccountUsage
    let now: Date
    let isCopied: Bool
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onCopy) { cardBody }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .accountContextMenu(usage.account)
            .help("Click to copy: \(AccountActions.launchCommand(for: usage.account))")
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("RUN NEXT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Palette.tint(forUsed: 100 - (Ranking.headroom(usage) ?? 0)))
                Spacer()
                if isCopied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.tint(forUsed: 0))
                } else if isHovering {
                    Label("click to copy command", systemImage: "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.subtle)
                } else {
                    OriginBadge(usage: usage, now: now)
                }
            }

            HStack(alignment: .center, spacing: 14) {
                Text(usage.account.label.uppercased())
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .frame(minWidth: 44, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int((Ranking.headroom(usage) ?? 0).rounded()))% headroom")
                        .font(.numeric(14, .semibold))
                    if let email = usage.account.email {
                        Text(email)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.subtle)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
            }

            HStack(spacing: 18) {
                WindowGauge(title: "5-hour", window: usage.fiveHour, now: now)
                Divider().frame(height: 44)
                WindowGauge(title: "Weekly", window: usage.sevenDay, now: now)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.cardFill.opacity(isHovering ? 2.2 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isHovering ? Palette.hairline.opacity(2.5) : Palette.hairline, lineWidth: 1)
        )
    }
}

/// Right-click actions shared by the card and the rows.
private struct AccountContextMenu: ViewModifier {
    let account: Account

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Copy launch command") {
                AccountActions.copy(AccountActions.launchCommand(for: account))
            }
            Button("Copy config dir path") {
                AccountActions.copy(account.configDir)
            }
            Divider()
            Button("Reveal config dir in Finder") {
                AccountActions.revealConfigDir(account)
            }
        }
    }
}

extension View {
    func accountContextMenu(_ account: Account) -> some View {
        modifier(AccountContextMenu(account: account))
    }
}

/// One window: ring, label, and when it rolls over.
struct WindowGauge: View {
    let title: String
    let window: UsageWindow?
    let now: Date

    var body: some View {
        HStack(spacing: 9) {
            UsageRing(used: window?.utilization ?? 0, size: 44, lineWidth: 5)
                .opacity(window == nil ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.subtle)
                if let resets = window?.resetsAt {
                    Text(Format.countdown(to: resets, now: now))
                        .font(.numeric(12, .semibold))
                    Text(Format.clock(resets))
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.subtle)
                } else {
                    Text("—").font(.numeric(12, .semibold)).foregroundStyle(Palette.subtle)
                }
            }
        }
    }
}

/// A compact row for every account below the recommendation.
///
/// Clicking copies the command that runs Claude Code under this account, which
/// is the thing you actually want once the board has told you which to pick.
struct AccountRow: View {
    let usage: AccountUsage
    let rank: Int
    let now: Date
    let isCopied: Bool
    let onCopy: () -> Void

    @State private var isHovering = false

    private var used: Double { 100 - (Ranking.headroom(usage) ?? 100) }

    var body: some View {
        Button(action: onCopy) { rowBody }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .accountContextMenu(usage.account)
            .help(tooltip)
    }

    private var rowBody: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.numeric(10, .medium))
                .foregroundStyle(Palette.subtle)
                .frame(width: 12, alignment: .trailing)

            Text(usage.account.label.uppercased())
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(width: 26, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                meter(label: "5h", window: usage.fiveHour)
                meter(label: "7d", window: usage.sevenDay)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if isCopied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.tint(forUsed: 0))
                        .transition(.opacity)
                } else if usage.hasNumbers {
                    Text("\(Int((100 - used).rounded()))%")
                        .font(.numeric(13, .bold))
                        .foregroundStyle(Palette.tint(forUsed: used))
                    Text(isHovering ? "copy" : "free")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.subtle)
                } else if let failure = usage.failure {
                    Text(failure.summary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.tint(forUsed: 100))
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func meter(label: String, window: UsageWindow?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.subtle)
                .frame(width: 15, alignment: .leading)
            UsageBar(used: window?.utilization ?? 0)
                .opacity(window == nil ? 0.3 : 1)
            Text(window?.resetsAt.map { Format.countdown(to: $0, now: now) } ?? "—")
                .font(.numeric(9, .medium))
                .foregroundStyle(Palette.subtle)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var tooltip: String {
        var lines = [usage.account.email ?? usage.account.configDir]
        if let f = usage.fiveHour { lines.append("5-hour: \(Format.percent(f.utilization)) used") }
        if let s = usage.sevenDay { lines.append("Weekly: \(Format.percent(s.utilization)) used") }
        if let failure = usage.failure { lines.append(failure.remedy) }
        lines.append("Click to copy: \(AccountActions.launchCommand(for: usage.account))")
        return lines.joined(separator: "\n")
    }
}

/// Says plainly whether a row is live or a stale cached read.
struct OriginBadge: View {
    let usage: AccountUsage
    let now: Date

    var body: some View {
        switch usage.origin {
        case .live:
            Label("live", systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.subtle)
        case .cache(let fetchedAt):
            Label("cached \(Format.countdown(to: now, now: fetchedAt)) old",
                  systemImage: "clock.badge.exclamationmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.tint(forUsed: 92))
        case nil:
            EmptyView()
        }
    }
}
