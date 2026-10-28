import Foundation
import Testing
@testable import AIUsage

@Test func snapshotCacheRoundTripAndFiltering() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SnapshotCache(url: root.appendingPathComponent("snapshots.json"))
    let account = AccountConfig(name: "Test", provider: .claude, dir: "/synthetic")
    let snapshot = UsageSnapshot(
        windows: [UsageWindow(label: "Session", usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 200),
                              detail: "Example", resetIsEstimate: true, period: 18000)],
        identity: "sample@example.com", plan: "Pro", fetchedAt: Date(timeIntervalSince1970: 100))
    #expect(cache.load(accounts: [account]).isEmpty)
    try cache.save(accounts: [account], snapshots: [account.id: snapshot])
    let loaded = try #require(cache.load(accounts: [account])[account.id])
    #expect(loaded.windows == snapshot.windows)
    #expect(loaded.identity == snapshot.identity)
    #expect(loaded.plan == snapshot.plan)
    #expect(loaded.fetchedAt == snapshot.fetchedAt)
    #expect(loaded.staleReason != nil)
    #expect(cache.load(accounts: []).isEmpty)
    var changed = account
    changed.provider = .codex
    #expect(cache.load(accounts: [changed]).isEmpty)
    try cache.save(accounts: [], snapshots: [account.id: snapshot])
    #expect(cache.load(accounts: [account]).isEmpty)
    try Data("corrupt".utf8).write(to: cache.url)
    #expect(cache.load(accounts: [account]).isEmpty)
    try Data(#"{"version":2,"entries":{}}"#.utf8).write(to: cache.url)
    #expect(cache.load(accounts: [account]).isEmpty)
}

@Test func configSaveValidatesBeforeReplacingFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("accounts.json")
    let account = AccountConfig(name: "Test", group: "Personal", short: "T",
                                provider: .claude, dir: "~/.claude", keychainService: "custom")
    try AppConfig.save([account], to: url)
    let original = try Data(contentsOf: url)
    #expect(try AppConfig.decode(original) == [account])
    #expect(throws: AppConfig.DuplicateAccount.self) { try AppConfig.save([account, account], to: url) }
    #expect(try Data(contentsOf: url) == original)
    var empty = account
    empty.name = "  "
    #expect(throws: FetchError.self) { try AppConfig.save([empty], to: url) }
    #expect(try Data(contentsOf: url) == original)
    try AppConfig.save([], to: url)
    #expect(try AppConfig.decode(Data(contentsOf: url)).isEmpty)
}
