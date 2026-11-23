import Foundation
import Testing
@testable import AIUsage

private let testEpoch = Date(timeIntervalSince1970: 1_800_000_000)

private final class RenewalFixture: @unchecked Sendable {
    let lock = NSLock()
    private var date = testEpoch
    private var logins: [String: ClaudeCredentials] = [:]
    private var calls: [String] = []
    private var advances = true

    func now() -> Date { lock.withLock { date } }
    func setNow(_ value: Date) { lock.withLock { date = value } }
    func setAdvances(_ value: Bool) { lock.withLock { advances = value } }
    func callCount() -> Int { lock.withLock { calls.count } }
    func set(_ account: AccountConfig, expiry: Date, token: String = "fixture-access",
             renewable: Bool = true, finalExpiry: Date? = nil) {
        lock.withLock {
            logins[account.expandedDir] = ClaudeCredentials(
                accessToken: token, expiresAt: expiry, hasRefreshToken: renewable,
                refreshTokenExpiresAt: finalExpiry, source: .file)
        }
    }
    func read(_ account: AccountConfig) throws -> ClaudeCredentials {
        try lock.withLock {
            guard let value = logins[account.expandedDir] else { throw FetchError("No fixture login") }
            return value
        }
    }
    func run(_ account: AccountConfig) {
        lock.withLock {
            calls.append(account.expandedDir)
            if advances, var value = logins[account.expandedDir] {
                value.accessToken += "-renewed"
                value.expiresAt = date.addingTimeInterval(3600)
                logins[account.expandedDir] = value
            }
        }
    }
    func keeper() -> ClaudeSessionRenewal {
        ClaudeSessionRenewal(read: { try self.read($0) }, runUsage: { account, _ in self.run(account) },
                            now: { self.now() })
    }
}

