import Foundation

/// Beat positions plus how they group into bars.
public struct BeatGrid: Equatable, Codable, Sendable {
    /// Beat times in seconds, ascending.
    public var beats: [Double]
    public var bpm: Double
    public var beatsPerBar: Int
    /// Index (0..<beatsPerBar) of the first beat that starts a bar; earlier beats are a pickup.
    public var downbeatOffset: Int

    public init(beats: [Double], bpm: Double, beatsPerBar: Int, downbeatOffset: Int) {
        self.beats = beats
        self.bpm = bpm
        self.beatsPerBar = max(1, beatsPerBar)
        self.downbeatOffset = ((downbeatOffset % self.beatsPerBar) + self.beatsPerBar) % self.beatsPerBar
    }

    public func isDownbeat(_ index: Int) -> Bool {
        (index - downbeatOffset) % beatsPerBar == 0 && index >= downbeatOffset
    }

    /// 1-based bar and beat for a beat index. Pickup beats belong to bar 0.
    public func position(ofBeat index: Int) -> (bar: Int, beat: Int) {
        let rel = index - downbeatOffset
        if rel < 0 { return (0, beatsPerBar + rel + 1) }
        return (rel / beatsPerBar + 1, rel % beatsPerBar + 1)
    }

    /// Index of the last beat at or before `time`.
    public func beatIndex(at time: Double) -> Int? {
        var lo = 0, hi = beats.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if beats[mid] <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Start time of the bar containing `time` (or the next bar if before the first downbeat).
    public func barStart(atOrBefore time: Double) -> Double? {
        guard var i = beatIndex(at: time) else { return beats.first }
        while i > 0 && !isDownbeat(i) { i -= 1 }
        return beats[i]
    }

    public func with(beatsPerBar: Int? = nil, downbeatOffset: Int? = nil) -> BeatGrid {
        BeatGrid(beats: beats, bpm: bpm,
                 beatsPerBar: beatsPerBar ?? self.beatsPerBar,
                 downbeatOffset: downbeatOffset ?? self.downbeatOffset)
    }
}

/// Tempo estimation and beat tracking (after Ellis, "Beat Tracking by Dynamic Programming", 2007).
///
/// 1. Onset strength: positive spectral flux of the log spectrogram (~86 frames/s).
/// 2. Tempo: autocorrelation of the onset curve, weighted toward ~120 BPM.
/// 3. Beats: dynamic programming that rewards beats on strong onsets and spacing close to the tempo.
/// 4. Bars: the downbeat phase where chord changes and bass onsets line up best.
public enum BeatAnalyzer {
    struct Onsets {
        var strength: [Float]
        var bass: [Float]
        var frameRate: Double
        var timeOffset: Double
    }

    public static func analyze(samples input: [Float], sampleRate inputRate: Double,
                               chords: [ChordSegment] = []) -> BeatGrid? {
        var samples = input
        var sampleRate = inputRate
        while sampleRate >= 32_000 {
            samples = ChordAnalyzer.decimateByTwo(samples)
            sampleRate /= 2
        }
        let onsets = onsetStrength(samples: samples, sampleRate: sampleRate)
        guard onsets.strength.count > Int(onsets.frameRate * 4),
              let period = estimatePeriod(onsets.strength, frameRate: onsets.frameRate) else { return nil }

        let frames = trackBeats(onsets.strength, period: period)
        guard frames.count >= 4 else { return nil }
        let beats = frames.map { Double($0) / onsets.frameRate + onsets.timeOffset }

        // Median inter-beat interval is more robust than the autocorrelation peak.
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let bpm = 60 / intervals[intervals.count / 2]

        let bassAtBeats = frames.map { f -> Float in
            var m: Float = 0
            for g in max(0, f - 2)...min(onsets.bass.count - 1, f + 2) { m = max(m, onsets.bass[g]) }
            return m
        }
        let (perBar, offset) = chooseMeter(beats: beats, bassAtBeats: bassAtBeats, chords: chords,
                                           beatPeriod: 60 / bpm)
        return BeatGrid(beats: beats, bpm: bpm, beatsPerBar: perBar, downbeatOffset: offset)
    }

    // MARK: Onset strength

