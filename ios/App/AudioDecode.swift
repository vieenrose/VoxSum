import AVFoundation

/// Any audio file the system can read (m4a, mp3, wav, caf, aac…) → 16 kHz mono float chunks of ~1 s,
/// streamed so an hour-long recording never sits in memory. `onChunk` returns false to stop early.
enum AudioDecode {
    static func duration(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    static func stream(_ url: URL, onChunk: ([Float]) -> Bool) throws {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFmt, to: out) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let inCap: AVAudioFrameCount = 16384
        while file.framePosition < file.length {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap) else { break }
            // A bad packet mid-file (seen at 2422 s of a 45 min mp3: avfaudio 560164718) cannot be skipped by AVAudioFile:
            // keep what was decoded instead of discarding the whole recording.
            do { try file.read(into: inBuf, frameCount: inCap) } catch {
                if file.framePosition == 0 { throw error }
                StatusLog.add("trace audio decode stopped at \(Int(Double(file.framePosition) / inFmt.sampleRate)) s: \(error)")
                return
            }
            if inBuf.frameLength == 0 { break }
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / inFmt.sampleRate) + 32
            guard let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { break }
            var fed = false
            var err: NSError?
            conv.convert(to: o, error: &err) { _, st in
                if fed { st.pointee = .noDataNow; return nil }; fed = true; st.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            if let p = o.floatChannelData?[0], o.frameLength > 0,
               !onChunk(Array(UnsafeBufferPointer(start: p, count: Int(o.frameLength)))) { return }
        }
    }
}
