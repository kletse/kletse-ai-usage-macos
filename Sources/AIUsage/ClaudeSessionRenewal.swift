import Darwin
import Foundation
import os
import OSLog

struct ClaudeRenewalCheck: Sendable {
    var nextCheck: Date?
    var error: String?
    var renewed = false
    /// The login as this check last read it, so the usage fetch that follows needn't read the
    /// Keychain again. Nil when it could not be read or may have changed since.
    var credentials: ClaudeCredentials?
}

/// Owns scheduling state, never credentials on disk. Claude Code performs all token writes.
actor ClaudeSessionRenewal {
    static let leadTime: TimeInterval = 4 * 60
    static let log = Logger(subsystem: "be.kletse.ai-usage", category: "claude-renewal")

    private struct Failure {
        var expiry: Date
        var count: Int
        var retryAt: Date
        var message: String
    }

    private let read: @Sendable (AccountConfig) async throws -> ClaudeCredentials
    private let runUsage: @Sendable (AccountConfig, ClaudeCredentials.Source) async throws -> Void
    private let now: @Sendable () -> Date
    private var failures: [String: Failure] = [:]
    private var inFlight: Set<String> = []

    init(
        read: @escaping @Sendable (AccountConfig) async throws -> ClaudeCredentials = {
            try await ClaudeProvider(account: $0).readCredentials()
        },
        runUsage: @escaping @Sendable (AccountConfig, ClaudeCredentials.Source) async throws -> Void = {
            try await ClaudeCLIUsage.run(account: $0, source: $1)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.read = read
        self.runUsage = runUsage
        self.now = now
    }

    private nonisolated func scope(_ account: AccountConfig) -> String {
        account.expandedDir + "|" + (account.keychainService ?? "")
    }

    func check(accounts: [AccountConfig]) async -> [String: ClaudeRenewalCheck] {
        let claude = accounts.filter { $0.provider == .claude }
        let active = Set(claude.map(scope))
        failures = failures.filter { active.contains($0.key) }
        // One check per login, all at once: a hung CLI for one login must not hold up the rest.
        let logins = Dictionary(grouping: claude) { scope($0) }
        return await withTaskGroup(of: ([String], ClaudeRenewalCheck).self) { group in
            for accounts in logins.values {
                group.addTask { (accounts.map(\.id), await self.check(account: accounts[0])) }
            }
            var results: [String: ClaudeRenewalCheck] = [:]
            for await (ids, check) in group {
                for id in ids { results[id] = check }
            }
            return results
        }
    }

    /// `account` must be a Claude account; `check(accounts:)` filters for that.
    func check(account: AccountConfig) async -> ClaudeRenewalCheck {
        let key = scope(account)
        if inFlight.contains(key) {
            return ClaudeRenewalCheck(nextCheck: now().addingTimeInterval(30))
        }
        // Cover the credential read too: a concurrent caller must not act on an old read
        // after another caller has already completed renewal.
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let credentials: ClaudeCredentials
        do {
            credentials = try await read(account)
        } catch {
            // Missing/unreadable credentials never trigger a CLI login or browser flow. Nothing
            // is being retried either, so an earlier renewal failure no longer applies.
            failures[key] = nil
            return ClaudeRenewalCheck()
        }
        guard let expiry = credentials.expiresAt else { return ClaudeRenewalCheck(credentials: credentials) }
        let current = now()
        if failures[key]?.expiry != expiry { failures[key] = nil }
        let deadline = expiry.addingTimeInterval(-Self.leadTime)
        if deadline > current { return ClaudeRenewalCheck(nextCheck: deadline, credentials: credentials) }
        // Only a login that now needs renewing is worth a warning; until then usage still loads.
        guard credentials.hasRefreshToken else {
            return ClaudeRenewalCheck(error: "Claude login cannot renew automatically. Run claude auth login.",
                                      credentials: credentials)
        }
        if let finalExpiry = credentials.refreshTokenExpiresAt, finalExpiry <= current {
            return ClaudeRenewalCheck(error: "Claude login expired. Run claude auth login.", credentials: credentials)
        }
        if let failure = failures[key], failure.retryAt > current {
            return ClaudeRenewalCheck(nextCheck: failure.retryAt, error: failure.message, credentials: credentials)
        }
        do {
            try await runUsage(account, credentials.source)
            // Exit code zero does not prove renewal: even invalid_grant can exit successfully.
            let updated = try await read(account)
            guard let nextExpiry = updated.expiresAt,
                  nextExpiry > expiry, nextExpiry > now(),
                  updated.accessToken != credentials.accessToken else {
                throw FetchError("Claude renewal did not advance the saved token expiry.")
            }
            failures[key] = nil
            Self.log.notice("Claude renewal confirmed; saved access expiry: \(nextExpiry.timeIntervalSince1970, privacy: .public)")
            // A very short server lifetime still gets a bounded retry rather than a busy loop.
            return ClaudeRenewalCheck(nextCheck: max(now().addingTimeInterval(5),
                                                     nextExpiry.addingTimeInterval(-Self.leadTime)),
                                      renewed: true, credentials: updated)
        } catch is CancellationError {
            // Stopped by the caller, not a failed renewal: no backoff, the next check tries again.
            return ClaudeRenewalCheck()
        } catch let error as ClaudeCLIUsage.UnsupportedLogin {
            // Retrying can't help, so no backoff or extra wake-up: the regular poll rechecks it.
            failures[key] = nil
            return ClaudeRenewalCheck(error: error.description, credentials: credentials)
        } catch {
            let count = min((failures[key]?.count ?? 0) + 1, 5)
            let retryAt = now().addingTimeInterval(min(300, 30 * pow(2, Double(count - 1))))
            // Never display subprocess output, credential blobs, or arbitrary error descriptions.
            let message = (error as? FetchError)?.description
                ?? "Could not verify Claude renewal. Retrying automatically."
            failures[key] = Failure(expiry: expiry, count: count, retryAt: retryAt, message: message)
            return ClaudeRenewalCheck(nextCheck: retryAt, error: message)
        }
    }
}

enum ClaudeCLIUsage {
    /// A login the CLI can't be pointed at, so automatic renewal is not attempted.
    struct UnsupportedLogin: Error, CustomStringConvertible {
        let description: String
    }

    static let arguments = [
        "--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--tools", "", "--no-chrome", "--no-session-persistence", "-p", "/usage",
    ]

    /// Match the credential source actually selected by the provider, including the two default
    /// Keychain names. GUI launches often have a minimal PATH, so resolve the native install too.
    /// Throws `UnsupportedLogin` for a Keychain item the CLI has no way to select.
    static func environment(account: AccountConfig, source: ClaudeCredentials.Source,
                            inherited: [String: String]) throws -> [String: String] {
        var environment = inherited.filter {
            !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_") && $0.key != "CLAUDECODE"
        }
        let dir = account.expandedDir
        let isDefault = dir == expandTilde("~/.claude")
        environment["CLAUDE_CONFIG_DIR"] = dir
        switch source {
        case .file:
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = isDefault ? "" : dir
            if isDefault { environment.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        case .keychain(let service):
            if service == ClaudeProvider.hashedService(dir) {
                environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = dir
            } else if isDefault, service == "Claude Code-credentials" {
                // Empty explicitly selects Claude's unsuffixed default Keychain item.
                environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ""
                environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            } else {
                throw UnsupportedLogin(description: "Automatic renewal cannot target this custom Claude keychain service. Open Claude Code to renew it.")
            }
        }
        environment["CLAUDE_CODE_SAFE_MODE"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        return environment
    }

    static func executable(in environment: [String: String]) -> URL? {
        let candidates = [expandTilde("~/.local/bin/claude")]
            + (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func run(account: AccountConfig, source: ClaudeCredentials.Source) async throws {
        let environment = try environment(account: account, source: source,
                                          inherited: ProcessInfo.processInfo.environment)
        guard let executable = executable(in: environment) else {
            throw FetchError("Claude CLI was not found. Install Claude Code to enable automatic renewal.")
        }
        let directory = URL(fileURLWithPath: AppConfig.directory).appendingPathComponent("claude-renewal")
        try await run(executable: executable, environment: environment, directory: directory)
    }

    static func run(executable: URL, environment: [String: String], directory: URL,
                    timeout: TimeInterval = 30) async throws {
        // Signalled when the process exits, and also on cancellation to cut the wait short.
        let finished = DispatchSemaphore(value: 0)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    continuation.resume(throwing: FetchError("Could not prepare Claude renewal."))
                    return
                }
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = directory
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: FetchError("Could not launch Claude CLI for renewal."))
                    return
                }
                let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
                let wasCancelled = cancelled.withLock { $0 }
                if timedOut || wasCancelled {
                    // Either signal can arrive during these waits, so go by whether it still runs.
                    if process.isRunning {
                        process.terminate()
                        _ = finished.wait(timeout: .now() + 2)
                    }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                        _ = finished.wait(timeout: .now() + 2)
                    }
                    let error: any Error = wasCancelled ? CancellationError()
                        : FetchError("Claude CLI renewal timed out. Retrying automatically.")
                    continuation.resume(throwing: error)
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: FetchError("Claude CLI renewal failed. Retrying automatically; check your Claude Code login if it persists."))
                } else {
                    continuation.resume()
                }
            }
          }
        } onCancel: {
            cancelled.withLock { $0 = true }
            finished.signal()
        }
    }
}
