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
                MenuBarLabel(segments: store.menuBarSegments, preview: store.animationPreview)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item's colour scheme follows the menu bar, which can differ from the system's.
/// Claude mascots play an animation when their usage changes, and previews from the Accounts window.
private struct MenuBarLabel: View {
    let segments: [MenuBarSegment]
    let preview: AnimationPreview?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MenuBarSettings.colorKey) private var colorIcon = true
    @AppStorage(MenuBarSettings.animateKey) private var animate = true
    /// What each animating mascot, by segment index, is playing and since when.
    @State private var playing: [Int: (animation: ClawdAnimation, start: Date)] = [:]
    @State private var now = Date()
    @State private var ticker: Task<Void, Never>?
    /// `segments` as of now, for the long-running fidget loop, which would otherwise keep the first.
    @State private var current: [MenuBarSegment] = []

    var body: some View {
        Image(nsImage: MenuBarImage.render(segments, dark: colorScheme == .dark, poses: poses, colorClaude: colorIcon))
            .onChange(of: segments) { old, new in
                current = new
                animate(changedFrom: old, to: new)
            }
            .task {
                current = segments
                await fidget()
            }
            .onChange(of: preview) { _, preview in
                // A preview was asked for, so it plays even with animations or Reduce Motion off.
                guard let preview else { return }
                let claudes = segments.indices.filter { isClaude(segments[$0]) }
                play(preview.animation.map { animation in
                    Dictionary(uniqueKeysWithValues: claudes.map { ($0, animation) })
                } ?? ClawdAnimation.assign(to: claudes))
            }
    }

    private var poses: [Int: ClawdPose] {
        playing.mapValues { $0.animation.pose(at: now.timeIntervalSince($0.start)) }
    }

    private func isClaude(_ segment: MenuBarSegment) -> Bool {
        if case .account(.claude, _) = segment { true } else { false }
    }

    private func animate(changedFrom old: [MenuBarSegment], to new: [MenuBarSegment]) {
        // Indexes only line up while the account list is the same length.
        guard animate, old.count == new.count, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let changed = new.indices.filter { index in
            guard case .account(.claude, let text) = new[index], case .account(.claude, let previous) = old[index]
            else { return false }
            return text != previous && text != "–"
        }
        play(ClawdAnimation.assign(to: changed))
    }

    /// About every ten minutes, one mascot picked at random animates for no reason.
    private func fidget() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(.random(in: 7 * 60...13 * 60)))
            let claudes = current.indices.filter { isClaude(current[$0]) }
            guard animate, playing.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  let index = claudes.randomElement(), let animation = ClawdAnimation.allCases.randomElement()
            else { continue }
            play([index: animation])
        }
    }

    private func play(_ animations: [Int: ClawdAnimation]) {
        guard !animations.isEmpty else { return }
        let start = Date()
        for (index, animation) in animations { playing[index] = (animation, start) }
        now = start
        guard ticker == nil else { return }
        ticker = Task {
            while !playing.isEmpty {
                try? await Task.sleep(for: .milliseconds(33))
                now = Date()
                playing = playing.filter { now.timeIntervalSince($0.value.start) < $0.value.animation.duration }
            }
            ticker = nil
        }
    }
}

struct UsagePanel: View {
    let store: UsageStore
    /// Glass and window rounding. Off for offscreen renders, which can't draw either.
    var windowChrome = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                header
                if let error = store.configError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if store.accounts.isEmpty && store.configError == nil {
                    Text("No accounts configured. Open Accounts to add a Claude or Codex login.")
                        .font(.callout).foregroundStyle(.secondary)
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
            .modifier(WindowChrome(enabled: windowChrome))
        }
    }

    private struct WindowChrome: ViewModifier {
        let enabled: Bool

        func body(content: Content) -> some View {
            if enabled {
                content
                    .glassPanel()
                    .background(RoundedWindowCorners(radius: PanelStyle.cornerRadius))
            } else {
                content
            }
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
                // The click came from the dropdown, so it is the key window; close it like a menu.
                NSApp.keyWindow?.close()
                AccountsWindowController.show(store: store)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Edit accounts")
            .accessibilityLabel("Edit accounts")
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
    private static let nameCapHeight = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                                                         weight: .semibold).capHeight

    let account: AccountConfig
    let state: AccountState?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Center the icon on the name's capital letters rather than its line box.
                ProviderIconView(provider: account.provider)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.nameCapHeight / 2 }
                Text(account.name).font(.body.weight(.semibold))
                Spacer()
                if let used = state?.snapshot?.headlineWindow?.displayUsedPercent {
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
        .cardBackground()
    }
}

struct ProviderIconView: View {
    let provider: Provider
    var height: CGFloat = 14
    private static let claudeOrange = Color(nsColor: ProviderIcon.claudeOrange)

    var body: some View {
        let size = ProviderIcon.size(for: provider, height: height)
        Image(nsImage: ProviderIcon.image(for: provider, height: height))
            .renderingMode(.template)
            .foregroundStyle(provider == .claude ? Self.claudeOrange : Color.primary)
            .background {
                if provider == .claude {
                    Image(nsImage: ProviderIcon.clawdEyes(height: height))
                        .renderingMode(.template)
                        .foregroundStyle(.black)
                }
            }
            .frame(width: size.width, height: size.height)
            // Same slot width for every provider so account names line up.
            .frame(width: ProviderIcon.size(for: .claude, height: height).width)
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
