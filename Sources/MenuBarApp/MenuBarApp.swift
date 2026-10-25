import AppKit
import MenuBarCore
import SwiftUI

@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.coordinator)
                .environmentObject(settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var instance: AppDelegate?
    let coordinator: MenuBarCoordinator
    private var hotkeyToken: Int?

    override init() {
        coordinator = MenuBarCoordinator(settings: SettingsStore.shared)
        super.init()
        AppDelegate.instance = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
        applyHotkey()
    }

    // MARK: - 热键

    func applyHotkey() {
        if let token = hotkeyToken {
            HotkeyCenter.shared.unregister(token: token)
            hotkeyToken = nil
        }
        guard SettingsStore.shared.settings.hotkeyEnabled else { return }
        hotkeyToken = HotkeyCenter.shared.register(
            HotkeyCenter.Hotkey(
                keyCode: SettingsStore.shared.settings.hotkeyKeyCode,
                modifiers: SettingsStore.shared.settings.hotkeyModifiers
            )
        ) { [weak self] in
            Task { @MainActor in
                self?.coordinator.toggleHiddenSection()
            }
        }
    }
}
