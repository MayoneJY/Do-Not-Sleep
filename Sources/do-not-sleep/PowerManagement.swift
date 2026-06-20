import Foundation
import IOKit.pwr_mgt
import Darwin


enum LidClosedKeepAwakePolicy {
    static func attemptKey(
        source: String,
        shouldEnable: Bool,
        preferences: AppPreferences,
        state: AppState
    ) -> String {
        let sessionKey = state.sessions.keys.sorted().joined(separator: ",")
        return [
            "source=\(source)",
            "target=\(shouldEnable)",
            "manual=\(preferences.manualHoldEnabled)",
            "lid=\(preferences.lidClosedKeepAwakeEnabled)",
            "sessions=\(sessionKey)",
        ].joined(separator: ";")
    }

    static func shouldEnable(
        shouldHold: Bool,
        preferences: AppPreferences
    ) -> Bool {
        guard preferences.lidClosedKeepAwakeEnabled else {
            return false
        }

        if shouldHold {
            return true
        }

        return false
    }
}

final class PowerAssertionController {
    private let logger: Logger
    private var noIdleSleepAssertion = IOPMAssertionID(0)
    private var noDisplaySleepAssertion = IOPMAssertionID(0)

    var isActive: Bool {
        noIdleSleepAssertion != 0 || noDisplaySleepAssertion != 0
    }

    init(logger: Logger) {
        self.logger = logger
    }

    deinit {
        releaseIfActive()
    }

    func ensureActive() throws {
        if noIdleSleepAssertion == 0 {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Do Not Sleep: AI 에이전트 실행 중이라 유휴 시스템 잠자기를 방지합니다." as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                throw AppError("유휴 시스템 잠자기 방지 assertion 생성에 실패했습니다. IOReturn=\(result)")
            }
            noIdleSleepAssertion = assertionID
            logger.log("유휴 시스템 잠자기 방지 assertion을 생성했습니다.")
        }

        if noDisplaySleepAssertion == 0 {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Do Not Sleep: AI 에이전트 실행 중이라 디스플레이 잠자기를 방지합니다." as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                if assertionID != 0 {
                    IOPMAssertionRelease(assertionID)
                }
                releaseIfActive()
                throw AppError("디스플레이 잠자기 방지 assertion 생성에 실패했습니다. IOReturn=\(result)")
            }
            noDisplaySleepAssertion = assertionID
            logger.log("디스플레이 잠자기 방지 assertion을 생성했습니다.")
        }
    }

    func releaseIfActive() {
        if noIdleSleepAssertion != 0 {
            IOPMAssertionRelease(noIdleSleepAssertion)
            noIdleSleepAssertion = 0
            logger.log("유휴 시스템 잠자기 방지 assertion을 해제했습니다.")
        }

        if noDisplaySleepAssertion != 0 {
            IOPMAssertionRelease(noDisplaySleepAssertion)
            noDisplaySleepAssertion = 0
            logger.log("디스플레이 잠자기 방지 assertion을 해제했습니다.")
        }
    }
}


struct LidClosedKeepAwakeSyncOutcome {
    let recentError: String?
}


final class LidClosedKeepAwakeController {
    private static let verificationGraceSeconds: TimeInterval = 30

    private let logger: Logger
    private var failedAttemptKey: String?
    private var failedErrorMessage: String?

    init(logger: Logger) {
        self.logger = logger
    }

    func resetFailureSuppression() {
        failedAttemptKey = nil
        failedErrorMessage = nil
    }

