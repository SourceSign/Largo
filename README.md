# Largo

An app for iPhone, iPad and Mac for learning songs by ear. Open a song, and Largo shows its
waveform, chords, key, tempo and bars – then lets you slow it down, change its key and loop any
part until you've got it. Everything runs on the device; Largo collects no data.

## Features

- **Speed** 0.25×–2× with the pitch kept the same (`AVAudioUnitTimePitch`). The 1× button opens a
  popover with practice presets (0.5–1×) and a tick ruler for any speed.
- **Key**: transpose ±12 semitones and fine-tune ±50 cents. The key button opens a popover with
  − / + and a cents ruler. Chords, key and tempo display follow the settings.
- **Scrolling waveform**: the playhead stays in the center and the song moves past it, with bar
  lines, bar numbers and a chord lane underneath. Tap to jump, tap a chord to jump to it, pinch or
  ⌘+/⌘− to zoom.
- **Loops**, like regions in Capo: drag across the waveform to create one, drag its edges to resize
  it, drag inside it to move it. Long-press (right-click on the Mac) for *Turn Loop Off* and
  *Clear Loop*. Playback repeats the loop without gaps.
- **Chord, key, tempo and bar detection** (see below). Chords snap to beats. On Mac and iPad the
  "…" menu switches between 3/4 and 4/4 and moves the bar lines if the downbeat was guessed wrong.
- **Remembers every song**: speed, key, loop, bars, position and zoom are restored when a song is
  opened again; the last song reopens at launch. Waveform and analysis are cached.
- **Demo song** built in; it opens on first launch.
- Cover art from the file's tags, background playback and AirPlay on iOS, light and dark mode.

### Layouts

- **iPhone** – in the style of the Podcasts "Now Playing" screen: the waveform as a square
  "cover", title with key and tempo, a song overview as the progress bar, one row of controls
  (1× · −5 s · play · +5 s · key) and the system volume slider.
- **iPad and Mac** – in the style of Podcasts on the Mac: the waveform fills the window, with a
  rounded command bar at the bottom (transport, cover/title/progress, "…" menu, AirPlay, volume).
  In a narrow iPad split view, the iPhone layout is used.

### Keyboard shortcuts (Mac, iPad with keyboard)

| Key | Action |
|---|---|
| Space | Play / pause |
| Return | Return to start (or to the loop start) |
| ← / → | Back / forward 5 s |
| - / = | Slower / faster (5 % steps) |
| ⌘↑ / ⌘↓ | Transpose up / down a semitone |
| ⌘0 | Reset speed and pitch |
| ⌘= / ⌘- | Zoom in / out |
| [ / ] | Set loop start / end at the playhead |
| L / ⇧L | Toggle loop / clear loop |
| ⌘O | Open a song |

### Opening songs

MP3, M4A (AAC), WAV, AIFF, FLAC and CAF from the Files app, iCloud Drive or the Finder (also by
drag and drop onto the window). On iPhone and iPad Largo keeps a copy of each song in its own
storage, since file permissions from the Files app don't last; on the Mac it keeps a bookmark to
the original file instead. Copy-protected Apple Music tracks can't be opened.

## How chord detection works

`LargoCore/Sources/LargoCore/ChordAnalyzer.swift`, run in the background when a song is opened:

1. Mixes to mono and downsamples to about 22 kHz.
2. Estimates the recording's tuning offset from A440 using spectral peaks.
3. Builds a log-compressed chromagram (energy of each of the 12 notes over time, ~93 ms frames)
   plus a bass chromagram.
4. Scores each frame against 60 chord templates (major, minor, 7, m7, maj7), allowing for overtones.
5. Smooths the result with Viterbi decoding so chords don't flicker. Silence is shown as "N.C.".
6. Finds the key by comparing the overall note balance to standard key profiles
   (Krumhansl–Schmuckler).

## How beat detection works

`LargoCore/Sources/LargoCore/BeatAnalyzer.swift` (after Ellis 2007, "Beat Tracking by Dynamic
Programming"):

1. Onset strength: rises in the log spectrogram, about 86 frames per second.
2. Tempo: autocorrelation of the onset curve, weighted toward ~120 BPM.
3. Beats: dynamic programming that favors strong onsets spaced close to the tempo.
4. Bars: picks 3/4 or 4/4 and the downbeat where chord changes and bass hits line up best.

## Project layout

- `Largo.xcodeproj` – the app: one multiplatform target for iOS/iPadOS 17+ and macOS 14+.
  Every file in `Largo/` is part of it automatically.
- `Largo/` – app code (SwiftUI). `AudioPlayer.swift` holds playback and state;
  `CompactPlayerView.swift` is the iPhone layout, `WidePlayerView.swift` the Mac/iPad layout.
- `LargoCore/` – local Swift package with the audio analysis (waveform, chords, key, beats) and
  its tests.
- `Largo-iOS-Info.plist` (background audio) and `Largo-macOS.entitlements` (file bookmarks) –
  kept outside `Largo/` so they aren't bundled as resources.
- `Design/` – scripts that generate assets:
  - `swift Design/make-app-icon.swift` – draws the app icon and writes all sizes into the asset catalog.
  - `./Design/make-demo-song.sh` – synthesizes the royalty-free demo song `Largo/LargoDemo.m4a`.
- `AppStore/` – store description, privacy policy, App Review notes and screenshots.

## Build & run

- App: open `Largo.xcodeproj`, scheme **Largo**, ⌘R.
- Tests: scheme **LargoCore**, ⌘U — or `cd LargoCore && swift test`.
- Previews: open `Largo/Previews.swift` (or any view file), ⌥⌘↩.
- Debug builds accept `-open /path/to/song` as a launch argument (scheme → Run → Arguments) to
  open a file at launch.
- From the command line (unsigned, for checking that it compiles):

  ```bash
  xcodebuild -project Largo.xcodeproj -scheme Largo -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
  xcodebuild -project Largo.xcodeproj -scheme Largo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  ```

## Release

Archive in Xcode (Product → Archive, once for "Any iOS Device" and once for "Any Mac"), then
Distribute App → App Store Connect. Each upload needs a higher build number. Privacy policy:
https://sourcesign.de/largo/privacy/
