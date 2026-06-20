import Foundation
import ServiceManagement

enum LaunchAtLoginController {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else {
            return false
        }
        guard #available(macOS 13.0, *) else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else {
            throw AppError(L10n.text(.launchAtLoginRequiresAppBundle))
        }
        guard #available(macOS 13.0, *) else {
            throw AppError(L10n.text(.launchAtLoginRequiresAppBundle))
        }

        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
