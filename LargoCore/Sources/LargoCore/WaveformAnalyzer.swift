import AVFoundation

public enum WaveformAnalyzer {
    /// Reads the file in chunks and returns `bins` peak amplitudes (0...1), mixed across channels.
    public static func peaks(url: URL, bins: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let format = file.processingFormat
        let total = file.length
        let framesPerBin = max(1, Double(total) / Double(bins))
        var peaks = [Float](repeating: 0, count: bins)

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }
        var frameIndex: AVAudioFramePosition = 0

        while frameIndex < total {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channelCount { v = max(v, abs(channels[c][i])) }
                let bin = min(bins - 1, Int(Double(frameIndex + AVAudioFramePosition(i)) / framesPerBin))
                if v > peaks[bin] { peaks[bin] = v }
            }
            frameIndex += AVAudioFramePosition(n)
        }

        let maxPeak = peaks.max() ?? 1
        return maxPeak > 0 ? peaks.map { $0 / maxPeak } : peaks
    }
}
