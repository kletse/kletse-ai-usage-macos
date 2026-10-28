import AppKit
import SwiftUI

/// The Accounts window. An AppKit window rather than a SwiftUI `Window` scene: only a window
/// created with `.fullSizeContentView` and a toolbar gets the macOS 26 glass sidebar and title bar,
/// and showing it directly avoids the scene machinery's extra resize while it animates in.
@MainActor
final class AccountsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AccountsWindowController?
    private let saver: AccountsAutosaver

    static func show(store: UsageStore) {
        let controller = shared ?? AccountsWindowController(store: store)
        shared = controller
        // Let the menu bar panel finish closing first so the two animations don't overlap.
        DispatchQueue.main.async {
            controller.showWindow(nil)
        }
    }

    private init(store: UsageStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        saver = AccountsAutosaver(store: store)
        super.init(window: window)

        window.title = "Accounts"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        // An empty toolbar gives the title bar its unified look over the sidebar and detail.
        window.toolbar = NSToolbar(identifier: "accounts")
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.minSize = NSSize(width: 760, height: 560)
        window.delegate = self

        let hosting = NSHostingController(rootView: AccountEditor(store: store, saver: saver))
        // The window owns its size; don't let SwiftUI resize it while it opens.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 840, height: 640))
        if !window.setFrameUsingName("AccountsWindow") { window.center() }
        window.setFrameAutosaveName("AccountsWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        // A menu bar app stays an accessory: becoming a regular app to show one window makes a
        // Dock icon pop in and out, which is the jank this avoids.
        NSApp.activate()
        window?.makeKeyAndOrderFront(sender)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Write the last edit now, so reopening straight away loads it.
        saver.flush()
        // A fresh editor next time, so it reloads the config.
        Self.shared = nil
    }
}
