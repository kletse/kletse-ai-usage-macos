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

        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // MenuBarExtra can keep a stale window size, e.g. after moving to another display.
            // This view keeps its own frame then, so layout() alone would miss it.
            let names = [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeBackingPropertiesNotification, NSWindow.didBecomeKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
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
            fitWindowToPanel(window)
            window.invalidateShadow()
        }

        /// A window larger than the panel shows up as a square outline and shadow around the glass.
        /// This view is the panel's background, so its size is the size the window should have.
        private func fitWindowToPanel(_ window: NSWindow) {
            var size = bounds.size
            if let visible = window.screen?.visibleFrame { size.height = min(size.height, visible.height) }
            guard size.width > 0, size.height > 0, window.frame.size != size else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            window.setFrame(frame, display: true)
        }
    }
}
