import Foundation

/// Edits the durable exclusion file, the one part of the shared policy this
/// app may change. Excluding or activating an account becomes a click on the
/// board instead of a hand edit of `~/.config/claude-fleet/exclude-accounts`,
/// which had been made some thirty times in seven weeks, each with a `.bak`.
///
/// claude-fleet reads this file on every dispatch and fails closed on anything
/// it cannot read, so every edit is checked before it lands:
/// - Only that one account's entry changes. Other entries, comments, spacing
///   and line breaks keep their exact bytes.
/// - The edited text is parsed back with the policy's own parser, and is
///   written only if it holds exactly the intended set.
/// - The write is atomic (a temp file, then a rename), so a dispatch reading
///   mid-edit sees the old policy or the new one, never a torn or empty file.
/// - The previous contents are copied to `exclude-accounts.bak-fleetbar` first.
enum ExclusionEditor {
    enum Change: Sendable, Equatable {
        case exclude, activate

        var reversed: Change { self == .exclude ? .activate : .exclude }
    }

    enum Failure: Error, Equatable, Sendable {
        /// The policy is missing, empty or malformed. A fresh file written
        /// over one the fleet cannot read would replace a policy nobody saw.
        case policyUnreadable
        /// The policy names accounts by one letter, and this one has none.
        case notAnAccountLetter
        /// Excluded by something the board must not change.
        case locked(AccountExclusions.Lock)
        /// Someone made the file read-only, and that is respected.
        case readOnly
        case writeFailed(String)

        var explanation: String {
            switch self {
            case .policyUnreadable:
                "The exclusion policy can't be read, so the board won't edit it. Check ~/.config/claude-fleet/exclude-accounts."
            case .notAnAccountLetter:
                "The fleet policy names accounts by a single letter, and this account has none."
            case .locked(let lock):
                lock.explanation
            case .readOnly:
                "The policy file is read-only, so the board left it alone."
            case .writeFailed(let detail):
                "Writing the policy file failed: \(detail)"
            }
        }
    }

    static let backupSuffix = ".bak-fleetbar"

    /// Applies `change` to `label` in the durable file, and returns whether
    /// the file changed. Excluding an account that is already excluded, or
    /// activating one that is already active, leaves it alone.
    @discardableResult
    static func apply(
        _ change: Change,
        to label: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) throws(Failure) -> Bool {
        guard AccountExclusions.isToken(label) else { throw .notAnAccountLetter }
        guard let sources = AccountExclusions.breakdown(environment: environment, fileURL: fileURL) else {
            throw .policyUnreadable
        }
        let policyURL = fileURL ?? AccountExclusions.defaultFile(environment: environment)
        // Edit the file a symlink points at, not the link: an atomic rename
        // onto the link's own path would replace it with a plain file. The
        // backup stays beside the policy's usual path, with the operator's own
        // backups, and out of whatever repo the link points into.
        let url = policyURL.resolvingSymlinksInPath()
        let backup = policyURL.deletingLastPathComponent()
            .appendingPathComponent(policyURL.lastPathComponent + backupSuffix)
        guard let original = try? Data(contentsOf: url),
              let raw = String(data: original, encoding: .utf8),
              let durable = AccountExclusions.parse(raw, comments: true), !durable.isEmpty
        else { throw .policyUnreadable }

        // Decide from the bytes about to be edited, not from the earlier read.
        let policy = AccountExclusions.Breakdown(
            environment: sources.environment, durable: durable, override: sources.override
        )
        switch (change, policy.toggle(for: label)) {
        case (.exclude, .exclude), (.activate, .activate):
            break
        case (.exclude, _), (.activate, .exclude):
            return false
        case (.activate, .locked(let lock)):
            throw .locked(lock)
        case (.activate, .unavailable):
            throw .notAnAccountLetter
        }

        let expected = change == .exclude ? durable.union([label]) : durable.subtracting([label])
        let edited = change == .exclude ? adding(label, to: raw) : removing(label, from: raw)
        guard !expected.isEmpty, AccountExclusions.parse(edited, comments: true) == expected else {
            throw .writeFailed("the edit did not read back as intended, so nothing was written.")
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { throw .readOnly }

        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            try original.write(to: backup, options: .atomic)
            try Data(edited.utf8).write(to: url, options: .atomic)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        // An atomic write makes a new file, with the default mode.
        if let permissions {
            for path in [url.path, backup.path] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            }
        }
        guard AccountExclusions.loadFile(url) == expected else {
            throw .writeFailed("it read back differently. The previous policy is in \(backup.lastPathComponent).")
        }
        return true
    }

    /// One entry in the policy text, and the code around it on its line.
    struct Entry {
        let range: Range<String.Index>
        /// Where the previous entry on the same line ends, if there is one.
        let previousEnd: String.Index?
        /// Where the next entry on the same line starts, or else where the
        /// line's code ends: at its `#` comment, its line break, or the end.
        var followingStart: String.Index
    }

    /// Every entry with its position: each run of characters that are
    /// neither a comma nor whitespace, outside `#` comments. That is the
    /// split the policy's parser makes, so the two agree on what an entry is.
    static func entries(in raw: String) -> [Entry] {
        var found: [Entry] = []
        var start: String.Index?
        var lastOnLine: Int?
        var inComment = false

        func closeEntry(at end: String.Index) {
            guard let begin = start else { return }
            let previousEnd = lastOnLine.map { found[$0].range.upperBound }
            found.append(Entry(range: begin..<end, previousEnd: previousEnd, followingStart: end))
            lastOnLine = found.count - 1
            start = nil
        }
        func closeCode(at end: String.Index) {
            closeEntry(at: end)
            if let last = lastOnLine { found[last].followingStart = end }
        }

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character.isNewline {
                if !inComment { closeCode(at: index) }
                inComment = false
                lastOnLine = nil
            } else if inComment {
                // The rest of the line is a comment.
            } else if character == "#" {
                closeCode(at: index)
                inComment = true
            } else if character == "," || character.isWhitespace {
                closeEntry(at: index)
            } else if start == nil {
                if let last = lastOnLine { found[last].followingStart = index }
                start = index
            }
            index = raw.index(after: index)
        }
        if !inComment { closeCode(at: raw.endIndex) }
        return found
    }

    /// `raw` without any `label` entry. Each removal takes one adjoining
    /// separator run with it: the one before the entry when its line has an
    /// earlier entry, otherwise the one after. So "p,i,r" loses "i" as ",i",
    /// and "x # note" loses "x" as "x ".
    static func removing(_ label: String, from raw: String) -> String {
        var text = raw
        while let entry = entries(in: text).last(where: { text[$0.range] == label }) {
            let cut = entry.previousEnd.map { $0..<entry.range.upperBound }
                ?? entry.range.lowerBound..<entry.followingStart
            text.removeSubrange(cut)
        }
        return text
    }

    /// `raw` with `label` added after its last entry. The separator copies
    /// the one between that entry and the entry before it on the same line,
    /// so "o, f" gains ", x" and "p,i,r" gains ",x". It is "," when there is
    /// no earlier entry on that line.
    static func adding(_ label: String, to raw: String) -> String {
        guard let last = entries(in: raw).last else {
            let lineBreak = raw.isEmpty || raw.last?.isNewline == true ? "" : "\n"
            return raw + lineBreak + label + "\n"
        }
        let separator = last.previousEnd.map { String(raw[$0..<last.range.lowerBound]) } ?? ","
        var text = raw
        text.insert(contentsOf: separator + label, at: last.range.upperBound)
        return text
    }
}
