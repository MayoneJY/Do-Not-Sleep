import Foundation
import AppKit
import Darwin

@MainActor
struct App {
    private let paths = AppPaths()

    func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            try runMenuBarApp()
            return
        }

        switch command {
        case "watch":
            try runWatch(arguments: Array(arguments.dropFirst()))
        case "hold":
            try runHold(arguments: Array(arguments.dropFirst()))
        case "done":
            try runDone(arguments: Array(arguments.dropFirst()))
        case "status":
            try runStatus()
        case "helper":
            try runHelper(arguments: Array(arguments.dropFirst()))
        case "help", "-h", "--help":
            printUsage()
        default:
            throw AppError(L10n.format(.unknownCommand, command))
        }
    }

    private func runWatch(arguments: [String]) throws {
        let options = try WatchOptions(arguments: arguments)
        let logger = try Logger(paths: paths, foreground: !options.background)
        let store = StateStore(paths: paths)
        let preferencesStore = PreferencesStore(paths: paths)

        try paths.prepareDirectory()
        let watchLock = try FileLock(path: paths.watchLockFile)
        guard watchLock.tryExclusiveLock() else {
            logger.log("이미 watcher가 실행 중입니다.")
            return
        }

        try store.update { state in
            state.watcherPID = Int32(getpid())
            state.updatedAt = Date().timeIntervalSince1970
        }

        let controller = PowerAssertionController(logger: logger)
        let lidClosedKeepAwakeController = LidClosedKeepAwakeController(logger: logger)
        let termination = TerminationController()
        let modeText = options.background ? "백그라운드 세션 모드" : "수동 감시 모드"
        logger.log("watcher를 시작했습니다. 모드: \(modeText), 감시 간격: \(options.interval)초")

        while !termination.isRequested {
            autoreleasepool {
                do {
                    let preferences = try preferencesStore.load()
                    let state = try store.load()
                    let hasSessions = !state.sessions.isEmpty
                    let shouldHold = hasSessions
                    let now = Date().timeIntervalSince1970
                    let shouldForceLidClosedKeepAwake = LidClosedKeepAwakePolicy.shouldEnable(
                        shouldHold: shouldHold,
                        preferences: preferences
                    )

                    if shouldHold {
                        try controller.ensureActive()
                    } else {
                        controller.releaseIfActive()
                    }

                    _ = try lidClosedKeepAwakeController.sync(
                        shouldEnable: shouldForceLidClosedKeepAwake,
                        stateStore: store,
                        attemptKey: LidClosedKeepAwakePolicy.attemptKey(
                            source: options.background ? "watch-background" : "watch-foreground",
                            shouldEnable: shouldForceLidClosedKeepAwake,
                            preferences: preferences,
                            state: state
                        )
                    )

                    try store.update { current in
                        current.watcherPID = Int32(getpid())
                        current.assertionActive = controller.isActive
                        if shouldHold && preferences.lidClosedKeepAwakeEnabled {
                            current.lidClosedKeepAwakeLastActiveAt = now
                        }
                        current.updatedAt = Date().timeIntervalSince1970
                    }

                    if shouldHold {
                        let sessionText = hasSessions ? "훅 등록 세션 \(state.sessions.count)개" : "훅 등록 세션 없음"
                        logger.log("잠자기 방지 유지 중: \(sessionText)")
                    }

                    if options.background && !hasSessions {
                        logger.log("훅 등록 세션이 없어 assertion과 덮개 닫힘 강제 방지를 즉시 해제하고 백그라운드 watcher를 종료합니다.")
                        termination.requestStop()
                    }
                } catch {
                    logger.log("watcher 반복 처리 실패: \(error.localizedDescription)")
                }
            }

            if !termination.isRequested {
                Thread.sleep(forTimeInterval: options.interval)
            }
        }

        controller.releaseIfActive()
        _ = try? lidClosedKeepAwakeController.sync(
            shouldEnable: false,
            stateStore: store,
            attemptKey: "source=watch-shutdown;target=false"
        )
        try store.update { current in
            if current.watcherPID == Int32(getpid()) {
                current.watcherPID = nil
            }
            current.assertionActive = false
            current.updatedAt = Date().timeIntervalSince1970
        }
        logger.log("watcher를 종료했습니다.")
    }

    private func runHold(arguments: [String]) throws {
        guard let sessionID = arguments.first, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError(L10n.text(.holdMissingSessionID))
        }

        try paths.prepareDirectory()
        let store = StateStore(paths: paths)
        try store.update { state in
            state.sessions[sessionID] = SessionRecord(
                id: sessionID,
                createdAt: state.sessions[sessionID]?.createdAt ?? Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970
            )
            state.updatedAt = Date().timeIntervalSince1970
        }

        print(L10n.format(.sessionRegistered, sessionID))

        if try isMenuBarAppRunning() {
            print(L10n.text(.menuAppWatchingState))
        } else {
            let watcherStarted = try ensureBackgroundWatcher()
            if watcherStarted {
                print(L10n.format(.backgroundWatcherStarted, paths.logFile.path))
            } else {
                print(L10n.text(.existingWatcherWatchingState))
            }
        }
    }

    private func runDone(arguments: [String]) throws {
        guard let sessionID = arguments.first, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError(L10n.text(.doneMissingSessionID))
        }

        let store = StateStore(paths: paths)
        var existed = false
        try store.update { state in
            existed = state.sessions.removeValue(forKey: sessionID) != nil
            state.updatedAt = Date().timeIntervalSince1970
        }

        if existed {
            print(L10n.format(.sessionDone, sessionID))
        } else {
            print(L10n.format(.sessionAlreadyDone, sessionID))
        }

        let state = try store.load()
        if state.sessions.isEmpty {
            if try isMenuBarAppRunning() {
                print(L10n.text(.noHookSessionsMenuApp))
            } else {
                print(L10n.text(.noHookSessionsBackgroundWatcher))
            }
        } else {
            print(L10n.format(.otherSessionsRemain, Self.formatSessionSummary(state.sessions)))
        }
    }

    private func runStatus() throws {
        let store = StateStore(paths: paths)
        var state = try store.load()
        var watcherPID = state.watcherPID
        var watcherAlive = watcherPID.map(ProcessDetector.isPIDRunning) ?? false
        var menuAppPID = state.menuAppPID
        var menuAppAlive = try isMenuBarAppRunning()

        if (!watcherAlive || !menuAppAlive) && (state.watcherPID != nil || state.menuAppPID != nil || state.assertionActive) {
            try store.update { current in
                if let pid = current.watcherPID, !ProcessDetector.isPIDRunning(pid) {
                    current.watcherPID = nil
                }
                if !menuAppAlive {
                    current.menuAppPID = nil
                }
                if !watcherAlive && !menuAppAlive {
                    current.assertionActive = false
                }
                current.updatedAt = Date().timeIntervalSince1970
            }
            state = try store.load()
            watcherPID = state.watcherPID
            watcherAlive = watcherPID.map(ProcessDetector.isPIDRunning) ?? false
            menuAppPID = state.menuAppPID
            menuAppAlive = try isMenuBarAppRunning()
        }

        print(L10n.text(.statusTitle))
        print("- \(L10n.text(.stateFile)): \(paths.stateFile.path)")
        print("- \(L10n.text(.preferencesFile)): \(paths.preferencesFile.path)")
        print("- \(L10n.text(.menuBarApp)): \(formatMenuAppStatus(isRunning: menuAppAlive, pid: menuAppPID))")
        print("- \(L10n.text(.watcher)): \(watcherAlive ? L10n.format(.runningWithPID, String(watcherPID!)) : L10n.text(.notRunning))")
        print("- \(L10n.text(.assertionRecord)): \(state.assertionActive ? L10n.text(.active) : L10n.text(.inactive))")
        let preferences = try PreferencesStore(paths: paths).load()
        print("- \(L10n.text(.currentSleepDisabled)): \(SystemSleepSettings.currentSleepDisabledText())")
        print("- \(L10n.text(.administratorPermission)): \(SystemSleepSettings.helperStatus().cliText)")
        print("- \(L10n.text(.lidClosedPolicy)): \(preferences.lidClosedKeepAwakeEnabled ? L10n.text(.enabledByDefault) : L10n.text(.disabled))")
        print("- \(L10n.text(.staleCleanupPolicy)): \(preferences.autoCleanupStaleSessionsEnabled ? L10n.text(.enabledByDefault) : L10n.text(.disabled)) (\(L10n.format(.staleCleanupInactiveSuffix, SessionAgeFormatter.duration(preferences.staleSessionTimeoutSeconds))))")
        print("- \(L10n.text(.lidClosedAppliedRecord)): \(state.lidClosedKeepAwakeApplied ? L10n.text(.applied) : L10n.text(.none))")
        let now = Date().timeIntervalSince1970
        print("- \(L10n.text(.hookSessions)): \(L10n.hookSessionCount(state.sessions.count))")
        for session in state.sessions.values.sorted(by: { $0.id < $1.id }) {
            let transcriptText = TranscriptActivityFormatter.cliText(for: session, now: now)
            print("  - \(session.id) (\(L10n.text(.lastHook)): \(SessionAgeFormatter.relativeAge(since: session.updatedAt, now: now)); \(transcriptText))")
        }
    }

    private func runHelper(arguments: [String]) throws {
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            printHelperUsage()
            return
        }

        let options = try HelperOptions(arguments: arguments)
        try PrivilegedSleepHelperServer(configPath: options.configPath).serve()
    }

    private func runMenuBarApp() throws {
        try paths.prepareDirectory()
        let menuLock = try FileLock(path: paths.menuLockFile)
        guard menuLock.tryExclusiveLock() else {
            print(L10n.text(.menuAppAlreadyRunning))
            return
        }

        let controller = try MenuBarAppController(paths: paths, menuLock: menuLock)
        DoNotSleepCLI.menuBarController = controller
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.delegate = controller
        controller.start()
        print(L10n.text(.menuAppStarted))
        NSApplication.shared.run()
    }

    private func isMenuBarAppRunning() throws -> Bool {
        try paths.prepareDirectory()
        let state = try StateStore(paths: paths).load()
        if let menuAppPID = state.menuAppPID, ProcessDetector.isPIDRunning(menuAppPID) {
            return true
        }

        let lock = try FileLock(path: paths.menuLockFile)
        if lock.tryExclusiveLock() {
            lock.unlock()
            try clearStaleMenuAppState()
            return false
        }
        return true
    }

    private func clearStaleMenuAppState() throws {
        let store = StateStore(paths: paths)
        try store.update { state in
            guard state.menuAppPID != nil || (state.assertionActive && state.watcherPID == nil) else {
                return
            }

            state.menuAppPID = nil
            if state.watcherPID == nil {
                state.assertionActive = false
            }
            state.updatedAt = Date().timeIntervalSince1970
        }
    }

    private func formatMenuAppStatus(isRunning: Bool, pid: Int32?) -> String {
        guard isRunning else {
            return L10n.text(.notRunning)
        }

        if let pid {
            return L10n.format(.runningWithPID, String(pid))
        }
        return L10n.text(.runningWithoutPID)
    }

    private static func formatSessionSummary(_ sessions: [String: SessionRecord]) -> String {
        let visible = sessions.keys.sorted().prefix(5).joined(separator: ", ")
        let hiddenCount = sessions.count - 5
        if hiddenCount > 0 {
            return L10n.format(
                .sessionSummaryWithHidden,
                L10n.hookSessionCount(sessions.count),
                visible,
                L10n.hookSessionCount(hiddenCount)
            )
        }
        return "\(L10n.hookSessionCount(sessions.count)) (\(visible))"
    }

    private func ensureBackgroundWatcher() throws -> Bool {
        let state = try StateStore(paths: paths).load()
        if let pid = state.watcherPID, ProcessDetector.isPIDRunning(pid) {
            return false
        }

        let executablePath = try currentExecutablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["watch", "--background"]
        let logHandle = FileHandle(forWritingAtPath: paths.logFile.path)
            ?? FileHandle(forWritingAtPath: "/dev/null")
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return true
    }

    private func currentExecutablePath() throws -> String {
        let candidate = CommandLine.arguments[0]
        if candidate.hasPrefix("/") {
            return candidate
        }

        let cwd = FileManager.default.currentDirectoryPath
        let resolved = URL(fileURLWithPath: cwd).appendingPathComponent(candidate).standardized.path
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw AppError(L10n.format(.executablePathUnavailable, candidate))
        }
        return resolved
    }

    private func printUsage() {
        print(L10n.text(.mainUsage))
    }

    private func printHelperUsage() {
        print(L10n.text(.helperUsage))
    }
}


