import SwiftUI

/// `ClaudeFleetBar --codex-report` — print what the Codex section will render,
/// and exit.
///
/// A menu bar panel cannot be screenshotted from a script and cannot be asserted
/// on, so "it works" was previously something only the operator could check by
/// looking. This runs the REAL `CodexDiscovery` against the REAL machine and
/// prints its output, so the section can be verified from a terminal, by CI, and
/// by whoever is reading a commit message a month from now.
///
/// It is also where the age of a reading is unmissable. `codex exec` records one
/// every turn, so a seat with a lane running is seconds fresh — but the number
/// only advances while a lane runs, and an idle seat's is as old as its last one.
@MainActor
private func printCodexReportAndExit() -> Never {
    let rows = CodexDiscovery.rows()
    print("CODEX SEATS — what the board's Codex section shows right now")
    print(String(repeating: "─", count: 72))
    if rows.isEmpty {
        print("  (no ~/.codex-account-* directories found)")
    }
    for row in rows {
        let lanes = row.liveLanes == 0 ? "" : "  · \(row.liveLanes) lane(s)"
        print("  \(row.account.label.uppercased())  \(row.state.headline)\(lanes)")
        if let detail = row.state.detail { print("       provider says: \(detail)") }
        if let email = row.account.email { print("       \(email)") }
        if let used = row.usedPercent {
            let window = (row.windowMinutes ?? 0) >= 1440
                ? "\((row.windowMinutes ?? 0) / 1440)d window"
                : "\((row.windowMinutes ?? 0) / 60)h window"
            let age = row.ageLabel ?? "unknown age"
            let stale = row.readingIsStale() ? "  ← STALE, not a live figure" : ""
            print("       recorded \(Format.percent(used)) of a \(window), \(age)\(stale)")
        } else {
            print("       no reading — no lane has run under this CODEX_HOME")
        }
        print("")
    }
    print(String(repeating: "─", count: 72))
    print("state is LIVE (probe cache + running lanes' logs); any percentage is a")
    print("RECORDED reading from a past interactive session and carries its age.")
    exit(0)
}

@main
struct ClaudeFleetBarApp: App {
    @State private var store: UsageStore
    @State private var updates = UpdateController()
    private let notifier: Notifier

    init() {
        if CommandLine.arguments.contains("--codex-report") {
            MainActor.assumeIsolated { printCodexReportAndExit() }
        }
        let notifier = Notifier()
        self.notifier = notifier
        _store = State(initialValue: UsageStore(notifier: notifier))
    }

    var body: some Scene {
        MenuBarExtra {
            FleetBoardView(store: store, notifier: notifier, updates: updates)
        } label: {
            MenuBarLabel(usages: store.usages)
                .task {
                    store.start()
                    if notifier.isEnabled { notifier.requestAuthorization() }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
