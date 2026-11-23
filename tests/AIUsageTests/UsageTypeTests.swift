import Foundation
import Testing
@testable import AIUsage

@Test func usageTypeDefaultsAndPersists() throws {
    let legacy = Data(#"[{"name":"Claude","provider":"claude","dir":"~/.claude"}]"#.utf8)
    var account = try #require(AppConfig.decode(legacy).first)
    #expect(account.claudeUsageType == .session)
    let id = account.id
    account.claudeUsageType = .week
    #expect(account.id == id)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("accounts.json")
    try AppConfig.save([account], to: url)
    let saved = try #require(AppConfig.decode(Data(contentsOf: url)).first)
    #expect(saved.claudeUsageType == .week)
    #expect(saved.id == id)
}

@Test(arguments: [
    #"{"five_hour":{"utilization":6},"seven_day":{"utilization":1},"seven_day_sonnet":{"utilization":90}}"#,
    #"{"limits":[{"kind":"weekly_scoped","percent":90,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_all","percent":1},{"kind":"session","percent":6}]}"#,
])
@MainActor func selectedUsageDrivesMenuBar(payload: String) throws {
    let windows = try JSONDecoder().decode(ClaudeUsage.self, from: Data(payload.utf8)).windows()
    let snapshot = UsageSnapshot(windows: windows, fetchedAt: Date())
    var claude = AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude")
    #expect(snapshot.headlineWindow(for: claude)?.usedPercent == 6)
    claude.claudeUsageType = .week
    #expect(snapshot.headlineWindow(for: claude)?.usedPercent == 1)
    let codex = AccountConfig(name: "Codex", provider: .codex, dir: "~/.codex", usageType: .week)
    #expect(snapshot.headlineWindow(for: codex)?.usedPercent == 6)

    let store = UsageStore(fixed: [(claude, snapshot), (codex, snapshot)])
    let values = store.menuBarSegments.compactMap { segment -> String? in
        if case .account(_, let value) = segment { return value }
        return nil
    }
    #expect(values == ["1%", "6%"])
    #expect(snapshot.windows == windows)
}

@Test @MainActor func missingWeeklyAllowanceDoesNotShowAnotherLimit() {
    var account = AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude", usageType: .week)
    let snapshot = UsageSnapshot(windows: [
        UsageWindow(label: "Session", usedPercent: 6, period: 18000, kind: .session),
        UsageWindow(label: "Week · Fable", usedPercent: 90, period: 604800, kind: .scopedWeek),
    ], fetchedAt: Date())
    #expect(snapshot.headlineWindow(for: account) == nil)
    let store = UsageStore(fixed: [(account, snapshot)])
    if case .account(_, let value) = store.menuBarSegments.first {
        #expect(value == "–")
    } else {
        Issue.record("Expected an account segment")
    }
    account.claudeUsageType = .session
    let monthly = UsageSnapshot(windows: [
        UsageWindow(label: "Monthly spend", usedPercent: 82, period: 2592000, kind: .spend),
    ], fetchedAt: Date())
    #expect(monthly.headlineWindow(for: account)?.usedPercent == 82)
}

/// A scoped weekly limit without a model name is labelled plain "Week"; it must not stand in for
/// the overall weekly allowance, nor for a missing session.
@Test func scopedWeekNeverStandsInForAnotherAllowance() throws {
    let payload = #"{"limits":[{"kind":"weekly_scoped","percent":90},{"kind":"weekly_all","percent":1}]}"#
    let windows = try JSONDecoder().decode(ClaudeUsage.self, from: Data(payload.utf8)).windows()
    #expect(windows.map(\.label) == ["Week", "Week"])
    let snapshot = UsageSnapshot(windows: windows, fetchedAt: Date())
    let week = AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude", usageType: .week)
    #expect(snapshot.headlineWindow(for: week)?.usedPercent == 1)
    let session = AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude")
    #expect(snapshot.headlineWindow(for: session) == nil)
}

@Test(arguments: [("week", ClaudeUsageType.week), ("Week", .week), ("weekly", .session), ("SESSION", .session)])
func unknownUsageTypeDoesNotBreakTheConfig(raw: String, expected: ClaudeUsageType) throws {
    let data = Data(#"[{"name":"Claude","provider":"claude","dir":"~/.claude","usageType":"\#(raw)"}]"#.utf8)
    #expect(try AppConfig.decode(data).first?.claudeUsageType == expected)
}
