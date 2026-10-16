import AVFoundation
import Accelerate

/// Offline chord recognition.
///
/// 1. Mix to mono and decimate to ~22 kHz.
/// 2. Estimate the recording's tuning offset from spectral peaks.
/// 3. Build a log-compressed chromagram (plus a separate bass chromagram).
/// 4. Score every frame against harmonic-aware chord templates.
/// 5. Viterbi-smooth the frame scores into stable chord segments.
public enum ChordAnalyzer {
    public struct Options: Sendable {
        /// Cost of changing chord between frames; higher means fewer, longer chords.
        public var switchPenalty: Float = 0.35
        /// Score multiplier for 7th chords so plain triads win when the evidence is equal.
        public var seventhWeight: Float = 0.96
        public var includeSevenths = true
        public init() {}
    }

    // MARK: Entry points

    /// Analyze an audio file. `progress` is called with values in 0...1 from a background thread.
    public static func analyze(url: URL, options: Options = Options(),
                               progress: ((Double) -> Void)? = nil) throws -> ChordAnalysis {
        let (samples, rate) = try loadMono(url: url) { progress?($0 * 0.3) }
        return analyze(samples: samples, sampleRate: rate, options: options) { progress?(0.3 + $0 * 0.7) }
    }

    public static func analyze(samples input: [Float], sampleRate inputRate: Double,
                               options: Options = Options(),
                               progress: ((Double) -> Void)? = nil) -> ChordAnalysis {
        var samples = input
        var sampleRate = inputRate
        while sampleRate >= 32_000 {
            samples = decimateByTwo(samples)
            sampleRate /= 2
        }

        var fftSize = 1024
        while Double(fftSize) < sampleRate * 0.37 { fftSize *= 2 } // ~8192 at 22 kHz → 2.7 Hz bins
        let hop = fftSize / 4
        guard samples.count >= fftSize else {
            return ChordAnalysis(segments: [], key: nil, tuningCents: 0)
        }

        let spectrum = Spectrum(size: fftSize)
        let frameCount = (samples.count - fftSize) / hop + 1
        let hopSeconds = Double(hop) / sampleRate

        let tuning = estimateTuning(samples: samples, sampleRate: sampleRate, hop: hop, spectrum: spectrum)
        progress?(0.2)

        // Chromagram
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 12), count: frameCount)
        var bass = chroma
        var energy = [Float](repeating: 0, count: frameCount)
        let binHz = sampleRate / Double(fftSize)
        let maxBin = min(fftSize / 2 - 1, Int(2_100 / binHz))
        let minBin = max(1, Int(60 / binHz))
        let bassMaxBin = Int(260 / binHz)
        var binPitchClass = [Int](repeating: 0, count: fftSize / 2)
        for k in minBin...maxBin {
            let midi = 69 + 12 * log2(Double(k) * binHz / 440) - tuning / 100
            binPitchClass[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        for f in 0..<frameCount {
            let start = f * hop
            let mags = samples.withUnsafeBufferPointer { buf in
                spectrum.magnitudes(of: UnsafeBufferPointer(rebasing: buf[start..<start + fftSize]))
            }
            energy[f] = spectrum.lastRMS
            for k in minBin...maxBin {
                let v = log1p(1_000 * mags[k])
                chroma[f][binPitchClass[k]] += v
                if k <= bassMaxBin { bass[f][binPitchClass[k]] += v }
            }
            if f % 64 == 0 { progress?(0.2 + 0.6 * Double(f) / Double(frameCount)) }
        }

        // Light temporal smoothing (±2 frames), then normalize.
        chroma = smooth(chroma, radius: 2).map(normalized)
        bass = smooth(bass, radius: 2).map(normalized)

        // Frame scoring
        let chords = candidateChords(includeSevenths: options.includeSevenths)
        let templates = chords.map(template(for:))
        let silenceThreshold = (energy.max() ?? 0) * 0.01 // −40 dB
        var scores = [[Float]](repeating: [], count: frameCount)
        for f in 0..<frameCount {
            var row = [Float](repeating: 0, count: chords.count + 1)
            let silent = energy[f] < silenceThreshold
            for (i, chord) in chords.enumerated() {
                var s = dot(chroma[f], templates[i])
                s += 0.12 * bass[f][chord.root!] // the bass note usually is the root
                if chord.quality.intervals.count == 4 { s *= options.seventhWeight }
                row[i] = silent ? 0 : s
            }
            row[chords.count] = silent ? 2 : 0.35 // "no chord"
            scores[f] = row
        }
        progress?(0.9)

        // Viterbi decoding with a uniform switch penalty
        let path = viterbi(scores: scores, penalty: options.switchPenalty)
        let allChords = chords + [Chord.none]

        var segments: [ChordSegment] = []
        for (f, state) in path.enumerated() {
            let chord = allChords[state]
            let t = Double(f) * hopSeconds
            if let last = segments.last, last.chord == chord {
                segments[segments.count - 1].end = t + hopSeconds
            } else {
                segments.append(ChordSegment(start: t, end: t + hopSeconds, chord: chord))
            }
        }
        // Frame f's window is centered at f*hop + fftSize/2; shift boundaries to match.
        let offset = Double(fftSize / 2) / sampleRate - hopSeconds / 2
        let duration = Double(samples.count) / sampleRate
        for i in segments.indices {
            segments[i].start = i == 0 ? 0 : min(duration, segments[i].start + offset)
            segments[i].end = i == segments.count - 1 ? duration : min(duration, segments[i].end + offset)
        }

        let key = estimateKey(chroma: chroma, energy: energy, silenceThreshold: silenceThreshold)
        progress?(1)
        return ChordAnalysis(segments: segments, key: key, tuningCents: tuning)
    }

    // MARK: Loading

    static func loadMono(url: URL, progress: (Double) -> Void) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 131_072
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            return ([], format.sampleRate)
        }
        var out = [Float]()
        out.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += data[c][i] }
                out.append(v / Float(channels))
            }
            progress(Double(file.framePosition) / Double(file.length))
        }
        return (out, format.sampleRate)
    }

    static func decimateByTwo(_ x: [Float]) -> [Float] {
        // 3-tap low-pass [1/4, 1/2, 1/4] then keep every other sample.
        guard x.count > 2 else { return x }
        var out = [Float](repeating: 0, count: x.count / 2)
        for i in 0..<out.count {
            let j = 2 * i
            let prev = j > 0 ? x[j - 1] : x[j]
            let next = j + 1 < x.count ? x[j + 1] : x[j]
            out[i] = 0.25 * prev + 0.5 * x[j] + 0.25 * next
        }
        return out
    }

    // MARK: Tuning

    /// Circular mean of the fractional MIDI pitch of strong spectral peaks, in cents (−50...50).
    private static func estimateTuning(samples: [Float], sampleRate: Double, hop: Int, spectrum: Spectrum) -> Double {
        let size = spectrum.size
        let binHz = sampleRate / Double(size)
        let lo = max(2, Int(100 / binHz)), hi = min(size / 2 - 2, Int(2_000 / binHz))
        var sx = 0.0, sy = 0.0
        let frames = (samples.count - size) / hop + 1
        let stride = max(1, frames / 300) // a few hundred frames is plenty
        for f in Swift.stride(from: 0, to: frames, by: stride) {
            let start = f * hop
            let m = samples.withUnsafeBufferPointer { buf in
                spectrum.magnitudes(of: UnsafeBufferPointer(rebasing: buf[start..<start + size]))
            }
            let peakFloor = (m[lo...hi].max() ?? 0) * 0.1
            for k in lo...hi where m[k] > peakFloor && m[k] > m[k - 1] && m[k] >= m[k + 1] {
                // Parabolic interpolation for sub-bin accuracy
                let a = Double(m[k - 1]), b = Double(m[k]), c = Double(m[k + 1])
                let denom = a - 2 * b + c
                let delta = denom == 0 ? 0 : 0.5 * (a - c) / denom
                let freq = (Double(k) + delta) * binHz
                let midi = 69 + 12 * log2(freq / 440)
                let angle = 2 * Double.pi * (midi - midi.rounded())
                sx += b * cos(angle)
                sy += b * sin(angle)
            }
        }
        guard sx != 0 || sy != 0 else { return 0 }
        return atan2(sy, sx) / (2 * .pi) * 100
    }

    // MARK: Templates

    private static func candidateChords(includeSevenths: Bool) -> [Chord] {
        let qualities: [ChordQuality] = includeSevenths ? ChordQuality.allCases : [.major, .minor]
        return qualities.flatMap { q in (0..<12).map { Chord(root: $0, quality: q) } }
    }

    /// Chord template that also accounts for the first few harmonics of each note
    /// (octave, fifth, major third), which is what a real chromagram actually contains.
    private static func template(for chord: Chord) -> [Float] {
        let harmonics: [(offset: Int, weight: Float)] = [(0, 1), (0, 0.6), (7, 0.36), (0, 0.22), (4, 0.13), (7, 0.08)]
        var t = [Float](repeating: 0, count: 12)
        for interval in chord.quality.intervals {
            for h in harmonics { t[(chord.root! + interval + h.offset) % 12] += h.weight }
        }
        return normalized(t)
    }

    // MARK: Decoding

    private static func viterbi(scores: [[Float]], penalty: Float) -> [Int] {
        guard let first = scores.first else { return [] }
        let n = first.count
        var dp = first
        var back = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: scores.count)
        for t in 1..<scores.count {
            var bestPrev = 0
            for s in 1..<n where dp[s] > dp[bestPrev] { bestPrev = s }
            let switchScore = dp[bestPrev] - penalty
            var next = [Float](repeating: 0, count: n)
            for s in 0..<n {
                if dp[s] >= switchScore {
                    next[s] = dp[s] + scores[t][s]
                    back[t][s] = UInt8(s)
                } else {
                    next[s] = switchScore + scores[t][s]
                    back[t][s] = UInt8(bestPrev)
                }
            }
            dp = next
        }
        var state = 0
        for s in 1..<n where dp[s] > dp[state] { state = s }
        var path = [Int](repeating: 0, count: scores.count)
        for t in stride(from: scores.count - 1, through: 0, by: -1) {
            path[t] = state
            state = Int(back[t][state])
        }
        return path
    }

    // MARK: Key

    /// Krumhansl–Schmuckler key finding on the summed chromagram.
    private static func estimateKey(chroma: [[Float]], energy: [Float], silenceThreshold: Float) -> MusicalKey? {
        var total = [Float](repeating: 0, count: 12)
        for (f, c) in chroma.enumerated() where energy[f] >= silenceThreshold {
            for i in 0..<12 { total[i] += c[i] }
        }
        guard total.contains(where: { $0 > 0 }) else { return nil }
        let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        var best: (MusicalKey, Float)?
        for tonic in 0..<12 {
            for (profile, isMinor) in [(major, false), (minor, true)] {
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                let r = correlation(total, rotated)
                if best == nil || r > best!.1 { best = (MusicalKey(tonic: tonic, isMinor: isMinor), r) }
            }
        }
        return best?.0
    }

    // MARK: Vector helpers

    private static func smooth(_ frames: [[Float]], radius: Int) -> [[Float]] {
        frames.indices.map { f in
            var acc = [Float](repeating: 0, count: 12)
            for g in max(0, f - radius)...min(frames.count - 1, f + radius) {
                for i in 0..<12 { acc[i] += frames[g][i] }
            }
            return acc
        }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<12 {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }
}

/// Hann-windowed real FFT returning magnitudes (normalized so a full-scale sine ≈ 1).
final class Spectrum {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private(set) var lastRMS: Float = 0

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        mags = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(of frame: UnsafeBufferPointer<Float>) -> [Float] {
        vDSP_rmsqv(frame.baseAddress!, 1, &lastRMS, vDSP_Length(size))
        vDSP_vmul(frame.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(size / 2))
            }
        }
        // zrip output is scaled by 2; the Hann window has a coherent gain of 0.5.
        var scale = Float(2) / Float(size)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(size / 2))
        mags[0] = 0
        return mags
    }
}