@Test func renewalSchedulesSuccessiveSavedExpiries() async throws {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    let expiry = testEpoch.addingTimeInterval(600)
    fixture.set(account, expiry: expiry)
    let keeper = fixture.keeper()
    let early = await keeper.check(account: account)
    #expect(early.nextCheck == expiry.addingTimeInterval(-240))
    #expect(fixture.callCount() == 0)

    fixture.setNow(try #require(early.nextCheck))
    let first = await keeper.check(account: account)
    #expect(first.renewed)
    #expect(first.error == nil)
    #expect(first.nextCheck == fixture.now().addingTimeInterval(3600 - 240))
    #expect(fixture.callCount() == 1)

    _ = await keeper.check(account: account)
    #expect(fixture.callCount() == 1)
    fixture.setNow(try #require(first.nextCheck))
    let second = await keeper.check(account: account)
    #expect(second.renewed)
    #expect(second.nextCheck == fixture.now().addingTimeInterval(3600 - 240))
    #expect(fixture.callCount() == 2)
}

@Test func externalRenewalReplacesOldDeadline() async {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    fixture.set(account, expiry: testEpoch.addingTimeInterval(600))
    let keeper = fixture.keeper()
    _ = await keeper.check(account: account)
    fixture.set(account, expiry: testEpoch.addingTimeInterval(7200), token: "external-renewal")
    fixture.setNow(testEpoch.addingTimeInterval(360))
    let result = await keeper.check(account: account)
    #expect(result.nextCheck == testEpoch.addingTimeInterval(7200 - 240))
    #expect(fixture.callCount() == 0)
}

@Test func concurrentChecksForSameLoginLaunchOnlyOnce() async {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    fixture.set(account, expiry: testEpoch.addingTimeInterval(120))
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let keeper = ClaudeSessionRenewal(read: { try fixture.read($0) }, runUsage: { account, _ in
        started.continuation.yield(())
        for await _ in release.stream { break }
        fixture.run(account)
    }, now: { fixture.now() })
    let first = Task { await keeper.check(account: account) }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    var alias = account
    alias.name = "Another label for the same login"
    let concurrent = await keeper.check(account: alias)
    #expect(!concurrent.renewed)
    #expect(fixture.callCount() == 0)
    release.continuation.yield(())
    #expect(await first.value.renewed)
    #expect(fixture.callCount() == 1)
    release.continuation.finish()
    started.continuation.finish()
}

@Test func unchangedExpiryBacksOffDespiteSuccessfulCommand() async throws {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    fixture.set(account, expiry: testEpoch.addingTimeInterval(120))
    fixture.setAdvances(false)
    let keeper = fixture.keeper()
    let first = await keeper.check(account: account)
    #expect(!first.renewed)
    #expect(first.error != nil)
    #expect(first.nextCheck == testEpoch.addingTimeInterval(30))
    _ = await keeper.check(account: account)
    #expect(fixture.callCount() == 1)
    fixture.setNow(try #require(first.nextCheck))
    let second = await keeper.check(account: account)
    #expect(second.nextCheck == fixture.now().addingTimeInterval(60))
    #expect(fixture.callCount() == 2)

    // A real external renewal clears the failure and its retry deadline immediately.
    fixture.set(account, expiry: fixture.now().addingTimeInterval(7200), token: "external")
    let external = await keeper.check(account: account)
    #expect(external.error == nil)
    #expect(external.nextCheck == fixture.now().addingTimeInterval(7200 - 240))
}

@Test func renewalSeparatesAccountsAndIgnoresCodex() async {
    let fixture = RenewalFixture()
    let due = AccountConfig(name: "Due", provider: .claude, dir: "/fixture/due")
    let later = AccountConfig(name: "Later", provider: .claude, dir: "/fixture/later")
    let codex = AccountConfig(name: "Codex", provider: .codex, dir: "/fixture/codex")
    fixture.set(due, expiry: testEpoch.addingTimeInterval(120))
    fixture.set(later, expiry: testEpoch.addingTimeInterval(7200))
    let result = await fixture.keeper().check(accounts: [due, later, codex])
    #expect(result[due.id]?.renewed == true)
    #expect(result[later.id]?.renewed == false)
    #expect(result[codex.id] == nil)
    #expect(fixture.callCount() == 1)
}

@Test func accountsSharingALoginAreCheckedOnceAndGetItsCredentials() async {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    var alias = account
    alias.name = "Another label for the same login"
    fixture.set(account, expiry: testEpoch.addingTimeInterval(120))
    let result = await fixture.keeper().check(accounts: [account, alias])
    #expect(result[account.id]?.renewed == true)
    #expect(result[alias.id]?.renewed == true)
    #expect(result[alias.id]?.credentials?.accessToken == "fixture-access-renewed")
    #expect(fixture.callCount() == 1)
}

@Test func wakeAfterExpiryStillRenewsButKnownFinalExpiryDoesNot() async {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    fixture.set(account, expiry: testEpoch.addingTimeInterval(-3600))
    #expect(await fixture.keeper().check(account: account).renewed)
    fixture.set(account, expiry: testEpoch, finalExpiry: testEpoch.addingTimeInterval(-1))
    let ended = await fixture.keeper().check(account: account)
    #expect(ended.nextCheck == nil)
    #expect(ended.error?.contains("Run claude auth login") == true)
    fixture.set(account, expiry: testEpoch, renewable: false)
    #expect(await fixture.keeper().check(account: account).nextCheck == nil)
    #expect(fixture.callCount() == 1)
}

@Test func loginThatCannotRenewOnlyWarnsOnceRenewalIsDue() async {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    let expiry = testEpoch.addingTimeInterval(3600)
    fixture.set(account, expiry: expiry, renewable: false)
    let valid = await fixture.keeper().check(account: account)
    #expect(valid.error == nil)
    #expect(valid.nextCheck == expiry.addingTimeInterval(-240))
    fixture.setNow(expiry)
    #expect(await fixture.keeper().check(account: account).error != nil)
    #expect(fixture.callCount() == 0)
}

@Test func unsupportedLoginIsReportedWithoutBackoff() async {
    let fixture = RenewalFixture()
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: "/fixture")
    fixture.set(account, expiry: testEpoch.addingTimeInterval(120))
    let keeper = ClaudeSessionRenewal(read: { try fixture.read($0) }, runUsage: { _, _ in
        throw ClaudeCLIUsage.UnsupportedLogin(description: "Unsupported fixture login.")
    }, now: { fixture.now() })
    let result = await keeper.check(account: account)
    #expect(result.error == "Unsupported fixture login.")
    #expect(result.nextCheck == nil)
}

@Test func cancellingRenewalStopsTheSubprocess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fake-claude")
    try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let start = Date()
    let task = Task { try await ClaudeCLIUsage.run(executable: script, environment: [:], directory: root) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func credentialMetadataParsing() throws {
    let data = Data(#"{"claudeAiOauth":{"accessToken":"fixture","refreshToken":"refresh","expiresAt":1800000000000,"refreshTokenExpiresAt":1801000000000}}"#.utf8)
    let value = try #require(ClaudeCredentials.parse(data, source: .file))
    #expect(value.expiresAt == testEpoch)
    #expect(value.refreshTokenExpiresAt == Date(timeIntervalSince1970: 1_801_000_000))
    #expect(value.hasRefreshToken)
    #expect(ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8), source: .file) == nil)
}

@Test func cliEnvironmentTargetsSelectedLoginAndRemovesAuthOverrides() throws {
    let inherited = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "private-sentinel",
                     "CLAUDE_CODE_OAUTH_TOKEN": "private-sentinel", "CLAUDE_CONFIG_DIR": "/wrong",
                     "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/wrong", "CLAUDECODE": "1"]
    let account = AccountConfig(name: "Default", provider: .claude, dir: "~/.claude")
    let standard = try ClaudeCLIUsage.environment(account: account,
        source: .keychain("Claude Code-credentials"), inherited: inherited)
    #expect(standard["CLAUDE_CONFIG_DIR"] == nil)
    #expect(standard["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "")
    #expect(standard["ANTHROPIC_API_KEY"] == nil)
    #expect(standard["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(standard["CLAUDECODE"] == nil)
    let explicit = try ClaudeCLIUsage.environment(account: account,
        source: .keychain(ClaudeProvider.hashedService(account.expandedDir)), inherited: inherited)
    #expect(explicit["CLAUDE_CONFIG_DIR"] == account.expandedDir)
    #expect(explicit["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == account.expandedDir)
    let other = AccountConfig(name: "Other", provider: .claude, dir: "/fixture/other")
    let file = try ClaudeCLIUsage.environment(account: other, source: .file, inherited: inherited)
    #expect(file["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == other.expandedDir)
    #expect(throws: ClaudeCLIUsage.UnsupportedLogin.self) {
        try ClaudeCLIUsage.environment(account: other, source: .keychain("arbitrary"), inherited: inherited)
    }
}

@Test func cliSubprocessHasBoundedRuntimeAndPrivateErrors() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fake-claude")
    try "#!/bin/sh\necho PRIVATE_OUTPUT_SENTINEL >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    do {
        try await ClaudeCLIUsage.run(executable: script, environment: [:], directory: root)
        Issue.record("A failing command was accepted")
    } catch {
        #expect(!String(describing: error).contains("PRIVATE_OUTPUT_SENTINEL"))
    }
    try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: script, atomically: true, encoding: .utf8)
    let start = Date()
    do {
        try await ClaudeCLIUsage.run(executable: script, environment: [:], directory: root, timeout: 0.1)
        Issue.record("A hung command was accepted")
    } catch {
        #expect(String(describing: error).contains("timed out"))
    }
    #expect(Date().timeIntervalSince(start) < 5)
}

