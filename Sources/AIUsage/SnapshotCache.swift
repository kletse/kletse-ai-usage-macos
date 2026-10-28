import Foundation

/// Best-effort display cache, containing usage data only, never credentials.
struct SnapshotCache {
    let url: URL

    private struct Entry: Codable {
        var provider: Provider
        var snapshot: UsageSnapshot
    }

    private struct Archive: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    func load(accounts: [AccountConfig]) -> [String: UsageSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1 else { return [:] }
        var result: [String: UsageSnapshot] = [:]
        for account in accounts {
            guard let entry = archive.entries[account.id], entry.provider == account.provider else { continue }
            var snapshot = entry.snapshot
            snapshot.staleReason = "Saved usage from a previous session. Refreshing…"
            result[account.id] = snapshot
        }
        return result
    }

    func save(accounts: [AccountConfig], snapshots: [String: UsageSnapshot]) throws {
        var entries: [String: Entry] = [:]
        for account in accounts {
            guard let snapshot = snapshots[account.id] else { continue }
            entries[account.id] = Entry(provider: account.provider, snapshot: snapshot)
        }
        let data = try JSONEncoder().encode(Archive(version: 1, entries: entries))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
