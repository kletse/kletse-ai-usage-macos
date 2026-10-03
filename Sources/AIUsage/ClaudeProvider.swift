import CryptoKit
import Foundation

/// Reads Claude Code's own OAuth login (read-only) and asks the usage endpoint that `/usage` uses.
/// It never refreshes the token: refreshing rotates the refresh token and would log the CLI out.
struct ClaudeProvider: Sendable {
    let account: AccountConfig

    private static let defaultDir = expandTilde("~/.claude")
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Claude Code stores credentials under "Claude Code-credentials", plus "-<first 8 hex chars of
    /// sha256(config dir)>" when `CLAUDE_CONFIG_DIR` is set.
    var keychainService: String {
        if let override = account.keychainService { return override }
        let dir = account.expandedDir
        if dir == Self.defaultDir { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    /// `~/.claude.json` for the default login, `$CLAUDE_CONFIG_DIR/.claude.json` otherwise.
    var stateFile: String {
        let dir = account.expandedDir
        return dir == Self.defaultDir ? expandTilde("~/.claude.json") : dir + "/.claude.json"
    }

    func fetch() async throws -> UsageSnapshot {
        let state = readState()
        let credentials: Credentials
        do {
            credentials = try await readCredentials()
        } catch {
            return try cached(state, reason: "\(error)")
        }
        if let expiresAt = credentials.expiresAt, expiresAt < Date() {
            return try cached(state, reason: "Token expired. Open Claude Code to refresh it.")
        }

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await sharedSession.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            let usage = try JSONDecoder().decode(ClaudeUsage.self, from: data)
            return UsageSnapshot(
                windows: usage.windows(),
                identity: state.identity,
                plan: state.plan ?? credentials.subscriptionType?.capitalized,
                fetchedAt: Date()
            )
        case 401:
            return try cached(state, reason: "Token rejected. Open Claude Code to refresh it.")
        case 429:
            throw FetchError("Rate limited by Anthropic", retryAfter: http.map(retryAfterDate))
        case let code:
            throw FetchError("Anthropic returned HTTP \(code)")
        }
    }

    // MARK: - Credentials

    private struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
    }

    private func readCredentials() async throws -> Credentials {
        var blob = try? await Keychain.readGenericPassword(service: keychainService)
        if blob == nil {
            // Some setups store credentials in a file instead of the keychain.
            blob = try? Data(contentsOf: URL(fileURLWithPath: account.expandedDir + "/.credentials.json"))
        }
        guard let blob,
              let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw FetchError("No Claude Code login found (keychain \"\(keychainService)\")")
        }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expiresAt, subscriptionType: oauth["subscriptionType"] as? String)
    }

    // MARK: - .claude.json (account info and Claude Code's own usage cache)

    private struct State {
        var identity: String?
        var plan: String?
        var cachedUsage: ClaudeUsage?
        var cachedAt: Date?
    }

    private func readState() -> State {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return State() }

        var state = State()
        if let oauth = json["oauthAccount"] as? [String: Any] {
            state.identity = oauth["emailAddress"] as? String
            state.plan = Self.planName(organizationType: oauth["organizationType"] as? String)
        }
        if let cache = json["cachedUsageUtilization"] as? [String: Any],
           let utilization = cache["utilization"],
           let usageData = try? JSONSerialization.data(withJSONObject: utilization) {
            state.cachedUsage = try? JSONDecoder().decode(ClaudeUsage.self, from: usageData)
            if let ms = cache["fetchedAtMs"] as? Double {
                state.cachedAt = Date(timeIntervalSince1970: ms / 1000)
            }
        }
        return state
    }

    private func cached(_ state: State, reason: String) throws -> UsageSnapshot {
        guard let usage = state.cachedUsage, let at = state.cachedAt else { throw FetchError(reason) }
        return UsageSnapshot(windows: usage.windows(), identity: state.identity, plan: state.plan, fetchedAt: at, staleReason: reason)
    }

    private static func planName(organizationType: String?) -> String? {
        switch organizationType {
        case "claude_max": "Max"
        case "claude_pro": "Pro"
        case "claude_team": "Team"
        case "claude_enterprise": "Enterprise"
        case let other?: other.replacingOccurrences(of: "claude_", with: "").capitalized
        case nil: nil
        }
    }
}

