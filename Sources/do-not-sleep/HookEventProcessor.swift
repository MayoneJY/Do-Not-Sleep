import Foundation

struct HookEventProcessor {
    private let store: StateStore

    init(store: StateStore) {
        self.store = store
    }

    func handle(payload: [String: Any]) throws -> HookEventResult {
        let eventName = Self.stringValue(payload["hook_event_name"]).trimmingCharacters(in: .whitespacesAndNewlines)

        switch eventName {
        case "SessionStart":
            return try registerSession(from: payload, isSubagent: false, eventName: eventName)
        case "UserPromptSubmit":
            return try registerSession(from: payload, isSubagent: false, eventName: eventName)
        case "PostToolUse":
            return try registerSession(from: payload, isSubagent: false, eventName: eventName)
        case "SessionEnd":
            return try removeSession(from: payload, isSubagent: false, eventName: eventName)
        case "SubagentStart":
            return try registerSession(from: payload, isSubagent: true, eventName: eventName)
        case "SubagentStop":
            return try removeSession(from: payload, isSubagent: true, eventName: eventName)
        case "Stop":
            return try removeSession(from: payload, isSubagent: false, eventName: eventName)
        case "":
            return .ignored("hook_event_name이 없어 무시했습니다.")
        default:
            return .ignored("처리하지 않는 훅입니다: \(eventName)")
        }
    }

    private func registerSession(from payload: [String: Any], isSubagent: Bool, eventName: String) throws -> HookEventResult {
        guard let sessionKey = Self.sessionKey(from: payload, isSubagent: isSubagent) else {
            return .ignored("\(eventName) 훅에 세션 식별 정보가 없어 상태를 바꾸지 않았습니다.")
        }

        let metadata = Self.sessionMetadata(from: payload)
        try store.update { state in
            let existing = state.sessions[sessionKey]
            state.sessions[sessionKey] = SessionRecord(
                id: sessionKey,
                createdAt: existing?.createdAt ?? Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970,
                transcriptPath: metadata.transcriptPath ?? existing?.transcriptPath,
                cwd: metadata.cwd ?? existing?.cwd,
                provider: metadata.provider ?? existing?.provider
            )
            state.updatedAt = Date().timeIntervalSince1970
        }
        return .registered(sessionKey)
    }

    private func removeSession(from payload: [String: Any], isSubagent: Bool, eventName: String) throws -> HookEventResult {
        guard let sessionKey = Self.sessionKey(from: payload, isSubagent: isSubagent) else {
            return .ignored("\(eventName) 훅에 세션 식별 정보가 없어 상태를 바꾸지 않았습니다.")
        }

        var existed = false
        try store.update { state in
            existed = state.sessions.removeValue(forKey: sessionKey) != nil
            state.updatedAt = Date().timeIntervalSince1970
        }

        if existed {
            return .removed(sessionKey)
        }
        return .ignored("등록되지 않은 훅 세션이라 제거할 항목이 없었습니다: \(sessionKey)")
    }

    private static func sessionKey(from payload: [String: Any], isSubagent: Bool) -> String? {
        let transcriptPath = stringValue(payload["transcript_path"])
        let prefix = transcriptPath.contains(".claude/") ? "claude" : "codex"
        let sessionID = stringValue(payload["session_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseKey: String

        if !sessionID.isEmpty {
            baseKey = "\(prefix)-\(sessionID)"
        } else {
            let parts = [
                transcriptPath,
                stringValue(payload["cwd"]),
                stringValue(payload["pid"]),
            ]

            guard parts.contains(where: { !$0.isEmpty }) else {
                return nil
            }

            baseKey = "\(prefix)-fallback-\(sha256Prefix(parts.joined(separator: "\0")))"
        }

        guard isSubagent else {
            return baseKey
        }

        guard let discriminator = subagentDiscriminator(from: payload) else {
            return nil
        }

        return "\(baseKey)-subagent-\(sha256Prefix(discriminator))"
    }

    private static func sessionMetadata(from payload: [String: Any]) -> (transcriptPath: String?, cwd: String?, provider: String?) {
        let transcriptPath = cleaned(stringValue(payload["transcript_path"]))
        let cwd = cleaned(stringValue(payload["cwd"]))
        let provider = cleaned(stringValue(payload["provider"]))
            ?? providerFromSourceValue(cleaned(stringValue(payload["source"])))
            ?? transcriptPath.map(providerPrefix)

        return (transcriptPath, cwd, provider)
    }

    private static func providerFromSourceValue(_ value: String?) -> String? {
        guard let source = value?.lowercased(), ["codex", "claude"].contains(source) else {
            return nil
        }
        return source
    }

    private static func providerPrefix(from transcriptPath: String) -> String {
        transcriptPath.contains(".claude/") ? "claude" : "codex"
    }

    private static func subagentDiscriminator(from payload: [String: Any]) -> String? {
        var parts: [String] = []
        appendSubagentPart("id", from: payload, keys: ["subagent_id", "subagentId"], to: &parts)
        appendSubagentPart("type", from: payload, keys: ["subagent_type", "subagentType"], to: &parts)
        appendSubagentPart("name", from: payload, keys: ["subagent_name", "subagentName"], to: &parts)

        if let subagent = payload["subagent"] as? [String: Any] {
            appendSubagentPart("id", from: subagent, keys: ["id", "subagent_id", "subagentId"], to: &parts)
            appendSubagentPart("type", from: subagent, keys: ["type", "subagent_type", "subagentType"], to: &parts)
            appendSubagentPart("name", from: subagent, keys: ["name", "subagent_name", "subagentName"], to: &parts)
        }

        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: "\0")
    }

    private static func appendSubagentPart(_ label: String, from payload: [String: Any], keys: [String], to parts: inout [String]) {
        for key in keys {
            let value = stringValue(payload[key]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                parts.append("\(label)=\(value)")
                return
            }
        }
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return ""
        }
    }

    private static func cleaned(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sha256Prefix(_ value: String) -> String {
        SHA256Hasher.hexPrefix(value, length: 16)
    }
}


enum HookEventResult {
    case registered(String)
    case removed(String)
    case ignored(String)

    var logMessage: String {
        switch self {
        case .registered(let key):
            return "훅 세션을 등록했습니다: \(key)"
        case .removed(let key):
            return "훅 세션을 해제했습니다: \(key)"
        case .ignored(let reason):
            return "훅을 무시했습니다. \(reason)"
        }
    }
}


enum SHA256Hasher {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hexPrefix(_ value: String, length: Int) -> String {
        hash(Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length).description
    }

    private static func hash(_ data: Data) -> [UInt8] {
        var bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var hash: [UInt32] = [
            0x6a09e667,
            0xbb67ae85,
            0x3c6ef372,
            0xa54ff53a,
            0x510e527f,
            0x9b05688c,
            0x1f83d9ab,
            0x5be0cd19,
        ]

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3])
            }

            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], by: 7)
                    ^ rotateRight(words[index - 15], by: 18)
                    ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], by: 17)
                    ^ rotateRight(words[index - 2], by: 19)
                    ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        return hash.flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff),
            ]
        }
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