/// Opt-in end-to-end probe, driven by tests/check_claude_renewal.py with a local OAuth server.
/// It must never select a real login or send real credentials to the fixture server.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AI_USAGE_CLAUDE_RENEWAL_FIXTURE"] != nil))
func renewalWithInstalledClaudeFixture() async throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(env["AI_USAGE_CLAUDE_RENEWAL_FIXTURE"]))
    try #require(root.lastPathComponent.hasPrefix("ai-usage-renewal-fixture-"))
    let account = AccountConfig(name: "Fixture", provider: .claude, dir: root.path)
    let initial = try await ClaudeProvider(account: account).readCredentials()
    try #require(initial.accessToken == "fixture-access-old")
    let clock = RenewalFixture()
    clock.setNow(Date())
    let keeper = ClaudeSessionRenewal(runUsage: { account, source in
        let environment = try ClaudeCLIUsage.environment(account: account, source: source, inherited: env)
        let executable = try #require(ClaudeCLIUsage.executable(in: environment))
        try await ClaudeCLIUsage.run(executable: executable, environment: environment,
                                    directory: root.appendingPathComponent("work"))
    }, now: { clock.now() })
    let first = await keeper.check(account: account)
    #expect(first.renewed)
    #expect(first.error == nil)
    let saved = try await ClaudeProvider(account: account).readCredentials()
    #expect(saved.accessToken == "fixture-access-new-1")
    #expect(saved.refreshTokenExpiresAt == initial.refreshTokenExpiresAt)
    let deadline = try #require(first.nextCheck)
    #expect(deadline == saved.expiresAt?.addingTimeInterval(-240))
    #expect(!(await keeper.check(account: account)).renewed)

    clock.setNow(deadline.addingTimeInterval(1))
    let second = await keeper.check(account: account)
    #expect(second.renewed)
    let next = try await ClaudeProvider(account: account).readCredentials()
    #expect(next.accessToken == "fixture-access-new-2")
    #expect(second.nextCheck == next.expiresAt?.addingTimeInterval(-240))
    #expect(next.refreshTokenExpiresAt == initial.refreshTokenExpiresAt)
}
