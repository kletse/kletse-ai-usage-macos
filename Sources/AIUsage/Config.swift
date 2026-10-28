import Foundation

enum Provider: String, Codable, Sendable {
    case claude
    case codex
}

/// One entry in `~/.config/ai-usage/accounts.json`.
struct AccountConfig: Codable, Sendable, Identifiable, Hashable {
    /// Name shown in the dropdown.
    var name: String
    /// Accounts with the same group sit together; a dot separates groups in the menu bar.
    var group: String?
    /// Optional legacy short label, retained for config compatibility.
    var short: String?
    var provider: Provider
    /// Claude: the `CLAUDE_CONFIG_DIR` (use "~/.claude" for the default login).
    /// Codex: the `CODEX_HOME` (use "~/.codex" for the default login).
    var dir: String
    /// Optional override for the Claude keychain service name.
    var keychainService: String?

    var id: String { name + "|" + dir }

    var expandedDir: String { expandTilde(dir) }
}

enum AppConfig {
    /// `AI_USAGE_CONFIG` overrides the location, for the live app; diagnostic commands never load it.
    static let path = ProcessInfo.processInfo.environment["AI_USAGE_CONFIG"].map(expandTilde)
        ?? expandTilde("~/.config/ai-usage/accounts.json")
    static var directory: String { (path as NSString).deletingLastPathComponent }

    static var defaults: [AccountConfig] {
        discoveredDefaults { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: expandTilde(path), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    static func discoveredDefaults(exists: (String) -> Bool) -> [AccountConfig] {
        [
            AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude"),
            AccountConfig(name: "Codex", provider: .codex, dir: "~/.codex"),
        ].filter { exists($0.dir) }
    }

    struct DuplicateAccount: LocalizedError {
        let name: String
        var errorDescription: String? { "Duplicate account: \(name). Each name and directory pair must be unique." }
    }

    static func decode(_ data: Data) throws -> [AccountConfig] {
        let accounts = try JSONDecoder().decode([AccountConfig].self, from: data)
        var ids = Set<String>()
        for account in accounts where !ids.insert(account.id).inserted {
            throw DuplicateAccount(name: account.name)
        }
        return accounts
    }

    /// Loads the account list, writing the defaults on first run.
    static func load() throws -> [AccountConfig] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let defaults = defaults
            try encoder.encode(defaults).write(to: URL(fileURLWithPath: path))
            if defaults.isEmpty {
                // JSON has no comments; keep the hint in an adjacent text file.
                try "# Add accounts to accounts.json using name, provider (claude or codex), and dir.\n# Example: [{\"name\":\"Claude\",\"provider\":\"claude\",\"dir\":\"~/.claude\"}]\n"
                    .write(toFile: directory + "/accounts.json.example", atomically: true, encoding: .utf8)
            }
            return defaults
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decode(data)
    }
}

func expandTilde(_ path: String) -> String {
    var expanded = (path as NSString).expandingTildeInPath
    while expanded.count > 1 && expanded.hasSuffix("/") {
        expanded.removeLast()
    }
    return expanded
}
