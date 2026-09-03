import Testing
@testable import SottoKit

/// The deadline has to track output length: generation costs roughly half a
/// second per word, so a fixed timeout either fails every long dictation or
/// wastes time on every short one.
@Suite("Adaptive cleanup deadline")
struct RefinerTimeoutTests {
    @Test("Short transcripts still get the minimum")
    func shortGetsFloor() {
        #expect(DictationRefiner.timeout(forWordCount: 1, maximumWait: 20)
            == DictationRefiner.minimumWait)
        #expect(DictationRefiner.timeout(forWordCount: 0, maximumWait: 20)
            == DictationRefiner.minimumWait)
    }

    @Test("The deadline grows with the transcript")
    func scalesWithLength() {
        let short = DictationRefiner.timeout(forWordCount: 10, maximumWait: 60)
        let long = DictationRefiner.timeout(forWordCount: 40, maximumWait: 60)
        #expect(long > short)
        #expect(long == 40 * DictationRefiner.secondsPerWord)
    }

    @Test("The maximum wait caps it")
    func respectsCeiling() {
        #expect(DictationRefiner.timeout(forWordCount: 1000, maximumWait: 20) == 20)
    }

    @Test("A realistic dictation gets enough time to actually finish")
    func realisticDictationIsNotCutShort() {
        // 40 words measured at ~0.4s/word ≈ 16s; the old fixed 1.5s guaranteed
        // a silent fallback to raw on anything but a short sentence.
        #expect(DictationRefiner.timeout(forWordCount: 40, maximumWait: 30) >= 16)
    }
}
