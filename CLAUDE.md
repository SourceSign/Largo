# Largo

Practice player for learning songs by ear (in the spirit of Capo): slow down without changing
pitch, transpose, loop sections, and follow detected chords, key, tempo and bars on a scrolling
waveform. One SwiftUI app for iPhone, iPad and Mac (bundle ID `de.sourcesign.Largo`).
Version 1.0 is in App Store review / TestFlight.

## Layout

- `Largo.xcodeproj` – one **multiplatform** app target (iOS/iPadOS 17+, macOS 14+). The `Largo/`
  folder is a file-system-synchronized group: every file in it is part of the target
  automatically (no project-file edits needed). Files that must *not* be bundled live outside it
  (`Largo-iOS-Info.plist`, `Largo-macOS.entitlements`).
- `Largo/` – app code:
  - `AudioPlayer.swift` – `@MainActor ObservableObject`: AVAudioEngine playback
    (player node → `AVAudioUnitTimePitch` → mixer), loop scheduling, iOS audio session,
    song identification, settings/cache loading. The single source of truth for UI state.
  - `CompactPlayerView.swift` – iPhone layout (Podcasts "Now Playing" style).
  - `WidePlayerView.swift` – Mac and iPad layout: waveform on top, rounded `CommandBar` at the bottom.
  - `WaveformView.swift` – scrolling waveform (`ScrollingTimelineView`), loop editing, overview.
  - `ChordLaneView.swift`, `PlaybackPopovers.swift` (1× and key buttons + popovers, `TickRuler`,
    `CoverArt`), `MusicSlider.swift`, `SongLibrary.swift`, `ContentView.swift` (picks the layout),
    `LargoApp.swift` (scenes, menu commands/shortcuts), `Previews.swift` (sample data, DEBUG only).
- `LargoCore/` – local Swift package (no UI): `WaveformAnalyzer`, `ChordAnalyzer`,
  `BeatAnalyzer`, `SongAnalyzer`, model types (`Chord`, `ChordAnalysis`, `BeatGrid`, … – Codable).
- `Design/` – scripts that generate assets: `make-app-icon.swift` (all icon sizes),
  `make-demo-song.sh` (+ `.py`, `tag-audio.swift`) for `Largo/LargoDemo.m4a`.
- `AppStore/` – store text, privacy policy (also published at https://sourcesign.de/largo/privacy/
  via the Hugo site in `~/Documents/Work/hugo/hugo4SourceSign`), review notes, screenshots.

## Build and test

```bash
# App (unsigned builds are fine for checking compilation)
xcodebuild -project Largo.xcodeproj -scheme Largo -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Largo.xcodeproj -scheme Largo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Analysis tests (~20 s)
cd LargoCore && swift test
```

- Always build **both** macOS and iOS after changes – much code is behind `#if os(...)`.
  Also check a Release build occasionally (`-configuration Release`): previews and `PreviewData`
  exist only in DEBUG, so a `#Preview` outside `#if DEBUG` breaks Release.
- Debug builds accept `-open /path/to/song` as a launch argument to open a file at launch
  (useful with `xcrun simctl launch … -open <path>`). On first launch with an empty library the
  built-in demo song opens.
- For English UI in the simulator: `xcrun simctl launch <device> de.sourcesign.Largo -AppleLanguages "(en)" -AppleLocale en_US`.
- `ImageRenderer` snapshots can't draw native AppKit/UIKit controls (sliders, menus, pickers):
  they appear as yellow/red placeholders. Use the simulator for real screenshots.

## Conventions

- Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency
  and `MemberImportVisibility`: every app file that uses LargoCore types needs `import LargoCore`.
  Background work uses `Task.detached` and hops back with `MainActor.run`.
- Platform differences via `#if os(iOS)` / `#if os(macOS)`; layout differences via
  `horizontalSizeClass` (compact = iPhone layout, also in narrow iPad split view).
- Colors: `Color.brand` (the red `AccentColor` asset – use it instead of `Color.accentColor`, which
  the Mac replaces with the system accent), `Color.transport` (play button and unplayed
  waveform), `Color.waveformBackground`.
- Popovers use `.presentationCompactAdaptation(.popover)` so they stay bubbles on iPhone; on iOS
  they page with a `TabView`, on the Mac both parts are stacked (`TwoPartPopover`). Buttons inside
  popovers need explicit `foregroundStyle(Color.brand)` – tint isn't inherited.
- Keep comments short and explain *why*. Match the existing code style.

## Behavior worth knowing

- **Audio graph:** `AVAudioUnitTimePitch` can't convert formats, so on load both of its
  connections are re-made with the file's processing format; the mixer converts to the device.
- **Loops:** drag on the waveform creates a loop, edges resize, inside moves; long-press/right-click
  opens Turn Loop Off / Clear Loop. The player's loop only updates when a drag ends.
  `setLoop` reschedules audio, so don't call it on every drag change.
- **Song library** (`SongLibrary.swift`): a song's ID is a SHA-256 fingerprint of
  title + artist + duration (rounded to the second) – deliberately simple (KISS); unknown songs
  just start fresh. Settings JSON in Application Support/Songs. iOS copies the audio into the
  library; the **Mac does not copy songs** (security-scoped bookmark, entitlement in
  `Largo-macOS.entitlements`). Saved automatically (throttled), on pause, on song switch,
  backgrounding (iOS) and quit (Mac).
- **Analysis cache:** waveform + `SongAnalysis` in Caches/Songs. When chord/beat detection or
  waveform output changes, **bump `SongLibrary.analysisVersion`** so old results are recomputed;
  `cleanUpCaches()` deletes outdated versions at launch.
- **Detection quality:** works well on the demo; on real recordings, sustained notes and the 7th
  overtone can produce false seventh chords. A global `seventhWeight` change loses real 7ths
  (tests fail) – tune on real songs before changing the analyzer.

## App Store

- Privacy: no data collected; `Largo/PrivacyInfo.xcprivacy` declares only UserDefaults (CA92.1).
  Adding analytics, networking or new "required reason" APIs means updating the manifest,
  the App Privacy answers and `AppStore/privacy-policy.md`.
- `ITSAppUsesNonExemptEncryption = NO` (hashing only), Mac category Music, background audio on iOS.
- Each upload needs a higher build number (`CURRENT_PROJECT_VERSION`).
- Apple Music tracks are DRM-protected and can't be analyzed – don't promise that.

## Working with the owner

- Lars writes in English or German; answer in the language he uses.
- Prefers simple solutions (KISS) and Apple-like UI (Podcasts / Music as references).
- Don't commit or push unless asked. `main` tracks `origin` (github.com/SourceSign/Largo).

## Ideas for later

Stem separation on device (Demucs → Core ML, feasibility test first), song list with delete on
iPhone, import from the Music library (non-DRM files), German localization, loop snapping to
beats, dark-mode contrast of the played waveform inside a loop, the key button showing "♮"
while the analysis is still running.
