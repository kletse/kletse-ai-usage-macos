import AppKit
import SwiftUI

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
            print("== \(account.name)\(account.short.map { " (\($0))" } ?? "")")
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

/// `AIUsage --render-menubar out.png` writes the menu bar image at 4x, for checking the layout.
if let index = CommandLine.arguments.firstIndex(of: "--render-menubar"), index + 1 < CommandLine.arguments.count {
    let segments: [MenuBarSegment] = [
        .account(.claude, "96%"), .account(.codex, "50%"), .separator, .account(.claude, "5%"), .account(.codex, "1%"),
    ]
    let image = MenuBarImage.render(segments)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 4), pixelsHigh: Int(image.size.height * 4),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

/// `AIUsage --render-panel out.png` fetches live data and writes the dropdown at 2x.
if let index = CommandLine.arguments.firstIndex(of: "--render-panel"), index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    await MainActor.run { _ = NSApplication.shared }
    let store = UsageStore()
    await store.refresh()
    await MainActor.run {
        let renderer = ImageRenderer(content: UsagePanel(store: store).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    await dump()
    exit(0)
}

AIUsageApp.main()
