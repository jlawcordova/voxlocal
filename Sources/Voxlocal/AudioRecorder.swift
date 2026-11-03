import AVFoundation

/// Captures microphone audio into memory as 16 kHz mono Float32 samples, the format Whisper
/// expects. Nothing is ever written to disk.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private(set) var isRecording = false
    /// Input level 0...1, delivered on the main thread at most ~30 times a second.
    var onLevel: (@MainActor (Float) -> Void)?
    private var lastLevelReport = Date.distantPast

    func start() throws {
        guard !isRecording else { return }
        lock.withLock { samples.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw RecorderError.noInput }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, to: target)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops recording and hands back the captured samples, clearing the internal buffer.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        return lock.withLock {
            let out = samples
            samples.removeAll()
            return out
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) {
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
        reportLevel(chunk)
    }

    private func reportLevel(_ chunk: UnsafeBufferPointer<Float>) {
        guard let onLevel, !chunk.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelReport) >= 1.0 / 30.0 else { return }
        lastLevelReport = now
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        // Map roughly -50 dB...0 dB to 0...1.
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(max((db + 50) / 50, 0), 1)
        DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(level) } }
    }

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }
}
