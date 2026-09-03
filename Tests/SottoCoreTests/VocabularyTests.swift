import Foundation
import Testing
@testable import SottoCore

@Suite("Vocabulary")
struct VocabularyTests {
    @Test("Duplicates are dropped case-insensitively, first spelling wins")
    func dedupes() {
        let v = Vocabulary(terms: ["Mento", "mento", "MENTO", "Linear"])
        #expect(v.terms == ["Mento", "Linear"])
    }

    @Test("Blank terms are dropped and surrounding space trimmed")
    func trimsAndDropsBlanks() {
        let v = Vocabulary(terms: ["  Obsidian  ", "", "   ", "Kairo"])
        #expect(v.terms == ["Obsidian", "Kairo"])
    }

    @Test("The list is capped so it cannot degrade recognition")
    func capsAtMax() {
        let v = Vocabulary(terms: (0..<250).map { "term\($0)" })
        #expect(v.terms.count == Vocabulary.maxTerms)
        #expect(v.isFull)
    }

    @Test("Adding rejects blanks, duplicates, and overflow")
    func addRejects() {
        var v = Vocabulary(terms: ["Sotto"])
        let addedNew = v.add("Engram")
        let addedBlank = v.add("  ")
        let addedDuplicate = v.add("sotto")
        #expect(addedNew)
        #expect(!addedBlank)
        #expect(!addedDuplicate)
        #expect(v.terms == ["Sotto", "Engram"])

        var full = Vocabulary(terms: (0..<Vocabulary.maxTerms).map { "t\($0)" })
        let addedWhenFull = full.add("overflow")
        #expect(!addedWhenFull)
    }

    @Test("Removal ignores case")
    func removesCaseInsensitively() {
        var v = Vocabulary(terms: ["Rostr", "Folio"])
        v.remove("ROSTR")
        #expect(v.terms == ["Folio"])
    }

    @Test("Codable round trip preserves and re-canonicalizes")
    func codableRoundTrip() throws {
        let v = Vocabulary(terms: ["Alpha", "Beta"])
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(Vocabulary.self, from: data) == v)

        // A hand-edited file with junk still loads clean.
        let messy = Data(#"["Alpha","alpha","","Beta"]"#.utf8)
        #expect(try JSONDecoder().decode(Vocabulary.self, from: messy).terms == ["Alpha", "Beta"])
    }
}

@Suite("Settings store")
struct SettingsStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    @Test("Missing file falls back to defaults")
    func defaultsWhenAbsent() {
        #expect(SettingsStore(url: tempURL()).settings == .default)
    }

    @Test("Changes survive a reload")
    func persists() {
        let url = tempURL()
        let store = SettingsStore(url: url)
        store.update {
            $0.cleanupEnabled = true
            $0.pasteboardRestoreDelay = 0.4
            $0.insertionMethod = .type
            $0.vocabulary.add("Sotto")
        }

        let reloaded = SettingsStore(url: url).settings
        #expect(reloaded.cleanupEnabled == true)
        #expect(reloaded.pasteboardRestoreDelay == 0.4)
        #expect(reloaded.insertionMethod == .type)
        #expect(reloaded.vocabulary.terms == ["Sotto"])
    }

    @Test("A settings file from an older build fills in missing keys")
    func toleratesPartialFile() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cleanupEnabled": true}"#.utf8).write(to: url)

        let s = SettingsStore(url: url).settings
        #expect(s.cleanupEnabled == true)
        #expect(s.refineMaximumWait == Settings.default.refineMaximumWait)
        #expect(s.localeIdentifier == Settings.default.localeIdentifier)
        #expect(s.insertionMethod == Settings.default.insertionMethod)
    }
}
