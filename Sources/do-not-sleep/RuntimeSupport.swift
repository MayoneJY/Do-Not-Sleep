import Foundation
import Darwin

final class Logger {
    private let foreground: Bool
    private let fileHandle: FileHandle?

    init(paths: AppPaths, foreground: Bool) throws {
        self.foreground = foreground
        try paths.prepareDirectory()
        FileManager.default.createFile(atPath: paths.logFile.path, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: paths.logFile.path)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        fileHandle?.closeFile()
    }

    func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)\n"
        if foreground {
            print(line, terminator: "")
        }
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}


final class TerminationController: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var sources: [DispatchSourceSignal] = []

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    init() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                self?.requestStop()
            }
            source.resume()
            return source
        }
    }

    func requestStop() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}


struct AppError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }

    init(_ message: String) {
        self.message = message
    }
}
