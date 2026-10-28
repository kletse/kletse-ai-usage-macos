import AppKit

enum ProviderIcon {
    /// The mascot's orange in Claude Code.
    static let claudeOrange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    /// Returns a template image of the provider's logo whose visible glyph is `height` points tall.
    /// `pose` moves the Claude mascot's eyes, arms and legs.
    static func image(for provider: Provider, height: CGFloat, pose: ClawdPose = ClawdPose()) -> NSImage {
        switch provider {
        case .claude: clawd(height: height, pose: pose)
        case .codex: codex(height: height)
        }
    }

    static func size(for provider: Provider, height: CGFloat) -> NSSize {
        switch provider {
        case .claude: NSSize(width: height * clawdAspect, height: height)
        // The knot fills about 82 of its 100-point view box, so draw the box larger.
        case .codex: NSSize(width: height * 100 / 82, height: height * 100 / 82)
        }
    }

    // MARK: - Claude Code mascot

    /// The mascot Claude Code prints on startup (`▐▛███▜▌` / `▝▜█████▛▘` / `▘▘ ▝▝`),
    /// as a 16×5 grid of quadrant-block pixels. Terminal pixels are roughly twice as tall as wide.
    private static let clawdRows: [[Int]] = [
        Array(2...13),
        [2, 3, 5, 6, 7, 8, 9, 10, 12, 13],
        Array(0...15),
        Array(2...13),
        [3, 5, 10, 12],
    ]
    private static let clawdPixelAspect: CGFloat = 1.8
    private static let clawdAspect: CGFloat = 16 / (5 * clawdPixelAspect)

    /// The grid for `pose`: eyes are the gaps in the second row, arms the two pixels either side
    /// of the third, and legs the bottom row.
    private static func clawdPixels(_ pose: ClawdPose) -> [[Int]] {
        var rows = clawdRows
        let eyes = eyeColumns(pose)
        rows[1] = Array(2...13).filter { !eyes.contains($0) }
        for (arm, columns, outer) in [(pose.leftArm, [0, 1], 0), (pose.rightArm, [14, 15], 15)] {
            switch arm {
            case .down: continue
            case .raised: rows[1] += columns
            // Straight up along the outer column, apart from the body so it doesn't read as a hat.
            case .high: rows[0].append(outer); rows[1].append(outer)
            }
            rows[2].removeAll { columns.contains($0) }
        }
        switch pose.legs {
        case .standing: break
        case .stepLeft: rows[4] = [3, 10]
        case .stepRight: rows[4] = [5, 12]
        case .tucked: rows[4] = []
        case .wide: rows[4] = [2, 13]
        }
        return rows
    }

    private static func eyeColumns(_ pose: ClawdPose) -> [Int] {
        switch pose.eyes {
        case .open: [4, 11]
        case .closed: []
        case .left: [3, 10]
        case .right: [5, 12]
        case .wide: [4, 5, 10, 11]
        case .wink: [4]
        }
    }

    private static func clawd(height: CGFloat, pose: ClawdPose) -> NSImage {
        pixelImage(clawdPixels(pose), height: height)
    }

    /// A template image of just the mascot's eyes, to fill the gaps the body leaves for them.
    static func clawdEyes(height: CGFloat, pose: ClawdPose = ClawdPose()) -> NSImage {
        pixelImage([[], eyeColumns(pose), [], [], []], height: height)
    }

