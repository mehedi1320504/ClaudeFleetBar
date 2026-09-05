import Testing
import Foundation
@testable import ClaudeFleetBar

/// The credential read must never raise the Keychain dialog from a refresh.
/// The keychain itself cannot be exercised here (tests run without a bundle
/// or a login session), so these pin the pure parts: what `security -w`
/// prints and how the blob is decoded.

private let blob = """
{"claudeAiOauth":{"accessToken":"sk-ant-oat01-example","refreshToken":"r","expiresAt":1893456000000,"scopes":["user:inference"],"subscriptionType":"team"}}
"""

@Suite("security -w output")
struct ToolOutputTests {
    @Test("the trailing newline is stripped and JSON passes through untouched")
    func stripsNewline() {
        let out = KeychainCredentials.toolOutput(Data((blob + "\n").utf8))
        #expect(String(decoding: out, as: UTF8.self) == blob)
    }

    @Test("a hex-encoded blob is decoded to its bytes")
    func decodesHex() {
        let hex = Data(blob.utf8).map { String(format: "%02x", $0) }.joined()
        let out = KeychainCredentials.toolOutput(Data((hex + "\n").utf8))
        #expect(String(decoding: out, as: UTF8.self) == blob)
    }

    @Test("empty output stays empty")
    func empty() {
        #expect(KeychainCredentials.toolOutput(Data("\n".utf8)).isEmpty)
    }
}

@Suite("Credential blob")
struct CredentialParseTests {
    @Test("token, expiry and plan come out of the CLI's blob")
    func parses() throws {
        let creds = try KeychainCredentials.parse(Data(blob.utf8))
        #expect(creds.accessToken == "sk-ant-oat01-example")
        #expect(creds.subscriptionType == "team")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(creds.isExpired == false)
    }

    @Test("a blob without a token is malformed, not silently empty")
    func malformed() {
        #expect(throws: KeychainCredentials.Failure.malformed) {
            try KeychainCredentials.parse(Data("{\"claudeAiOauth\":{}}".utf8))
        }
        #expect(throws: KeychainCredentials.Failure.malformed) {
            try KeychainCredentials.parse(Data("not json".utf8))
        }
    }
}

@Suite("Locked keychain row")
struct KeychainDeniedTests {
    @Test("a locked item reads as a permission to grant, not a broken account")
    func copy() {
        let f = UsageFailure.keychainDenied
        #expect(f.needsGrant)
        #expect(f.summary == "keychain locked")
        #expect(f.remedy.contains("Always Allow"))
        #expect(UsageFailure.rateLimited(retryAt: nil).needsGrant == false)
    }

    @Test("a locked row has no reading and is never recommended")
    func notRecommended() {
        let account = Account(configDir: "/tmp/.claude-account-d", label: "d", email: nil, displayName: nil)
        let row = AccountUsage.failed(account, .keychainDenied)
        #expect(Ranking.headroom(row) == nil)
        #expect(Ranking.recommended([row]) == nil)
    }
}
