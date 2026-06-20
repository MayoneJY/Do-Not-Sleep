import Foundation
import Darwin

struct ProcessDetector {
    static func isPIDRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
