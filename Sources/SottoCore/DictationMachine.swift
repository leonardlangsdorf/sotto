import Foundation

/// Process ID of the app that was frontmost when dictation began.
public typealias TargetPID = Int32

/// Why a dictation ended without inserting text.
public enum AbortReason: Equatable, Sendable {
    /// The user switched apps mid-dictation. Pasting now would hit the wrong window.
    case focusChanged
    /// A password field is focused; macOS blocks event taps entirely.
    case secureInput
    /// The key was held but nothing intelligible was said.
    case emptyTranscript
    case transcriptionFailed(String)
    case injectionFailed(String)
    case notPermitted

    public var userMessage: String {
        switch self {
        case .focusChanged: return "Focus changed — text left on clipboard"
        case .secureInput: return "Secure field — dictation unavailable"
        case .emptyTranscript: return "Didn't catch anything"
        case .transcriptionFailed(let detail): return "Transcription failed — \(detail)"
        case .injectionFailed(let detail): return "Couldn't insert text — \(detail)"
        case .notPermitted: return "Missing permission"
        }
    }
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording(target: TargetPID)
    case transcribing(target: TargetPID)
    case injecting(target: TargetPID)

    public var isBusy: Bool { self != .idle }

    public var target: TargetPID? {
        switch self {
        case .idle: return nil
        case .recording(let t), .transcribing(let t), .injecting(let t): return t
        }
    }
}

public enum DictationEvent: Equatable, Sendable {
    case triggerPressed(target: TargetPID)
    case triggerReleased
    case transcriptReady(String)
    case injectionCompleted
    case abort(AbortReason)
}

public enum DictationEffect: Equatable, Sendable {
    case startCapture
    case stopCaptureAndFinalize
    case cancelCapture
    case deliver(text: String, target: TargetPID)
    case notify(AbortReason)
}

/// Pure transition function for the dictation lifecycle.
///
/// Kept free of any framework dependency so every path — including the abort
/// paths that are near-impossible to reproduce by hand — is unit testable.
public struct DictationMachine: Sendable {
    public private(set) var state: DictationState = .idle

    public init(state: DictationState = .idle) {
        self.state = state
    }

    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> [DictationEffect] {
        let (next, effects) = Self.reduce(state: state, event: event)
        state = next
        return effects
    }

    public static func reduce(
        state: DictationState,
        event: DictationEvent
    ) -> (DictationState, [DictationEffect]) {
        switch (state, event) {
        case (.idle, .triggerPressed(let target)):
            return (.recording(target: target), [.startCapture])

        case (.recording(let target), .triggerReleased):
            return (.transcribing(target: target), [.stopCaptureAndFinalize])

        case (.recording, .abort(let reason)):
            return (.idle, [.cancelCapture, .notify(reason)])

        case (.transcribing(let target), .transcriptReady(let text)):
            let cleaned = Transcript.normalize(text)
            // Never paste an empty string; a held key with no speech is a no-op.
            guard !cleaned.isEmpty else {
                return (.idle, [.notify(.emptyTranscript)])
            }
            return (.injecting(target: target), [.deliver(text: cleaned, target: target)])

        case (.transcribing, .abort(let reason)),
             (.injecting, .abort(let reason)):
            return (.idle, [.notify(reason)])

        case (.injecting, .injectionCompleted):
            return (.idle, [])

        // A second press while busy, or a stray release while idle. Both are
        // routine with a physical key and must not corrupt state.
        default:
            return (state, [])
        }
    }
}
