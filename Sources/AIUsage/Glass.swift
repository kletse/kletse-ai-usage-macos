import AppKit
import SwiftUI

enum PanelStyle {
    /// About the corner radius macOS 26 uses for windows and popovers.
    static let cornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 10
}

extension View {
    /// Liquid Glass on macOS 26+, a translucent material before that, clipped to rounded corners.
    @ViewBuilder
    func glassPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape).clipShape(shape)
        }
    }

    /// Translucent tile for an account, so the glass shows through.
    func cardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelStyle.cardCornerRadius, style: .continuous)
        return background(Color.primary.opacity(0.06), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// MenuBarExtra draws its panel as a square-cornered rectangle. This rounds the corners of the
/// hosting view so the window (and its shadow) takes the panel's rounded shape.
struct RoundedWindowCorners: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSView { CornerView(radius: radius) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CornerView: NSView {
        let radius: CGFloat

        init(radius: CGFloat) {
            self.radius = radius
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func layout() {
            super.layout()
            apply()
        }

        private func apply() {
            guard let window, let host = window.contentView else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            host.wantsLayer = true
            host.layer?.cornerRadius = radius
            host.layer?.cornerCurve = .continuous
            host.layer?.masksToBounds = true
            window.invalidateShadow()
        }
    }
}
