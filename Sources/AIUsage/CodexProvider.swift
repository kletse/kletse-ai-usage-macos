import Foundation

/// Reads the Codex CLI's ChatGPT login from `$CODEX_HOME/auth.json` (read-only) and asks the
/// usage endpoint behind `/status`. It never refreshes the token; the Codex CLI does that itself.
struct CodexProvider: Sendable {
    let account: AccountConfig

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch() async throws -> UsageSnapshot {
        let auth: Auth
        do {
            auth = try readAuth()
        } catch {
            return try sessionLogSnapshot(reason: "\(error)")
        }
        if let expiresAt = auth.expiresAt, expiresAt < Date() {
            return try sessionLogSnapshot(reason: "Token expired. Run Codex to refresh it.", auth: auth)
        }

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("ai-usage", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await sharedSession.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            let usage = try JSONDecoder().decode(CodexUsage.self, from: data)
            return UsageSnapshot(
                windows: usage.windows(),
                identity: auth.email,
                plan: Self.planName(usage.plan_type ?? auth.plan),
                fetchedAt: Date()
            )
        case 401, 403:
            return try sessionLogSnapshot(reason: "Token rejected. Run Codex to refresh it.", auth: auth)
        case 429:
            throw FetchError("Rate limited by ChatGPT", retryAfter: http.map(retryAfterDate))
        case let code:
            throw FetchError("ChatGPT returned HTTP \(code)")
        }
    }

    // MARK: - auth.json

    private struct Auth {
        var accessToken: String
        var accountID: String?
        var email: String?
        var plan: String?
        var expiresAt: Date?
    }

    private func readAuth() throws -> Auth {
        let path = account.expandedDir + "/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
        else {
            throw FetchError("No ChatGPT login in \(account.dir)/auth.json")
        }

        var auth = Auth(accessToken: accessToken, accountID: tokens["account_id"] as? String)
        if let claims = jwtClaims(accessToken), let exp = claims["exp"] as? Double {
            auth.expiresAt = Date(timeIntervalSince1970: exp)
        }
        if let idToken = tokens["id_token"] as? String, let claims = jwtClaims(idToken) {
            auth.email = claims["email"] as? String
            let openAI = claims["https://api.openai.com/auth"] as? [String: Any]
            auth.plan = openAI?["chatgpt_plan_type"] as? String
            if auth.accountID == nil { auth.accountID = openAI?["chatgpt_account_id"] as? String }
        }
        return auth
    }

    // MARK: - Session log fallback

    /// Codex writes a `rate_limits` snapshot into its session logs after each turn.
    private func sessionLogSnapshot(reason: String, auth: Auth? = nil) throws -> UsageSnapshot {
        // The newest log may be a session that hasn't finished a turn yet, so look at a few.
        for (file, modified) in newestSessionFiles(limit: 5) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(SessionEntry.self, from: data),
                      let limits = entry.payload?.rate_limits
                else { continue }
                let windows = [limits.primary, limits.secondary].compactMap { window -> UsageWindow? in
                    guard let window, let used = window.used_percent else { return nil }
                    return UsageWindow(
                        label: CodexUsage.label(seconds: (window.window_minutes ?? 0) * 60),
                        usedPercent: used,
                        resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) },
                        period: window.window_minutes.map { TimeInterval($0 * 60) }
                    )
                }
                return UsageSnapshot(
                    windows: windows,
                    identity: auth?.email,
                    plan: Self.planName(limits.plan_type ?? auth?.plan),
                    fetchedAt: Dates.parseISO(entry.timestamp) ?? modified,
                    staleReason: reason
                )
            }
        }
        throw FetchError(reason)
    }

    private func newestSessionFiles(limit: Int) -> [(URL, Date)] {
        let root = URL(fileURLWithPath: account.expandedDir + "/sessions").resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
            files.append((url, date))
        }
        return Array(files.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    private struct SessionEntry: Decodable {
        struct Payload: Decodable { var rate_limits: Limits? }
        struct Limits: Decodable {
            var primary: Window?
            var secondary: Window?
            var plan_type: String?
        }
        struct Window: Decodable {
            var used_percent: Double?
            var window_minutes: Int?
            var resets_at: Double?
        }

        var timestamp: String?
        var payload: Payload?
    }

    private static func planName(_ raw: String?) -> String? {
        switch raw {
        case "prolite": "Pro Lite"
        case let other?: other.capitalized
        case nil: nil
        }
    }
}

// MARK: - Response model

struct CodexUsage: Decodable {
    struct Window: Decodable {
        var used_percent: Double?
        var limit_window_seconds: Int?
        var reset_at: Double?
    }

    struct RateLimit: Decodable {
        var primary_window: Window?
        var secondary_window: Window?
    }

    struct Additional: Decodable {
        var limit_name: String?
        var rate_limit: RateLimit?
    }

    var plan_type: String?
    var rate_limit: RateLimit?
    var additional_rate_limits: [Additional]?

    func windows() -> [UsageWindow] {
        var result = Self.windows(from: rate_limit, prefix: nil)
        for extra in additional_rate_limits ?? [] {
            result += Self.windows(from: extra.rate_limit, prefix: extra.limit_name)
        }
        return result
    }

    private static func windows(from limit: RateLimit?, prefix: String?) -> [UsageWindow] {
        [limit?.primary_window, limit?.secondary_window].compactMap { window in
            guard let window, let used = window.used_percent else { return nil }
            let label = Self.label(seconds: window.limit_window_seconds ?? 0)
            return UsageWindow(
                label: prefix.map { "\(label) · \($0)" } ?? label,
                usedPercent: used,
                resetsAt: window.reset_at.map { Date(timeIntervalSince1970: $0) },
                period: window.limit_window_seconds.map(TimeInterval.init)
            )
        }
    }

    static func label(seconds: Int) -> String {
        switch seconds {
        case 18_000: "5-hour"
        case 604_800: "Week"
        case let s where s > 0 && s % 86_400 == 0: "\(s / 86_400)-day"
        case let s where s > 0: "\(s / 3_600)-hour"
        default: "Limit"
        }
    }
}
