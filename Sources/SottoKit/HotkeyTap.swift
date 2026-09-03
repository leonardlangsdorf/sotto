import AppKit
import CoreGraphics

/// Watches for Right-Command being held.
///
/// Right-⌘ is distinguished from Left-⌘ by keycode *and* by the device-dependent
/// flag bit, so holding both never confuses the state. The tap is `.listenOnly`:
/// events pass through untouched, which is why ⌘C/⌘V/⌘T keep working normally.
@MainActor
final class HotkeyTap {
    /// kVK_RightCommand
    private static let rightCommandKeyCode: Int64 = 0x36
    /// NX_DEVICERCMDKEYMASK
    private static let rightCommandFlag: UInt64 = 0x0000_0010

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

    enum StartError: LocalizedError {
        case notPermitted
        case tapCreationFailed

        var errorDescription: String? {
            switch self {
            case .notPermitted: return "Accessibility permission is required to watch for the hotkey."
            case .tapCreationFailed: return "Could not create the keyboard event tap."
            }
        }
    }

    func start() throws {
        guard Permissions.hasAccessibility else { throw StartError.notPermitted }
        guard machPort == nil else { return }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { tap.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw StartError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        machPort = port
        runLoopSource = source
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        runLoopSource = nil
        machPort = nil
        isHeld = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that blocks for too long. Re-arm rather
        // than dying silently, which would look like the hotkey "just stopped".
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = machPort { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightCommandKeyCode
        else { return }

        let down = (event.flags.rawValue & Self.rightCommandFlag) != 0
        guard down != isHeld else { return }
        isHeld = down
        down ? onPress?() : onRelease?()
    }
}
