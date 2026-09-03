import Foundation

public enum Transcript {
    /// Joins the finalized fragments emitted by the transcriber into one string.
    public static func assemble(_ fragments: [String]) -> String {
        normalize(fragments.joined(separator: " "))
    }

    /// Collapses runs of whitespace and trims. Returns "" for whitespace-only input.
    public static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
