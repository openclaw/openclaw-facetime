import AVFAudio

@MainActor
final class TonePlayer {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Tone.rate, channels: 1)!
    private var generation = PlaybackGeneration()
    private(set) var playing = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func startSilentEngine() throws {
        if !engine.isRunning { try engine.start() }
    }

    func play(duration: Double) throws {
        let samples = try Tone.samples(duration: duration)
        guard engine.isRunning else { throw ProbeError("engine is not running; prepare/enable again") }
        stopTone()
        let current = generation.value
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw ProbeError("cannot allocate bounded tone") }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // One completion per finite command, never one dispatch per render callback.
            DispatchQueue.main.async {
                guard let self, self.generation.accepts(current) else { return }
                self.stopTone()
            }
        }
        player.play()
        playing = true
    }

    func stopTone() {
        generation.invalidate()
        player.stop()
        playing = false
    }

    func shutdown() { stopTone(); engine.stop() }
}
