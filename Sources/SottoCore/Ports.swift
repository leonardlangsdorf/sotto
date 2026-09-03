import Foundation

/// Boundaries to the hardware. The app target supplies the real implementations;
/// tests supply fakes so the orchestration above can be exercised without a
/// microphone, an event tap, or Accessibility permission.

public protocol TextInjecting: Sendable {
    func inject(_ text: String, into target: TargetPID) async throws
}

public protocol Refining: Sendable {
    /// Must never throw for content reasons — callers rely on falling back to
    /// the raw transcript, so implementations return the input unchanged on
    /// timeout, refusal, or model error.
    func refine(_ transcript: String, vocabulary: [String]) async -> String
}

public protocol Transcribing: Sendable {
    func startCapture() async throws
    /// Stops capture, finalizes, and returns the assembled transcript.
    func finishAndTranscribe() async throws -> String
    func cancel() async
}
