import SwiftUI

/// A sheet for trying the mascot's animations one at a time; each also plays in the menu bar.
struct AnimationGallery: View {
    let store: UsageStore
    @Environment(\.dismiss) private var dismiss
    /// When each tile started playing.
    @State private var playing: [ClawdAnimation: Date] = [:]

    private static let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]
    private static let mascotHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(ClawdAnimation.allCases) { animation in
                        tile(animation)
                    }
                }
                .padding(20)
            }
            HStack {
                Text("Click one to play it here and in the menu bar.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Play Random") { store.previewAnimation(nil) }
                    .help("Plays a different animation on each mascot, as a usage change does")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 640, height: 600)
    }

    private func tile(_ animation: ClawdAnimation) -> some View {
        Button {
            playing[animation] = Date()
            store.previewAnimation(animation)
        } label: {
            VStack(spacing: 10) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: playing[animation] == nil)) { context in
                    mascot(pose(animation, at: context.date))
                }
                .frame(height: Self.mascotHeight * 1.8)
                Text(animation.name).font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(animation.name)")
    }

    /// The pose `date` falls on, clearing the tile once its animation has finished.
    private func pose(_ animation: ClawdAnimation, at date: Date) -> ClawdPose {
        guard let start = playing[animation] else { return ClawdPose() }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed < animation.duration else {
            DispatchQueue.main.async { if playing[animation] == start { playing[animation] = nil } }
            return ClawdPose()
        }
        return animation.pose(at: elapsed)
    }

    private func mascot(_ pose: ClawdPose) -> some View {
        // The menu bar draws the mascot 11 points tall; scale its movement to match.
        let scale = Self.mascotHeight / 11
        return Image(nsImage: ProviderIcon.image(for: .claude, height: Self.mascotHeight, pose: pose))
            .renderingMode(.template)
            .foregroundStyle(Color(nsColor: ProviderIcon.claudeOrange))
            .background {
                Image(nsImage: ProviderIcon.clawdEyes(height: Self.mascotHeight, pose: pose))
                    .renderingMode(.template)
                    .foregroundStyle(.black)
            }
            .scaleEffect(x: pose.scale, y: pose.scale * pose.stretch, anchor: .bottom)
            .rotationEffect(.degrees(pose.tilt))
            .opacity(pose.opacity)
            .offset(x: (pose.shift * 2).rounded() / 2 * scale, y: -(pose.lift * 2).rounded() / 2 * scale)
    }
}
