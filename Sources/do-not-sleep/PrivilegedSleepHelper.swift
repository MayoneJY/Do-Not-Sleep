import Foundation
import Darwin

enum SleepHelperStatus {
    case available(String)
    case unavailable(String)

    var isAvailable: Bool {
        switch self {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    var cliText: String {
        switch self {
        case .available(let detail):
            return L10n.format(.helperApplied, detail)
        case .unavailable(let reason):
            return L10n.format(.helperNotApplied, reason)
        }
    }

    var menuText: String {
        switch self {
        case .available:
            return L10n.text(.helperMenuApplied)
        case .unavailable:
            return L10n.text(.helperMenuRequired)
        }
    }
}


struct HelperUnavailableError: LocalizedError {
    let detail: String

    var errorDescription: String? {
        detail
    }
}


enum PrivilegedSleepHelper {
    private static var helperRequiredMessage: String {
        L10n.text(.helperRequiredMessage)
    }

    private static var socketPath: String {
        "/var/run/do-not-sleep-helper-\(getuid()).sock"
    }

    static func status() -> SleepHelperStatus {
        do {
            let response = try send(command: "status")
            return .available(response)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func setDisableSleep(_ enabled: Bool) throws {
        let command = enabled ? "enable" : "disable"
        do {
            _ = try send(command: command)
        } catch is HelperUnavailableError {
            throw AppError(helperRequiredMessage)
        }
    }

    static func sleepNowIfLidClosed() throws -> LidClosedSleepNowOutcome {
        do {
            let response = try send(command: "sleepnow-if-lid-closed")
            return try LidClosedSleepNowOutcome(helperResponse: response)
        } catch is HelperUnavailableError {
            throw AppError(helperRequiredMessage)
        }
    }

    private static func send(command: String) throws -> String {
        guard ["enable", "disable", "status", "sleepnow-if-lid-closed"].contains(command) else {
            throw AppError(L10n.text(.invalidHelperCommand))
        }

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw HelperUnavailableError(detail: L10n.format(.helperSocketCreateFailed, errno))
        }
        defer { Darwin.close(fileDescriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        try socketPath.withCString { pathPointer in
            let pathLength = strlen(pathPointer)
            let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
            guard pathLength < maxPathLength else {
                throw AppError(L10n.format(.helperSocketPathTooLong, socketPath))
            }

            withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
                sunPathPointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                    memset(buffer, 0, maxPathLength)
                    strncpy(buffer, pathPointer, maxPathLength - 1)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw HelperUnavailableError(detail: L10n.format(.helperConnectionFailed, socketPath, errno))
        }

        let request = Data((command + "\n").utf8)
        try request.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var sent = 0
            while sent < request.count {
                let result = Darwin.send(fileDescriptor, baseAddress.advanced(by: sent), request.count - sent, 0)
                guard result > 0 else {
                    throw HelperUnavailableError(detail: L10n.format(.helperSendFailed, errno))
                }
                sent += result
            }
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while responseData.count < 4096 {
            let count = Darwin.recv(fileDescriptor, &buffer, buffer.count, 0)
            if count == 0 {
                break
            }
            guard count > 0 else {
                throw HelperUnavailableError(detail: L10n.format(.helperReceiveFailed, errno))
            }
            responseData.append(contentsOf: buffer.prefix(count))
            if buffer[..<count].contains(10) {
                break
            }
        }

        let response = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard response.hasPrefix("ok") else {
            throw AppError(response.isEmpty ? L10n.text(.helperEmptyResponse) : response)
        }
        return response
    }
}


enum LidClosedSleepNowOutcome {
    case requested
    case skippedLidOpen
    case skippedUnknown

    init(helperResponse: String) throws {
        if helperResponse.contains("sleepnow=requested") {
            self = .requested
        } else if helperResponse.contains("sleepnow=skipped-lid-open") {
            self = .skippedLidOpen
        } else if helperResponse.contains("sleepnow=skipped-unknown") {
            self = .skippedUnknown
        } else {
            throw AppError(L10n.format(.helperSleepNowResponseUnknown, helperResponse))
        }
    }

    var logMessage: String {
        switch self {
        case .requested:
            return L10n.text(.sleepNowRequested)
        case .skippedLidOpen:
            return L10n.text(.sleepNowSkippedLidOpen)
        case .skippedUnknown:
            return L10n.text(.sleepNowSkippedUnknown)
        }
    }
}
