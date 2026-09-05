import Foundation
import CryptoKit

/// A Claude Code config directory — one per signed-in account.
struct Account: Sendable, Equatable, Identifiable, Hashable {
    /// Absolute path of the config dir, e.g. `~/.claude-account-a`.
    let configDir: String
    /// Short display label: `a`…`e` for `~/.claude-account-*`, else the dir name.
    let label: String
    /// Email from `.claude.json`'s `oauthAccount`, when present.
    let email: String?
    /// Display name from `.claude.json`, when present.
    let displayName: String?

    var id: String { configDir }

    /// Claude Code derives its Keychain service name as
    /// `Claude Code-credentials-<sha256(configDir) first 8 hex>`.
    /// Matching that derivation is what lets us read each account
    /// separately without ever writing to the Keychain.
    var keychainService: String {
        let digest = SHA256.hash(data: Data(configDir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }
}
