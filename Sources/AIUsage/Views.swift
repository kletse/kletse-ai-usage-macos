import AppKit
import ServiceManagement
import SwiftUI

struct AIUsageApp: App {
    @State private var store = UsageStore()

    init() {
        LoginItem.enableOnFirstLaunch()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            Text(store.menuBarText).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

struct UsagePanel: View {
    let store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                header
                if let error = store.configError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ForEach(store.accounts) { account in
                    AccountCard(account: account, state: store.states[account.id], now: context.date)
                }
                Divider()
                Footer()
            }
            .padding(12)
            .frame(width: 360)
        }
    }

    private var header: some View {
        HStack {
            Text("AI Usage").font(.headline)
            Spacer()
            if let last = store.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(store.isRefreshing)
        }
    }
}

struct AccountCard: View {
    let account: AccountConfig
    let state: AccountState?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.short)
                    .font(.caption.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Text(account.name).font(.subheadline.weight(.semibold))
                Spacer()
                if let remaining = state?.snapshot?.remainingPercent {
                    Text("\(Int(remaining.rounded()))% left")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(color(forRemaining: remaining))
                }
            }

            if let snapshot = state?.snapshot {
                Text([snapshot.identity, snapshot.plan].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(snapshot.windows) { window in
                    WindowRow(window: window, now: now)
                }
                if snapshot.windows.isEmpty {
                    Text("No limits reported").font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.staleReason != nil {
                    Text("Cached data from \(snapshot.fetchedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else if state == nil {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = state?.error {
                Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.caption)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.caption.weight(.medium)).monospacedDigit()
                if let reset = window.resetsAt {
                    Text(resetText(reset))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help(reset.formatted(date: .complete, time: .shortened))
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color(forRemaining: window.remainingPercent))
                        .frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }
            .frame(height: 5)
            if let detail = window.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func resetText(_ date: Date) -> String {
        if window.resetIsEstimate {
            return "resets ~" + date.formatted(.dateTime.month(.abbreviated).day())
        }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }
}

struct Footer: View {
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox).font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    LoginItem.set(enabled)
                    launchAtLogin = LoginItem.isEnabled
                }
            Spacer()
            Button("Edit accounts") {
                NSWorkspace.shared.open(URL(fileURLWithPath: AppConfig.path))
            }
            .font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.caption)
        }
    }
}

func color(forRemaining remaining: Double) -> Color {
    switch remaining {
    case ..<10: .red
    case ..<25: .orange
    default: .green
    }
}

enum LoginItem {
    private static let setupKey = "didSetUpLoginItem"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AIUsage: could not change login item: \(error.localizedDescription)")
        }
    }

    /// Turns on launch at login once; after that the checkbox is the source of truth.
    static func enableOnFirstLaunch() {
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: setupKey) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: setupKey)
    }
}