struct HelperOptions {
    let configPath: String

    init(arguments: [String]) throws {
        var configPath: String?
        var index = 0

        while index < arguments.count {
            let value = arguments[index]
            switch value {
            case "--config":
                guard index + 1 < arguments.count else {
                    throw AppError(L10n.text(.helperMissingConfigValue))
                }
                configPath = arguments[index + 1]
                index += 2
            default:
                throw AppError(L10n.format(.helperUnknownArgument, value))
            }
        }

        guard let configPath, !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError(L10n.text(.helperMissingConfig))
        }

        self.configPath = configPath
    }
}


struct WatchOptions {
    let interval: TimeInterval
    let background: Bool

    init(arguments: [String]) throws {
        var interval: TimeInterval = 5
        var background = false
        var index = 0

        while index < arguments.count {
            let value = arguments[index]
            switch value {
            case "--background":
                background = true
                index += 1
            case "--interval":
                guard index + 1 < arguments.count, let parsed = TimeInterval(arguments[index + 1]), parsed > 0 else {
                    throw AppError(L10n.text(.watchInvalidInterval))
                }
                interval = parsed
                index += 2
            default:
                throw AppError(L10n.format(.watchUnknownOption, value))
            }
        }

        self.interval = interval
        self.background = background
    }
}
