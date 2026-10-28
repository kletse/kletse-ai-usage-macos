import AppKit
import Foundation
import Observation

/// A request to play a mascot animation in the menu bar; each one is distinct, so repeats replay.
struct AnimationPreview: Equatable {
    let id = UUID()
    /// Nil picks a different one for each mascot, as a usage change does.
    let animation: ClawdAnimation?
}

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
    /// The latest animation preview asked for in the Accounts window.
    private(set) var animationPreview: AnimationPreview?

    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var wakeObserver: WakeObserver?
    @ObservationIgnored private var cache: SnapshotCache?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false

    /// A store with fixed data and no polling, for rendering screenshots.
    init(fixed: [(AccountConfig, UsageSnapshot)]) {
        accounts = fixed.map(\.0)
        states = Dictionary(uniqueKeysWithValues: fixed.map { ($0.0.id, AccountState(snapshot: $0.1)) })
        lastRefresh = Date()
    }

    init() {
        let cache = SnapshotCache(url: URL(fileURLWithPath: AppConfig.directory)
            .appendingPathComponent("snapshots.json"))
        self.cache = cache
        do {
            accounts = try AppConfig.load()
            states = cache.load(accounts: accounts).mapValues {
                AccountState(snapshot: $0)
            }
        } catch {
            configError = "Could not read \(AppConfig.path): \(error.localizedDescription)"
        }
        wakeObserver = WakeObserver { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    /// Plays `animation` on every Claude mascot in the menu bar, or a random one on each.
    func previewAnimation(_ animation: ClawdAnimation?) {
        animationPreview = AnimationPreview(animation: animation)
    }

    /// Menu bar content in config order: a provider icon plus the used percentage of the
    /// shortest-period limit per account, with a dot wherever the group changes.
    var menuBarSegments: [MenuBarSegment] {
        var segments: [MenuBarSegment] = []
        for (index, account) in accounts.enumerated() {
            if index > 0, account.group != accounts[index - 1].group { segments.append(.separator) }
            let used = states[account.id]?.snapshot?.headlineWindow?.displayUsedPercent
            segments.append(.account(account.provider, used.map { "\(Int($0.rounded()))%" } ?? "–"))
        }
        return segments
    }

    func refresh() async {
        // A refresh asked for mid-run runs again afterwards, so it sees a config saved meanwhile.
        guard !isRefreshing else { refreshQueued = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            await refreshOnce()
            lastRefresh = Date()
        } while refreshQueued
    }

    private func refreshOnce() async {
        // Reload the config each time so edits apply without restarting.
        do {
            let updated = try AppConfig.load()
            let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            let unchanged = Set(updated.filter {
                previous[$0.id]?.provider == $0.provider
                    && previous[$0.id]?.keychainService == $0.keychainService
            }.map(\.id))
            states = states.filter { unchanged.contains($0.key) }
            retryAfter = retryAfter.filter { unchanged.contains($0.key) }
            accounts = updated
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
        retryAfter = retryAfter.filter { ids.contains($0.key) }
        // Cache failures must not turn a successful fetch into an account error.
        try? cache?.save(accounts: accounts, snapshots: states.compactMapValues(\.snapshot))
    }
}

/// Owns the observer registration so fixed-data diagnostics never subscribe to wake events.
private final class WakeObserver {
    private let token: NSObjectProtocol

    init(onWake: @escaping @Sendable () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in onWake() }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
}
