import Foundation

/// Terms biased toward during recognition — product names, teammates, jargon.
///
/// Capped deliberately: contextual strings bias the decoder, and an oversized
/// list degrades general accuracy rather than improving it.
public struct Vocabulary: Codable, Equatable, Sendable {
    public static let maxTerms = 100

    public private(set) var terms: [String]

    public init(terms: [String] = []) {
        self.terms = Self.canonical(terms)
    }

    /// Returns false if the term was empty, a duplicate, or the list is full.
    @discardableResult
    public mutating func add(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, terms.count < Self.maxTerms else { return false }
        guard !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return false }
        terms.append(trimmed)
        return true
    }

    public mutating func remove(_ term: String) {
        terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    public var isFull: Bool { terms.count >= Self.maxTerms }

    /// Trims, drops empties, removes case-insensitive duplicates keeping the
    /// first spelling, and truncates to the cap.
    private static func canonical(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in raw {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
            if out.count == maxTerms { break }
        }
        return out
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.terms = Self.canonical(try container.decode([String].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(terms)
    }
}
