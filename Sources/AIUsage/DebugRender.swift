import AppKit
import SwiftUI

/// Renders the menu bar item and the dropdown to PNG files, for checking the layout and for
/// README screenshots:
///   AIUsage --render-menubar out.png [--dark]
///   AIUsage --render-panel out.png [--sample] [--dark]
/// All diagnostic output uses made-up accounts. `--sample` is accepted for compatibility.
@MainActor
enum DebugRender {
    static func sampleStore() -> UsageStore {
        let now = Date()
        func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3_600) }
        func account(_ name: String, _ group: String, _ provider: Provider) -> AccountConfig {
            AccountConfig(name: name, group: group, provider: provider, dir: "~/.\(provider.rawValue)-\(group.lowercased())")
        }
        return UsageStore(fixed: [
            (account("Claude", "Work", .claude), UsageSnapshot(
                windows: [UsageWindow(label: "Monthly spend", usedPercent: 82, resetsAt: Dates.startOfNextMonth(),
                                      detail: "$410.00 of $500.00", resetIsEstimate: true)],
                identity: "you@company.com", plan: "Enterprise", fetchedAt: now)),
            (account("Codex", "Work", .codex), UsageSnapshot(
                windows: [UsageWindow(label: "5-hour", usedPercent: 12, resetsAt: hours(3.2)),
                          UsageWindow(label: "Week", usedPercent: 38, resetsAt: hours(70))],
                identity: "you@company.com", plan: "Team", fetchedAt: now)),
            (account("Claude", "Personal", .claude), UsageSnapshot(
                windows: [UsageWindow(label: "Session", usedPercent: 23, resetsAt: hours(2.6)),
                          UsageWindow(label: "Week", usedPercent: 41, resetsAt: hours(121)),
                          UsageWindow(label: "Week · Fable", usedPercent: 18, resetsAt: hours(121))],
                identity: "you@example.com", plan: "Max", fetchedAt: now)),
            (account("Codex", "Personal", .codex), UsageSnapshot(
                windows: [UsageWindow(label: "5-hour", usedPercent: 7, resetsAt: hours(4.1)),
                          UsageWindow(label: "Week", usedPercent: 22, resetsAt: hours(150))],
                identity: "you@example.com", plan: "Pro", fetchedAt: now)),
        ])
    }

    /// Prints only synthetic data; no account config, credentials, or providers are read.
    static func dump() {
        let store = sampleStore()
        print("Sample data only")
        for account in store.accounts {
            guard let snapshot = store.states[account.id]?.snapshot else { continue }
            print("== \(account.name)")
            print("  \(snapshot.identity ?? "?") · \(snapshot.plan ?? "?")")
            for window in snapshot.windows {
                print("  \(window.label): \(Int(window.displayUsedPercent.rounded()))% used \(window.detail ?? "")")
            }
        }
    }

    /// Writes the menu bar item at 4x, using the sample accounts.
    static func menuBar(to path: String, dark: Bool) throws {
        let image = MenuBarImage.render(sampleStore().menuBarSegments)
        let padding: CGFloat = 8
        let size = NSSize(width: image.size.width + padding * 2, height: image.size.height + padding)
        try writePNG(size: size, scale: 4, to: path) {
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
            tinted(image, dark ? .white : .black)
                .draw(in: NSRect(origin: NSPoint(x: padding, y: padding / 2), size: image.size))
        }
    }

    static func panel(to path: String, dark: Bool) throws {
        let content = UsagePanel(store: sampleStore())
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw FetchError("Could not render the panel") }
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// Template images draw black; fill them with a color for a preview.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func writePNG(size: NSSize, scale: CGFloat, to path: String, draw: () -> Void) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw FetchError("Could not encode PNG") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
