import AVFoundation

/// Microphone tap that converts hardware buffers into the format the speech
/// analyzer asked for, and reports an input level for the HUD meter.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var running = false

    /// Called on the audio thread. Keep the work here trivial.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onLevel: (@Sendable (Double) -> Void)?

    enum CaptureError: LocalizedError {
        case converterUnavailable

        var errorDescription: String? {
            "Could not convert microphone audio to the format the recognizer needs."
        }
    }

    func start(outputFormat: AVAudioFormat) throws {
        guard !running else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter
        self.outputFormat = outputFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(Self.level(of: buffer))
            if let converted = self.convert(buffer) {
                self.onBuffer?(converted)
            }
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        outputFormat = nil
        running = false
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// RMS of the first channel, curved so quiet speech still moves the meter.
    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = Double((sum / Float(count)).squareRoot())
        return min(1, rms * 12)
    }
}
