import SwiftUI
import AppKit

@main
struct ClipmacxxerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(app)
        } label: {
            Image(systemName: app.isRecording ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    // The app is menu-bar-only (LSUIElement), so there is no Dock icon.
    // The clip window opens from the popover's window button, or by
    // launching the app again while it is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        if let mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: MenuView().environmentObject(AppState.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clipmacxxer"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
