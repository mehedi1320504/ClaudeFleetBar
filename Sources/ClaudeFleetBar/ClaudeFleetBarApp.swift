import SwiftUI

@main
struct ClaudeFleetBarApp: App {
    @State private var store: UsageStore
    @State private var updates = UpdateController()
    private let notifier: Notifier

    init() {
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
