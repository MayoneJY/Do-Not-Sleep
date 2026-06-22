import Foundation

enum AgentHookInstaller {
    private static let hookURL = "http://127.0.0.1:\(defaultHookReceiverPort)/event"
    private static let hookCommand = #"curl -s -X POST -H "Content-Type: application/json" --data-binary @- \#(hookURL)"#
    private static let statusMessage = "Do Not Sleep 훅 등록 세션 동기화"

    static func installAll() throws -> [String] {
        [
            try installCodexHooks(),
            try installClaudeHooks()
        ]
    }

    private static func installCodexHooks() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("hooks.json")
        var data = try loadJSONObject(at: path)
        try backup(path)

        for event in ["UserPromptSubmit", "PostToolUse", "Stop", "SubagentStart", "SubagentStop"] {
            addHook(to: &data, event: event)
        }

        try saveJSONObject(data, to: path)
        return "Codex 훅 설정 완료: \(path.path)"
    }

    private static func installClaudeHooks() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
        var data = try loadJSONObject(at: path)
        try backup(path)

        for event in ["SessionStart", "SessionEnd", "SubagentStart", "SubagentStop"] {
            addHook(to: &data, event: event)
        }

        try saveJSONObject(data, to: path)
        return "Claude 훅 설정 완료: \(path.path)"
    }

    private static func addHook(to data: inout [String: Any], event: String) {
        var hooks = data["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[event] as? [[String: Any]] ?? []
        if !hasCommand(in: entries) {
            entries.append(hookEntry())
        }
        hooks[event] = entries
        data["hooks"] = hooks
    }

    private static func hasCommand(in entries: [[String: Any]]) -> Bool {
        for entry in entries {
            guard let hooks = entry["hooks"] as? [[String: Any]] else {
                continue
            }
            if hooks.contains(where: { ($0["command"] as? String) == hookCommand }) {
                return true
            }
        }
        return false
    }

    private static func hookEntry() -> [String: Any] {
        [
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": hookCommand,
                    "timeout": 5,
                    "statusMessage": statusMessage
                ]
            ]
        ]
    }

    private static func loadJSONObject(at path: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return [:]
        }

        let data = try Data(contentsOf: path)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw AppError("JSON 루트가 객체가 아닙니다: \(path.path)")
        }
        return dictionary
    }

    private static func saveJSONObject(_ object: [String: Any], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    private static func backup(_ path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let backupURL = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).before-do-not-sleep-\(formatter.string(from: Date()))")
        try FileManager.default.copyItem(at: path, to: backupURL)
    }
}
