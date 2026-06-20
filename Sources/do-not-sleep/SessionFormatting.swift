import Foundation

enum SessionAgeFormatter {
    static func relativeAge(since timestamp: TimeInterval, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        L10n.relativeAge(since: timestamp, now: now)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        L10n.duration(seconds)
    }
}


enum TranscriptActivityFormatter {
    static func compactText(for session: SessionRecord, now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        guard let path = usableTranscriptPath(for: session) else {
            return nil
        }

        guard let modifiedAt = modificationTime(atPath: path) else {
            return L10n.text(.transcriptUnavailableCompact)
        }

        return "transcript: \(SessionAgeFormatter.relativeAge(since: modifiedAt, now: now))"
    }

    static func cliText(for session: SessionRecord, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        guard let path = usableTranscriptPath(for: session) else {
            return L10n.text(.transcriptMissing)
        }

        guard let modifiedAt = modificationTime(atPath: path) else {
            return L10n.format(.transcriptUnavailableWithPath, path)
        }

        return L10n.format(.transcriptAgeWithPath, SessionAgeFormatter.relativeAge(since: modifiedAt, now: now), path)
    }

    static func isStale(_ session: SessionRecord, now: TimeInterval, timeout: TimeInterval) -> Bool {
        guard timeout > 0,
              let path = usableTranscriptPath(for: session),
              let modifiedAt = modificationTime(atPath: path) else {
            return false
        }

        return now - modifiedAt >= timeout
    }

    private static func usableTranscriptPath(for session: SessionRecord) -> String? {
        guard let path = session.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }

    private static func modificationTime(atPath path: String) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return modifiedAt.timeIntervalSince1970
    }
}


enum StaleSessionCleaner {
    static func prune(store: StateStore, preferences: AppPreferences, now: TimeInterval = Date().timeIntervalSince1970) throws -> [String] {
        guard preferences.autoCleanupStaleSessionsEnabled else {
            return []
        }

        var removedSessionIDs: [String] = []
        try store.update { state in
            let staleSessionIDs = state.sessions.values
                .filter { TranscriptActivityFormatter.isStale($0, now: now, timeout: preferences.staleSessionTimeoutSeconds) }
                .map(\.id)

            for sessionID in staleSessionIDs {
                if state.sessions.removeValue(forKey: sessionID) != nil {
                    removedSessionIDs.append(sessionID)
                }
            }

            if !removedSessionIDs.isEmpty {
                state.updatedAt = now
            }
        }
        return removedSessionIDs
    }
}
