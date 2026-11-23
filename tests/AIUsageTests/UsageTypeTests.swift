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
        UsageWindow(label: "Week · Fable", usedPercent: 90, period: 604800, kind: .weeklyScoped),
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

private let weeklyAll = #"{"kind":"weekly_all","percent":1,"resets_at":"2026-11-30T09:00:00Z"}"#
private let scopedNamed = #"{"kind":"weekly_scoped","percent":90,"scope":{"model":{"display_name":"Fable"}}}"#
/// No model display name, so the label is plain "Week", identical to the overall allowance.
private let scopedUnnamed = #"{"kind":"weekly_scoped","percent":90}"#
private let scopedEmptyScope = #"{"kind":"weekly_scoped","percent":90,"scope":{}}"#

/// Week selects `weekly_all` explicitly, whatever the order of limits and whether scoped limits
/// have a model name. Session never falls back to a scoped weekly limit.
@Test(arguments: [
    [scopedUnnamed, weeklyAll],
    [weeklyAll, scopedUnnamed],
    [scopedEmptyScope, weeklyAll],
    [weeklyAll, scopedEmptyScope],
    [scopedNamed, scopedUnnamed, weeklyAll],
    [weeklyAll, scopedUnnamed, scopedNamed],
])
@MainActor func weekSelectsWeeklyAllRegardlessOfOrderAndModelName(limits: [String]) throws {
    let payload = #"{"limits":["# + limits.joined(separator: ",") + "]}"
    let windows = try JSONDecoder().decode(ClaudeUsage.self, from: Data(payload.utf8)).windows()
    #expect(windows.filter { $0.label == "Week" }.count >= 2, "The fixture must reproduce the ambiguous label")

    let snapshot = UsageSnapshot(windows: windows, fetchedAt: Date())
    let week = AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude", usageType: .week)
    let selected = try #require(snapshot.headlineWindow(for: week))
    #expect(selected.kind == .weeklyAll)
    #expect(selected.usedPercent == 1)
    #expect(selected.resetsAt == Dates.parseISO("2026-11-30T09:00:00Z"))

    let store = UsageStore(fixed: [(week, snapshot)])
    guard case .account(_, let value) = store.menuBarSegments.first else {
        Issue.record("Expected an account segment"); return
    }
    #expect(value == "1%")

    let session = AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude")
    #expect(snapshot.headlineWindow(for: session) == nil)
}

/// Only scoped weekly limits, all without model names: Week shows a dash, not a scoped limit.
@Test(arguments: [[scopedUnnamed], [scopedUnnamed, scopedEmptyScope]])
func weekWithoutWeeklyAllShowsNothing(limits: [String]) throws {
    let payload = #"{"limits":["# + limits.joined(separator: ",") + "]}"
    let windows = try JSONDecoder().decode(ClaudeUsage.self, from: Data(payload.utf8)).windows()
    let week = AccountConfig(name: "Claude", provider: .claude, dir: "~/.claude", usageType: .week)
    #expect(UsageSnapshot(windows: windows, fetchedAt: Date()).headlineWindow(for: week) == nil)
}

/// The semantic type survives the snapshot cache's JSON round trip under the API's own names.
@Test func limitKindRoundTripsWithApiNames() throws {
    let window = UsageWindow(label: "Week", usedPercent: 1, kind: .weeklyAll)
    let json = try #require(String(data: JSONEncoder().encode(window), encoding: .utf8))
    #expect(json.contains(#""kind":"weekly_all""#))
    #expect(try JSONDecoder().decode(UsageWindow.self, from: Data(json.utf8)).kind == .weeklyAll)
}

@Test(arguments: [("week", ClaudeUsageType.week), ("Week", .week), ("weekly", .session), ("SESSION", .session)])
func unknownUsageTypeDoesNotBreakTheConfig(raw: String, expected: ClaudeUsageType) throws {
    let data = Data(#"[{"name":"Claude","provider":"claude","dir":"~/.claude","usageType":"\#(raw)"}]"#.utf8)
    #expect(try AppConfig.decode(data).first?.claudeUsageType == expected)
}
