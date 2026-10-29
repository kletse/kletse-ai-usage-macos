import Foundation
import Testing
@testable import AIUsage

private func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

@Test func claudeLimitsAndLegacy() throws {
    let modern = try decode(#"{"limits":[{"kind":"weekly_scoped","percent":42,"scope":{"model":{"display_name":"Sonnet"}}},{"kind":"session","percent":12},{"kind":"new_limit","percent":3},{"kind":"session"}],"five_hour":{"utilization":99}}"#, as: ClaudeUsage.self).windows()
    #expect(modern.map(\.label) == ["Week · Sonnet", "Session", "New Limit"])
    #expect(modern.map(\.usedPercent) == [42, 12, 3])
    #expect(modern.map(\.period) == [604800, 18000, nil])
    let legacy = try decode(#"{"limits":[],"five_hour":{"utilization":0},"seven_day":{"utilization":100},"seven_day_opus":{"utilization":20},"seven_day_sonnet":{}}"#, as: ClaudeUsage.self).windows()
    #expect(legacy.map(\.label) == ["Session", "Week", "Week · Opus"])
    #expect(try decode("{}", as: ClaudeUsage.self).windows().isEmpty)
}

@Test(arguments: [(0, "JPY"), (2, "USD"), (3, "KWD"), (2, "EUR")])
func money(exponent: Int, currency: String) throws {
    let json = """
    {"spend":{"enabled":true,"used":{"amount_minor":250},"limit":{"amount_minor":1000,"exponent":\(exponent),"currency":"\(currency)"}},"extra_usage":{"is_enabled":true,"monthly_limit":100,"used_credits":99}}
    """
    let window = try #require(decode(json, as: ClaudeUsage.self).windows().first)
    #expect(window.usedPercent == 25)
    let scale = pow(10, Double(exponent))
    #expect(window.detail == "\((250 / scale).formatted(.currency(code: currency))) of \((1000 / scale).formatted(.currency(code: currency)))")
    #expect(window.resetIsEstimate)
    #expect(window.resetsAt != nil)
}

@Test func extraUsage() throws {
    let windows = try decode(#"{"spend":{"enabled":false},"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":250,"utilization":30}}"#, as: ClaudeUsage.self).windows()
    #expect(windows.first?.usedPercent == 30)
    #expect(try decode(#"{"extra_usage":{"is_enabled":true,"monthly_limit":0}}"#, as: ClaudeUsage.self).windows().isEmpty)
}

@Test func headlineAndDates() {
    func window(_ label: String, _ period: Double?) -> UsageWindow {
        UsageWindow(label: label, usedPercent: 0, resetsAt: nil, period: period)
    }
    func headline(_ windows: [UsageWindow]) -> String? {
        UsageSnapshot(windows: windows, fetchedAt: Date()).headlineWindow?.label
    }
    #expect(headline([window("unknown", nil), window("week", 604800), window("first", 18000), window("tie", 18000)]) == "first")
    #expect(headline([window("first", nil), window("second", nil)]) == "first")
    #expect(headline([]) == nil)
    #expect(Dates.parseISO("2026-01-01T00:00:00Z") == Date(timeIntervalSince1970: 1767225600))
    #expect(Dates.parseISO("2026-01-01T00:00:00.123456Z") == Dates.parseISO("2026-01-01T00:00:00Z"))
    #expect(Dates.parseISO(nil) == nil)
    #expect(Dates.parseISO("invalid") == nil)
}

@Test(arguments: [(2700, "45-minute"), (5400, "90-minute"), (18000, "5-hour"), (604800, "Week"), (172800, "2-day"), (7200, "2-hour"), (61, "61-second"), (0, "Limit"), (-1, "Limit")])
func labels(seconds: Int, expected: String) {
    #expect(CodexUsage.label(seconds: seconds) == expected)
}

@Test func codexWindows() throws {
    let windows = try decode(#"{"rate_limit":{"primary_window":{"used_percent":23,"limit_window_seconds":2700,"reset_at":100},"secondary_window":{}},"additional_rate_limits":[{"limit_name":"Review","rate_limit":{"primary_window":{"used_percent":45}}}]}"#, as: CodexUsage.self).windows()
    #expect(windows.map(\.label) == ["45-minute", "Limit · Review"])
    #expect(windows.map(\.period) == [2700, nil])
    #expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 100))
    #expect(try decode("{}", as: CodexUsage.self).windows().isEmpty)
}

@Test func configAndKeychain() throws {
    #expect(AppConfig.discoveredDefaults { _ in false }.isEmpty)
    #expect(AppConfig.discoveredDefaults { $0 == "~/.codex" }.map(\.provider) == [.codex])
    let row = #"{"name":"A","provider":"claude","dir":"/tmp/test"}"#
    #expect(throws: AppConfig.DuplicateAccount.self) { try AppConfig.decode(Data("[\(row),\(row)]".utf8)) }
    #expect(try AppConfig.decode(Data("[\(row)]".utf8)).count == 1)
    var account = AccountConfig(name: "Test", provider: .claude, dir: "/tmp/test")
    #expect(ClaudeProvider(account: account).keychainService == "Claude Code-credentials-0872effe")
    account.dir = "~/.claude"
    #expect(ClaudeProvider(account: account).keychainService == "Claude Code-credentials")
    #expect(ClaudeProvider(account: account).keychainServices.count == 2)
    account.keychainService = "override"
    #expect(ClaudeProvider(account: account).keychainService == "override")
    #expect(ClaudeProvider(account: account).keychainServices == ["override"])
}

@Test func sessionFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lines = """
    {"timestamp":"2026-01-01T00:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":300}}}}
    {"timestamp":"2026-01-02T00:00:00.123Z","payload":{"rate_limits":{"primary":{"used_percent":35,"window_minutes":45,"resets_at":100},"secondary":{},"plan_type":"prolite"}}}
    {"payload":{"rate_limits":
    {"payload":{"other":true}}
    """
    try lines.write(to: sessions.appendingPathComponent("test.jsonl"), atomically: true, encoding: .utf8)
    let snapshot = try await CodexProvider(account: AccountConfig(name: "Test", provider: .codex, dir: root.path)).fetch()
    #expect(snapshot.windows.map(\.usedPercent) == [35])
    #expect(snapshot.windows.first?.label == "45-minute")
    #expect(snapshot.windows.first?.period == 2700)
    #expect(snapshot.plan == "Pro Lite")
    #expect(snapshot.fetchedAt == Dates.parseISO("2026-01-02T00:00:00Z"))
    #expect(snapshot.staleReason != nil)
}
