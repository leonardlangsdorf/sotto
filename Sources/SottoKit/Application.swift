import AppKit
import SottoCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private lazy var coordinator = Coordinator(store: store)
    private let menuBar = MenuBarController()
    private let settingsWindow = SettingsWindowController()
    private lazy var settingsModel = SettingsModel(store: store)
    private var debugBridge: DebugBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsModel.onChange = { [weak self] in self?.coordinator.applySettings() }

        menuBar.onOpenSettings = { [weak self] in
            guard let self else { return }
            settingsModel.refinerAvailable = coordinator.refinerAvailable
            settingsModel.refinerUnavailableReason = coordinator.refinerUnavailableReason
            settingsWindow.show(model: settingsModel)
        }
        menuBar.onGrantAccessibility = {
            Permissions.requestAccessibility()
            Permissions.openSettings(.accessibility)
        }
        menuBar.onQuit = { NSApp.terminate(nil) }

        coordinator.onStatusChange = { [weak self] status in self?.menuBar.update(status) }
        menuBar.update(coordinator.status)

        debugBridge = DebugBridge(coordinator: coordinator)

        Task { await coordinator.start() }
    }
}

/// The only symbol the executable target needs. Everything else stays internal
/// so tests can reach it with `@testable import SottoKit`.
public enum SottoApplication {
    @MainActor
    public static func run() -> Never {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock icon, and critically, never steals focus from the
        // app the user is dictating into.
        app.setActivationPolicy(.accessory)
        app.run()
        fatalError("NSApplication.run() returned")
    }
}