    static func onsetStrength(samples: [Float], sampleRate: Double) -> Onsets {
        let size = 1024, hop = 256
        let spectrum = Spectrum(size: size)
        let frameCount = max(0, (samples.count - size) / hop + 1)
        let binHz = sampleRate / Double(size)
        let bassBins = max(2, Int(200 / binHz))
        let bins = size / 2

        var flux = [Float](repeating: 0, count: frameCount)
        var bass = [Float](repeating: 0, count: frameCount)
        var energy = [Float](repeating: 0, count: frameCount)
        var prev = [Float](repeating: 0, count: bins)
        for f in 0..<frameCount {
            let start = f * hop
            var mags = samples.withUnsafeBufferPointer { buf in
                spectrum.magnitudes(of: UnsafeBufferPointer(rebasing: buf[start..<start + size]))
            }
            energy[f] = spectrum.lastRMS
            for k in 1..<bins { mags[k] = log1p(1_000 * mags[k]) }
            if f > 0 {
                var s: Float = 0, b: Float = 0
                for k in 1..<bins {
                    let d = mags[k] - prev[k]
                    if d > 0 {
                        s += d
                        if k < bassBins { b += d }
                    }
                }
                flux[f] = s
                bass[f] = b
            }
            prev = mags
        }

        // Remove the slowly varying part (±0.25 s) and keep only rises.
        let frameRate = sampleRate / Double(hop)
        flux = highPass(flux, radius: Int(frameRate * 0.25))
        bass = highPass(bass, radius: Int(frameRate * 0.25))

        // Silence any frames that are essentially silent so DP doesn't invent beats from noise.
        let floor = (energy.max() ?? 0) * 0.003
        for f in 0..<frameCount where energy[f] < floor { flux[f] = 0; bass[f] = 0 }

        // Normalize to unit standard deviation.
        let mean = flux.reduce(0, +) / Float(max(1, flux.count))
        let sd = sqrt(flux.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, flux.count)))
        if sd > 0 { flux = flux.map { $0 / sd } }

        return Onsets(strength: flux, bass: bass, frameRate: frameRate,
                      timeOffset: Double(size / 2) / sampleRate)
    }

    private static func highPass(_ x: [Float], radius: Int) -> [Float] {
        guard radius > 0, !x.isEmpty else { return x }
        var prefix = [Float](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + x[i] }
        return x.indices.map { i in
            let lo = max(0, i - radius), hi = min(x.count, i + radius + 1)
            let avg = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            return max(0, x[i] - avg)
        }
    }

    // MARK: Tempo

    /// Beat period in onset frames.
    static func estimatePeriod(_ onset: [Float], frameRate: Double) -> Double? {
        let minLag = Int(frameRate * 60 / 220), maxLag = Int(frameRate * 60 / 40)
        guard onset.count > maxLag * 2 else { return nil }
        var ac = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var s: Float = 0
            for i in 0..<(onset.count - lag) { s += onset[i] * onset[i + lag] }
            ac[lag] = s / Float(onset.count - lag)
        }
        var best = minLag
        var bestScore = -Float.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            // Perceptual tempo prior: log-Gaussian around 120 BPM, one octave wide.
            let w = Float(exp(-0.5 * pow(log2(bpm / 120), 2)))
            // Also credit the half-tempo lag, which reinforces the true beat.
            let half = 2 * lag <= maxLag + 1 ? ac[2 * lag] * 0.5 : 0
            let score = w * (ac[lag] + half)
            if score > bestScore { bestScore = score; best = lag }
        }
        guard bestScore > 0 else { return nil }
        // Parabolic refinement
        let a = Double(ac[best - 1]), b = Double(ac[best]), c = Double(ac[best + 1])
        let denom = a - 2 * b + c
        let delta = denom == 0 ? 0 : max(-0.5, min(0.5, 0.5 * (a - c) / denom))
        return Double(best) + delta
    }

    // MARK: Beat tracking

    static func trackBeats(_ onset: [Float], period: Double, tightness: Double = 100) -> [Int] {
        let n = onset.count
        // Smooth onsets with a narrow Gaussian so near-misses still count.
        let sigma = max(1, period / 32)
        let r = Int(sigma * 3)
        let kernel = (-r...r).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
        var local = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            for (j, k) in kernel.enumerated() {
                let idx = i + j - r
                if idx >= 0 && idx < n { s += onset[idx] * k }
            }
            local[i] = s
        }

        var score = [Float](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let lo = Int((period / 2).rounded()), hi = Int((period * 2).rounded())
        var penalty = [Float](repeating: 0, count: hi + 1)
        for d in max(1, lo)...hi { penalty[d] = Float(tightness * pow(log(Double(d) / period), 2)) }

        for t in 0..<n {
            var best: Float = 0
            var arg = -1
            if t >= lo {
                for d in max(1, lo)...min(hi, t) {
                    let s = score[t - d] - penalty[d]
                    if arg < 0 || s > best { best = s; arg = t - d }
                }
            }
            if arg >= 0 && best > 0 {
                score[t] = local[t] + best
                back[t] = arg
            } else {
                score[t] = local[t]
            }
        }

        // End on the best-scoring frame within the last beat period.
        var t = max(0, n - Int(period))
        for i in t..<n where score[i] > score[t] { t = i }
        var beats = [Int]()
        while t >= 0 {
            beats.append(t)
            t = back[t]
        }
        beats.reverse()

        // Drop beats in leading/trailing silence.
        let active = onset.indices.filter { onset[$0] > 0.5 }
        if let first = active.first, let last = active.last {
            let margin = Int(period / 2)
            beats = beats.filter { $0 >= first - margin && $0 <= last + margin }
        }
        return beats
    }

    // MARK: Meter / downbeats

    /// Picks 3 or 4 beats per bar and the downbeat phase, using chord changes and bass onsets.
    static func chooseMeter(beats: [Double], bassAtBeats: [Float], chords: [ChordSegment],
                            beatPeriod: Double) -> (Int, Int) {
        let boundaries = chords.dropFirst().map(\.start)
        let tolerance = beatPeriod * 0.3
        let changeAtBeat: [Float] = beats.map { b in
            boundaries.contains { abs($0 - b) < tolerance } ? 1 : 0
        }
        let bassMean = max(1e-6, bassAtBeats.reduce(0, +) / Float(max(1, bassAtBeats.count)))
        let evidence = beats.indices.map { changeAtBeat[$0] + 0.5 * min(3, bassAtBeats[$0] / bassMean) }

        func bestPhase(_ perBar: Int) -> (phase: Int, contrast: Float) {
            var means = [Float](repeating: 0, count: perBar)
            var counts = [Float](repeating: 0, count: perBar)
            for (i, e) in evidence.enumerated() { means[i % perBar] += e; counts[i % perBar] += 1 }
            for p in 0..<perBar { means[p] /= max(1, counts[p]) }
            let phase = means.indices.max { means[$0] < means[$1] }!
            let others = means.enumerated().filter { $0.offset != phase }.map(\.element)
            let contrast = means[phase] - others.reduce(0, +) / Float(max(1, others.count))
            return (phase, contrast)
        }

        let four = bestPhase(4), three = bestPhase(3)
        // 4/4 is far more common, so 3/4 must be clearly better.
        if three.contrast > four.contrast * 1.25 && three.contrast > 0.2 { return (3, three.phase) }
        return (4, four.phase)
    }
}

