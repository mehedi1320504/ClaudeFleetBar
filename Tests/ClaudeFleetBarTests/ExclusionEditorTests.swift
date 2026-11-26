import Foundation
import Testing
@testable import ClaudeFleetBar

/// A throwaway HOME holding a policy file. Every edit passes both the file and
/// an environment whose HOME is this dir, so no path can reach the real policy.
private struct Sandbox {
    let home: URL
    var file: URL { home.appendingPathComponent(".config/claude-fleet/exclude-accounts") }
    var backup: URL {
        file.deletingLastPathComponent().appendingPathComponent("exclude-accounts" + ExclusionEditor.backupSuffix)
    }
    var environment: [String: String] { ["HOME": home.path] }

    init(policy: String?) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config/claude-fleet"), withIntermediateDirectories: true
        )
        if let policy { try policy.write(to: file, atomically: true, encoding: .utf8) }
    }

    func contents() throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func apply(
        _ change: ExclusionEditor.Change, _ label: String, environment extra: [String: String] = [:]
    ) throws(ExclusionEditor.Failure) -> Bool {
        try ExclusionEditor.apply(
            change, to: label, environment: environment.merging(extra) { $1 }, fileURL: file
        )
    }
}

private func snapshotUsage(_ label: String, used: Double) -> AccountUsage {
    AccountUsage(
        account: Account(configDir: "/tmp/.claude-account-\(label)", label: label, email: nil, displayName: nil),
        fiveHour: UsageWindow(utilization: used, resetsAt: nil),
        sevenDay: UsageWindow(utilization: used, resetsAt: nil),
        origin: .live,
        failure: nil,
        plan: nil
    )
}

@Suite("Exclusion editor: the text")
struct ExclusionTextTests {
    /// The operator's own file on 2026-11-26.
    let fleet = "p,i,r,s,u,o,g,c,f,m,x,j,e\n"

    @Test("excluding appends to the last entry, joined the way its line already is")
    func adding() {
        #expect(ExclusionEditor.adding("k", to: fleet) == "p,i,r,s,u,o,g,c,f,m,x,j,e,k\n")
        #expect(ExclusionEditor.adding("x", to: "o, f # unavailable\n") == "o, f, x # unavailable\n")
        #expect(ExclusionEditor.adding("x", to: "a b\n") == "a b x\n")
        #expect(ExclusionEditor.adding("x", to: "# reserved\nh,m\n# end\n") == "# reserved\nh,m,x\n# end\n")
        #expect(ExclusionEditor.adding("x", to: "h") == "h,x")
    }

    @Test("activating removes that entry and one separator, wherever it sits")
    func removing() {
        #expect(ExclusionEditor.removing("s", from: fleet) == "p,i,r,u,o,g,c,f,m,x,j,e\n")
        #expect(ExclusionEditor.removing("p", from: fleet) == "i,r,s,u,o,g,c,f,m,x,j,e\n")
        #expect(ExclusionEditor.removing("e", from: fleet) == "p,i,r,s,u,o,g,c,f,m,x,j\n")
        #expect(ExclusionEditor.removing("p", from: "p,i,p\n") == "i\n")
    }

    @Test("comments, other lines and CRLF line breaks keep their bytes")
    func preserves() {
        #expect(ExclusionEditor.removing("f", from: "o, f # unavailable\n") == "o # unavailable\n")
        #expect(ExclusionEditor.removing("o", from: "o, f # unavailable\n") == "f # unavailable\n")
        #expect(ExclusionEditor.removing("x", from: "x # reserved for ops\nh,m\n") == "# reserved for ops\nh,m\n")
        #expect(ExclusionEditor.removing("m", from: "h,m # m is the judge\n") == "h # m is the judge\n")
        #expect(ExclusionEditor.removing("i", from: "p,i\r\nr\r\n") == "p\r\nr\r\n")
    }

