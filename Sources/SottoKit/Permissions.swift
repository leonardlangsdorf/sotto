import AVFoundation
import AppKit
import ApplicationServices
import Carbon

/// The three gates between Sotto and a working dictation.
enum Permissions {
    /// Required for both the event tap and synthesizing the paste keystroke.
    ///
    /// This grant is attached to the binary's *code signature*, not its path.
    /// An unsigned rebuild silently loses it — see `Scripts/build.sh`.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// True while a password field is focused. macOS blocks event taps outright
    /// in this state, so dictation cannot work and we say so rather than
    /// appearing to hang.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    static func openSettings(_ pane: SettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    enum SettingsPane {
        case accessibility, microphone

        var urlString: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            }
        }
    }
}
