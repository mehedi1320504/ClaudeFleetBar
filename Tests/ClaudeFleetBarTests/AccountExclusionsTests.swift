import Foundation
import Testing
@testable import ClaudeFleetBar

private func exclusionUsage(_ label: String, used: Double) -> AccountUsage {
    let account = Account(
        configDir: "/tmp/.claude-account-\(label)",
        label: label,
        email: nil,
        displayName: nil
    )
    return AccountUsage(
        account: account,
        fiveHour: UsageWindow(utilization: used, resetsAt: nil),
        sevenDay: UsageWindow(utilization: used, resetsAt: nil),
        origin: .live,
        failure: nil,
        plan: nil
    )
}

@Suite("Account exclusions")
struct AccountExclusionsTests {
    @Test("environment and durable file form one set")
    func union() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-exclusions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try "o, f # unavailable\nj k,l\n".write(to: url, atomically: true, encoding: .utf8)

        let labels = AccountExclusions.load(
            environment: [AccountExclusions.environmentName: "h,m,o"],
            fileURL: url
        )
        #expect(labels == Set(["f", "h", "j", "k", "l", "m", "o"]))
    }

    @Test("a malformed policy fails closed")
    func malformed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-exclusions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try "h, account-m\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(AccountExclusions.load(environment: [:], fileURL: url) == nil)
    }

    @Test("excluded accounts are neither ordered nor recommended")
    func ranking() {
        let rows = [
            exclusionUsage("h", used: 1),
            exclusionUsage("c", used: 40),
            exclusionUsage("m", used: 2),
        ]
        let excluded = Set(["h", "m"])
        #expect(Ranking.dispatchOrder(rows, excluding: excluded).map(\.account.label) == ["c"])
        #expect(Ranking.recommended(rows, excluding: excluded)?.account.label == "c")
        #expect(Ranking.dispatchOrder(rows, excluding: nil).isEmpty)
        #expect(Ranking.recommended(rows, excluding: nil) == nil)
    }

    @Test("snapshot omits exclusions from recommendation and run_order, but retains diagnostics")
    func snapshot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-exclusions-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = [exclusionUsage("h", used: 1), exclusionUsage("c", used: 40)]

        SnapshotExporter.write(rows, to: url, excluding: Set(["h"]))
        let data = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["recommended"] as? String == "c")
        #expect(json["run_order"] as? [String] == ["c"])
        let accounts = try #require(json["accounts"] as? [[String: Any]])
        #expect(Set(accounts.compactMap { $0["label"] as? String }) == Set(["c", "h"]))
    }
}