    @Test("the editor and the parser agree on what an entry is")
    func agreement() {
        for text in [fleet, " a , b\t c\n", "# x\nh,m # m too\n\n", "a,b # c\r\nd\r\n", ",,a,,\n", "h"] {
            let entries = Set(ExclusionEditor.entries(in: text).map { String(text[$0.range]) })
            #expect(entries == AccountExclusions.parse(text, comments: true), "\(text.debugDescription)")
        }
    }

    /// Swift reads "\r\n" as ONE character, so splitting on "\n" saw a single
    /// line, and its first `#` hid every entry after it. claude-fleet's
    /// `splitlines()` excludes d here; the board used to recommend it.
    @Test("a CRLF line break ends a comment, as it does for claude-fleet")
    func crlf() {
        #expect(AccountExclusions.parse("a,b # c\r\nd\r\n", comments: true) == ["a", "b", "d"])
    }
}

@Suite("Exclusion toggles")
struct ExclusionToggleTests {
    @Test("the board offers what it can do, and says why when it can't")
    func availability() {
        let policy = AccountExclusions.Breakdown(environment: ["e"], durable: ["d", "x"], override: ["o"])
        #expect(policy.toggle(for: "a") == .exclude)
        #expect(policy.toggle(for: "d") == .activate)
        #expect(policy.toggle(for: "e") == .locked(.environment))
        #expect(policy.toggle(for: "o") == .locked(.overrideFile))
        #expect(policy.toggle(for: "default") == .unavailable)
        #expect(policy.toggle(for: "ops") == .unavailable)
    }

    @Test("taking an account out of the file would not activate one the environment still excludes")
    func environmentWins() {
        let policy = AccountExclusions.Breakdown(environment: ["d"], durable: ["d", "x"], override: [])
        #expect(policy.toggle(for: "d") == .locked(.environment))
    }

    @Test("the file's last entry stays, because an empty file stops every dispatch")
    func lastEntry() {
        let policy = AccountExclusions.Breakdown(environment: [], durable: ["d"], override: [])
        #expect(policy.toggle(for: "d") == .locked(.lastEntry))
    }

    @Test("the breakdown keeps each source apart, and load is their union")
    func sources() throws {
        let box = try Sandbox(policy: "d,x\n")
        defer { box.remove() }
        let extra = box.home.appendingPathComponent("extra")
        try "o\n".write(to: extra, atomically: true, encoding: .utf8)
        let environment = box.environment.merging([
            AccountExclusions.environmentName: "e",
            AccountExclusions.fileEnvironmentName: extra.path,
        ]) { $1 }

        let policy = try #require(AccountExclusions.breakdown(environment: environment, fileURL: box.file))
        #expect(policy == AccountExclusions.Breakdown(environment: ["e"], durable: ["d", "x"], override: ["o"]))
        #expect(AccountExclusions.load(environment: environment, fileURL: box.file) == ["d", "e", "o", "x"])
    }
}

@Suite("Exclusion editor: the file")
struct ExclusionFileTests {
    @Test("exclude, then activate: each edit lands, and the previous policy is kept")
    func roundTrip() throws {
        let box = try Sandbox(policy: "p,i,r\n")
        defer { box.remove() }

        #expect(try box.apply(.exclude, "k"))
        #expect(try box.contents() == "p,i,r,k\n")
        #expect(try String(contentsOf: box.backup, encoding: .utf8) == "p,i,r\n")
        #expect(AccountExclusions.load(environment: box.environment, fileURL: box.file) == ["p", "i", "r", "k"])

        #expect(try box.apply(.activate, "i"))
        #expect(try box.contents() == "p,r,k\n")
        #expect(try String(contentsOf: box.backup, encoding: .utf8) == "p,i,r,k\n")
    }

    @Test("asking for the state an account is already in writes nothing")
    func idempotent() throws {
        let box = try Sandbox(policy: "p,i,r\n")
        defer { box.remove() }
        #expect(try box.apply(.exclude, "p") == false)
        #expect(try box.apply(.activate, "z") == false)
        #expect(try box.contents() == "p,i,r\n")
        #expect(!FileManager.default.fileExists(atPath: box.backup.path))
    }

