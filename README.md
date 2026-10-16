# Largo

An app for Mac, iPhone and iPad for learning songs by ear, modeled on Capo's playback features.

- Open audio by dragging it onto the window or with ⌘O
- Scrolling waveform: the playhead stays in the center and the song (with its chords) moves past it.
  Click to seek, drag to select an A–B loop, pinch or ⌘+/⌘− to zoom. A full-song overview sits on top.
- Speed 25–200% with pitch kept the same (AVAudioUnitTimePitch)
- Transpose ±12 semitones, plus fine tuning of ±50 cents
- A–B looping without gaps
- Chord detection: a chord lane under the waveform, the current and next chord, and the song's key.
  Chords follow the transpose setting. Click a chord to jump to it.
- Bars and beats: detected tempo and bar lines with bar numbers over the waveform; current bar · beat.
  Switch 3/4 ↔ 4/4 or move the bar lines by a beat if the downbeat was guessed wrong. Chords snap to beats.

## How chord detection works

`LargoCore/Sources/LargoCore/ChordAnalyzer.swift`, run in the background when a file opens:

1. Mixes to mono and downsamples to about 22 kHz.
2. Estimates the recording's tuning offset from A440 using spectral peaks.
3. Builds a log-compressed chromagram (energy of each of the 12 notes over time, ~93 ms frames) plus a bass chromagram.
4. Scores each frame against 60 chord templates (major, minor, 7, m7, maj7), allowing for overtones.
5. Smooths the result with Viterbi decoding so chords don't flicker. Silence is shown as "N.C." (no chord).
6. Finds the key by comparing the overall note balance to standard key profiles (Krumhansl–Schmuckler).

## How beat detection works

`LargoCore/Sources/LargoCore/BeatAnalyzer.swift` (after Ellis 2007, "Beat Tracking by Dynamic Programming"):

1. Onset strength: rises in the log spectrogram, about 86 frames per second.
2. Tempo: autocorrelation of the onset curve, weighted toward ~120 BPM.
3. Beats: dynamic programming that favors strong onsets spaced close to the tempo.
4. Bars: picks 3/4 or 4/4 and the downbeat where chord changes and bass hits line up best.

## Project layout

- `Largo.xcodeproj` – the app: one multiplatform target for macOS 14+ and iOS/iPadOS 17+.
  Every Swift file in `Largo/` is part of it. iPhone uses a compact layout; iPad and Mac share the wide one.
- `Largo-iOS-Info.plist` – iOS-only Info.plist additions (background audio).
- `Design/make-app-icon.swift` – draws the app icon and writes all sizes into the asset catalog
  (`swift Design/make-app-icon.swift`).
- `LargoCore/` – local Swift package with the audio analysis (waveform, chords, beats) and its tests.

## Build & run

- App: open `Largo.xcodeproj`, scheme **Largo**, ⌘R.
- Tests: scheme **LargoCore**, ⌘U — or `cd LargoCore && swift test`.
- Previews: open `Largo/Previews.swift`, ⌥⌘↩.
- Debug builds accept `-open /path/to/song` as a launch argument (scheme → Run → Arguments) to open a file at launch.
