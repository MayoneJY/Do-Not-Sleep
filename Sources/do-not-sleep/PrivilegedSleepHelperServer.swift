import Foundation
import Darwin

struct PrivilegedHelperConfig: Decodable {
    let allowedUID: uid_t
    let allowedGID: gid_t
    let socketPath: String

    enum CodingKeys: String, CodingKey {
        case allowedUID = "allowed_uid"
        case allowedGID = "allowed_gid"
        case socketPath = "socket_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowedUIDValue = try container.decode(Int.self, forKey: .allowedUID)
        let allowedGIDValue = try container.decode(Int.self, forKey: .allowedGID)
        let socketPath = try container.decode(String.self, forKey: .socketPath)

        guard allowedUIDValue >= 0, allowedUIDValue <= Int(UInt32.max) else {
            throw AppError("helper 설정의 allowed_uid가 올바르지 않습니다.")
        }
        guard allowedGIDValue >= 0, allowedGIDValue <= Int(UInt32.max) else {
            throw AppError("helper 설정의 allowed_gid가 올바르지 않습니다.")
        }
        guard !socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError("helper 설정의 socket_path가 비어 있습니다.")
        }

        self.allowedUID = uid_t(allowedUIDValue)
        self.allowedGID = gid_t(allowedGIDValue)
        self.socketPath = socketPath
    }
}


final class PrivilegedSleepHelperServer {
    private let configPath: String
    private var listenFileDescriptor: Int32 = -1

    init(configPath: String) {
        self.configPath = configPath
    }

