import Foundation
import Security

/// Reads Claude Code's OAuth credentials out of the login Keychain.
///
/// Strictly read-only: this app never writes, refreshes or deletes a
/// credential. If a token has expired, we say so and fall back to the
/// cached numbers rather than touching the CLI's auth state.
///
/// It also never puts a Keychain dialog on screen by itself. Claude Code
/// creates each item with `/usr/bin/security`, which stamps it with an
/// `apple-tool:` partition: any non-Apple app reading it gets "enter the
/// login keychain password", and "Allow" covers one read. A poller that reads
/// five items every two minutes turns that into a dialog every two minutes —
/// on 2026-09-05 it did, for account D, again and again. So the native read
/// runs with keychain interaction switched off, and when the keychain would
/// have asked, the item is read through `security` itself, which sits inside
/// the partition and is answered silently. The one dialog left is the one the
/// operator asks for with "Grant access", where "Always Allow" puts this app
/// on the item for good.
enum KeychainCredentials {
    struct Credentials: Sendable {
        let accessToken: String
        let expiresAt: Date
        let subscriptionType: String?
        var isExpired: Bool { Date() >= expiresAt }
    }

    enum Failure: Error, Equatable {
        case notFound
        case unreadable(OSStatus)
        case malformed
        /// The keychain wants the operator's say-so before this app may read
        /// the item, and the silent paths could not get around asking.
        case needsGrant
    }

    /// Longest we wait for `security` before treating the read as blocked on
    /// a dialog of its own (which happens only if the item was not created
    /// by `security` — some future Claude Code writing the keychain natively).
    static let toolTimeout: TimeInterval = 8

    /// Stops the legacy keychain from raising its dialog for this process.
    /// Called once at start-up; `grant(for:)` lifts it for exactly one read.
    static func silenceDialogs() {
        setDialogsAllowed(false)
    }

    /// `SecKeychainSetUserInteractionAllowed` is deprecated with the rest of
    /// SecKeychain, but it is still the only switch that works here:
    /// `kSecUseAuthenticationUIFail` on the query is deprecated too and,
    /// measured against a real item on macOS 26, does NOT suppress the ACL
    /// prompt — the query blocks on the dialog regardless — while this call
    /// makes the same query return `errSecInteractionNotAllowed` at once.
    /// One deprecation warning, here, on purpose.
    private static func setDialogsAllowed(_ allowed: Bool) {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    static func load(for account: Account) async throws -> Credentials {
        switch nativeRead(service: account.keychainService) {
        case .success(let data):
            return try parse(data)
        case .failure(.needsGrant):
            return try parse(await toolRead(service: account.keychainService))
        case .failure(let failure):
            throw failure
        }
    }

    /// The interactive read. Raises the Keychain dialog exactly once so the
    /// operator can enter the login password and choose "Always Allow".
    static func grant(for account: Account) throws -> Credentials {
        setDialogsAllowed(true)
        defer { setDialogsAllowed(false) }
        return try parse(nativeRead(service: account.keychainService).get())
    }

    // MARK: - Native

    private static func nativeRead(service: String) -> Result<Data, Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failure(.unreadable(status)) }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.notFound)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .failure(.needsGrant)
        default:
            return .failure(.unreadable(status))
        }
    }

    // MARK: - /usr/bin/security

    /// `security find-generic-password -s <service> -w`: the same tool that
    /// wrote the item, so the partition check passes without a dialog.
    private static func toolRead(service: String) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let outcome: (status: Int32, out: Data, err: Data) = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, out, err))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure.needsGrant)
                return
            }
            // If `security` itself is blocked on a dialog, do not leave the
            // refresh hanging on it: kill it and report that a grant is needed.
            let pid = process.processIdentifier
            Task {
                try? await Task.sleep(for: .seconds(toolTimeout))
                kill(pid, SIGTERM)
            }
        }

        // `security` exits 44 for "could not be found"; the message is on stderr.
        if outcome.status == 44 || String(decoding: outcome.err, as: UTF8.self).contains("could not be found") {
            throw Failure.notFound
        }
        guard outcome.status == 0 else { throw Failure.needsGrant }
        return Self.toolOutput(outcome.out)
    }

    /// `-w` prints the secret followed by a newline. A blob that is not
    /// printable text comes out hex-encoded instead; decode that too.
    static func toolOutput(_ raw: Data) -> Data {
        var text = String(decoding: raw, as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        let isHex = !text.isEmpty && text.count.isMultiple(of: 2)
            && text.allSatisfy { $0.isHexDigit }
        if isHex, !text.hasPrefix("{") {
            var bytes = [UInt8]()
            bytes.reserveCapacity(text.count / 2)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                if let byte = UInt8(text[index..<next], radix: 16) { bytes.append(byte) }
                index = next
            }
            return Data(bytes)
        }
        return Data(text.utf8)
    }

    // MARK: - Shared

    static func parse(_ data: Data) throws -> Credentials {
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
