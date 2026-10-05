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
