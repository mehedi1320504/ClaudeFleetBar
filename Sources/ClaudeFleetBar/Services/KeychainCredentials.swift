import Foundation
import Security

/// Reads Claude Code's OAuth credentials out of the login Keychain.
///
/// Strictly read-only: this app never writes, refreshes or deletes a
/// credential. If a token has expired, we say so and fall back to the
/// cached numbers rather than touching the CLI's auth state.
enum KeychainCredentials {
    struct Credentials: Sendable {
        let accessToken: String
        let expiresAt: Date
        let subscriptionType: String?
        var isExpired: Bool { Date() >= expiresAt }
    }

    enum Failure: Error {
        case notFound
        case unreadable(OSStatus)
        case malformed
    }

    static func load(for account: Account) throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw Failure.notFound }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.unreadable(status)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw Failure.malformed }

        let expiresMs = (oauth["expiresAt"] as? Double) ?? 0
        return Credentials(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
