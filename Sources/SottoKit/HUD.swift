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

    /// Roomy enough for the glow and the scale-in to render without clipping.
    static let size = NSSize(width: 260, height: 92)

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
        panel.hasShadow = false  // the view draws its own, so the glow isn't boxed
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

    /// Parked at the bottom of the active screen rather than chasing the caret.
    ///
    /// A fixed spot is easier to read at a glance than one that moves per app —
    /// you learn where to look once instead of hunting for it every time.
    private func reposition() {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(
                x: frame.midX - Self.size.width / 2,
                y: frame.minY + 72,
                width: Self.size.width,
                height: Self.size.height),
            display: false)
    }
}

// MARK: - View

struct HUDView: View {
    @Bindable var model: HUDModel
    @State private var appeared: Bool

    init(model: HUDModel) {
        self.model = model
        // Already-live state means this is a static render, not a fresh show.
        _appeared = State(initialValue: model.state != .hidden)
    }

    var body: some View {
        pill
            .scaleEffect(appeared ? 1 : 0.86)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: appeared)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { appeared = true }
            .onChange(of: model.state) { _, new in
                appeared = new != .hidden
            }
    }

    private var pill: some View {
        HStack(spacing: 11) {
            leading
            label
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background {
            ZStack {
                // Deliberately dark in both themes. This is an overlay floating
                // over someone else's window, not a document — a light chip
                // disappears against light content.
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.82))
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.10), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom))
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.22),
                                accent.opacity(isLive ? 0.30 : 0.06),
                            ],
                            startPoint: .top,
                            endPoint: .bottom),
                        lineWidth: 1)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var leading: some View {
        switch model.state {
        case .recording(let level, _):
            Waveform(level: level, accent: accent)
        case .transcribing:
            Waveform(level: 0, accent: accent, thinking: true)
        case .message:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.5))
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var label: some View {
        switch model.state {
        case .recording(_, let partial):
            Text(partial.isEmpty ? "Listening" : partial)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.white.opacity(partial.isEmpty ? 0.55 : 0.95))
                .frame(maxWidth: 150, alignment: .leading)
        case .transcribing:
            Text("Transcribing")
                .foregroundStyle(.white.opacity(0.55))
        case .message(let text):
            Text(text)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: 170, alignment: .leading)
        case .hidden:
            EmptyView()
        }
        // Fixed metrics: a pill that resizes on every partial result is worse
        // to look at than one that stays put.
    }

    private var isLive: Bool {
        if case .recording = model.state { return true }
        if case .transcribing = model.state { return true }
        return false
    }

    private var accent: Color {
        switch model.state {
        case .recording: return Color(red: 1.0, green: 0.29, blue: 0.31)
        case .transcribing: return Color(red: 0.38, green: 0.68, blue: 1.0)
        default: return .white
        }
    }
}

/// Bars driven by live input level, with per-bar phase so the motion looks
/// organic rather than a synchronised bounce.
///
/// `TimelineView` drives the animation independently of level updates, so the
/// waveform keeps breathing between audio callbacks instead of stepping.
struct Waveform: View {
    let level: Double
    let accent: Color
    var thinking = false

    private static let barCount = 5
    private static let barWidth: Double = 3
    private static let maxHeight: Double = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent, accent.opacity(0.62)],
                                startPoint: .top,
                                endPoint: .bottom))
                        .frame(width: Self.barWidth, height: height(index, time))
                }
            }
            .frame(width: 30, height: Self.maxHeight)
        }
    }

    private func height(_ index: Int, _ time: TimeInterval) -> Double {
        let phase = Double(index) * 0.7

        if thinking {
            // A wave travelling left to right while the model works.
            let travel = sin(time * 4 - phase)
            return 4 + 8 * (travel + 1) / 2
        }

        // Taller in the middle, so quiet speech still reads as a voice shape.
        let centre = Double(Self.barCount - 1) / 2
        let profile = 1 - abs(Double(index) - centre) / (centre + 1.4)
        let wobble = (sin(time * 9 + phase) + 1) / 2
        let energy = max(0.06, level.clamped(to: 0...1))
        return 4 + (Self.maxHeight - 4) * energy * profile * (0.55 + 0.45 * wobble)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
