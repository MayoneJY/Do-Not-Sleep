import Foundation
import Darwin

enum HookReceiverStatus {
    case stopped
    case listening(port: UInt16)
    case failed(port: UInt16, message: String)

    var menuText: String {
        switch self {
        case .stopped:
            return L10n.text(.hookReceiverStopped)
        case .listening(let port):
            return L10n.format(.hookReceiverListening, String(port))
        case .failed(let port, let message):
            return L10n.format(.hookReceiverFailed, String(port), message)
        }
    }
}


struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}


struct HTTPRequestError: Error {
    let statusCode: Int
    let reason: String
    let message: String

    static func badRequest(_ message: String) -> HTTPRequestError {
        HTTPRequestError(statusCode: 400, reason: "Bad Request", message: message)
    }

    static func notFound(_ message: String) -> HTTPRequestError {
        HTTPRequestError(statusCode: 404, reason: "Not Found", message: message)
    }

    static func methodNotAllowed(_ message: String) -> HTTPRequestError {
        HTTPRequestError(statusCode: 405, reason: "Method Not Allowed", message: message)
    }

    static func payloadTooLarge(_ message: String) -> HTTPRequestError {
        HTTPRequestError(statusCode: 413, reason: "Payload Too Large", message: message)
    }
}


final class HookHTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let store: StateStore
    private let logger: Logger
    private let onEventHandled: () -> Void
    private let queue = DispatchQueue(label: "do-not-sleep.hook-http-server")
    private let statusLock = NSLock()
    private var status = HookReceiverStatus.stopped
    private var listenFileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?

    var statusSnapshot: HookReceiverStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return status
    }

    init(port: UInt16 = defaultHookReceiverPort, store: StateStore, logger: Logger, onEventHandled: @escaping () -> Void = {}) {
        self.port = port
        self.store = store
        self.logger = logger
        self.onEventHandled = onEventHandled
    }

    func start() {
        guard readSource == nil else {
            return
        }

        do {
            let fileDescriptor = try makeListenSocket(port: port)
            listenFileDescriptor = fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptConnections()
            }
            source.setCancelHandler {
                Darwin.close(fileDescriptor)
            }
            readSource = source
            setStatus(.listening(port: port))
            logger.log("훅 HTTP 수신기를 시작했습니다: http://127.0.0.1:\(port)/event")
            source.resume()
        } catch {
            let message = error.localizedDescription
            setStatus(.failed(port: port, message: message))
            logger.log("훅 HTTP 수신기 시작 실패: \(message)")
        }
    }

    func stop() {
        queue.sync {
            if let readSource {
                readSource.cancel()
                self.readSource = nil
                listenFileDescriptor = -1
            }
            setStatus(.stopped)
        }
    }

    private func makeListenSocket(port: UInt16) throws -> Int32 {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AppError("소켓을 만들 수 없습니다: errno \(errno)")
        }

        do {
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw AppError("소켓 옵션을 설정할 수 없습니다: errno \(errno)")
            }

            let flags = fcntl(fileDescriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw AppError("소켓을 non-blocking으로 바꿀 수 없습니다: errno \(errno)")
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                throw AppError("127.0.0.1:\(port)에 바인딩할 수 없습니다: errno \(errno)")
            }

            guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw AppError("소켓 listen을 시작할 수 없습니다: errno \(errno)")
            }
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private func acceptConnections() {
        while true {
            var address = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFileDescriptor = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(listenFileDescriptor, socketAddress, &addressLength)
                }
            }

            if clientFileDescriptor < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                let message = "연결 수락 실패: errno \(errno)"
                setStatus(.failed(port: port, message: message))
                logger.log("훅 HTTP 수신기 오류: \(message)")
                return
            }

            handleConnection(clientFileDescriptor)
        }
    }

    private func handleConnection(_ fileDescriptor: Int32) {
        defer {
            Darwin.close(fileDescriptor)
        }

        do {
            try configureClientSocket(fileDescriptor)
            let request = try readRequest(from: fileDescriptor)
            let responseBody = try handle(request: request)
            sendResponse(statusCode: 200, reason: "OK", body: responseBody, to: fileDescriptor)
        } catch let error as HTTPRequestError {
            logger.log("훅 HTTP 요청 실패: \(error.message)")
            sendResponse(statusCode: error.statusCode, reason: error.reason, body: #"{"ok":false}"# + "\n", to: fileDescriptor)
        } catch let error as AppError {
            logger.log("훅 HTTP 요청 처리 실패: \(error.message)")
            sendResponse(statusCode: 500, reason: "Internal Server Error", body: #"{"ok":false}"# + "\n", to: fileDescriptor)
        } catch {
            logger.log("훅 HTTP 요청 처리 실패: \(error.localizedDescription)")
            sendResponse(statusCode: 500, reason: "Internal Server Error", body: #"{"ok":false}"# + "\n", to: fileDescriptor)
        }
    }

    private func configureClientSocket(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0 else {
            throw AppError("클라이언트 소켓 상태를 읽을 수 없습니다: errno \(errno)")
        }

        let blockingFlags = flags & ~O_NONBLOCK
        if blockingFlags != flags && fcntl(fileDescriptor, F_SETFL, blockingFlags) != 0 {
            throw AppError("클라이언트 소켓을 blocking 모드로 바꿀 수 없습니다: errno \(errno)")
        }

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readRequest(from fileDescriptor: Int32) throws -> HTTPRequest {
        let headerSeparator = Data([13, 10, 13, 10])
        let maximumBodySize = 1024 * 1024
        let maximumRequestSize = maximumBodySize + 16 * 1024
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            if let headerRange = data.range(of: headerSeparator) {
                let headerData = data.subdata(in: 0..<headerRange.lowerBound)
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    throw HTTPRequestError.badRequest("HTTP 헤더가 UTF-8이 아닙니다.")
                }

                let parsedHeader = try parseHeader(headerText)
                if parsedHeader.contentLength > maximumBodySize {
                    throw HTTPRequestError.payloadTooLarge("훅 JSON 본문이 너무 큽니다.")
                }

                let bodyStart = headerRange.upperBound
                let requiredSize = bodyStart + parsedHeader.contentLength
                if data.count >= requiredSize {
                    let body = data.subdata(in: bodyStart..<requiredSize)
                    return HTTPRequest(method: parsedHeader.method, path: parsedHeader.path, body: body)
                }
            }

            if data.count > maximumRequestSize {
                throw HTTPRequestError.payloadTooLarge("HTTP 요청이 너무 큽니다.")
            }

            let received = buffer.withUnsafeMutableBytes { pointer in
                Darwin.recv(fileDescriptor, pointer.baseAddress, bufferSize, 0)
            }
            if received > 0 {
                data.append(buffer, count: received)
                continue
            }
            if received == 0 {
                throw HTTPRequestError.badRequest("HTTP 요청이 끝까지 도착하지 않았습니다.")
            }
            throw HTTPRequestError.badRequest("HTTP 요청을 읽을 수 없습니다: errno \(errno)")
        }
    }

    private func parseHeader(_ headerText: String) throws -> (method: String, path: String, contentLength: Int) {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPRequestError.badRequest("HTTP 요청 라인이 없습니다.")
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            throw HTTPRequestError.badRequest("HTTP 요청 라인을 이해할 수 없습니다.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        guard let contentLengthText = headers["content-length"], let contentLength = Int(contentLengthText), contentLength >= 0 else {
            throw HTTPRequestError.badRequest("Content-Length 헤더가 올바르지 않습니다.")
        }

        let rawPath = requestParts[1]
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return (method: requestParts[0], path: path, contentLength: contentLength)
    }

    private func handle(request: HTTPRequest) throws -> String {
        guard request.method == "POST" else {
            throw HTTPRequestError.methodNotAllowed("POST 요청만 받을 수 있습니다.")
        }
        guard request.path == "/event" else {
            throw HTTPRequestError.notFound("지원하지 않는 HTTP 경로입니다: \(request.path)")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: request.body)
        } catch {
            throw HTTPRequestError.badRequest("훅 JSON을 파싱할 수 없습니다: \(error.localizedDescription)")
        }

        guard let payload = object as? [String: Any] else {
            throw HTTPRequestError.badRequest("훅 JSON은 객체여야 합니다.")
        }

        let result = try HookEventProcessor(store: store).handle(payload: payload)
        logger.log(result.logMessage)
        onEventHandled()
        return #"{"ok":true}"# + "\n"
    }

    private func sendResponse(statusCode: Int, reason: String, body: String, to fileDescriptor: Int32) {
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(statusCode) \(reason)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        var responseData = Data(header.utf8)
        responseData.append(bodyData)
        responseData.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return
            }

            var sent = 0
            while sent < responseData.count {
                let result = Darwin.send(fileDescriptor, baseAddress.advanced(by: sent), responseData.count - sent, 0)
                if result <= 0 {
                    return
                }
                sent += result
            }
        }
    }

    private func setStatus(_ newStatus: HookReceiverStatus) {
        statusLock.lock()
        status = newStatus
        statusLock.unlock()
    }
}
