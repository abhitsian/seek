import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panel = PanelController()
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?
    var initialQuery: String?
    var snapshotPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Seek")
        statusItem.button?.toolTip = "Seek"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        panel.openSettings = { [weak self] in self?.showSettings() }
        Launcher.refreshIfStale()
        registerShortcut()
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerShortcut()
                self?.panel.engine.refreshReader()
            }
        }

        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if let initialQuery {
            panel.show(query: initialQuery)
        } else if firstLaunch || snapshotPath != nil {
            panel.show()
        }
        if let snapshotPath {
            // Wait for the search to settle (up to 20 s), then render once more after thumbnails load.
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<80 where self.panel.engine.status == .working {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .seconds(1.5))
                self.panel.snapshot(to: URL(fileURLWithPath: snapshotPath))
                NSApp.terminate(nil)
            }
        }
    }

    /// Opening Seek again (Finder, Spotlight, `open`) shows the search panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    private func registerShortcut() {
        hotKey?.unregister()
        let shortcut = Prefs.shortcut
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.panel.toggle()
        }
        if hotKey?.registered == false {
            NSLog("Seek: \(shortcut.label) is taken by another app; pick another shortcut in Settings")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = Prefs.shortcut
        let search = NSMenuItem(title: "Search Files", action: #selector(search), keyEquivalent: shortcut.menuKey)
        search.keyEquivalentModifierMask = shortcut.menuModifiers
        search.target = self
        menu.addItem(search)
        if hotKey?.registered == false {
            let taken = NSMenuItem(title: "\(shortcut.label) is taken by another app", action: nil, keyEquivalent: "")
            taken.isEnabled = false
            menu.addItem(taken)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsItem), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Seek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func search() { panel.show() }
    @objc private func openSettingsItem() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Seek Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
