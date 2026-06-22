import Foundation

enum L10n {
    enum Key: String {
        case active
        case inactive
        case attentionRequired
        case errorPrefix
        case unknownCommand
        case holdMissingSessionID
        case doneMissingSessionID
        case helperMissingConfigValue
        case helperUnknownArgument
        case helperMissingConfig
        case watchInvalidInterval
        case watchUnknownOption
        case executablePathUnavailable
        case mainUsage
        case helperUsage
        case statusTitle
        case stateFile
        case preferencesFile
        case menuBarApp
        case watcher
        case assertionRecord
        case currentSleepDisabled
        case administratorPermission
        case lidClosedPolicy
        case staleCleanupPolicy
        case lidClosedAppliedRecord
        case hookSessions
        case lastHook
        case transcriptUnavailableCompact
        case transcriptMissing
        case transcriptUnavailableWithPath
        case transcriptAgeWithPath
        case runningWithPID
        case runningWithoutPID
        case notRunning
        case enabledByDefault
        case disabled
        case applied
        case none
        case statusLabel
        case manualHold
        case launchAtLogin
        case launchAtLoginSaveFailed
        case launchAtLoginRequiresAppBundle
        case checkForUpdates
        case updateAlreadyRunningTitle
        case updateAlreadyRunningMessage
        case updateRequiresAppBundle
        case updateAvailableTitle
        case updateAvailableMessage
        case updateNotAvailableTitle
        case updateNotAvailableMessage
        case updateNoInstallableAsset
        case downloadAndInstallUpdate
        case openReleasesPage
        case updateFailedTitle
        case updateNetworkFailed
        case cancel
        case ok
        case installHelper
        case uninstallHelper
        case refreshStatus
        case quit
        case hookReceiverStopped
        case hookReceiverListening
        case hookReceiverFailed
        case helperApplied
        case helperNotApplied
        case helperMenuApplied
        case helperMenuRequired
        case helperRequiredMessage
        case invalidHelperCommand
        case helperSocketCreateFailed
        case helperSocketPathTooLong
        case helperConnectionFailed
        case helperSendFailed
        case helperReceiveFailed
        case helperEmptyResponse
        case helperSleepNowResponseUnknown
        case sleepNowRequested
        case sleepNowSkippedLidOpen
        case sleepNowSkippedUnknown
        case sleepDisabledMissing
        case sleepDisabledFailed
        case lidClosedSleepRequestFailed
        case lidClosedEnableAction
        case lidClosedDisableAction
        case lidClosedSyncFailed
        case staleCleanupInactiveSuffix
        case menuAppAlreadyRunning
        case menuAppStarted
        case manualHoldSaveFailed
        case hookSessionRemoveMissingID
        case hookSessionRemoveFailed
        case clearHookSessionsFailed
        case installHelperSuccess
        case installHooksSuccess
        case installHooksFailed
        case uninstallHelperSuccess
        case refreshFailed
        case appleScriptCreateFailed
        case helperTaskFailed
        case helperScriptMissing
        case appleScriptError
        case activeCondition
        case recentError
        case noActiveCondition
        case manualHoldCondition
        case unknown
        case removeSession
        case clearAllHookSessions
        case hookSessionCleanup
        case sessionRegistered
        case menuAppWatchingState
        case backgroundWatcherStarted
        case existingWatcherWatchingState
        case sessionDone
        case sessionAlreadyDone
        case noHookSessionsMenuApp
        case noHookSessionsBackgroundWatcher
        case otherSessionsRemain
        case hookSessionsCountFormat
        case relativeAgeJustNow
        case relativeAgeMinutes
        case relativeAgeHours
        case relativeAgeDays
        case durationSeconds
        case durationMinutes
        case durationHours
        case durationDays
        case sessionSummaryWithHidden
    }

    static var locale: Locale {
        if let languageOverride {
            return Locale(identifier: languageOverride.replacingOccurrences(of: "-", with: "_"))
        }
        return Locale.autoupdatingCurrent
    }

