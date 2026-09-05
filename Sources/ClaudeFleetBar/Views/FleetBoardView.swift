import SwiftUI

/// The panel that drops out of the menu bar.
struct FleetBoardView: View {
    @Bindable var store: UsageStore
    let notifier: Notifier
    let updates: UpdateController

    @State private var now = Date()
    @State private var showSettings = false
    @State private var copiedID: String?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var expandedID: String?


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let version = updates.availableVersion {
                updateBanner(version)
            }

            if store.usages.isEmpty && !store.hasLoaded {
                loadingState
            } else if store.usages.isEmpty {
                emptyState
            } else {
                if let best = Ranking.recommended(store.usages, now: now) {
                    RecommendedCard(usage: best, now: now,
                                    isCopied: copiedID == best.id) { copy(best) }
                    rest(excluding: best)
                } else {
                    if store.usages.allSatisfy({ $0.failure != nil }) {
                        unreadable
                    } else {
                        allSpent
                    }
                    rest(excluding: nil)
                }
            }

            Divider().overlay(Palette.hairline)
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .task { await runClock() }
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
                Text(Format.since(last, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.subtle)
            }
            Button { Task { await store.refresh(force: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }

    /// Surfaces an update without taking over the panel. Clicking hands off to
    /// Sparkle's own dialog, which is where the install is confirmed.
    private func updateBanner(_ version: String) -> some View {
        Button { updates.checkForUpdates() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tint(forUsed: 0))
                Text("Version \(version) is available")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("Update\u{2026}")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.tint(forUsed: 0))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.tint(forUsed: 0).opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rest(excluding best: AccountUsage?) -> some View {
        let others = Ranking.runOrder(store.usages, now: now).filter { $0.id != best?.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(best == nil ? "ACCOUNTS" : "THEN")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Palette.subtle)

                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, usage in
                        AccountRow(
                            usage: usage,
                            rank: index + 2,
                            now: now,
                            isExpanded: expandedID == usage.id,
                            isCopied: copiedID == usage.id,
                            onToggle: { toggle(usage) },
                            onCopy: { copy(usage) }
                        )
                        if index < others.count - 1 {
                            Divider().overlay(Palette.hairline)
                        }
                    }
                }
            }
        }
    }

    /// Drives the countdowns.
    ///
    /// A `Timer.publish` here kept firing while the panel was closed — profiling
    /// an idle app showed `TimerPublisher.fire` invalidating AttributeGraph and
    /// relaying out the whole window once a second, for a board nobody was
    /// looking at. `.task` is cancelled when the view goes away, so the clock
    /// cannot outlive what it is animating.
    ///
    /// The cadence follows the content: every countdown reads in whole minutes
    /// except under a minute, so a second-by-second tick is only worth paying
    /// for when something is actually counting seconds.
    private func runClock() async {
        while !Task.isCancelled {
            now = Date()
            try? await Task.sleep(for: .seconds(needsSecondTicks ? 1 : 10))
        }
    }

    /// True when any visible countdown is inside its final minute.
    private var needsSecondTicks: Bool {
        if let last = store.lastRefresh, now.timeIntervalSince(last) < 60 { return true }
        return store.usages.contains { usage in
            [usage.fiveHour, usage.sevenDay].contains { window in
                guard let seconds = window?.secondsUntilReset(now: now) else { return false }
                return seconds < 60
            }
        }
    }

    /// One row open at a time, so the panel cannot grow past the screen and
    /// the comparison stays between the open row and the card above it.
    private func toggle(_ usage: AccountUsage) {
        withAnimation(.smooth(duration: 0.22)) {
            expandedID = expandedID == usage.id ? nil : usage.id
        }
    }

    /// Copies the account's launch command and flags the row for a moment.
    /// The previous confirmation is cancelled so rapid clicks cannot leave a
    /// stale "Copied" on a row you have since moved away from.
    private func copy(_ usage: AccountUsage) {
        AccountActions.copy(AccountActions.launchCommand(for: usage.account))
        copyResetTask?.cancel()
        withAnimation(.smooth(duration: 0.15)) { copiedID = usage.id }
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) { copiedID = nil }
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
            .compactMap { Ranking.bindingWindow($0, now: now)?.window.resetsAt }
            .filter { $0 > now }
            .min()
    }

    /// Every read failed. That is not "every account is spent" — the moon
    /// card — and saying so sent people to bed with quota left. When the
    /// usage endpoint throttles all five, the accounts themselves are fine.
    private var unreadable: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.tint(forUsed: 92))
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't read usage").font(.system(size: 13, weight: .semibold))
                Text(store.usages.allSatisfy({ $0.failure?.retryAt != nil })
                     ? "The usage API is throttling every account. Last readings below, with their age."
                     : "No account answered. Last readings below, with their age.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).scaleEffect(0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading accounts\u{2026}").font(.system(size: 12, weight: .medium))
                Text("Checking each config dir's usage.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.subtle)
            }
            Spacer()
        }
        .padding(.vertical, 14)
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
                SettingsView(store: store, notifier: notifier, updates: updates)
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
    let updates: UpdateController
    @State private var alertsOn: Bool
    @State private var autoUpdate: Bool

    init(store: UsageStore, notifier: Notifier, updates: UpdateController) {
        self.store = store
        self.notifier = notifier
        self.updates = updates
        _alertsOn = State(initialValue: notifier.isEnabled)
        _autoUpdate = State(initialValue: updates.automaticallyChecks)
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

            Divider().overlay(Palette.hairline)

            Toggle("Check for updates automatically", isOn: $autoUpdate)
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: autoUpdate) { _, on in updates.automaticallyChecks = on }

            HStack(spacing: 8) {
                Text("Version \(updates.currentVersion)")
                    .font(.numeric(10, .medium))
                    .foregroundStyle(Palette.subtle)
                Spacer()
                Button("Check now") { updates.checkForUpdates() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.tint(forUsed: 0))
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
