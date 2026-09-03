import Foundation

/// How text reaches the focused field.
public enum InsertionMethod: String, Codable, CaseIterable, Sendable {
    /// Pasteboard + synthesized ⌘V. Works essentially everywhere.
    case paste
    /// Synthesized Unicode keystrokes. Slower and drops text in some apps, but
    /// never touches the pasteboard — useful alongside a clipboard manager.
    case type

    public var label: String {
        switch self {
        case .paste: return "Paste (⌘V)"
        case .type: return "Type characters"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    /// Run the transcript through the on-device LLM before inserting.
    ///
    /// Off by default: cleanup costs roughly 0.6s per word of output, so a
    /// long dictation would sit on "Transcribing…" for many seconds. The raw
    /// transcript already arrives punctuated and capitalized.
    public var cleanupEnabled: Bool
    /// How long to wait after synthesizing paste before restoring the previous
    /// pasteboard. Too short and the target app reads stale contents.
    public var pasteboardRestoreDelay: TimeInterval
    /// Upper bound on the cleanup wait. The actual deadline scales with the
    /// length of the transcript — see `DictationRefiner.timeout(forWordCount:)`.
    public var refineMaximumWait: TimeInterval
    public var localeIdentifier: String
    public var insertionMethod: InsertionMethod
    public var vocabulary: Vocabulary

    public static let `default` = Settings(
        cleanupEnabled: false,
        pasteboardRestoreDelay: 0.15,
        refineMaximumWait: 20,
        localeIdentifier: "en-US",
        insertionMethod: .paste,
        vocabulary: Vocabulary()
    )

    public init(
        cleanupEnabled: Bool = false,
        pasteboardRestoreDelay: TimeInterval = 0.15,
        refineMaximumWait: TimeInterval = 20,
        localeIdentifier: String = "en-US",
        insertionMethod: InsertionMethod = .paste,
        vocabulary: Vocabulary = Vocabulary()
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.pasteboardRestoreDelay = pasteboardRestoreDelay
        self.refineMaximumWait = refineMaximumWait
        self.localeIdentifier = localeIdentifier
        self.insertionMethod = insertionMethod
        self.vocabulary = vocabulary
    }

    /// Tolerates a settings file written by an older build that lacks keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? d.cleanupEnabled
        pasteboardRestoreDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .pasteboardRestoreDelay) ?? d.pasteboardRestoreDelay
        refineMaximumWait = try c.decodeIfPresent(TimeInterval.self, forKey: .refineMaximumWait) ?? d.refineMaximumWait
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? d.localeIdentifier
        insertionMethod = try c.decodeIfPresent(InsertionMethod.self, forKey: .insertionMethod) ?? d.insertionMethod
        vocabulary = try c.decodeIfPresent(Vocabulary.self, forKey: .vocabulary) ?? d.vocabulary
    }
}

/// JSON-backed settings file in Application Support.
public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cached: Settings

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sotto/settings.json")
    }

    public init(url: URL = SettingsStore.defaultURL()) {
        self.url = url
        self.cached = Self.read(from: url) ?? .default
    }

    public var settings: Settings {
        get { lock.withLock { cached } }
        set {
            lock.withLock { cached = newValue }
            try? write(newValue)
        }
    }

    public func update(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    private static func read(from url: URL) -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    private func write(_ settings: Settings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
