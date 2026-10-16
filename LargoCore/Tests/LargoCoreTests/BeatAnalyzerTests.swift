import XCTest
@testable import LargoCore

final class BeatAnalyzerTests: XCTestCase {
    let rate = 44_100.0

    /// A drum-and-chords loop: kick on beats 1 & 3, hi-hat click on every beat,
    /// chords changing on each downbeat (C G Am F). Starts with `pickup` beats of drums only.
    private func song(bpm: Double, bars: Int, beatsPerBar: Int = 4, pickup: Int = 0) -> (audio: [Float], downbeats: [Double]) {
        let beat = 60 / bpm
        let total = Double(pickup + bars * beatsPerBar) * beat + 1
        var x = [Float](repeating: 0, count: Int(total * rate))
        var rng = SystemRandomNumberGenerator()
        func add(at t: Double, dur: Double, _ f: (Double) -> Double) {
            let s = Int(t * rate)
            for i in 0..<Int(dur * rate) where s + i < x.count { x[s + i] += Float(f(Double(i) / rate)) }
        }
        let progression: [[Int]] = [[0, 4, 7], [7, 11, 14], [9, 12, 16], [5, 9, 12]]
        var downbeats: [Double] = []
        for b in 0..<(pickup + bars * beatsPerBar) {
            let t = Double(b) * beat
            let inBar = b - pickup
            // hi-hat
            add(at: t, dur: 0.04) { _ in Double(Int.random(in: -1000...1000, using: &rng)) / 1000 * 0.15 } 
            guard inBar >= 0 else { continue }
            let pos = inBar % beatsPerBar
            if pos == 0 || (beatsPerBar == 4 && pos == 2) {
                add(at: t, dur: 0.15) { tt in sin(2 * .pi * 55 * tt) * exp(-tt * 25) * 0.8 } // kick
            }
            if pos == 0 {
                downbeats.append(t)
                let chord = progression[(inBar / beatsPerBar) % 4]
                for note in chord {
                    let f0 = 440 * pow(2, (Double(60 + note) - 69) / 12)
                    add(at: t, dur: beat * Double(beatsPerBar)) { tt in
                        (1...4).reduce(0.0) { $0 + sin(2 * .pi * f0 * Double($1) * tt) * 0.08 / Double($1) }
                    }
                }
            }
        }
        return (x, downbeats)
    }

    private func check(bpm: Double, beatsPerBar: Int, pickup: Int, file: StaticString = #filePath, line: UInt = #line) {
        let (audio, downbeats) = song(bpm: bpm, bars: 12, beatsPerBar: beatsPerBar, pickup: pickup)
        let result = SongAnalyzer.analyze(samples: audio, sampleRate: rate)
        guard let grid = result.beats else { return XCTFail("no beats", file: file, line: line) }
        XCTAssertEqual(grid.bpm, bpm, accuracy: bpm * 0.02, "tempo", file: file, line: line)
        XCTAssertEqual(grid.beatsPerBar, beatsPerBar, "meter", file: file, line: line)

        // Every true downbeat should have a detected beat within 40 ms that is marked as a downbeat.
        let tol = 0.04
        var hits = 0
        for d in downbeats.dropFirst().dropLast() {
            guard let i = grid.beats.indices.min(by: { abs(grid.beats[$0] - d) < abs(grid.beats[$1] - d) }),
                  abs(grid.beats[i] - d) < tol else { continue }
            if grid.isDownbeat(i) { hits += 1 }
        }
        XCTAssertGreaterThanOrEqual(hits, downbeats.count - 3, "downbeats \(hits)/\(downbeats.count - 2)", file: file, line: line)
    }

    func test4_4At120() { check(bpm: 120, beatsPerBar: 4, pickup: 0) }
    func test4_4At95WithPickup() { check(bpm: 95, beatsPerBar: 4, pickup: 1) }
    func test3_4At140() { check(bpm: 140, beatsPerBar: 3, pickup: 0) }

    func testChordsSnapToBeats() {
        let (audio, _) = song(bpm: 100, bars: 8)
        let result = SongAnalyzer.analyze(samples: audio, sampleRate: rate)
        guard let grid = result.beats else { return XCTFail("no beats") }
        for seg in result.chords.segments.dropFirst() {
            let nearest = grid.beats.map { abs($0 - seg.start) }.min()!
            XCTAssertLessThan(nearest, 0.001, "chord at \(seg.start) not on a beat")
        }
        XCTAssertEqual(result.chords.segments.filter { $0.end - $0.start > 1 }.prefix(4).map { $0.chord.name() },
                       ["C", "G", "Am", "F"])
    }

    func testGridPositions() {
        let grid = BeatGrid(beats: (0..<10).map(Double.init), bpm: 60, beatsPerBar: 4, downbeatOffset: 1)
        XCTAssertFalse(grid.isDownbeat(0))
        XCTAssertTrue(grid.isDownbeat(1))
        XCTAssertTrue(grid.isDownbeat(5))
        XCTAssertEqual(grid.position(ofBeat: 0).bar, 0)
        XCTAssertEqual(grid.position(ofBeat: 0).beat, 4)
        XCTAssertEqual(grid.position(ofBeat: 6).bar, 2)
        XCTAssertEqual(grid.position(ofBeat: 6).beat, 2)
        XCTAssertEqual(grid.barStart(atOrBefore: 7.5), 5)
    }
}
