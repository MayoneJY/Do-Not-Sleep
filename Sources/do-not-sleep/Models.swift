import Foundation

struct AppState: Codable {
    var sessions: [String: SessionRecord] = [:]
    var watcherPID: Int32?
    var menuAppPID: Int32?
    var assertionActive = false
    var lidClosedKeepAwakeApplied = false
    var lidClosedKeepAwakeLastActiveAt: TimeInterval?
    var lidClosedKeepAwakeLastSyncTarget: Bool?
    var lidClosedKeepAwakeLastSyncAt: TimeInterval?
    var updatedAt = Date().timeIntervalSince1970

    private enum CodingKeys: String, CodingKey {
        case sessions
        case watcherPID
        case menuAppPID
        case assertionActive
        case lidClosedKeepAwakeApplied
        case lidClosedKeepAwakeLastActiveAt
        case lidClosedKeepAwakeLastSyncTarget
        case lidClosedKeepAwakeLastSyncAt
        case updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([String: SessionRecord].self, forKey: .sessions) ?? [:]
        watcherPID = try container.decodeIfPresent(Int32.self, forKey: .watcherPID)
        menuAppPID = try container.decodeIfPresent(Int32.self, forKey: .menuAppPID)
        assertionActive = try container.decodeIfPresent(Bool.self, forKey: .assertionActive) ?? false
        lidClosedKeepAwakeApplied = try container.decodeIfPresent(Bool.self, forKey: .lidClosedKeepAwakeApplied) ?? false
        lidClosedKeepAwakeLastActiveAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lidClosedKeepAwakeLastActiveAt)
        lidClosedKeepAwakeLastSyncTarget = try container.decodeIfPresent(Bool.self, forKey: .lidClosedKeepAwakeLastSyncTarget)
        lidClosedKeepAwakeLastSyncAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lidClosedKeepAwakeLastSyncAt)
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? Date().timeIntervalSince1970
    }
}


struct AppPreferences: Codable {
    static let currentSchemaVersion = 4

    var schemaVersion = AppPreferences.currentSchemaVersion
    var manualHoldEnabled = false
    var lidClosedKeepAwakeEnabled = true
    var autoCleanupStaleSessionsEnabled = true
    var staleSessionTimeoutSeconds: TimeInterval = 600
    private var needsSchemaRepair = false

    var needsRepair: Bool {
        needsSchemaRepair
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case manualHoldEnabled
        case lidClosedKeepAwakeEnabled
        case autoCleanupStaleSessionsEnabled
        case staleSessionTimeoutSeconds
    }

    init(
        manualHoldEnabled: Bool = false,
        lidClosedKeepAwakeEnabled: Bool = true,
        autoCleanupStaleSessionsEnabled: Bool = true,
        staleSessionTimeoutSeconds: TimeInterval = 600
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.manualHoldEnabled = manualHoldEnabled
        self.lidClosedKeepAwakeEnabled = true
        self.autoCleanupStaleSessionsEnabled = true
        self.staleSessionTimeoutSeconds = staleSessionTimeoutSeconds > 0 ? staleSessionTimeoutSeconds : 600
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) else {
            schemaVersion = Self.currentSchemaVersion
            manualHoldEnabled = false
            lidClosedKeepAwakeEnabled = true
            autoCleanupStaleSessionsEnabled = true
            staleSessionTimeoutSeconds = 600
            needsSchemaRepair = true
            return
        }

        schemaVersion = Self.currentSchemaVersion
        manualHoldEnabled = try container.decodeIfPresent(Bool.self, forKey: .manualHoldEnabled) ?? false
        _ = try container.decodeIfPresent(Bool.self, forKey: .lidClosedKeepAwakeEnabled)
        lidClosedKeepAwakeEnabled = true
        if decodedSchemaVersion >= 3 {
            _ = try container.decodeIfPresent(Bool.self, forKey: .autoCleanupStaleSessionsEnabled)
            autoCleanupStaleSessionsEnabled = true
            let decodedTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .staleSessionTimeoutSeconds) ?? 600
            staleSessionTimeoutSeconds = decodedTimeout > 0 ? decodedTimeout : 600
        } else {
            autoCleanupStaleSessionsEnabled = true
            staleSessionTimeoutSeconds = 600
        }
        needsSchemaRepair = decodedSchemaVersion != Self.currentSchemaVersion
    }
}


struct SessionRecord: Codable {
    let id: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval
    let transcriptPath: String?
    let cwd: String?
    let provider: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case transcriptPath
        case cwd
        case provider
    }

    init(
        id: String,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        provider: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcriptPath = Self.cleaned(transcriptPath)
        self.cwd = Self.cleaned(cwd)
        self.provider = Self.cleaned(provider)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(TimeInterval.self, forKey: .createdAt)
        updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
        transcriptPath = Self.cleaned(try container.decodeIfPresent(String.self, forKey: .transcriptPath))
        cwd = Self.cleaned(try container.decodeIfPresent(String.self, forKey: .cwd))
        provider = Self.cleaned(try container.decodeIfPresent(String.self, forKey: .provider))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}


struct PreferencesLoadResult {
    let preferences: AppPreferences
    let needsRepair: Bool
}
