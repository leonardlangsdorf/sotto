import AppKit

@MainActor
final class MenuBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var onOpenSettings: (() -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        item.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Sotto")
        update(.startingUp)
    }

    func update(_ status: AppStatus) {
        item.button?.image = NSImage(
            systemSymbolName: status.symbolName, accessibilityDescription: "Sotto — \(status.summary)")
        item.button?.contentTintColor = status == .recording ? .systemRed : nil

        let menu = NSMenu()
        let statusItem = NSMenuItem(title: status.summary, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        switch status {
        case .needsAccessibility:
            menu.addItem(action(title: "Open Accessibility Settings…") {
                [weak self] in self?.onGrantAccessibility?()
            })
        case .needsMicrophone:
            menu.addItem(action(title: "Open Microphone Settings…") {
                Permissions.openSettings(.microphone)
            })
        default:
            break
        }

        menu.addItem(action(title: "Settings…", key: ",") { [weak self] in self?.onOpenSettings?() })
        menu.addItem(.separator())
        menu.addItem(action(title: "Quit Sotto", key: "q") { [weak self] in self?.onQuit?() })

        item.menu = menu
    }

    private func action(title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
        let target = MenuAction(handler: handler)
        item.target = target
        item.representedObject = target  // keeps the target alive
        return item
    }
}

private final class MenuAction: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
