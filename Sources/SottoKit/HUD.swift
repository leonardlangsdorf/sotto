import AppKit
import SwiftUI

enum HUDState: Equatable {
    case hidden
    case recording(level: Double, partial: String)
    case transcribing
    case message(String)
}

@Observable
final class HUDModel {
    var state: HUDState = .hidden
}

/// A borderless, non-activating panel.
///
/// `canBecomeKey` must stay false: the instant this window takes focus, macOS
/// changes the frontmost app and the transcript lands in the wrong place.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {
    private let model = HUDModel()
    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?

    private static let size = NSSize(width: 280, height: 46)

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ state: HUDState) {
        dismissTask?.cancel()
        model.state = state
        reposition()
        panel.orderFrontRegardless()
    }

    /// Transient states (errors, "didn't catch anything") clear themselves.
    func flash(_ message: String, for duration: Duration = .seconds(2)) {
        show(.message(message))
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        model.state = .hidden
        panel.orderOut(nil)
    }

    private func reposition() {
        let size = Self.size
        if let caret = CaretLocator.caretPoint() {
            panel.setFrameOrigin(NSPoint(x: caret.x, y: caret.y - size.height - 8))
            return
        }
        // Fall back to bottom-centre of the screen holding the pointer.
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90))
    }
}

private struct HUDView: View {
    @Bindable var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .hidden:
                EmptyView()
            case .recording(let level, let partial):
                LevelMeter(level: level)
                Text(partial.isEmpty ? "Listening…" : partial)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(partial.isEmpty ? .secondary : .primary)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            case .message(let text):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(text).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Seven bars rising from the centre, driven by input level.
private struct LevelMeter: View {
    let level: Double
    private static let bars = 7

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(.red)
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .frame(width: 26, height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> Double {
        let centre = Double(Self.bars - 1) / 2
        let falloff = 1 - abs(Double(index) - centre) / (centre + 1)
        return max(3, 18 * level.clamped(to: 0...1) * falloff)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
