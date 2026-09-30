import Foundation
import Observation

struct AccountState: Sendable {
    var snapshot: UsageSnapshot?
    var error: String?
}

@MainActor
@Observable
final class UsageStore {
    static let refreshInterval: TimeInterval = 5 * 60

    private(set) var accounts: [AccountConfig] = []
    private(set) var states: [String: AccountState] = [:]
    private(set) var configError: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    /// Compact text for the menu bar, e.g. "CC 4% CCK 96% CO 50% COK 99%".
    var menuBarText: String {
        if configError != nil { return "AI ⚠" }
        if accounts.isEmpty { return "AI …" }
        return accounts.map { account in
            guard let remaining = states[account.id]?.snapshot?.remainingPercent else { return "\(account.short) –" }
            return "\(account.short) \(Int(remaining.rounded()))%"
        }.joined(separator: " ")
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Reload the config each time so edits apply without restarting.
        do {
            accounts = try AppConfig.load()
            configError = nil
        } catch {
            configError = "Could not read \(AppConfig.path): \(error.localizedDescription)"
            return
        }

        let now = Date()
        let due = accounts.filter { (retryAfter[$0.id] ?? .distantPast) <= now }
        let results = await withTaskGroup(of: (String, Result<UsageSnapshot, Error>).self) { group in
            for account in due {
                group.addTask {
                    do { return (account.id, .success(try await fetchSnapshot(for: account))) }
                    catch { return (account.id, .failure(error)) }
                }
            }
            var results: [(String, Result<UsageSnapshot, Error>)] = []
            for await result in group { results.append(result) }
            return results
        }

        for (id, result) in results {
            var state = states[id] ?? AccountState()
            switch result {
            case .success(let snapshot):
                // Don't replace fresher live data with an older cached copy.
                if snapshot.staleReason == nil || (state.snapshot?.fetchedAt ?? .distantPast) <= snapshot.fetchedAt {
                    state.snapshot = snapshot
                }
                state.error = snapshot.staleReason
                retryAfter[id] = nil
            case .failure(let error):
                state.error = (error as? FetchError)?.description ?? error.localizedDescription
                retryAfter[id] = (error as? FetchError)?.retryAfter
            }
            states[id] = state
        }
        // Forget accounts that were removed from the config.
        let ids = Set(accounts.map(\.id))
        states = states.filter { ids.contains($0.key) }
        lastRefresh = Date()
    }
}
