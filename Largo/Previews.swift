#if DEBUG
import SwiftUI
import LargoCore

/// Sample data for SwiftUI previews: a 2-minute song at 120 BPM in 4/4,
/// C – G – Am – F one chord per bar, with a loop over bars 5–8.
@MainActor
enum PreviewData {
    static let bpm = 120.0
    static let duration = 120.0
    static let progression = [Chord(root: 0, quality: .major), Chord(root: 7, quality: .major),
                              Chord(root: 9, quality: .minor), Chord(root: 5, quality: .major)]

    static var beats: BeatGrid {
        let beat = 60 / bpm
        let times = stride(from: 0.0, to: duration, by: beat).map { $0 }
        return BeatGrid(beats: times, bpm: bpm, beatsPerBar: 4, downbeatOffset: 0)
    }

    static var chords: ChordAnalysis {
        let bar = 4 * 60 / bpm
        var segments = [ChordSegment(start: 0, end: bar, chord: .none)] // one bar count-in
        var t = bar
        var i = 0
        while t < duration - bar {
            segments.append(ChordSegment(start: t, end: t + bar, chord: progression[i % 4]))
            t += bar
            i += 1
        }
        segments.append(ChordSegment(start: t, end: duration, chord: .none))
        return ChordAnalysis(segments: segments, key: MusicalKey(tonic: 0, isMinor: false), tuningCents: 0)
    }

    /// Kick on every beat, louder sections every 8 bars, fade in and out.
    static var waveform: [Float] {
        let perSecond = AudioPlayer.waveformPeaksPerSecond
        let beat = 60 / bpm
        return (0..<Int(duration * perSecond)).map { i in
            let t = Double(i) / perSecond
            let sinceBeat = t.truncatingRemainder(dividingBy: beat)
            let kick = exp(-sinceBeat * 12)
            let section = 0.55 + 0.25 * sin(t / (beat * 32) * .pi)
            let texture = 0.15 * abs(sin(t * 37.3) * sin(t * 11.1))
            let fade = min(1, t / 2, (duration - t) / 3)
            return Float(max(0, min(1, (0.35 * kick + section * 0.6 + texture) * fade)))
        }
    }

    /// A player positioned mid-song with chords, beats and a loop.
    static func player(currentTime: Double = 21.3, semitones: Int = 0, rate: Float = 1,
                       loop: Bool = true) -> AudioPlayer {
        let p = AudioPlayer()
        p.loadPreviewState(url: URL(fileURLWithPath: "/Preview/Sample Song.mp3"), duration: duration,
                           currentTime: currentTime, waveform: waveform, chords: chords, beats: beats)
        p.semitones = semitones
        p.rate = rate
        if loop { p.setLoop(start: 16, end: 24) }
        return p
    }

    /// File just opened: waveform ready, chord/beat analysis still running.
    static func analyzingPlayer() -> AudioPlayer {
        let p = AudioPlayer()
        p.loadPreviewState(url: URL(fileURLWithPath: "/Preview/Sample Song.mp3"), duration: duration,
                           currentTime: 0, waveform: waveform, chords: nil, beats: nil, analysisProgress: 0.4)
        return p
    }
}

// MARK: - Full window

#Preview("Window – song loaded") {
    ContentView(player: PreviewData.player())
        .frame(width: 960, height: 620)
}

#Preview("Window – analyzing") {
    ContentView(player: PreviewData.analyzingPlayer())
        .frame(width: 960, height: 620)
}

#Preview("Window – empty") {
    ContentView(player: AudioPlayer())
        .frame(width: 760, height: 560)
}

#Preview("Window – dark, transposed, 75%") {
    ContentView(player: PreviewData.player(semitones: 2, rate: 0.75))
        .frame(width: 960, height: 620)
        .preferredColorScheme(.dark)
}

// MARK: - Individual views

#Preview("Scrolling timeline") {
    ScrollingTimelineView(player: PreviewData.player())
        .frame(width: 800, height: 240)
        .padding()
}

#Preview("Scrolling timeline – zoomed out") {
    let p = PreviewData.player()
    p.visibleSeconds = 90
    return ScrollingTimelineView(player: p)
        .frame(width: 800, height: 240)
        .padding()
}

#Preview("Scrolling timeline – song start") {
    // Playhead near 0: left half of the view is before the song.
    ScrollingTimelineView(player: PreviewData.player(currentTime: 1.2, loop: false))
        .frame(width: 800, height: 240)
        .padding()
}

#Preview("Overview") {
    OverviewView(player: PreviewData.player())
        .frame(width: 800)
        .padding()
}

#Preview("Chord lane") {
    let p = PreviewData.player()
    return GeometryReader { geo in
        ChordLaneView(player: p,
                      map: .centered(on: p.currentTime, visible: 12, width: geo.size.width),
                      now: p.currentTime)
    }
    .frame(width: 800, height: 28)
    .padding()
}

#Preview("Chord lane – analyzing") {
    let p = PreviewData.analyzingPlayer()
    return ChordLaneView(player: p, map: .centered(on: 0, visible: 12, width: 800), now: 0)
        .frame(width: 800)
        .padding()
}

#endif
