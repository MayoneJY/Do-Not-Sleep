import Foundation
import AppKit
import Darwin

@MainActor
final class MenuBarAppController: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let paths: AppPaths
    private let menuLock: FileLock
    private let store: StateStore
    private let preferencesStore: PreferencesStore
    private let logger: Logger
    private let assertionController: PowerAssertionController
    private let lidClosedKeepAwakeController: LidClosedKeepAwakeController
    private let updateChecker = UpdateChecker()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var hookServer: HookHTTPServer?
    private var timer: Timer?
    private var lastState = AppState()
    private var lastPreferences = AppPreferences()
    private var lastHookReceiverStatus = HookReceiverStatus.stopped
    private var lastErrorMessage: String?
    private var statusGlyphImage: NSImage?
    private var statusDotView: MenuBarStatusDotView?
    private var setupStatusMessage: String?

    private enum SetupWorkflowResult: Sendable {
        case success(helperOutput: String, hookMessages: [String])
        case failure(message: String)
    }

    private enum MenuBarStatusDot {
        case active
        case inactive
        case error

        var color: NSColor {
            switch self {
            case .active:
                return NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.27, alpha: 1)
            case .inactive:
                return NSColor(calibratedRed: 0.88, green: 0.71, blue: 0.16, alpha: 1)
            case .error:
                return NSColor(calibratedRed: 0.90, green: 0.20, blue: 0.16, alpha: 1)
            }
        }

        var accessibilityDescription: String {
            switch self {
            case .active:
                return L10n.text(.active)
            case .inactive:
                return L10n.text(.inactive)
            case .error:
                return L10n.text(.attentionRequired)
            }
        }
    }

    init(paths: AppPaths, menuLock: FileLock) throws {
        self.paths = paths
        self.menuLock = menuLock
        store = StateStore(paths: paths)
        preferencesStore = PreferencesStore(paths: paths)
        logger = try Logger(paths: paths, foreground: false)
        assertionController = PowerAssertionController(logger: logger)
        lidClosedKeepAwakeController = LidClosedKeepAwakeController(logger: logger)
        super.init()
    }

    func start() {
        logger.log("메뉴 막대 앱을 시작했습니다.")
        hookServer = HookHTTPServer(store: store, logger: logger) { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        hookServer?.start()
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(refreshFromTimer), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        hookServer?.stop()
        assertionController.releaseIfActive()
        _ = try? lidClosedKeepAwakeController.sync(
            shouldEnable: false,
            stateStore: store,
            attemptKey: "source=menu-shutdown;target=false"
        )
        do {
            try store.update { state in
                if state.menuAppPID == Int32(getpid()) {
                    state.menuAppPID = nil
                }
                if state.watcherPID == nil {
                    state.assertionActive = false
                }
                state.updatedAt = Date().timeIntervalSince1970
            }
        } catch {
            logger.log("메뉴 막대 앱 종료 상태 저장 실패: \(error.localizedDescription)")
        }
        menuLock.unlock()
        logger.log("메뉴 막대 앱을 종료했습니다.")
    }

    @objc private func refreshFromTimer() {
        refresh()
    }

    @objc private func toggleManualHold() {
        do {
            try preferencesStore.update { preferences in
                preferences.manualHoldEnabled.toggle()
            }
            refresh()
        } catch {
            recordError(L10n.format(.manualHoldSaveFailed, error.localizedDescription))
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLoginController.setEnabled(!LaunchAtLoginController.isEnabled)
            refresh()
        } catch {
            recordError(L10n.format(.launchAtLoginSaveFailed, error.localizedDescription))
        }
    }

    @objc private func refreshMenu() {
        refresh()
    }

    @objc private func checkForUpdates() {
        updateChecker.checkForUpdates()
    }

    @objc private func removeHookSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else {
            recordError(L10n.text(.hookSessionRemoveMissingID))
            return
        }

        do {
            var existed = false
            try store.update { state in
                existed = state.sessions.removeValue(forKey: sessionID) != nil
                state.updatedAt = Date().timeIntervalSince1970
            }

            if !existed {
                logger.log("이미 없어진 훅 세션이라 제거하지 않았습니다: \(sessionID)")
            }
            refresh()
        } catch {
            recordError(L10n.format(.hookSessionRemoveFailed, error.localizedDescription))
        }
    }

    @objc private func clearAllHookSessions() {
        do {
            var removedCount = 0
            try store.update { state in
                removedCount = state.sessions.count
                state.sessions.removeAll()
                state.updatedAt = Date().timeIntervalSince1970
            }

            logger.log("사용자 요청으로 훅 세션 전체를 정리했습니다: \(removedCount)개")
            refresh()
        } catch {
            recordError(L10n.format(.clearHookSessionsFailed, error.localizedDescription))
        }
    }

    @objc private func installOrUpdatePrivilegedHelper() {
        guard setupStatusMessage == nil else {
            return
        }

        do {
            let scriptPath = try resolveHelperScriptPath("install-helper.sh")
            let installUID = getuid()
            beginSetup(message: L10n.text(.setupApplyingPermissions))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: SetupWorkflowResult
                do {
                    let helperOutput = try Self.executePrivilegedHelperScript(scriptPath: scriptPath, installUID: installUID)
                    let hookMessages = try AgentHookInstaller.installAll()
                    result = .success(helperOutput: helperOutput, hookMessages: hookMessages)
                } catch {
                    result = .failure(message: error.localizedDescription)
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.handleSetupWorkflowResult(result)
                }
            }
        } catch {
            recordError(L10n.format(.setupFailed, error.localizedDescription))
        }
    }

    private func handleSetupWorkflowResult(_ result: SetupWorkflowResult) {
        switch result {
        case let .success(helperOutput, hookMessages):
            if !helperOutput.isEmpty {
                logger.log("install-helper.sh 출력: \(helperOutput)")
            }
            logger.log(L10n.text(.installHelperSuccess))
            for message in hookMessages {
                logger.log(message)
            }
            logger.log(L10n.text(.installHooksSuccess))
            finishSetup()
            showHookTrustGuide()
        case let .failure(message):
            finishSetup(errorMessage: L10n.format(.setupFailed, message))
        }
    }

    @objc private func uninstallPrivilegedHelper() {
        runPrivilegedHelperScript(scriptName: "uninstall-helper.sh", successMessage: L10n.text(.uninstallHelperSuccess))
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func refresh() {
        do {
            let preferences = try preferencesStore.load()
            let removedSessionIDs = try StaleSessionCleaner.prune(store: store, preferences: preferences)
            if !removedSessionIDs.isEmpty {
                logger.log("transcript 비활성 기준으로 좀비 세션을 자동 정리했습니다: \(removedSessionIDs.sorted().joined(separator: ", "))")
            }
            let state = try store.load()
            let shouldHold = preferences.manualHoldEnabled
                || !state.sessions.isEmpty
            let now = Date().timeIntervalSince1970
            let shouldForceLidClosedKeepAwake = LidClosedKeepAwakePolicy.shouldEnable(
                shouldHold: shouldHold,
                preferences: preferences
            )

            if shouldHold {
                try assertionController.ensureActive()
            } else {
                assertionController.releaseIfActive()
            }

            let lidOutcome = try lidClosedKeepAwakeController.sync(
                shouldEnable: shouldForceLidClosedKeepAwake,
                stateStore: store,
                attemptKey: LidClosedKeepAwakePolicy.attemptKey(
                    source: "menu",
                    shouldEnable: shouldForceLidClosedKeepAwake,
                    preferences: preferences,
                    state: state
                )
            )

            try store.update { current in
                current.menuAppPID = Int32(getpid())
                current.assertionActive = assertionController.isActive
                if shouldHold && preferences.lidClosedKeepAwakeEnabled {
                    current.lidClosedKeepAwakeLastActiveAt = now
                }
                current.updatedAt = Date().timeIntervalSince1970
            }

            lastPreferences = preferences
            lastState = try store.load()
            lastHookReceiverStatus = hookServer?.statusSnapshot ?? .stopped
            lastErrorMessage = lidOutcome.recentError
            rebuildMenu()
        } catch {
            recordError(L10n.format(.refreshFailed, error.localizedDescription))
        }
    }

    private func recordError(_ message: String) {
        lastErrorMessage = message
        logger.log(message)
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let active = assertionController.isActive
        let activeReason = activeReasonText(active: active)
        let helperStatus = SystemSleepSettings.helperStatus()

        updateStatusButton(active: active, activeReason: activeReason, helperStatus: helperStatus)

        addDisabledItem("\(L10n.text(.statusLabel)): \(activeReason)", to: menu)
        addDisabledItem(helperStatus.menuText, to: menu)

        menu.addItem(NSMenuItem.separator())

        let manualItem = NSMenuItem(
            title: L10n.text(.manualHold),
            action: #selector(toggleManualHold),
            keyEquivalent: ""
        )
        manualItem.target = self
        manualItem.state = lastPreferences.manualHoldEnabled ? .on : .off
        menu.addItem(manualItem)

        let launchAtLoginItem = NSMenuItem(
            title: L10n.text(.launchAtLogin),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLoginController.isEnabled ? .on : .off
        launchAtLoginItem.isEnabled = LaunchAtLoginController.isAvailable
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())
        addDisabledItem("\(L10n.text(.hookSessions)): \(L10n.hookSessionCount(lastState.sessions.count))", to: menu)
        addHookSessionCleanupItems(to: menu, now: Date().timeIntervalSince1970)

        menu.addItem(NSMenuItem.separator())

        let installHelperItem = NSMenuItem(
            title: setupStatusMessage ?? L10n.text(.installHelper),
            action: setupStatusMessage == nil ? #selector(installOrUpdatePrivilegedHelper) : nil,
            keyEquivalent: ""
        )
        installHelperItem.target = self
        installHelperItem.isEnabled = setupStatusMessage == nil
        menu.addItem(installHelperItem)

        if helperStatus.isAvailable {
            menu.addItem(NSMenuItem.separator())

            let uninstallHelperItem = NSMenuItem(
                title: L10n.text(.uninstallHelper),
                action: #selector(uninstallPrivilegedHelper),
                keyEquivalent: ""
            )
            uninstallHelperItem.target = self
            uninstallHelperItem.isEnabled = setupStatusMessage == nil
            menu.addItem(uninstallHelperItem)
        }

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: L10n.text(.checkForUpdates), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let refreshItem = NSMenuItem(title: L10n.text(.refreshStatus), action: #selector(refreshMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: L10n.text(.quit), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func beginSetup(message: String) {
        setupStatusMessage = message
        lastErrorMessage = nil
        rebuildMenu()
    }

    private func finishSetup(errorMessage: String? = nil) {
        setupStatusMessage = nil
        if let errorMessage {
            recordError(errorMessage)
        } else {
            refresh()
        }
    }

    private func showHookTrustGuide() {
        let alert = NSAlert()
        alert.messageText = L10n.text(.hookTrustGuideTitle)
        alert.informativeText = L10n.text(.hookTrustGuideMessage)
        alert.addButton(withTitle: L10n.text(.openCodexAndCopyHooksCommand))
        alert.addButton(withTitle: L10n.text(.ok))

        if alert.runModal() == .alertFirstButtonReturn {
            copyHooksCommandToPasteboard()
            openCodexApp()
        }
    }

    private func copyHooksCommandToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("/hooks", forType: .string)
    }

    private func openCodexApp() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.open(appURL)
        }
    }

    @discardableResult
    private func runPrivilegedHelperScript(scriptName: String, successMessage: String) -> Bool {
        do {
            let scriptPath = try resolveHelperScriptPath(scriptName)
            let scriptOutput = try Self.executePrivilegedHelperScript(scriptPath: scriptPath, installUID: getuid())
            if !scriptOutput.isEmpty {
                logger.log("\(scriptName) 출력: \(scriptOutput)")
            }
            logger.log(successMessage)
            refresh()
            return true
        } catch {
            recordError(L10n.format(.helperTaskFailed, error.localizedDescription))
            return false
        }
    }

    private func resolveHelperScriptPath(_ scriptName: String) throws -> String {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Scripts").appendingPathComponent(scriptName).path)
        }

        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Scripts")
            .appendingPathComponent(scriptName)
            .path)

        if let executableURL = Bundle.main.executableURL {
            var directory = executableURL.deletingLastPathComponent()
            for _ in 0..<8 {
                candidates.append(directory.appendingPathComponent("Scripts").appendingPathComponent(scriptName).path)
                directory.deleteLastPathComponent()
            }
        }

        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty && seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw AppError(L10n.format(.helperScriptMissing, scriptName))
    }

    nonisolated private static func executePrivilegedHelperScript(scriptPath: String, installUID: uid_t) throws -> String {
        let command = "/usr/bin/env DO_NOT_SLEEP_INSTALL_UID=\(installUID) \(Self.shellQuoted(scriptPath))"
        let source = #"do shell script "\#(Self.appleScriptEscaped(command))" with administrator privileges"#
        guard let script = NSAppleScript(source: source) else {
            throw AppError(L10n.text(.appleScriptCreateFailed))
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw AppError(Self.appleScriptErrorMessage(errorInfo))
        }

        return output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private static func appleScriptErrorMessage(_ errorInfo: NSDictionary) -> String {
        let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let number = errorInfo["NSAppleScriptErrorNumber"].map { "\($0)" }
        if let message, !message.isEmpty, let number {
            return L10n.format(.appleScriptError, message, number)
        }
        if let message, !message.isEmpty {
            return message
        }
        return errorInfo.description
    }

    private func activeReasonText(active: Bool) -> String {
        active ? L10n.text(.active) : L10n.text(.inactive)
    }

    private func updateStatusButton(active: Bool, activeReason: String, helperStatus: SleepHelperStatus) {
        guard let button = statusItem.button else {
            return
        }

        let dot = statusDot(active: active, helperStatus: helperStatus)
        button.title = ""
        button.image = templateGlyphImage()
        button.imagePosition = .imageOnly
        button.toolTip = statusToolTip(active: active, activeReason: activeReason)
        updateStatusDot(dot, in: button)
    }

    private func statusDot(active: Bool, helperStatus: SleepHelperStatus) -> MenuBarStatusDot {
        if lastErrorMessage != nil || (lastPreferences.lidClosedKeepAwakeEnabled && !helperStatus.isAvailable) {
            return .error
        }
        guard active else {
            return .inactive
        }
        return .active
    }

    private func templateGlyphImage() -> NSImage? {
        if let statusGlyphImage {
            return statusGlyphImage
        }

        if let image = loadMenuBarImage(named: "DoNotSleepGlyph") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusGlyphImage = image
            return image
        }

        var fallbackImage: NSImage?
        if #available(macOS 11.0, *) {
            fallbackImage = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Do Not Sleep")
        }
        fallbackImage?.isTemplate = true
        fallbackImage?.size = NSSize(width: 18, height: 18)
        statusGlyphImage = fallbackImage
        return fallbackImage
    }

    private func updateStatusDot(_ dot: MenuBarStatusDot, in button: NSStatusBarButton) {
        let dotView = ensureStatusDotView(in: button)
        let dotSize: CGFloat = 5.5
        let padding: CGFloat = 2.5
        let x = max(padding, button.bounds.width - dotSize - padding)
        let y = button.isFlipped ? padding : max(padding, button.bounds.height - dotSize - padding)

        dotView.frame = NSRect(x: x, y: y, width: dotSize, height: dotSize)
        dotView.toolTip = dot.accessibilityDescription
        dotView.layer?.cornerRadius = dotSize / 2
        dotView.layer?.backgroundColor = dot.color.cgColor
    }

    private func ensureStatusDotView(in button: NSStatusBarButton) -> MenuBarStatusDotView {
        if let statusDotView, statusDotView.superview === button {
            return statusDotView
        }

        statusDotView?.removeFromSuperview()
        let dotView = MenuBarStatusDotView(frame: .zero)
        dotView.wantsLayer = true
        dotView.layer?.masksToBounds = true
        button.addSubview(dotView)
        statusDotView = dotView
        return dotView
    }

    private func loadMenuBarImage(named name: String) -> NSImage? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("MenuBar").appendingPathComponent("\(name)@2x.png"))
            candidates.append(resourceURL.appendingPathComponent("MenuBar").appendingPathComponent("\(name).png"))
        }

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(currentDirectory.appendingPathComponent("Assets/MenuBar/\(name)@2x.png"))
        candidates.append(currentDirectory.appendingPathComponent("Assets/MenuBar/\(name).png"))

        if let executableURL = Bundle.main.executableURL {
            var directory = executableURL.deletingLastPathComponent()
            for _ in 0..<8 {
                candidates.append(directory.appendingPathComponent("Assets/MenuBar/\(name)@2x.png"))
                candidates.append(directory.appendingPathComponent("Assets/MenuBar/\(name).png"))
                directory.deleteLastPathComponent()
            }
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            guard fileManager.isReadableFile(atPath: candidate.path) else {
                continue
            }
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }

        return nil
    }

    private func statusToolTip(active: Bool, activeReason: String) -> String {
        var parts = [
            "Do Not Sleep: \(activeReason)",
            "\(L10n.text(.activeCondition)): \(activeConditionText(active: active))",
        ]
        if let lastErrorMessage {
            parts.append("\(L10n.text(.recentError)): \(lastErrorMessage)")
        }
        return parts.joined(separator: "\n")
    }

    private func activeConditionText(active: Bool) -> String {
        guard active else {
            return L10n.text(.noActiveCondition)
        }

        var reasons: [String] = []
        if lastPreferences.manualHoldEnabled {
            reasons.append(L10n.text(.manualHoldCondition))
        }
        if !lastState.sessions.isEmpty {
            reasons.append("\(L10n.text(.hookSessions)) \(L10n.hookSessionCount(lastState.sessions.count))")
        }
        return reasons.isEmpty ? L10n.text(.unknown) : reasons.joined(separator: ", ")
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addHookSessionCleanupItems(to menu: NSMenu, now: TimeInterval) {
        let sortedSessions = lastState.sessions.values.sorted(by: { $0.id < $1.id })
        guard !sortedSessions.isEmpty else {
            return
        }

        let removeMenu = NSMenu()
        for session in sortedSessions {
            let age = SessionAgeFormatter.relativeAge(since: session.updatedAt, now: now)
            let transcriptText = TranscriptActivityFormatter.compactText(for: session, now: now)
            let detailText = transcriptText.map { "\(age), \($0)" } ?? age
            let item = NSMenuItem(title: L10n.format(.removeSession, session.id, detailText), action: #selector(removeHookSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            removeMenu.addItem(item)
        }

        removeMenu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: L10n.text(.clearAllHookSessions), action: #selector(clearAllHookSessions), keyEquivalent: "")
        clearItem.target = self
        removeMenu.addItem(clearItem)

        let removeRootItem = NSMenuItem(title: L10n.text(.hookSessionCleanup), action: nil, keyEquivalent: "")
        removeRootItem.submenu = removeMenu
        menu.addItem(removeRootItem)
    }
}
