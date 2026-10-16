import XCTest
@testable import LargoCore

final class ChordAnalyzerTests: XCTestCase {
    let rate = 44_100.0

    /// Synthesizes a chord as harmonic-rich tones (like a plucked/bowed instrument), plus a bass root.
    private func render(_ chords: [(root: Int, intervals: [Int])?], secondsEach: Double, cents: Double = 0) -> [Float] {
        let n = Int(secondsEach * rate)
        var out = [Float]()
        for chord in chords {
            var block = [Float](repeating: 0, count: n)
            if let chord {
                var midis = chord.intervals.map { 60 + chord.root + $0 } // around middle C
                midis.append(48 + chord.root - (chord.root > 5 ? 12 : 0)) // bass
                for midi in midis {
                    let f0 = 440 * pow(2, (Double(midi) - 69 + cents / 100) / 12)
                    for h in 1...6 {
                        let amp = 0.15 / Double(h)
                        let w = 2 * Double.pi * f0 * Double(h) / rate
                        for i in 0..<n { block[i] += Float(amp * sin(w * Double(i))) }
                    }
                }
            }
            out += block
        }
        return out
    }

    private func names(_ analysis: ChordAnalysis, minLength: Double = 0.5) -> [String] {
        analysis.segments.filter { $0.end - $0.start >= minLength }.map { $0.chord.name() }
    }

    func testPopProgression() {
        // C – G – Am – F
        let audio = render([(0, [0, 4, 7]), (7, [0, 4, 7]), (9, [0, 3, 7]), (5, [0, 4, 7])], secondsEach: 2)
        let result = ChordAnalyzer.analyze(samples: audio, sampleRate: rate)
        XCTAssertEqual(names(result), ["C", "G", "Am", "F"])
        XCTAssertEqual(result.key, MusicalKey(tonic: 0, isMinor: false))
    }

    func testSeventhsAndMinors() {
        // Dm7 – G7 – Cmaj7 – Em
        let audio = render([(2, [0, 3, 7, 10]), (7, [0, 4, 7, 10]), (0, [0, 4, 7, 11]), (4, [0, 3, 7])], secondsEach: 2)
        let result = ChordAnalyzer.analyze(samples: audio, sampleRate: rate)
        XCTAssertEqual(names(result), ["Dm7", "G7", "Cmaj7", "Em"])
    }

    func testDetunedRecordingAndSilence() {
        // Recording tuned 35 cents sharp, with silence in between: E – (silence) – A – B
        let audio = render([(4, [0, 4, 7]), nil, (9, [0, 4, 7]), (11, [0, 4, 7])], secondsEach: 2, cents: 35)
        let result = ChordAnalyzer.analyze(samples: audio, sampleRate: rate)
        XCTAssertEqual(result.tuningCents, 35, accuracy: 5)
        XCTAssertEqual(names(result), ["E", "N.C.", "A", "B"])
    }

    func testBoundariesAreAccurate() {
        let audio = render([(0, [0, 4, 7]), (7, [0, 4, 7])], secondsEach: 3)
        let result = ChordAnalyzer.analyze(samples: audio, sampleRate: rate)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.first?.end ?? 0, 3, accuracy: 0.2)
        XCTAssertEqual(result.segmentIndex(at: 1), 0)
        XCTAssertEqual(result.segmentIndex(at: 4), 1)
    }

    func testTransposeAndNaming() {
        let chord = Chord(root: 10, quality: .minor7)
        XCTAssertEqual(chord.name(useFlats: true), "B♭m7")
        XCTAssertEqual(chord.transposed(by: 3).name(), "C♯m7")
        XCTAssertEqual(MusicalKey(tonic: 2, isMinor: true).name, "D minor")
        XCTAssertEqual(MusicalKey(tonic: 7, isMinor: false).transposed(by: -2).name, "F major")
    }
}

final class AnalysisCodingTests: XCTestCase {
    func testSongAnalysisRoundTripsThroughJSON() throws {
        let chords = ChordAnalysis(
            segments: [ChordSegment(start: 0, end: 2, chord: .none),
                       ChordSegment(start: 2, end: 4, chord: Chord(root: 9, quality: .minor7))],
            key: MusicalKey(tonic: 7, isMinor: false), tuningCents: -12.5)
        let beats = BeatGrid(beats: [0, 0.5, 1, 1.5], bpm: 120, beatsPerBar: 3, downbeatOffset: 1)
        let original = SongAnalysis(chords: chords, beats: beats)

        let decoded = try JSONDecoder().decode(SongAnalysis.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.chords.segments, chords.segments)
        XCTAssertEqual(decoded.chords.key, chords.key)
        XCTAssertEqual(decoded.chords.tuningCents, -12.5)
        XCTAssertEqual(decoded.beats, beats)
    }
}
