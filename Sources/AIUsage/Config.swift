import Foundation

enum Provider: String, Codable, Sendable {
    case claude
    case codex
}

/// One entry in `~/.config/ai-usage/accounts.json`.
struct AccountConfig: Codable, Sendable, Identifiable, Hashable {
    /// Short label shown in the menu bar, e.g. "CC".
    var short: String
    /// Longer name shown in the dropdown.
    var name: String
    var provider: Provider
    /// Claude: the `CLAUDE_CONFIG_DIR` (use "~/.claude" for the default login).
    /// Codex: the `CODEX_HOME` (use "~/.codex" for the default login).
    var dir: String
    /// Optional override for the Claude keychain service name.
    var keychainService: String?

    var id: String { short + "|" + dir }

    var expandedDir: String { expandTilde(dir) }
}

enum AppConfig {
    /// `AI_USAGE_CONFIG` overrides the location, e.g. for testing with `--dump`.
    static let path = ProcessInfo.processInfo.environment["AI_USAGE_CONFIG"].map(expandTilde)
        ?? expandTilde("~/.config/ai-usage/accounts.json")
    static var directory: String { (path as NSString).deletingLastPathComponent }

    static let defaults: [AccountConfig] = [
        AccountConfig(short: "CC", name: "Claude Code work", provider: .claude, dir: "~/.claude-work"),
        AccountConfig(short: "CCK", name: "Claude Code personal", provider: .claude, dir: "~/.claude"),
        AccountConfig(short: "CO", name: "Codex work", provider: .codex, dir: "~/.codex-work"),
        AccountConfig(short: "COK", name: "Codex personal", provider: .codex, dir: "~/.codex"),
    ]

    /// Loads the account list, writing the defaults on first run.
    static func load() throws -> [AccountConfig] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(defaults).write(to: URL(fileURLWithPath: path))
            return defaults
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([AccountConfig].self, from: data)
    }
}

func expandTilde(_ path: String) -> String {
    var expanded = (path as NSString).expandingTildeInPath
    while expanded.count > 1 && expanded.hasSuffix("/") {
        expanded.removeLast()
    }
    return expanded
}
