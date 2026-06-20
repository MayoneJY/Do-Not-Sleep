import Foundation

final class StateStore {
    private let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
    }

    func load() throws -> AppState {
        try paths.prepareDirectory()
        let lock = try FileLock(path: paths.stateLockFile)
        try lock.exclusiveLock()
        defer { lock.unlock() }
        return try loadWithoutLock()
    }

    func update(_ body: (inout AppState) throws -> Void) throws {
        try paths.prepareDirectory()
        let lock = try FileLock(path: paths.stateLockFile)
        try lock.exclusiveLock()
        defer { lock.unlock() }

        var state = try loadWithoutLock()
        try body(&state)
        try saveWithoutLock(state)
    }

    private func loadWithoutLock() throws -> AppState {
        guard FileManager.default.fileExists(atPath: paths.stateFile.path) else {
            return AppState()
        }

        let data = try Data(contentsOf: paths.stateFile)
        if data.isEmpty {
            return AppState()
        }
        return try JSONDecoder().decode(AppState.self, from: data)
    }

    private func saveWithoutLock(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let temporaryFile = paths.directory.appendingPathComponent("state.json.tmp")
        try data.write(to: temporaryFile, options: .atomic)
        if FileManager.default.fileExists(atPath: paths.stateFile.path) {
            try FileManager.default.removeItem(at: paths.stateFile)
        }
        try FileManager.default.moveItem(at: temporaryFile, to: paths.stateFile)
    }
}


final class PreferencesStore {
    private let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
    }

    func load() throws -> AppPreferences {
        try paths.prepareDirectory()
        let lock = try FileLock(path: paths.preferencesLockFile)
        try lock.exclusiveLock()
        defer { lock.unlock() }
        let fileExists = FileManager.default.fileExists(atPath: paths.preferencesFile.path)
        let result = try loadWithoutLock()
        if !fileExists || result.needsRepair {
            try saveWithoutLock(result.preferences)
        }
        return result.preferences
    }

    func update(_ body: (inout AppPreferences) throws -> Void) throws {
        try paths.prepareDirectory()
        let lock = try FileLock(path: paths.preferencesLockFile)
        try lock.exclusiveLock()
        defer { lock.unlock() }

        var preferences = try loadWithoutLock().preferences
        try body(&preferences)
        try saveWithoutLock(preferences)
    }

    private func loadWithoutLock() throws -> PreferencesLoadResult {
        guard FileManager.default.fileExists(atPath: paths.preferencesFile.path) else {
            return PreferencesLoadResult(preferences: AppPreferences(), needsRepair: false)
        }

        let data = try Data(contentsOf: paths.preferencesFile)
        if data.isEmpty {
            return PreferencesLoadResult(preferences: AppPreferences(), needsRepair: true)
        }

        do {
            let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
            return PreferencesLoadResult(preferences: preferences, needsRepair: preferences.needsRepair)
        } catch {
            return PreferencesLoadResult(preferences: AppPreferences(), needsRepair: true)
        }
    }

    private func saveWithoutLock(_ preferences: AppPreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        let temporaryFile = paths.directory.appendingPathComponent("preferences.json.tmp")
        try data.write(to: temporaryFile, options: .atomic)
        if FileManager.default.fileExists(atPath: paths.preferencesFile.path) {
            try FileManager.default.removeItem(at: paths.preferencesFile)
        }
        try FileManager.default.moveItem(at: temporaryFile, to: paths.preferencesFile)
    }
}