    private static func pixelImage(_ rows: [[Int]], height: CGFloat) -> NSImage {
        let size = size(for: .claude, height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            let pixelHeight = height / CGFloat(rows.count)
            let pixelWidth = size.width / 16
            // One path so adjacent pixels fill without seams.
            let path = NSBezierPath()
            for (row, columns) in rows.enumerated() {
                for column in columns {
                    path.appendRect(NSRect(x: CGFloat(column) * pixelWidth, y: CGFloat(row) * pixelHeight,
                                           width: pixelWidth, height: pixelHeight))
                }
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Codex logo

    /// The OpenAI knot, the logo Codex used before its cloud icon (from CodexBar, MIT).
    private static let codexSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">\
    <path fill="#000" d="M83.7733 42.8087C84.6678 40.1149 84.9771 37.2613 84.6807 34.4385C84.3843 31.6156 83.489 28.8885 82.0544 26.4394C77.6908 18.8436 68.9203 14.9365 60.3548 16.7725C57.9831 14.1344 54.9591 12.1668 51.5864 11.0673C48.2137 9.96772 44.611 9.77498 41.1402 10.5084C37.6694 11.2418 34.4527 12.8755 31.8132 15.2455C29.1736 17.6155 27.204 20.6383 26.1024 24.0103C23.3212 24.5806 20.6938 25.738 18.3958 27.405C16.0977 29.0721 14.1819 31.2104 12.7765 33.6772C8.36538 41.2609 9.3669 50.8267 15.2527 57.3327C14.3549 60.0251 14.0424 62.8782 14.3361 65.7012C14.6298 68.5241 15.523 71.2518 16.9558 73.7017C21.325 81.3002 30.1011 85.207 38.6712 83.3686C40.5554 85.4904 42.8707 87.1858 45.4623 88.3416C48.0539 89.4975 50.8622 90.0871 53.6999 90.0713C62.4793 90.079 70.2575 84.4114 72.9393 76.0515C75.7201 75.4802 78.347 74.3225 80.6449 72.6555C82.9427 70.9886 84.8587 68.8507 86.2649 66.3846C90.6227 58.8145 89.6172 49.3005 83.7733 42.8087ZM53.6999 84.8356C50.1955 84.8411 46.801 83.6129 44.1116 81.3661L44.5848 81.098L60.5123 71.9043C60.9087 71.6718 61.2379 71.3402 61.4674 70.942C61.6969 70.5439 61.8189 70.0929 61.8215 69.6333V47.1769L68.5553 51.072C68.6225 51.1063 68.6694 51.1707 68.6814 51.2456V69.854C68.6641 78.1208 61.9667 84.8183 53.6999 84.8356ZM21.4977 71.0843C19.7402 68.0497 19.1092 64.4925 19.7156 61.0386L20.1885 61.3225L36.1321 70.5165C36.5266 70.748 36.9757 70.87 37.4331 70.87C37.8905 70.87 38.3396 70.748 38.7341 70.5165L58.21 59.2883V67.0628C58.2081 67.1031 58.1973 67.1424 58.1782 67.1779C58.1591 67.2134 58.1322 67.2441 58.0996 67.2678L41.9671 76.5722C34.798 80.7022 25.6388 78.2463 21.4977 71.0843ZM17.3026 36.3898C19.0723 33.3357 21.8655 31.0062 25.1878 29.8138V48.7376C25.1818 49.1949 25.2986 49.6453 25.5261 50.042C25.7535 50.4387 26.0833 50.7671 26.4809 50.9928L45.8622 62.1739L39.1283 66.069C39.0919 66.0883 39.0513 66.0984 39.0101 66.0984C38.9689 66.0984 38.9283 66.0883 38.8919 66.069L22.7908 56.7809C15.6359 52.6337 13.1822 43.4816 17.3026 36.3112V36.3898ZM72.624 49.2426L53.1792 37.9512L59.8976 34.0718C59.9341 34.0524 59.9747 34.0423 60.016 34.0423C60.0573 34.0423 60.0979 34.0524 60.1344 34.0718L76.2355 43.3761C78.6973 44.7966 80.7043 46.8882 82.0221 49.4065C83.3398 51.9249 83.914 54.7661 83.6775 57.5985C83.4411 60.431 82.4038 63.1377 80.6867 65.4027C78.9696 67.6677 76.6436 69.3975 73.9803 70.3901V51.466C73.9663 51.0096 73.834 50.5647 73.5962 50.1749C73.3584 49.7851 73.0234 49.4638 72.624 49.2426ZM79.3261 39.1657L78.8529 38.8815L62.9411 29.6089C62.5442 29.376 62.0924 29.2532 61.6322 29.2532C61.172 29.2532 60.7202 29.376 60.3233 29.6089L40.8629 40.8374V33.0628C40.8587 33.0233 40.8654 32.9834 40.882 32.9473C40.8987 32.9113 40.9248 32.8803 40.9575 32.8579L57.0586 23.5692C59.5263 22.1476 62.3478 21.458 65.193 21.5811C68.0382 21.7042 70.7896 22.6348 73.1253 24.2642C75.461 25.8936 77.2845 28.1543 78.3825 30.782C79.4806 33.4097 79.8077 36.2957 79.3257 39.1025V39.1657H79.3261ZM37.1888 52.9484L30.455 49.069C30.4213 49.0487 30.3925 49.0212 30.3707 48.9884C30.3488 48.9557 30.3345 48.9186 30.3286 48.8797V30.3188C30.3323 27.4714 31.1466 24.6839 32.6761 22.2822C34.2057 19.8805 36.3874 17.9639 38.9661 16.7564C41.5448 15.549 44.4139 15.1005 47.2381 15.4636C50.0622 15.8267 52.7247 16.9862 54.9141 18.8067L54.4409 19.0748L38.5134 28.2686C38.117 28.5011 37.7879 28.8327 37.5584 29.2308C37.329 29.629 37.207 30.0799 37.2045 30.5395L37.1888 52.9487V52.9484ZM40.8472 45.0632L49.5209 40.0643L58.21 45.0635V55.0615L49.5523 60.0608L40.8632 55.0615L40.8472 45.0632Z"/></svg>
    """

    private static let codexBase: NSImage? = NSImage(data: Data(codexSVG.utf8))

    private static func codex(height: CGFloat) -> NSImage {
        let size = size(for: .codex, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            codexBase?.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Menu bar preferences, kept in user defaults.
enum MenuBarSettings {
    /// Whether the Claude mascot is orange; on by default.
    static let colorKey = "menuBarClaudeInColor"
    /// Whether mascots animate when usage changes; on by default.
    static let animateKey = "menuBarAnimations"
}

/// One frame of a Claude mascot animation.
struct ClawdPose: Equatable {
    enum Eyes { case open, closed, left, right, wide, wink }
    enum Arm { case down, raised, high }
    enum Legs { case standing, stepLeft, stepRight, tucked, wide }

    /// Points above its resting place.
    var lift: CGFloat = 0
    /// Points right of its resting place.
    var shift: CGFloat = 0
    /// Degrees clockwise, about its centre.
    var tilt: CGFloat = 0
    /// Size, about its feet.
    var scale: CGFloat = 1
    /// Height on top of `scale`: below 1 squashes, above stretches.
    var stretch: CGFloat = 1
    var opacity: CGFloat = 1
    var eyes = Eyes.open
    var leftArm = Arm.down
    var rightArm = Arm.down
    var legs = Legs.standing
}

/// The Claude mascot's menu bar animations. A usage change plays a random one.
enum ClawdAnimation: CaseIterable, Identifiable {
    case hop, wave, lookAround, dance, shiver, bigJump, cheer, wink
    case walk, bounce, doze, surprise, flap, stretch, rockOut
    case spin, curious, boing, pop, scared, teleport, ghost, sneeze, snore, backflip
    case wobble, jumpingJacks, tapFoot, moonwalk, peekaboo, shy, hiccup, heartbeat, dizzy, swim

    var id: Self { self }

    var name: String {
        switch self {
        case .hop: "Hop"
        case .wave: "Wave"
        case .lookAround: "Look around"
        case .dance: "Dance"
        case .shiver: "Shiver"
        case .bigJump: "Big jump"
        case .cheer: "Cheer"
        case .wink: "Wink"
        case .walk: "Walk"
        case .bounce: "Bounce"
        case .doze: "Doze off"
        case .surprise: "Surprise"
        case .flap: "Flap"
        case .stretch: "Stretch"
        case .rockOut: "Rock out"
        case .spin: "Spin"
        case .curious: "Curious"
        case .boing: "Boing"
        case .pop: "Pop"
        case .scared: "Scared"
        case .teleport: "Teleport"
        case .ghost: "Ghost"
        case .sneeze: "Sneeze"
        case .snore: "Snore"
        case .backflip: "Backflip"
        case .wobble: "Wobble"
        case .jumpingJacks: "Jumping jacks"
        case .tapFoot: "Tap foot"
        case .moonwalk: "Moonwalk"
        case .peekaboo: "Peekaboo"
        case .shy: "Shy"
        case .hiccup: "Hiccup"
        case .heartbeat: "Heartbeat"
        case .dizzy: "Dizzy"
        case .swim: "Swim"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .pop: 0.7
        case .shiver: 0.8
        case .wink, .bounce: 0.9
        case .hop, .surprise, .spin, .boing: 1
        case .bigJump, .rockOut, .backflip, .wobble: 1.2
        case .wave, .cheer, .teleport: 1.3
        case .dance, .scared, .sneeze, .peekaboo, .heartbeat: 1.4
        case .lookAround, .flap, .jumpingJacks: 1.5
        case .walk, .stretch, .curious, .tapFoot, .moonwalk, .shy: 1.6
        case .ghost, .hiccup, .swim: 1.8
        case .doze, .dizzy: 2
        case .snore: 2.4
        }
    }

    /// Different animations for each mascot, as long as there are enough to go round.
    static func assign(to indexes: [Int]) -> [Int: ClawdAnimation] {
        let shuffled = allCases.shuffled()
        return Dictionary(uniqueKeysWithValues: indexes.enumerated().map { ($1, shuffled[$0 % shuffled.count]) })
    }

    func pose(at t: TimeInterval) -> ClawdPose {
        /// A jump of `height` points from `start` to `start + length`.
        func arc(_ start: TimeInterval, _ length: TimeInterval, _ height: CGFloat) -> CGFloat {
            let progress = (t - start) / length
            return (0...1).contains(progress) ? height * sin(.pi * progress) : 0
        }
        func during(_ start: TimeInterval, _ end: TimeInterval) -> Bool { (start..<end).contains(t) }
        /// Alternates every `period` seconds, starting true.
        func beat(_ period: TimeInterval) -> Bool { Int(t / period) % 2 == 0 }
        /// Eases between (time, value) keyframes, holding the first and last values outside them.
        func keys(_ frames: [(TimeInterval, CGFloat)]) -> CGFloat {
            guard let next = frames.firstIndex(where: { $0.0 > t }) else { return frames.last?.1 ?? 0 }
            guard next > 0 else { return frames[0].1 }
            let (t0, v0) = frames[next - 1], (t1, v1) = frames[next]
            let progress = (t - t0) / (t1 - t0)
            return v0 + (v1 - v0) * CGFloat((1 - cos(.pi * progress)) / 2)
        }
        func wave(_ period: TimeInterval) -> CGFloat { CGFloat(sin(2 * .pi * t / period)) }

        var pose = ClawdPose()
        switch self {
        case .hop:
            // Two hops, the second smaller, then a blink.
            pose.lift = arc(0, 0.36, 3) + arc(0.36, 0.26, 1.5)
            if during(0.08, 0.28) { pose.legs = .tucked }
            if during(0.75, 0.9) { pose.eyes = .closed }
        case .wave:
            if during(0.1, 1.15) { pose.rightArm = beat(0.15) ? .high : .raised }
            if during(1.15, 1.27) { pose.eyes = .closed }
        case .lookAround:
            pose.eyes = during(0.15, 0.6) ? .left : during(0.6, 1.05) ? .right : during(1.2, 1.32) ? .closed : .open
        case .dance:
            guard t < 1.4 else { break }
            pose.legs = beat(0.175) ? .stepLeft : .stepRight
            pose.lift = beat(0.175) ? 0 : 1
            pose.shift = beat(0.35) ? -1 : 1
            pose.leftArm = beat(0.35) ? .raised : .down
            pose.rightArm = beat(0.35) ? .down : .raised
        case .shiver:
            guard t < 0.7 else { break }
            pose.shift = (beat(0.05) ? 1 : -1) * (t < 0.45 ? 1 : 0.5)
            pose.eyes = .wide
        case .bigJump:
            // Crouch, leap with arms up, land in a crouch.
            pose.lift = during(0, 0.2) || during(0.75, 0.9) ? -1 : arc(0.2, 0.55, 3.5)
            if during(0.25, 0.7) { pose.legs = .tucked }
            if during(0.3, 0.65) { pose.leftArm = .high; pose.rightArm = .high }
            if during(0.95, 1.07) { pose.eyes = .closed }
        case .cheer:
            guard t < 1.1 else { break }
            pose.leftArm = beat(0.15) ? .high : .raised
            pose.rightArm = beat(0.15) ? .raised : .high
            pose.eyes = .closed
            pose.lift = arc(0, 0.3, 1) + arc(0.3, 0.3, 1) + arc(0.6, 0.3, 1)
        case .wink:
            pose.lift = arc(0, 0.25, 1)
            if during(0.2, 0.7) { pose.eyes = .wink; pose.rightArm = .raised }
        case .walk:
            // A few steps left, a look back, and home again.
            pose.shift = t < 0.7 ? -2 * t / 0.7 : t < 0.9 ? -2 : -2 + 2 * min(1, (t - 0.9) / 0.7)
            if !during(0.7, 0.9), t < 1.6 { pose.legs = beat(0.12) ? .stepLeft : .stepRight }
            pose.eyes = t < 0.7 ? .left : t < 0.9 ? .open : .right
        case .bounce:
            pose.lift = arc(0, 0.3, 1.5) + arc(0.3, 0.3, 1) + arc(0.6, 0.3, 0.5)
        case .doze:
            // Nods off, then wakes with a start.
            if during(0.2, 1.5) { pose.eyes = .closed }
            if during(0.5, 1.5) { pose.lift = -0.5 }
            if during(1.5, 1.9) { pose.eyes = .wide }
            pose.lift += arc(1.5, 0.3, 2)
        case .surprise:
            pose.lift = arc(0, 0.35, 2.5)
            if during(0, 0.8) { pose.eyes = .wide }
            if during(0.05, 0.5) { pose.leftArm = .high; pose.rightArm = .high }
            if during(0.05, 0.3) { pose.legs = .tucked }
        case .flap:
            // Flaps up into the air, then drops.
            if t < 1.2 {
                pose.leftArm = beat(0.1) ? .raised : .down
                pose.rightArm = pose.leftArm
                pose.lift = 2.5 * min(1, t / 0.9)
                if t > 0.3 { pose.legs = .tucked }
            } else if t < 1.35 {
                pose.lift = 2.5 * (1.35 - t) / 0.15
            }
        case .stretch:
            let arm: ClawdPose.Arm = during(0.3, 1.2) ? .high : during(0.1, 1.35) ? .raised : .down
            pose.leftArm = arm
            pose.rightArm = arm
            if during(0.3, 1.2) { pose.lift = 0.5 }
            if during(0.25, 1.25) { pose.eyes = .closed }
        case .rockOut:
            guard t < 1.05 else { break }
            pose.lift = beat(0.15) ? 0 : -1
            pose.eyes = .closed
            pose.rightArm = .high
        case .spin:
            // Smaller while turning, so its corners stay inside the menu bar.
            pose.tilt = keys([(0.1, 0), (0.8, 360)])
            if during(0.1, 0.8) { pose.scale = 0.8 }
            pose.lift = arc(0.05, 0.8, 1.5)
        case .curious:
            pose.tilt = keys([(0, 0), (0.2, -12), (0.6, -12), (0.8, 0), (1, 12), (1.4, 12), (1.6, 0)])
            pose.eyes = during(0.15, 0.7) ? .left : during(0.9, 1.45) ? .right : .open
        case .boing:
            pose.stretch = keys([(0, 1), (0.15, 0.7), (0.3, 1.25), (0.55, 1.1), (0.7, 0.75), (0.85, 1.08), (1, 1)])
            pose.lift = arc(0.25, 0.4, 3)
            if during(0.3, 0.55) { pose.legs = .tucked }
        case .pop:
            pose.scale = keys([(0, 1), (0.12, 1.2), (0.3, 0.92), (0.45, 1.05), (0.6, 1)])
            if during(0.05, 0.4) { pose.eyes = .wide }
        case .scared:
            pose.scale = keys([(0, 1), (0.1, 0.65), (1, 0.65), (1.3, 1)])
            if during(0.1, 1) { pose.shift = beat(0.06) ? 0.5 : -0.5; pose.eyes = .wide }
        case .teleport:
            // Beams out as a thin streak and back in, then blinks.
            pose.opacity = keys([(0, 1), (0.3, 0), (0.6, 0), (0.9, 1)])
            pose.scale = keys([(0, 1), (0.3, 0.6), (0.6, 0.6), (0.9, 1)])
            pose.stretch = keys([(0, 1), (0.3, 1.8), (0.6, 1.8), (0.9, 1)])
            if during(0.95, 1.07) { pose.eyes = .closed }
        case .ghost:
            pose.opacity = keys([(0, 1), (0.2, 0.35), (1.5, 0.35), (1.75, 1)])
            if during(0.2, 1.6) {
                pose.lift = 1.5 * wave(0.8)
                pose.leftArm = .raised
                pose.rightArm = .raised
                pose.eyes = .wide
            }
        case .sneeze:
            // Leans back as it builds, then lurches forward.
            pose.tilt = keys([(0, 0), (0.7, -8), (0.78, 10), (1, 0)])
            pose.stretch = keys([(0, 1), (0.7, 1.12), (0.78, 0.8), (1, 1)])
            pose.shift = keys([(0, 0), (0.7, -0.5), (0.78, 1), (1, 0)])
            if during(0.35, 1) { pose.eyes = .closed }
        case .snore:
            guard t < 2.2 else { break }
            pose.eyes = .closed
            pose.lift = -0.5
            pose.stretch = 1 - 0.08 * (1 - CGFloat(cos(2 * .pi * t / 1.1))) / 2
        case .backflip:
            pose.lift = arc(0.1, 0.8, 3.5)
            pose.tilt = keys([(0.2, 0), (0.75, -360)])
            if during(0.2, 0.75) { pose.scale = 0.8 }
            if during(0.15, 0.8) { pose.legs = .tucked }
            pose.stretch = keys([(0.85, 1), (0.92, 0.8), (1.05, 1)])
        case .wobble:
            pose.tilt = 12 * wave(0.3) * CGFloat(max(0, 1 - t / 1.2))
        case .jumpingJacks:
            guard t < 1.5 else { break }
            let open = t.truncatingRemainder(dividingBy: 0.5) < 0.25
            if open {
                pose.leftArm = .high
                pose.rightArm = .high
                pose.legs = .wide
            }
            pose.lift = arc(0, 0.25, 1) + arc(0.5, 0.25, 1) + arc(1, 0.25, 1)
        case .tapFoot:
            guard t < 1.5 else { break }
            pose.legs = beat(0.1) ? .stepRight : .standing
            pose.eyes = .left
            pose.tilt = -3
        case .moonwalk:
            // Slides backwards while the legs walk forwards.
            pose.shift = keys([(0, 0), (1.1, -3), (1.35, -3), (1.6, 0)])
            if t < 1.1 {
                pose.legs = beat(0.14) ? .stepLeft : .stepRight
                pose.eyes = .right
                pose.tilt = 4
            }
        case .peekaboo:
            pose.lift = keys([(0, 0), (0.15, -2), (0.7, -2), (0.8, 1.5), (1, 0)])
            pose.stretch = keys([(0, 1), (0.15, 0.75), (0.7, 0.75), (0.8, 1.15), (1, 1)])
            pose.eyes = during(0.1, 0.72) ? .closed : during(0.72, 1.2) ? .wide : .open
            if during(0.72, 1.1) { pose.leftArm = .high; pose.rightArm = .high }
        case .shy:
            pose.tilt = keys([(0, 0), (0.25, -10), (1.2, -10), (1.5, 0)])
            pose.scale = keys([(0, 1), (0.25, 0.9), (1.2, 0.9), (1.5, 1)])
            pose.shift = keys([(0, 0), (0.25, -1), (1.2, -1), (1.5, 0)])
            pose.eyes = during(0.7, 1) ? .wink : during(0.2, 1.3) ? .left : .open
        case .hiccup:
            for start in [0.2, 0.9, 1.35] where during(start, start + 0.3) {
                pose.lift = arc(start, 0.18, 1.5)
                pose.eyes = .wide
                if during(start, start + 0.18) { pose.legs = .tucked }
            }
        case .heartbeat:
            // Lub-dub, twice.
            pose.scale = 1 + arc(0, 0.14, 0.15) + arc(0.18, 0.14, 0.1) + arc(0.7, 0.14, 0.15) + arc(0.88, 0.14, 0.1)
        case .dizzy:
            if t < 1.6 {
                pose.tilt = 10 * wave(0.6)
                pose.shift = CGFloat(cos(2 * .pi * t / 0.6))
                pose.eyes = beat(0.12) ? .left : .right
            } else {
                pose.eyes = .closed
                pose.stretch = keys([(1.6, 1), (1.7, 0.85), (1.9, 1)])
            }
        case .swim:
            pose.lift = arc(0, 1.8, 2.5) + 0.5 * wave(0.45)
            pose.leftArm = beat(0.225) ? .raised : .down
            pose.rightArm = pose.leftArm
            if during(0.2, 1.6) { pose.legs = .tucked }
        }
        return pose
    }
}

enum MenuBarSegment: Hashable {
    case account(Provider, String)
    case separator
}

enum MenuBarImage {
    /// Renders the whole menu bar label as one image: the Claude mascot in its orange, the rest
    /// in the text colour of a `dark` or light menu bar. A template image can't keep the orange.
    /// `poses` animates the Claude mascots, keyed by segment index; `colorClaude` false draws them
    /// in the text colour like the other icons.
    static func render(_ segments: [MenuBarSegment], dark: Bool, poses: [Int: ClawdPose] = [:],
                       colorClaude: Bool = true) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        // Taller than the usual 18 points, to leave room above the mascot for its jumps.
        let height: CGFloat = 22
        let iconHeight: CGFloat = 13
        /// Poses are in points for an 11-point mascot; scale them to the size drawn.
        let motion = iconHeight / 11
        let iconGap: CGFloat = 2
        let itemGap: CGFloat = 5
        let dotSize: CGFloat = 2.5

        func width(of segment: MenuBarSegment) -> CGFloat {
            switch segment {
            case .account(let provider, let text):
                ProviderIcon.size(for: provider, height: iconHeight).width + iconGap + (text as NSString).size(withAttributes: attributes).width
            case .separator:
                dotSize
            }
        }

        // Room for a mascot at the front to move left without being cut off.
        let inset = 3 * motion
        let total = inset + segments.map(width).reduce(0, +) + itemGap * CGFloat(max(0, segments.count - 1))
        let image = NSImage(size: NSSize(width: max(1, ceil(total)), height: height), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x = inset
                for (index, segment) in segments.enumerated() {
                    switch segment {
                    case .account(let provider, let text):
                        let iconSize = ProviderIcon.size(for: provider, height: iconHeight)
                        let pose = poses[index] ?? ClawdPose()
                        // Whole half-points keep the pixel art crisp on Retina menu bars.
                        let iconY = (height - iconSize.height) / 2 + (pose.lift * motion * 2).rounded() / 2
                        let iconX = x + (pose.shift * motion * 2).rounded() / 2
                        let color = provider == .claude && colorClaude ? ProviderIcon.claudeOrange : NSColor.labelColor
                        let rect = NSRect(origin: NSPoint(x: iconX, y: iconY), size: iconSize)
                        NSGraphicsContext.saveGraphicsState()
                        // Applied last to first: scale about the feet, then turn about the centre.
                        let transform = NSAffineTransform()
                        transform.translateX(by: rect.midX, yBy: rect.midY)
                        transform.rotate(byDegrees: -pose.tilt)
                        transform.translateX(by: -rect.midX, yBy: -rect.midY)
                        transform.translateX(by: rect.midX, yBy: rect.minY)
                        transform.scaleX(by: pose.scale, yBy: pose.scale * pose.stretch)
                        transform.translateX(by: -rect.midX, yBy: -rect.minY)
                        transform.concat()
                        tinted(ProviderIcon.image(for: provider, height: iconHeight, pose: pose), color)
                            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: pose.opacity)
                        // Black eyes on the orange mascot; in black and white they stay see-through.
                        if provider == .claude && colorClaude {
                            tinted(ProviderIcon.clawdEyes(height: iconHeight, pose: pose), .black)
                                .draw(in: rect, from: .zero, operation: .sourceOver, fraction: pose.opacity)
                        }
                        NSGraphicsContext.restoreGraphicsState()
                        x += iconSize.width + iconGap
                        let textSize = (text as NSString).size(withAttributes: attributes)
                        (text as NSString).draw(at: NSPoint(x: x, y: (height - textSize.height) / 2), withAttributes: attributes)
                        x += textSize.width
                    case .separator:
                        NSColor.labelColor.setFill()
                        NSBezierPath(ovalIn: NSRect(x: x, y: (height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
                        x += dotSize
                    }
                    x += itemGap
                }
            }
            return true
        }
        return image
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
