import SwiftUI

/// The panel that drops out of the menu bar.
struct FleetBoardView: View {
    @Bindable var store: UsageStore
    let notifier: Notifier

    @State private var now = Date()
    @State private var showSettings = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if store.usages.isEmpty {
                emptyState
            } else {
                if let best = Ranking.recommended(store.usages) {
                    RecommendedCard(usage: best, now: now)
                    rest(excluding: best)
                } else {
                    allSpent
                    rest(excluding: nil)
                }
            }

            Divider().overlay(Palette.hairline)
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .onReceive(tick) { now = $0 }
        .onAppear { Task { await store.refreshIfStale(olderThan: 20) } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Fleet")
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if let last = store.lastRefresh {
                Text("updated \(Format.countdown(to: now, now: last)) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.subtle)
            }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }

    @ViewBuilder
    private func rest(excluding best: AccountUsage?) -> some View {
        let others = Ranking.runOrder(store.usages).filter { $0.id != best?.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(best == nil ? "ACCOUNTS" : "THEN")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Palette.subtle)

                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, usage in
                        AccountRow(usage: usage, rank: index + 2, now: now)
                        if index < others.count - 1 {
                            Divider().overlay(Palette.hairline)
                        }
                    }
                }
            }
        }
    }

    private var allSpent: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.tint(forUsed: 100))
            VStack(alignment: .leading, spacing: 2) {
                Text("Every account is spent").font(.system(size: 13, weight: .semibold))
                if let soonest = soonestReset {
                    Text("First reset in \(Format.countdown(to: soonest, now: now))")
                        .font(.numeric(11, .medium))
                        .foregroundStyle(Palette.subtle)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
    }

    private var soonestReset: Date? {
        store.usages
            .compactMap { Ranking.bindingWindow($0)?.window.resetsAt }
            .filter { $0 > now }
            .min()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts found").font(.system(size: 13, weight: .semibold))
            Text("Looking for ~/.claude-account-* and ~/.claude. Sign in with CLAUDE_CONFIG_DIR set, then refresh.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { showSettings.toggle() } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView(store: store, notifier: notifier)
            }

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle)
        }
    }
}

/// Interval and alert preferences.
struct SettingsView: View {
    @Bindable var store: UsageStore
    let notifier: Notifier
    @State private var alertsOn: Bool

    init(store: UsageStore, notifier: Notifier) {
        self.store = store
        self.notifier = notifier
        _alertsOn = State(initialValue: notifier.isEnabled)
    }

    private let intervals: [(String, TimeInterval)] = [
        ("30s", 30), ("1 min", 60), ("2 min", 120), ("5 min", 300), ("15 min", 900),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 13, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 5) {
                Text("Refresh every").font(.system(size: 11, weight: .medium))
                Picker("", selection: $store.refreshInterval) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Alert when an account frees up", isOn: $alertsOn)
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: alertsOn) { _, on in
                    notifier.isEnabled = on
                    if on { notifier.requestAuthorization() }
                }

            Text("Board is exported to ~/.cache/claude-fleet-bar/usage.json for scripting.")
                .font(.system(size: 9))
                .foregroundStyle(Palette.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 290)
    }
}