    @Test("a refused edit leaves the file exactly as it was")
    func refusals() throws {
        let box = try Sandbox(policy: "h\n")
        defer { box.remove() }
        #expect(throws: ExclusionEditor.Failure.locked(.lastEntry)) { try box.apply(.activate, "h") }
        #expect(throws: ExclusionEditor.Failure.notAnAccountLetter) { try box.apply(.exclude, "default") }
        #expect(try box.contents() == "h\n")

        try "p,x\n".write(to: box.file, atomically: true, encoding: .utf8)
        #expect(throws: ExclusionEditor.Failure.locked(.environment)) {
            try box.apply(.activate, "x", environment: [AccountExclusions.environmentName: "x"])
        }
        let extra = box.home.appendingPathComponent("extra")
        try "x\n".write(to: extra, atomically: true, encoding: .utf8)
        #expect(throws: ExclusionEditor.Failure.locked(.overrideFile)) {
            try box.apply(.activate, "x", environment: [AccountExclusions.fileEnvironmentName: extra.path])
        }
        #expect(try box.contents() == "p,x\n")
        #expect(!FileManager.default.fileExists(atPath: box.backup.path))
    }

    @Test("an unreadable policy is never overwritten, and a missing one is never created")
    func unreadable() throws {
        let box = try Sandbox(policy: nil)
        defer { box.remove() }
        #expect(throws: ExclusionEditor.Failure.policyUnreadable) { try box.apply(.exclude, "x") }
        #expect(!FileManager.default.fileExists(atPath: box.file.path))

        for broken in ["h, account-m\n", "# truncated\n", ""] {
            try broken.write(to: box.file, atomically: true, encoding: .utf8)
            #expect(throws: ExclusionEditor.Failure.policyUnreadable) { try box.apply(.exclude, "x") }
            #expect(try box.contents() == broken)
        }
    }

    @Test("a read-only policy is left alone")
    func readOnly() throws {
        let box = try Sandbox(policy: "p,i\n")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.file.path)
            box.remove()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.file.path)
        #expect(throws: ExclusionEditor.Failure.readOnly) { try box.apply(.exclude, "x") }
        #expect(try box.contents() == "p,i\n")
    }

    @Test("the policy keeps its mode, and a symlinked one stays a symlink")
    func modeAndSymlink() throws {
        let box = try Sandbox(policy: nil)
        defer { box.remove() }
        let target = box.home.appendingPathComponent("dotfiles-exclude-accounts")
        try "p,i\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: box.file, withDestinationURL: target)

        #expect(try box.apply(.exclude, "x"))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.file.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "p,i,x\n")
        #expect(try String(contentsOf: box.backup, encoding: .utf8) == "p,i\n")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

@Suite("Snapshot after an exclusion edit")
struct ExclusionSnapshotTests {
    /// claude-fleet's rankers trust the export only while `generated_at` is
    /// recent. The re-export after an edit passes the last refresh's time, so
    /// it changes what the policy decides and nothing about how old the
    /// readings look.
    @Test("a re-export follows the new policy and keeps the refresh's time")
    func keepsRefreshTime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-republish-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let refreshedAt = Date(timeIntervalSinceNow: -600)
        let rows = [snapshotUsage("h", used: 1), snapshotUsage("c", used: 40)]

        SnapshotExporter.write(rows, now: refreshedAt, to: url, excluding: ["h"])
        SnapshotExporter.write(rows, now: refreshedAt, to: url, excluding: ["m"])

        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["recommended"] as? String == "h")
        #expect(json["run_order"] as? [String] == ["h", "c"])
        #expect(json["generated_at"] as? String == ISO8601.string(refreshedAt))
        let accounts = try #require(json["accounts"] as? [[String: Any]])
        #expect(accounts.allSatisfy { $0["fetched_at"] as? String == ISO8601.string(refreshedAt) })
    }
}
