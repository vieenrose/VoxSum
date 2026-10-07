import AVFoundation

/// Microphone → 16 kHz mono float chunks (what `NemoEngine.push` takes).
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
    }

    func start(_ onChunk: @escaping ([Float]) -> Void) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement); try s.setActive(true)
        let input = engine.inputNode, inFmt = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFmt, to: out)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [self] buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFmt.sampleRate) + 16
            guard let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap), let conv = converter else { return }
            var fed = false
            conv.convert(to: o, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }; fed = true; st.pointee = .haveData; return buf
            }
            if let p = o.floatChannelData?[0], o.frameLength > 0 { onChunk(Array(UnsafeBufferPointer(start: p, count: Int(o.frameLength)))) }
        }
        engine.prepare(); try engine.start()
    }

    func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop(); try? AVAudioSession.sharedInstance().setActive(false) }
}

/// Android LiveAgc: gentle boost-only gain for the live mic (far speaker → audible to VAD/ASR), applied before the
/// WAV writer and the recognizer so every consumer hears the same signal. Envelope rises instantly, decays ~5 s;
/// gain moves slowly (~2 s) toward targetPeak/envelope, capped at maxGain, and holds during silence.
final class LiveAgc {
    private let targetPeak: Float, maxGain: Float
    private var envelope: Float = 0
    private(set) var gain: Float = 1
    init(targetPeak: Float = 0.35, maxGain: Float = 8) { self.targetPeak = targetPeak; self.maxGain = maxGain }
    @discardableResult func process(_ block: inout [Float]) -> Float {
        var pk: Float = 0
        for v in block { let a = abs(v); if a > pk { pk = a } }
        envelope = pk > envelope ? pk : max(envelope * 0.985, pk)
        if envelope > 0.004 { gain += (min(max(targetPeak / envelope, 1), maxGain) - gain) * 0.06 }
        if gain > 1.001 { for i in block.indices { block[i] = min(max(block[i] * gain, -1), 1) } }
        return gain
    }
}