// MARK: - Response model

struct ClaudeUsage: Decodable {
    struct Window: Decodable {
        var utilization: Double?
        var resets_at: String?
    }

    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { var display_name: String? }
            var model: Model?
        }

        var kind: String?
        var group: String?
        var percent: Double?
        var resets_at: String?
        var scope: Scope?
    }

    struct Money: Decodable {
        var amount_minor: Double?
        var currency: String?
        var exponent: Int?
    }

    struct Spend: Decodable {
        var used: Money?
        var limit: Money?
        var percent: Double?
        var enabled: Bool?
    }

    struct ExtraUsage: Decodable {
        var is_enabled: Bool?
        var monthly_limit: Double?
        var used_credits: Double?
        var utilization: Double?
        var currency: String?
    }

    var five_hour: Window?
    var seven_day: Window?
    var seven_day_opus: Window?
    var seven_day_sonnet: Window?
    var limits: [Limit]?
    var spend: Spend?
    var extra_usage: ExtraUsage?

    func windows() -> [UsageWindow] {
        var result: [UsageWindow] = []

        if let limits, !limits.isEmpty {
            for limit in limits {
                guard let percent = limit.percent else { continue }
                result.append(UsageWindow(label: Self.label(for: limit), usedPercent: percent, resetsAt: Dates.parseISO(limit.resets_at),
                                          period: Self.period(for: limit)))
            }
        } else {
            let legacy: [(String, TimeInterval, Window?)] = [
                ("Session", Self.session, five_hour), ("Week", Self.week, seven_day),
                ("Week · Opus", Self.week, seven_day_opus), ("Week · Sonnet", Self.week, seven_day_sonnet),
            ]
            for (label, period, window) in legacy {
                guard let window, let used = window.utilization else { continue }
                result.append(UsageWindow(label: label, usedPercent: used, resetsAt: Dates.parseISO(window.resets_at), period: period))
            }
        }

        // Spend cap, e.g. the Enterprise monthly limit. The API gives no reset date, so assume the 1st.
        if let spend, spend.enabled == true, let limit = spend.limit?.amount_minor, limit > 0 {
            let used = spend.used?.amount_minor ?? 0
            let exponent = spend.limit?.exponent ?? 2
            let currency = spend.limit?.currency ?? spend.used?.currency ?? "USD"
            result.append(UsageWindow(
                label: "Monthly spend",
                usedPercent: used / limit * 100,
                resetsAt: Dates.startOfNextMonth(),
                detail: "\(Self.money(used, exponent: exponent, currency: currency)) of \(Self.money(limit, exponent: exponent, currency: currency))",
                resetIsEstimate: true,
                period: Self.month
            ))
        } else if let extra = extra_usage, extra.is_enabled == true, let limit = extra.monthly_limit, limit > 0 {
            let used = extra.used_credits ?? 0
            let currency = extra.currency ?? "USD"
            result.append(UsageWindow(
                label: "Monthly spend",
                usedPercent: extra.utilization ?? used / limit * 100,
                resetsAt: Dates.startOfNextMonth(),
                detail: "\(Self.money(used, exponent: 2, currency: currency)) of \(Self.money(limit, exponent: 2, currency: currency))",
                resetIsEstimate: true,
                period: Self.month
            ))
        }
        return result
    }

    private static let session: TimeInterval = 5 * 3_600
    private static let week: TimeInterval = 7 * 86_400
    private static let month: TimeInterval = 30 * 86_400

    private static func period(for limit: Limit) -> TimeInterval? {
        switch limit.kind {
        case "session": session
        case "weekly_all", "weekly_scoped": week
        default: nil
        }
    }

    private static func label(for limit: Limit) -> String {
        let base: String = switch limit.kind {
        case "session": "Session"
        case "weekly_all": "Week"
        case "weekly_scoped": "Week"
        default: (limit.group ?? limit.kind ?? "Limit").replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let model = limit.scope?.model?.display_name { return "\(base) · \(model)" }
        return base
    }

    private static func money(_ minor: Double, exponent: Int, currency: String) -> String {
        let amount = minor / pow(10, Double(exponent))
        return amount.formatted(.currency(code: currency))
    }
}
