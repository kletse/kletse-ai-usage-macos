import Foundation

func fetchSnapshot(for account: AccountConfig) async throws -> UsageSnapshot {
    switch account.provider {
    case .claude: try await ClaudeProvider(account: account).fetch()
    case .codex: try await CodexProvider(account: account).fetch()
    }
}

/// `AIUsage --dump` prints what the app would show, for debugging. It never prints tokens.
func dump() async {
    do {
        for account in try AppConfig.load() {
            print("== \(account.short) (\(account.name))")
            do {
                let snapshot = try await fetchSnapshot(for: account)
                print("  \(snapshot.identity ?? "?") · \(snapshot.plan ?? "?") · fetched \(snapshot.fetchedAt)")
                if let stale = snapshot.staleReason { print("  stale: \(stale)") }
                for window in snapshot.windows {
                    let reset = window.resetsAt.map { "resets \($0)\(window.resetIsEstimate ? " (est.)" : "")" } ?? ""
                    print("  \(window.label): \(Int(window.displayUsedPercent.rounded()))% used \(window.detail ?? "") \(reset)")
                }
                print("  => \(snapshot.maxUsedPercent.map { "\(Int($0.rounded()))% used" } ?? "no limits")")
            } catch {
                print("  error: \(error)")
            }
        }
    } catch {
        print("config error: \(error)")
    }
}

if CommandLine.arguments.contains("--dump") {
    await dump()
    exit(0)
}

AIUsageApp.main()
