import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the menu bar item, the dropdown, the Accounts window and the mascot animations to
/// PNG and GIF files, for checking the layout and for README screenshots:
///   AIUsage --render-menubar out.png [--dark]
///   AIUsage --render-panel out.png [--sample] [--dark]
///   AIUsage --render-accounts out.png [--dark]
///   AIUsage --render-menubar-settings out.png [--dark]
///   AIUsage --render-menubar-gif out.gif [--dark]
///   AIUsage --render-animations out.gif [--dark]
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
        let image = MenuBarImage.render(sampleStore().menuBarSegments, dark: dark)
        let padding: CGFloat = 8
        let size = NSSize(width: image.size.width + padding * 2, height: image.size.height + padding)
        try writePNG(size: size, scale: 4, to: path) {
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
            image.draw(in: NSRect(origin: NSPoint(x: padding, y: padding / 2), size: image.size))
        }
    }

    static func panel(to path: String, dark: Bool) throws {
        // Offscreen renders can't draw Liquid Glass, so approximate it: a translucent rounded
        // panel over a colourful gradient.
        let shape = RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
        let content = UsagePanel(store: sampleStore(), windowChrome: false)
            .background((dark ? Color.black.opacity(0.45) : Color.white.opacity(0.55)), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.18 : 0.5)))
            .padding(36)
            .background(
                LinearGradient(colors: [Color(red: 0.36, green: 0.25, blue: 0.75), Color(red: 0.1, green: 0.45, blue: 0.6),
                                        Color(red: 0.85, green: 0.45, blue: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw FetchError("Could not render the panel") }
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// Synthetic editor preview; never loads or saves the live configuration.
    static func accounts(to path: String, dark: Bool, showMenuBar: Bool = false) throws {
        let store = sampleStore()
        let content = AccountEditor(store: store, saver: AccountsAutosaver(store: store, sampleAccounts: store.accounts),
                                    showMenuBar: showMenuBar)
            .frame(width: 840, height: 680)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        // Native text fields and scroll views require an AppKit host rather than ImageRenderer.
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 840, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.display()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { throw FetchError("Could not render accounts") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:])
        else { throw FetchError("Could not render accounts") }
        try png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Animations

    private static let gifFrameRate: Double = 25

    /// The sample menu bar for about 12 seconds: the mascots take turns animating as their
    /// usage ticks up, then both go at once, as after a refresh that changed both.
    static func menuBarGIF(to path: String, dark: Bool) throws {
        var segments = sampleStore().menuBarSegments
        let claudes = segments.indices.filter { if case .account(.claude, _) = segments[$0] { true } else { false } }
        guard claudes.count >= 2 else { throw FetchError("The sample needs two Claude accounts") }
        let (first, second) = (claudes[0], claudes[1])
        let events: [(start: TimeInterval, plays: [Int: ClawdAnimation])] = [
            (0.4, [first: .hop]), (1.8, [second: .wave]), (3.4, [first: .backflip]), (5, [second: .dance]),
            (6.8, [first: .teleport]), (8.4, [second: .spin]), (10, [first: .bigJump, second: .cheer]),
        ]
        let length: TimeInterval = 12
        let first0 = MenuBarImage.render(segments, dark: dark)
        let padding: CGFloat = 8
        let size = NSSize(width: first0.size.width + padding * 2, height: first0.size.height + padding)
        let frames = Int(length * gifFrameRate)

        var applied = 0
        try writeGIF(size: size, scale: 3, frames: frames, to: path) { frame in
            let t = Double(frame) / gifFrameRate
            // Each animation starts as its account's number goes up by one.
            while applied < events.count, events[applied].start <= t {
                for index in events[applied].plays.keys {
                    if case .account(let provider, let text) = segments[index], let value = Int(text.dropLast()) {
                        segments[index] = .account(provider, "\(value + 1)%")
                    }
                }
                applied += 1
            }
            var poses: [Int: ClawdPose] = [:]
            for event in events where event.start <= t {
                for (index, animation) in event.plays where t - event.start < animation.duration {
                    poses[index] = animation.pose(at: t - event.start)
                }
            }
            background(dark).setFill()
            NSRect(origin: .zero, size: size).fill()
            MenuBarImage.render(segments, dark: dark, poses: poses)
                .draw(in: NSRect(origin: NSPoint(x: padding, y: padding / 2), size: first0.size))
        }
    }

    /// Every animation at once in a labelled grid, each playing from the start of the loop.
    static func animationsGIF(to path: String, dark: Bool) throws {
        let animations = ClawdAnimation.allCases
        let columns = 7
        let rows = (animations.count + columns - 1) / columns
        let tile = NSSize(width: 104, height: 84)
        let size = NSSize(width: tile.width * CGFloat(columns), height: tile.height * CGFloat(rows))
        let mascot: [MenuBarSegment] = [.account(.claude, "")]
        let mascotScale: CGFloat = 1.9
        let length = (animations.map(\.duration).max() ?? 1) + 0.6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.3, alpha: 1),
        ]
        try writeGIF(size: size, scale: 2, frames: Int(length * gifFrameRate), to: path) { frame in
            let t = Double(frame) / gifFrameRate
            background(dark).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (index, animation) in animations.enumerated() {
                let origin = NSPoint(x: CGFloat(index % columns) * tile.width,
                                     y: size.height - CGFloat(index / columns + 1) * tile.height)
                let pose = t < animation.duration ? animation.pose(at: t) : ClawdPose()
                let image = MenuBarImage.render(mascot, dark: dark, poses: [0: pose])
                let drawn = NSSize(width: image.size.width * mascotScale, height: image.size.height * mascotScale)
                image.draw(in: NSRect(x: origin.x + (tile.width - drawn.width) / 2, y: origin.y + 22,
                                      width: drawn.width, height: drawn.height))
                let name = animation.name as NSString
                let nameWidth = name.size(withAttributes: attributes).width
                name.draw(at: NSPoint(x: origin.x + (tile.width - nameWidth) / 2, y: origin.y + 8), withAttributes: attributes)
            }
        }
    }

    private static func background(_ dark: Bool) -> NSColor {
        dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    }

    /// Writes a looping GIF of `frames` frames at `gifFrameRate`, each drawn by `draw(frame)`.
    private static func writeGIF(size: NSSize, scale: CGFloat, frames: Int, to path: String,
                                 draw: (Int) -> Void) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString, frames, nil)
        else { throw FetchError("Could not create GIF") }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1 / gifFrameRate
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
        ] as CFDictionary
        for frame in 0..<frames {
            guard let image = bitmap(size: size, scale: scale, draw: { draw(frame) }).cgImage
            else { throw FetchError("Could not draw a GIF frame") }
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw FetchError("Could not write GIF") }
    }

    private static func writePNG(size: NSSize, scale: CGFloat, to path: String, draw: () -> Void) throws {
        guard let png = bitmap(size: size, scale: scale, draw: draw).representation(using: .png, properties: [:])
        else { throw FetchError("Could not encode PNG") }
        try png.write(to: URL(fileURLWithPath: path))
    }

    private static func bitmap(size: NSSize, scale: CGFloat, draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
