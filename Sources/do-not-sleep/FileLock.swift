import Foundation
import Darwin

final class FileLock {
    private let fileDescriptor: Int32

    init(path: URL) throws {
        FileManager.default.createFile(atPath: path.path, contents: nil)
        fileDescriptor = open(path.path, O_RDWR)
        guard fileDescriptor >= 0 else {
            throw AppError("락 파일을 열 수 없습니다: \(path.path)")
        }
    }

    deinit {
        close(fileDescriptor)
    }

    func exclusiveLock() throws {
        if flock(fileDescriptor, LOCK_EX) != 0 {
            throw AppError("파일 락을 획득할 수 없습니다.")
        }
    }

    func tryExclusiveLock() -> Bool {
        flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0
    }

    func unlock() {
        flock(fileDescriptor, LOCK_UN)
    }
}

