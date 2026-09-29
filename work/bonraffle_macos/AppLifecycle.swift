import AppKit
import Carbon

@MainActor
final class BonRaffleAppDelegate: NSObject, NSApplicationDelegate {
    weak var mainWindow: NSWindow?
    var openMainWindow: (() -> Void)?
    private var appliedLaunchFullScreen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI can consume the Dock reopen event before forwarding it to
        // applicationShouldHandleReopen. Keep SwiftUI's delegates in place.
        DispatchQueue.main.async { [self] in
            NSAppleEventManager.shared().setEventHandler(
                self, andSelector: #selector(handleReopen(_:withReplyEvent:)),
                forEventClass: AEEventClass(kCoreEventClass),
                andEventID: AEEventID(kAEReopenApplication))
        }
    }

    @objc private func handleReopen(_ event: NSAppleEventDescriptor,
                                    withReplyEvent reply: NSAppleEventDescriptor) {
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        !showMainWindow()
    }

    func attachMainWindow(_ window: NSWindow, startFullScreen: Bool) {
        mainWindow = window
        // Restoring or reattaching a window must not toggle full screen again.
        guard !appliedLaunchFullScreen else { return }
        appliedLaunchFullScreen = true
        if startFullScreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    @discardableResult
    func showMainWindow() -> Bool {
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return true
            }
        }
        // A closed SwiftUI window must be recreated through its scene. The
        // single Window scene also prevents duplicate raffle windows.
        guard let openMainWindow else { return false }
        openMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