    func serve() throws {
        let config = try loadConfig()
        let termination = TerminationController()
        try prepareSocketDirectory(config.socketPath)
        try removeStaleSocket(config.socketPath)
        listenFileDescriptor = try makeListenSocket(config: config)
        defer {
            cleanup(socketPath: config.socketPath)
        }

        print("privileged helper를 시작했습니다: \(config.socketPath)")

        while !termination.isRequested {
            let clientFileDescriptor = Darwin.accept(listenFileDescriptor, nil, nil)
            if clientFileDescriptor < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                if termination.isRequested {
                    break
                }
                throw AppError("helper 연결 수락 실패: errno \(errno)")
            }

            handleConnection(fileDescriptor: clientFileDescriptor, config: config)
        }
    }

    private func loadConfig() throws -> PrivilegedHelperConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        return try JSONDecoder().decode(PrivilegedHelperConfig.self, from: data)
    }

    private func prepareSocketDirectory(_ socketPath: String) throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func removeStaleSocket(_ socketPath: String) throws {
        var info = stat()
        let result = socketPath.withCString { path in
            Darwin.lstat(path, &info)
        }

        if result != 0 {
            if errno == ENOENT {
                return
            }
            throw AppError("기존 helper 소켓 확인 실패: errno \(errno)")
        }

        let fileType = info.st_mode & S_IFMT
        guard fileType == S_IFSOCK else {
            throw AppError("기존 경로가 소켓이 아니라서 helper를 시작할 수 없습니다: \(socketPath)")
        }

        try unlinkSocket(socketPath)
    }

    private func makeListenSocket(config: PrivilegedHelperConfig) throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AppError("helper 소켓을 만들 수 없습니다: errno \(errno)")
        }

        do {
            let flags = fcntl(fileDescriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw AppError("helper 소켓을 non-blocking으로 바꿀 수 없습니다: errno \(errno)")
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            #if os(macOS)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            #endif

            try config.socketPath.withCString { pathPointer in
                let pathLength = strlen(pathPointer)
                let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
                guard pathLength < maxPathLength else {
                    throw AppError("helper 소켓 경로가 너무 깁니다: \(config.socketPath)")
                }

                withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
                    sunPathPointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                        memset(buffer, 0, maxPathLength)
                        strncpy(buffer, pathPointer, maxPathLength - 1)
                    }
                }
            }

            let oldUmask = umask(0o077)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            umask(oldUmask)

            guard bindResult == 0 else {
                throw AppError("helper 소켓 바인딩 실패(\(config.socketPath)): errno \(errno)")
            }

            guard config.socketPath.withCString({ Darwin.chown($0, config.allowedUID, config.allowedGID) }) == 0 else {
                throw AppError("helper 소켓 소유자 설정 실패: errno \(errno)")
            }

            guard config.socketPath.withCString({ Darwin.chmod($0, 0o600) }) == 0 else {
                throw AppError("helper 소켓 권한 설정 실패: errno \(errno)")
            }

            guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw AppError("helper 소켓 listen 시작 실패: errno \(errno)")
            }

            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private func handleConnection(fileDescriptor: Int32, config: PrivilegedHelperConfig) {
        defer {
            Darwin.close(fileDescriptor)
        }

        do {
            try verifyPeer(fileDescriptor: fileDescriptor, allowedUID: config.allowedUID)
            let command = try readCommand(from: fileDescriptor)
            let response = try handle(command: command)
            try send(response: response, to: fileDescriptor)
        } catch let error as AppError {
            try? send(response: "error \(error.message)\n", to: fileDescriptor)
        } catch {
            try? send(response: "error \(error.localizedDescription)\n", to: fileDescriptor)
        }
    }

    private func verifyPeer(fileDescriptor: Int32, allowedUID: uid_t) throws {
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(fileDescriptor, &peerUID, &peerGID) == 0 else {
            throw AppError("helper peer UID 확인 실패: errno \(errno)")
        }

        guard peerUID == allowedUID else {
            throw AppError("allowed_uid가 일치하지 않습니다.")
        }
    }

    private func readCommand(from fileDescriptor: Int32) throws -> String {
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 256)

        while responseData.count < 1024 {
            let count = Darwin.recv(fileDescriptor, &buffer, min(buffer.count, 1024 - responseData.count), 0)
            if count == 0 {
                break
            }
            guard count > 0 else {
                throw AppError("helper 명령 수신 실패: errno \(errno)")
            }
            responseData.append(contentsOf: buffer.prefix(count))
            if buffer[..<count].contains(10) {
                break
            }
        }

        return String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func handle(command: String) throws -> String {
        switch command {
        case "enable":
            _ = try runPMSet(arguments: ["-a", "disablesleep", "1"])
            return "ok sleep_disabled=1\n"
        case "disable":
            _ = try runPMSet(arguments: ["-a", "disablesleep", "0"])
            return "ok sleep_disabled=0\n"
        case "sleepnow-if-lid-closed":
            return try sleepNowIfLidClosedResponse()
        case "status":
            let output = try runPMSet(arguments: ["-g"])
            return "ok status=available sleep_disabled=\(parseSleepDisabled(from: output))\n"
        default:
            throw AppError("허용되지 않은 helper 명령입니다.")
        }
    }

    private func runPMSet(arguments: [String]) throws -> String {
        try runProcess(executablePath: "/usr/bin/pmset", arguments: arguments)
    }

    private func runProcess(executablePath: String, arguments: [String]) throws -> String {
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
            throw AppError(message.isEmpty ? "\(executablePath) 실행 실패: 종료 코드 \(process.terminationStatus)" : message)
        }

        return output
    }

    private func sleepNowIfLidClosedResponse() throws -> String {
        let output = try runProcess(executablePath: "/usr/sbin/ioreg", arguments: ["-r", "-k", "AppleClamshellState", "-d", "1"])
        guard let isLidClosed = lidClosedValue(from: output) else {
            return "ok sleepnow=skipped-unknown\n"
        }

        guard isLidClosed else {
            return "ok sleepnow=skipped-lid-open\n"
        }

        _ = try runPMSet(arguments: ["sleepnow"])
        return "ok sleepnow=requested\n"
    }

    private func parseSleepDisabled(from output: String) -> String {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2 && parts[0] == "SleepDisabled" {
                return parts[1]
            }
        }
        return "unknown"
    }

    private func lidClosedValue(from output: String) -> Bool? {
        guard let line = output
            .split(separator: "\n")
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.contains(#""AppleClamshellState""#) }) else {
            return nil
        }

        let parts = line.split(separator: "=", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2 else {
            return nil
        }

        switch parts[1].lowercased() {
        case "yes", "true", "1":
            return true
        case "no", "false", "0":
            return false
        default:
            return nil
        }
    }

    private func send(response: String, to fileDescriptor: Int32) throws {
        let data = Data(response.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var sent = 0
            while sent < data.count {
                let result = Darwin.send(fileDescriptor, baseAddress.advanced(by: sent), data.count - sent, 0)
                guard result > 0 else {
                    throw AppError("helper 응답 전송 실패: errno \(errno)")
                }
                sent += result
            }
        }
    }

    private func cleanup(socketPath: String) {
        if listenFileDescriptor >= 0 {
            Darwin.close(listenFileDescriptor)
            listenFileDescriptor = -1
        }
        try? unlinkSocket(socketPath)
        print("privileged helper를 종료했습니다.")
    }

    private func unlinkSocket(_ socketPath: String) throws {
        let result = socketPath.withCString { path in
            Darwin.unlink(path)
        }
        guard result == 0 || errno == ENOENT else {
            throw AppError("helper 소켓 삭제 실패: errno \(errno)")
        }
    }
}

