import AppKit
import CoreGraphics
import SottoCore

/// Inserts text into whatever app is frontmost.
///
/// Pasteboard + synthesized ⌘V is the only approach that works across native,
/// Electron, and terminal apps alike. The direct-typing fallback exists for the
/// handful of apps that ignore programmatic paste.
@MainActor
final class PasteboardInjector: TextInjecting {
    /// kVK_ANSI_V
    private static let vKeyCode: CGKeyCode = 0x09

    private let restoreDelay: () -> TimeInterval
    private let method: () -> InsertionMethod

    init(
        restoreDelay: @escaping () -> TimeInterval,
        method: @escaping () -> InsertionMethod = { .paste }
    ) {
        self.restoreDelay = restoreDelay
        self.method = method
    }

    enum InjectError: LocalizedError {
        case focusChanged
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .focusChanged: return "The frontmost app changed during dictation."
            case .eventCreationFailed: return "Could not synthesize the paste keystroke."
            }
        }
    }

    func inject(_ text: String, into target: TargetPID) async throws {
        // If the user ⌘-tabbed mid-dictation, pasting now would drop the text
        // into the wrong window. Leave it on the clipboard instead.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            throw InjectError.focusChanged
        }

        if method() == .type {
            try typeDirectly(text)
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try synthesizePaste()

        // The target app reads the pasteboard asynchronously after ⌘V arrives.
        // Restoring too early hands it the *previous* contents.
        try? await Task.sleep(for: .seconds(restoreDelay()))
        restore(saved, to: pasteboard)
    }

    private func synthesizePaste() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else { throw InjectError.eventCreationFailed }

        // Set flags explicitly: whatever modifiers were physically held during
        // dictation must not leak into the synthesized keystroke.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Synthesizes the text as Unicode keystrokes, leaving the pasteboard alone.
    ///
    /// Posted in small chunks: a single event carries a limited UTF-16 payload,
    /// and oversized ones are silently dropped by the window server.
    private func typeDirectly(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunkSize = 16

        for start in stride(from: 0, to: units.count, by: chunkSize) {
            var chunk = Array(units[start..<min(start + chunkSize, units.count)])
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw InjectError.eventCreationFailed }

            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
