import AppKit
import SwiftUI

enum PanelStyle {
    static let cornerRadius: CGFloat = 26
}

extension View {
    /// Liquid Glass on macOS 26+, a translucent material before that, clipped to rounded corners.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape).clipShape(shape)
        }
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
