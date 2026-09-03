import AppKit
import Foundation
import SottoCore

/// Lets the running app be driven without a physical keypress, so the
/// hotkey-to-inserted-text path can be exercised in automation.
///
/// Disabled unless `SOTTO_DEBUG=1` is set in the environment: this posts
/// synthesized keystrokes into whatever app is frontmost, which is not
/// something a normally-launched build should expose.
@MainActor
final class DebugBridge {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOTTO_DEBUG"] == "1"
    }

    static let injectText = Notification.Name("com.langsdorf.sotto.debug.injectText")
    static let dictateFile = Notification.Name("com.langsdorf.sotto.debug.dictateFile")

    private weak var coordinator: Coordinator?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        guard Self.isEnabled else { return }

        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Self.injectText, object: nil, queue: .main
        ) { [weak self] note in
            let text = note.userInfo?["text"] as? String ?? "Sotto debug"
            MainActor.assumeIsolated {
                Log.dictation.info("debug: inject requested")
                self?.coordinator?.debugInject(text)
            }
        }
        center.addObserver(
            forName: Self.dictateFile, object: nil, queue: .main
        ) { [weak self] note in
            guard let path = note.userInfo?["path"] as? String else { return }
            MainActor.assumeIsolated {
                Log.dictation.info("debug: dictate file requested")
                self?.coordinator?.debugDictate(fileURL: URL(fileURLWithPath: path))
            }
        }
        Log.lifecycle.info("debug bridge enabled")
    }
}