extension ChordAnalysis {
    /// Moves chord boundaries onto the nearest beat (when within half a beat), then tidies up.
    public func snapped(to grid: BeatGrid) -> ChordAnalysis {
        guard grid.beats.count > 1, segments.count > 1 else { return self }
        let half = 30 / grid.bpm
        var segs = segments
        for i in 1..<segs.count {
            let b = segs[i].start
            guard let j = grid.beatIndex(at: b + half) else { continue }
            let beat = grid.beats[j]
            if abs(beat - b) <= half {
                segs[i].start = beat
                segs[i - 1].end = beat
            }
        }
        var tidy: [ChordSegment] = []
        for s in segs where s.end - s.start > 0.05 {
            if var last = tidy.last {
                if last.chord == s.chord {
                    last.end = s.end
                    tidy[tidy.count - 1] = last
                    continue
                }
                if last.end != s.start { tidy[tidy.count - 1].end = s.start }
            }
            tidy.append(s)
        }
        if !tidy.isEmpty {
            tidy[0].start = segments.first!.start
            tidy[tidy.count - 1].end = segments.last!.end
        }
        return ChordAnalysis(segments: tidy, key: key, tuningCents: tuningCents)
    }
}

/// Everything detected about a song in one pass over the audio.
/// Saved to disk by the app so a song is only analyzed once.
public struct SongAnalysis: Codable, Sendable {
    public var chords: ChordAnalysis
    public var beats: BeatGrid?
}

public enum SongAnalyzer {
    public static func analyze(url: URL, progress: ((Double) -> Void)? = nil) throws -> SongAnalysis {
        let (samples, rate) = try ChordAnalyzer.loadMono(url: url) { progress?($0 * 0.3) }
        return analyze(samples: samples, sampleRate: rate) { progress?(0.3 + $0 * 0.7) }
    }

    public static func analyze(samples: [Float], sampleRate: Double,
                               progress: ((Double) -> Void)? = nil) -> SongAnalysis {
        let chords = ChordAnalyzer.analyze(samples: samples, sampleRate: sampleRate) { progress?($0 * 0.6) }
        let beats = BeatAnalyzer.analyze(samples: samples, sampleRate: sampleRate, chords: chords.segments)
        progress?(1)
        return SongAnalysis(chords: beats.map { chords.snapped(to: $0) } ?? chords, beats: beats)
    }
}
