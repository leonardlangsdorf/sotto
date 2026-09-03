import Foundation
import FoundationModels
import Testing
@testable import SottoKit

/// Measures what cleanup actually costs once the model is warm, which is what
/// the `refineTimeout` default has to be set against.
@Suite("Refiner latency", .serialized)
struct RefinerLatencyTests {
    @Test("Report cold and warm cleanup latency")
    func measureLatency() async throws {
        guard SystemLanguageModel.default.isAvailable else {
            print("SKIP: Apple Intelligence unavailable.")
            return
        }

        let refiner = await MainActor.run { DictationRefiner() }
        await MainActor.run { refiner.maximumWait = 60 }

        let samples = [
            "um so like can you send the deck to sarah uh by friday you know",
            "i think we should uh push the release to next week because the tests are you know still failing",
            "can you remind me to um follow up with the design team tomorrow morning",
        ]

        await MainActor.run { refiner.prewarm() }

        var timings: [Double] = []
        for (index, sample) in samples.enumerated() {
            let start = ContinuousClock.now
            let result = await refiner.refine(sample, vocabulary: ["Sarah"])
            let elapsed = Double(start.duration(to: .now).components.seconds)
                + Double(start.duration(to: .now).components.attoseconds) / 1e18
            timings.append(elapsed)
            print(String(format: "  [%d] %.2fs  %@", index, elapsed, result))
        }

        let warm = timings.dropFirst()
        print(String(format: "COLD: %.2fs", timings[0]))
        print(String(format: "WARM: min %.2fs  max %.2fs",
                     warm.min() ?? 0, warm.max() ?? 0))
    }
}
