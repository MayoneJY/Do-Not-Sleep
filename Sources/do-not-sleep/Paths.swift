import Foundation

struct AppPaths {
    let directory: URL
    let stateFile: URL
    let stateLockFile: URL
    let preferencesFile: URL
    let preferencesLockFile: URL
    let watchLockFile: URL
    let menuLockFile: URL
    let logFile: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent(".do-not-sleep", isDirectory: true)
        stateFile = directory.appendingPathComponent("state.json")
        stateLockFile = directory.appendingPathComponent("state.lock")
        preferencesFile = directory.appendingPathComponent("preferences.json")
        preferencesLockFile = directory.appendingPathComponent("preferences.lock")
        watchLockFile = directory.appendingPathComponent("watch.lock")
        menuLockFile = directory.appendingPathComponent("menu.lock")
        logFile = directory.appendingPathComponent("watch.log")
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