    private static var languageOverride: String? {
        let environment = ProcessInfo.processInfo.environment["DO_NOT_SLEEP_LANG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return environment?.isEmpty == false ? environment : nil
    }

    private static var resourceBundle: Bundle {
        if let languageOverride {
            for sourceBundle in localizationSourceBundles {
                for candidate in lprojCandidates(for: languageOverride) {
                    if let bundle = localizedBundle(in: sourceBundle, named: candidate) {
                        return bundle
                    }
                }
            }
        }

        return defaultResourceBundle
    }

    private static var localizationSourceBundles: [Bundle] {
        if containsLocalizationResources(Bundle.main) {
            return [Bundle.main, Bundle.module]
        }
        return [Bundle.module]
    }

    private static var defaultResourceBundle: Bundle {
        containsLocalizationResources(Bundle.main) ? Bundle.main : Bundle.module
    }

    private static func localizedBundle(in sourceBundle: Bundle, named lprojName: String) -> Bundle? {
        guard let path = sourceBundle.path(forResource: lprojName, ofType: "lproj"),
              containsLocalizableStrings(at: path) else {
            return nil
        }
        return Bundle(path: path)
    }

    private static func containsLocalizationResources(_ bundle: Bundle) -> Bool {
        guard let resourcePath = bundle.resourcePath,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) else {
            return false
        }

        return contents.contains { item in
            item.hasSuffix(".lproj")
                && containsLocalizableStrings(at: (resourcePath as NSString).appendingPathComponent(item))
        }
    }

    private static func containsLocalizableStrings(at lprojPath: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: (lprojPath as NSString).appendingPathComponent("Localizable.strings"))
            || fileManager.fileExists(atPath: (lprojPath as NSString).appendingPathComponent("Localizable.stringsdict"))
    }

    private static func lprojCandidates(for languageTag: String) -> [String] {
        let normalized = languageTag.replacingOccurrences(of: "_", with: "-")
        let languagePart = normalized.split(separator: "-", maxSplits: 1).first.map(String.init)
        let candidates = [normalized, normalized.lowercased(), languagePart?.lowercased()].compactMap { $0 }
        return candidates.reduce(into: []) { uniqueCandidates, candidate in
            if !uniqueCandidates.contains(candidate) {
                uniqueCandidates.append(candidate)
            }
        }
    }

    private static func pluralFormat(_ key: Key, _ value: Int) -> String {
        let categorizedKey = "\(key.rawValue)\(value == 1 ? "One" : "Other")"
        let categorizedFormat = resourceBundle.localizedString(forKey: categorizedKey, value: nil, table: "Localizable")
        if categorizedFormat != categorizedKey {
            return String(format: categorizedFormat, locale: locale, value)
        }

        return NSString.localizedStringWithFormat(text(key) as NSString, value) as String
    }

    static func text(_ key: Key) -> String {
        resourceBundle.localizedString(forKey: key.rawValue, value: key.rawValue, table: "Localizable")
    }

    static func format(_ key: Key, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    static func hookSessionCount(_ count: Int) -> String {
        pluralFormat(.hookSessionsCountFormat, count)
    }

    static func relativeAge(since timestamp: TimeInterval, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        let elapsed = max(0, Int(now - timestamp))
        if elapsed < 60 {
            return text(.relativeAgeJustNow)
        }

        let minutes = elapsed / 60
        if minutes < 60 {
            return pluralFormat(.relativeAgeMinutes, minutes)
        }

        let hours = minutes / 60
        if hours < 24 {
            return pluralFormat(.relativeAgeHours, hours)
        }

        let days = hours / 24
        return pluralFormat(.relativeAgeDays, days)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(1, Int(seconds))
        if totalSeconds < 60 {
            return pluralFormat(.durationSeconds, totalSeconds)
        }

        let minutes = totalSeconds / 60
        if minutes < 60 {
            return pluralFormat(.durationMinutes, minutes)
        }

        let hours = minutes / 60
        if hours < 24 {
            return pluralFormat(.durationHours, hours)
        }

        let days = hours / 24
        return pluralFormat(.durationDays, days)
    }
}
