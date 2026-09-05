import SwiftUI

/// The detail treatment: who the account is, how much room it has, and both
/// windows as rings with their countdown and wall-clock reset.
///
/// Shared by the recommended card and by an expanded row, so the two cannot
/// drift apart — clicking a row shows exactly what the top card shows.
struct AccountDetail: View {
    let usage: AccountUsage
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            if let failure = usage.failure {
                Text(failure.remedy)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tint(forUsed: 92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The headline card: the account to reach for right now.
struct RecommendedCard: View {
    let usage: AccountUsage
    let now: Date
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("RUN NEXT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Palette.tint(forUsed: 100 - (Ranking.headroom(usage) ?? 0)))
                Spacer()
                OriginBadge(usage: usage, now: now)
            }

            AccountDetail(usage: usage, now: now)

            CopyCommandButton(account: usage.account, isCopied: isCopied, action: onCopy)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.hairline, lineWidth: 1)
        )
        .accountContextMenu(usage.account)
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

/// A row in the ranked list. Collapsed it is a compact meter; clicking it
/// expands into the same detail the top card shows.
struct AccountRow: View {
    let usage: AccountUsage
    let rank: Int
    let now: Date
    let isExpanded: Bool
    let isCopied: Bool
    let onToggle: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    private var used: Double { 100 - (Ranking.headroom(usage) ?? 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // contentShape must be applied to the LABEL, not to the Button.
            // Outside it, the button's hit area is still just its drawn glyphs,
            // so every Spacer and inter-element gap stays dead and only the
            // chevron responds.
            Button(action: onToggle) {
                collapsedRow
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    AccountDetail(usage: usage, now: now)
                    CopyCommandButton(account: usage.account, isCopied: isCopied, action: onCopy)
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.05 : (isHovering ? 0.06 : 0)))
        )
        .accountContextMenu(usage.account)
        .help(tooltip)
    }

    private var collapsedRow: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.numeric(10, .medium))
                .foregroundStyle(Palette.subtle)
                .frame(width: 12, alignment: .trailing)

            Text(usage.account.label.uppercased())
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(width: 26, alignment: .leading)

            // The meters would only repeat what the detail says, so they give
            // way to it rather than stacking two readings of the same number.
            if !isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    meter(label: "5h", window: usage.fiveHour)
                    meter(label: "7d", window: usage.sevenDay)
                }
            } else {
                OriginBadge(usage: usage, now: now)
            }

            Spacer(minLength: 6)

            trailing
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 2) {
                if usage.hasNumbers {
                    Text("\(Int((100 - used).rounded()))%")
                        .font(.numeric(13, .bold))
                        .foregroundStyle(Palette.tint(forUsed: used))
                    Text("free").font(.system(size: 9)).foregroundStyle(Palette.subtle)
                } else if let failure = usage.failure {
                    Text(failure.summary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.tint(forUsed: 100))
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(width: 62, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.subtle)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(isHovering || isExpanded ? 1 : 0.35)
                .frame(width: 10)
        }
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
        lines.append(isExpanded ? "Click to collapse" : "Click for detail")
        return lines.joined(separator: "\n")
    }
}

/// Copies the command that runs Claude Code under this account.
struct CopyCommandButton: View {
    let account: Account
    let isCopied: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(isCopied ? "Copied" : "Copy launch command")
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isCopied ? Palette.tint(forUsed: 0) : Palette.subtle)
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(AccountActions.launchCommand(for: account))
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