    func sync(shouldEnable: Bool, stateStore: StateStore, attemptKey: String) throws -> LidClosedKeepAwakeSyncOutcome {
        let state = try stateStore.load()
        let now = Date().timeIntervalSince1970
        let currentSleepDisabled = SystemSleepSettings.currentSleepDisabledValue()
        let recentlySucceededForSameTarget = state.lidClosedKeepAwakeLastSyncTarget == shouldEnable
            && state.lidClosedKeepAwakeLastSyncAt.map { now - $0 < Self.verificationGraceSeconds } == true

        if !shouldEnable && state.lidClosedKeepAwakeApplied && currentSleepDisabled == false {
            try stateStore.update { current in
                current.lidClosedKeepAwakeApplied = false
                current.lidClosedKeepAwakeLastSyncTarget = false
                current.lidClosedKeepAwakeLastSyncAt = now
                current.updatedAt = now
            }
            resetFailureSuppression()
            logger.log("덮개 닫힘 강제 방지 실제 값이 이미 꺼져 있어 상태 기록만 정리했습니다.")
            return LidClosedKeepAwakeSyncOutcome(recentError: nil)
        }

        let needsChange: Bool
        if shouldEnable {
            if state.lidClosedKeepAwakeApplied && currentSleepDisabled == false && recentlySucceededForSameTarget {
                needsChange = false
            } else {
                needsChange = !state.lidClosedKeepAwakeApplied || currentSleepDisabled == false
            }
        } else {
            needsChange = state.lidClosedKeepAwakeApplied
        }

        guard needsChange else {
            resetFailureSuppression()
            return LidClosedKeepAwakeSyncOutcome(recentError: nil)
        }

        if failedAttemptKey == attemptKey && !SystemSleepSettings.helperStatus().isAvailable {
            return LidClosedKeepAwakeSyncOutcome(recentError: failedErrorMessage)
        }

        do {
            try SystemSleepSettings.setDisableSleep(shouldEnable)
            try stateStore.update { current in
                current.lidClosedKeepAwakeApplied = shouldEnable
                current.lidClosedKeepAwakeLastSyncTarget = shouldEnable
                current.lidClosedKeepAwakeLastSyncAt = now
                current.updatedAt = now
            }
            resetFailureSuppression()
            if shouldEnable {
                logger.log("덮개 닫힘 강제 방지를 적용했습니다: pmset -a disablesleep 1")
            } else {
                logger.log("덮개 닫힘 강제 방지를 해제했습니다: pmset -a disablesleep 0")
                do {
                    let sleepNowOutcome = try PrivilegedSleepHelper.sleepNowIfLidClosed()
                    logger.log(sleepNowOutcome.logMessage)
                } catch {
                    let message = L10n.format(.lidClosedSleepRequestFailed, error.localizedDescription)
                    logger.log(message)
                    return LidClosedKeepAwakeSyncOutcome(recentError: message)
                }
            }
            return LidClosedKeepAwakeSyncOutcome(recentError: nil)
        } catch {
            let action = shouldEnable ? L10n.text(.lidClosedEnableAction) : L10n.text(.lidClosedDisableAction)
            let message = L10n.format(.lidClosedSyncFailed, action, error.localizedDescription)
            failedAttemptKey = attemptKey
            failedErrorMessage = message
            logger.log(message)
            return LidClosedKeepAwakeSyncOutcome(recentError: message)
        }
    }
}


enum SystemSleepSettings {
    static func helperStatus() -> SleepHelperStatus {
        PrivilegedSleepHelper.status()
    }

    static func currentSleepDisabledText() -> String {
        do {
            let output = try runProcess(executablePath: "/usr/bin/pmset", arguments: ["-g"])
            if let value = sleepDisabledValue(from: output) {
                return value ? "1" : "0"
            }
            if let line = sleepDisabledLine(from: output) {
                return line
            }
            return L10n.text(.sleepDisabledMissing)
        } catch {
            return L10n.format(.sleepDisabledFailed, error.localizedDescription)
        }
    }

    static func currentSleepDisabledValue() -> Bool? {
        do {
            let output = try runProcess(executablePath: "/usr/bin/pmset", arguments: ["-g"])
            return sleepDisabledValue(from: output)
        } catch {
            return nil
        }
    }

    static func setDisableSleep(_ enabled: Bool) throws {
        try PrivilegedSleepHelper.setDisableSleep(enabled)
    }

    private static func sleepDisabledValue(from output: String) -> Bool? {
        guard let line = sleepDisabledLine(from: output) else {
            return nil
        }

        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else {
            return nil
        }
        switch parts[1] {
        case "0":
            return false
        case "1":
            return true
        default:
            return nil
        }
    }

    private static func sleepDisabledLine(from output: String) -> String? {
        output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("SleepDisabled") }
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = [output, errorOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if message.isEmpty {
                throw AppError("\(executablePath) 종료 코드 \(process.terminationStatus)")
            }
            throw AppError(message)
        }

        return output
    }

}
