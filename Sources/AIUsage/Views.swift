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
            if store.configError != nil {
                Text("AI ⚠")
            } else if store.accounts.isEmpty {
                Text("AI …")
            } else {
                Image(nsImage: MenuBarImage.render(store.menuBarSegments))
            }
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
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                    if let group = account.group, index == 0 || store.accounts[index - 1].group != group {
                        Text(group.uppercased())
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 0 : 6)
                    }
                    AccountCard(account: account, state: store.states[account.id], now: context.date)
                }
            }
            .padding(14)
            .frame(width: 380)
            .glassPanel(cornerRadius: PanelStyle.cornerRadius)
            .background(RoundedWindowCorners(radius: PanelStyle.cornerRadius))
        }
    }

    private var header: some View {
        HStack {
            Text("AI Usage").font(.headline)
            Spacer()
            if let last = store.lastRefresh {
                Text(last.formatted(date: .omitted, time: .shortened))
                    .font(.callout).foregroundStyle(.secondary)
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
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(store.isRefreshing)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit AI Usage")
        }
    }
}

struct AccountCard: View {
    let account: AccountConfig
    let state: AccountState?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIconView(provider: account.provider)
                Text(account.name).font(.body.weight(.semibold))
                Spacer()
                if let used = state?.snapshot?.maxUsedPercent {
                    Text("\(Int(used.rounded()))%")
                        .font(.body.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(color(forUsed: used))
                }
            }

            if let snapshot = state?.snapshot {
                Text([snapshot.identity, snapshot.plan].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ForEach(snapshot.windows) { window in
                    WindowRow(window: window, now: now)
                }
                if snapshot.windows.isEmpty {
                    Text("No limits reported").font(.callout).foregroundStyle(.secondary)
                }
                if snapshot.staleReason != nil {
                    Text("Cached data from \(snapshot.fetchedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if state == nil {
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
            if let error = state?.error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct ProviderIconView: View {
    let provider: Provider
    private static let height: CGFloat = 14
    private static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        let size = ProviderIcon.size(for: provider, height: Self.height)
        Image(nsImage: ProviderIcon.image(for: provider, height: Self.height))
            .renderingMode(.template)
            .foregroundStyle(provider == .claude ? Self.claudeOrange : Color.primary)
            .frame(width: size.width, height: size.height)
            // Same slot width for every provider so account names line up.
            .frame(width: ProviderIcon.size(for: .claude, height: Self.height).width)
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(window.label).font(.callout)
                Spacer()
                if let reset = window.resetsAt {
                    Text(resetText(reset))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .help("Resets " + reset.formatted(date: .complete, time: .shortened))
                }
                Text("\(Int(window.displayUsedPercent.rounded()))%")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color(forUsed: window.displayUsedPercent))
                        .frame(width: proxy.size.width * window.displayUsedPercent / 100)
                }
            }
            .frame(height: 6)
            if let detail = window.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func resetText(_ date: Date) -> String {
        if window.resetIsEstimate {
            return "↻ ~" + date.formatted(.dateTime.day().month(.abbreviated))
        }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return "↻ \(days)d \(hours)h" }
        if hours > 0 { return "↻ \(hours)h \(minutes)m" }
        return "↻ \(minutes)m"
    }
}

func color(forUsed used: Double) -> Color {
    switch used {
    case 90...: .red
    case 75...: .orange
    default: .green
    }
}

enum LoginItem {
    private static let setupKey = "didSetUpLoginItem"

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AIUsage: could not change login item: \(error.localizedDescription)")
        }
    }

    /// Turns on launch at login once, so turning it off in System Settings sticks.
    static func enableOnFirstLaunch() {
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: setupKey) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: setupKey)
    }
}
