import AppKit
import ApplicationServices

/// Best-effort screen position of the text caret, used to place the HUD.
///
/// Many apps (notably Electron ones) do not publish caret bounds over
/// Accessibility, so every step here is allowed to fail and fall back.
enum CaretLocator {
    static func caretPoint() -> NSPoint? {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused
        else { return nil }
        let focusedElement = element as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let range = rangeValue
        else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &boundsValue) == .success,
            let bounds = boundsValue
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.width.isFinite, rect.height.isFinite, !rect.isNull else { return nil }

        // Accessibility reports top-left origin; AppKit screens are bottom-left.
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return nil }
        return NSPoint(x: rect.minX, y: primaryHeight - rect.maxY)
    }
}
