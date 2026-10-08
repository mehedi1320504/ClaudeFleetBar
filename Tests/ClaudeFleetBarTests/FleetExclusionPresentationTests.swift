import Foundation
import Testing
@testable import ClaudeFleetBar

private func presentationUsage(_ label: String, used: Double) -> AccountUsage {
    AccountUsage(
        account: Account(
            configDir: "/tmp/.claude-account-\(label)",
            label: label,
            email: nil,
            displayName: nil
        ),
        fiveHour: UsageWindow(utilization: used, resetsAt: nil),
        sevenDay: UsageWindow(utilization: used, resetsAt: nil),
        origin: .live,
        failure: nil,
        plan: nil
    )
}

@Suite("Fleet exclusion presentation")
struct FleetExclusionPresentationTests {
    @Test("THEN ranks only dispatchable rows and excluded rows have no launch action")
    func boardSections() {
        let h = presentationUsage("h", used: 1)
        let c = presentationUsage("c", used: 20)
        let d = presentationUsage("d", used: 30)
        let sections = Ranking.boardSections([h, c, d], best: c, excluding: ["h"])

        #expect(sections.dispatchable.map(\.usage.account.label) == ["d"])
        #expect(sections.dispatchable.map(\.rank) == [2])
        #expect(sections.dispatchable.allSatisfy { $0.allowsLaunchCommand })
        #expect(sections.excluded.map(\.usage.account.label) == ["h"])
        #expect(sections.excluded.allSatisfy { $0.rank == nil && !$0.allowsLaunchCommand })
    }

    @Test("an unreadable policy disables every board launch action")
    func unreadablePolicy() {
        let rows = [presentationUsage("a", used: 10), presentationUsage("b", used: 20)]
        let sections = Ranking.boardSections(rows, best: nil, excluding: nil)
        #expect(sections.dispatchable.isEmpty)
        #expect(sections.excluded.count == 2)
        #expect(sections.excluded.allSatisfy { $0.rank == nil && !$0.allowsLaunchCommand })
    }

    @Test("an excluded account is never announced as good to dispatch")
    func notifierSkipsExcludedFreeTransition() {
        final class Box: @unchecked Sendable { var messages: [String] = [] }
        let box = Box()
        let notifier = Notifier(sink: { title, body in box.messages.append("\(title): \(body)") })
        notifier.isEnabled = true
        let spent = presentationUsage("h", used: 95)
        let free = presentationUsage("h", used: 20)

        notifier.reportTransitions(from: [], to: [spent], excluding: ["h"])
        notifier.reportTransitions(from: [spent], to: [free], excluding: ["h"])

        #expect(box.messages.isEmpty)
    }
}
