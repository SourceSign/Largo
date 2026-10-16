import AVFoundation
import Combine
import SwiftUI
import LargoCore
#if os(iOS)
import UIKit
#endif

/// Plays an audio file with independent speed and pitch control and an optional A–B loop.
///
/// Signal chain: AVAudioPlayerNode -> AVAudioUnitTimePitch -> main mixer.
/// The player node's sample clock counts *source* frames consumed, so the
/// playhead position stays correct at any playback rate.
@MainActor
final class AudioPlayer: ObservableObject {
    // MARK: Published state
    @Published private(set) var fileURL: URL?
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false {
        didSet {
            #if os(iOS)
            // Keep the screen on while practicing.
            UIApplication.shared.isIdleTimerDisabled = isPlaying
            #endif
        }
    }
    /// Shows the file picker; set from the Open button and the File menu.
    @Published var isImporterPresented = false
    /// Peak amplitudes at `waveformPeaksPerSecond` resolution, fine enough for the zoomed view.
    @Published private(set) var waveform: [Float] = []
    nonisolated static let waveformPeaksPerSecond = 200.0
    /// Seconds visible in the scrolling waveform (zoom level).
    @Published var visibleSeconds: Double = 12
    static let zoomRange = 3.0...120.0

    func zoom(by factor: Double) {
        visibleSeconds = min(max(visibleSeconds / factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }
    @Published var errorMessage: String?
    @Published private(set) var chordAnalysis: ChordAnalysis?
    /// 0...1 while chord/beat analysis runs, nil otherwise.
    @Published private(set) var analysisProgress: Double?
    @Published private(set) var beatGrid: BeatGrid?
    /// Cover art embedded in the file (MP3/M4A tags), if any.
    @Published private(set) var artwork: Image?

    /// Playback rate, 0.25 ... 2.0. Pitch is preserved.
    @Published var rate: Float = 1.0 { didSet { timePitch.rate = rate } }
    /// Transpose in semitones, -12 ... +12.
    @Published var semitones: Int = 0 { didSet { applyPitch() } }
    /// Fine tuning in cents, -50 ... +50.
    @Published var cents: Int = 0 { didSet { applyPitch() } }
    /// Largo's own volume, 0...1 (used on the Mac; iOS uses the system volume slider).
    @Published var volume: Float = 1 { didSet { engine.mainMixerNode.outputVolume = volume } }

    @Published var loopStart: Double?
    @Published var loopEnd: Double?
    @Published var loopEnabled = false { didSet { if oldValue != loopEnabled { reschedule() } } }

    var hasValidLoop: Bool {
        guard let a = loopStart, let b = loopEnd else { return false }
        return b - a > 0.05
    }

    // MARK: Audio graph
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100

    /// Frame where the current schedule started, plus how the schedule is laid out.
    private var scheduleStartFrame: AVAudioFramePosition = 0
    private var scheduledLoop: (start: AVAudioFramePosition, end: AVAudioFramePosition)?
    /// Bumped on every reschedule so completion handlers from old schedules are ignored.
    private var generation = 0
    private var timer: Timer?
    /// File we hold security-scoped access to (files from the picker or the Files app).
    private var accessedURL: URL?
    private var resumeAfterInterruption = false

    // Song library (see SongLibrary): the current song's id and settings, saved automatically.
    private var songID: String?
    private var songSettings: SongSettings?
    /// Bar settings to re-apply once beat detection has finished.
    private var pendingBars: (beatsPerBar: Int?, downbeatOffset: Int?)?
    private var autosave: AnyCancellable?

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        timePitch.overlap = 8 // higher quality time stretching
        observeAudioSystem()
        // Save a moment after changes (throttled, since the playhead changes many times a second).
        autosave = objectWillChange
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.saveSongSettings() }
    }

    // MARK: Audio system events

    private func observeAudioSystem() {
        let center = NotificationCenter.default
        #if os(macOS)
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.saveSongSettings() }
        }
        #endif
        // The engine stops itself when the output device changes; keep our state in sync.
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Task { @MainActor in if self.isPlaying { self.pause() } }
        }
        #if os(iOS)
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in self.handleInterruption(type: type, shouldResume: options.contains(.shouldResume)) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Headphones unplugged: pause instead of blasting through the speaker.
            if reason == .oldDeviceUnavailable {
                Task { @MainActor in if self.isPlaying { self.pause() } }
            }
        }
        #endif
    }

    #if os(iOS)
    private func handleInterruption(type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            if resumeAfterInterruption && shouldResume { play() }
            resumeAfterInterruption = false
        default:
            break
        }
    }
    #endif

    private func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .playback: plays with the ring/silent switch on silent, and in the background.
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        #endif
    }

    // MARK: Loading

    /// Opens a song. `librarySong` is set when reopening a song from the library.
    func load(url: URL, librarySong: SongSettings? = nil) {
        saveSongSettings() // keep the previous song's state
        stopInternal()
        songID = nil
        songSettings = nil
        pendingBars = nil
        songTitleOverride = librarySong?.title
        rate = 1
        semitones = 0
        cents = 0
        if url != accessedURL {
            accessedURL?.stopAccessingSecurityScopedResource()
            // Needed for files from the picker; returns false (harmlessly) for files we can read anyway.
            accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        }
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            sampleRate = f.processingFormat.sampleRate
            // Time-pitch can't convert formats, so both of its sides use the file's format;
            // the mixer then converts to whatever the output device needs.
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(playerNode, to: timePitch, format: f.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: f.processingFormat)
            fileURL = url
            duration = Double(f.length) / sampleRate
            currentTime = 0
            scheduleStartFrame = 0
            loopStart = nil
            loopEnd = nil
            loopEnabled = false
            waveform = []
            errorMessage = nil
            chordAnalysis = nil
            beatGrid = nil
            analysisProgress = 0
            // Waveform and analysis start once the song is identified (cached results or computed).
            loadMetadata(url: url, librarySong: librarySong)
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Uses the library's cached waveform and analysis when there are any, otherwise computes and caches them.
    private func loadWaveformAndAnalysis(url: URL, id: String) {
        if let peaks = SongLibrary.cachedWaveform(for: id) {
            waveform = peaks
        } else {
            computeWaveform(url: url, id: id)
        }
        if let cached = SongLibrary.cachedAnalysis(for: id) {
            chordAnalysis = cached.chords
            beatGrid = cached.beats
            analysisProgress = nil
            applyPendingBars()
        } else {
            analyzeSong(url: url, id: id)
        }
    }

    private func computeWaveform(url: URL, id: String) {
        Task.detached(priority: .userInitiated) {
            let seconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            let bins = max(1, Int(seconds * AudioPlayer.waveformPeaksPerSecond))
            let peaks = WaveformAnalyzer.peaks(url: url, bins: bins)
            await MainActor.run { [weak self] in
                guard let self, self.fileURL == url else { return }
                self.waveform = peaks
                if !peaks.isEmpty { SongLibrary.saveWaveform(peaks, for: id) }
            }
        }
    }

    private func analyzeSong(url: URL, id: String) {
        Task.detached(priority: .utility) {
            let result = try? SongAnalyzer.analyze(url: url) { p in
                Task { @MainActor in
                    if self.fileURL == url, self.analysisProgress != nil { self.analysisProgress = p }
                }
            }
            await MainActor.run {
                guard self.fileURL == url else { return }
                self.chordAnalysis = result?.chords
                self.beatGrid = result?.beats
                self.analysisProgress = nil
                self.applyPendingBars()
                if let result { SongLibrary.saveAnalysis(result, for: id) }
            }
        }
    }

    /// Reads title, artist and cover art, then looks the song up in the library.
    private func loadMetadata(url: URL, librarySong: SongSettings?) {
        artwork = nil
        Task {
            let asset = AVURLAsset(url: url)
            let items = (try? await asset.load(.commonMetadata)) ?? []
            var title: String?, artist: String?, artworkData: Data?
            for item in items {
                switch item.commonKey {
                case .commonKeyTitle? where title == nil: title = try? await item.load(.stringValue)
                case .commonKeyArtist? where artist == nil: artist = try? await item.load(.stringValue)
                case .commonKeyArtwork? where artworkData == nil: artworkData = try? await item.load(.dataValue)
                default: break
                }
            }
            guard fileURL == url else { return }
            if let artworkData {
                #if os(iOS)
                if let image = UIImage(data: artworkData) { artwork = Image(uiImage: image) }
                #else
                if let image = NSImage(data: artworkData) { artwork = Image(nsImage: image) }
                #endif
            }
            identifySong(url: url,
                         title: librarySong?.title ?? title ?? url.deletingPathExtension().lastPathComponent,
                         artist: librarySong?.artist ?? artist)
        }
    }

    // MARK: Song library

    /// Fingerprints the song (title, artist, duration); restores its settings if known,
    /// otherwise starts a new library entry. Either way, remembers where the audio is.
    private func identifySong(url: URL, title: String, artist: String?) {
        let id = SongLibrary.id(title: title, artist: artist, duration: duration)
        songTitleOverride = title
        var settings: SongSettings
        if let saved = SongLibrary.settings(for: id) {
            apply(saved)
            settings = saved
        } else {
            settings = SongSettings(title: title, artist: artist, duration: duration)
        }
        SongLibrary.rememberAudio(at: url, id: id, in: &settings)
        SongLibrary.save(settings, for: id)
        songSettings = settings
        songID = id
        SongLibrary.lastSongID = id
        loadWaveformAndAnalysis(url: url, id: id)
    }

    private func apply(_ saved: SongSettings) {
        rate = saved.rate
        semitones = saved.semitones
        cents = saved.cents
        visibleSeconds = saved.visibleSeconds
        if let a = saved.loopStart, let b = saved.loopEnd {
            loopStart = a
            loopEnd = b
            loopEnabled = saved.loopEnabled && hasValidLoop
        }
        seek(to: saved.position)
        if saved.beatsPerBar != nil || saved.downbeatOffset != nil {
            pendingBars = (saved.beatsPerBar, saved.downbeatOffset)
            applyPendingBars()
        }
    }

    private func applyPendingBars() {
        guard let bars = pendingBars, let grid = beatGrid else { return }
        beatGrid = grid.with(beatsPerBar: bars.beatsPerBar, downbeatOffset: bars.downbeatOffset)
        pendingBars = nil
    }

    /// Writes the current song's settings to the library. Called automatically.
    func saveSongSettings() {
        guard let id = songID, var settings = songSettings else { return }
        settings.rate = rate
        settings.semitones = semitones
        settings.cents = cents
        settings.loopStart = loopStart
        settings.loopEnd = loopEnd
        settings.loopEnabled = loopEnabled
        if let grid = beatGrid {
            settings.beatsPerBar = grid.beatsPerBar
            settings.downbeatOffset = grid.downbeatOffset
        }
        settings.position = isPlaying ? currentPosition() : currentTime
        settings.visibleSeconds = visibleSeconds
        guard settings != songSettings || !FileManager.default.fileExists(
            atPath: SongLibrary.folder.appendingPathComponent(id + ".json").path) else { return }
        songSettings = settings
        SongLibrary.save(settings, for: id)
    }

    /// Reopens the song that was open when the app was last used.
    /// The demo song shipped with the app (Design/make-demo-song.sh), so there's something to try right away.
    func openDemoSong() {
        guard let url = Bundle.main.url(forResource: "LargoDemo", withExtension: "m4a") else { return }
        load(url: url)
    }

    func restoreLastSong() {
        guard fileURL == nil, let id = SongLibrary.lastSongID,
              let saved = SongLibrary.settings(for: id) else { return }
        guard let url = SongLibrary.audioURL(of: saved) else { return } // moved or deleted: start empty
        load(url: url, librarySong: saved)
    }

    // MARK: Bars

    func setBeatsPerBar(_ n: Int) {
        guard let grid = beatGrid, n != grid.beatsPerBar else { return }
        // Keep the first downbeat where it is.
        beatGrid = grid.with(beatsPerBar: n, downbeatOffset: grid.downbeatOffset % n)
    }

    /// Moves every bar line by `beats` (fixes a misdetected downbeat).
    func shiftDownbeat(by beats: Int) {
        guard let grid = beatGrid else { return }
        beatGrid = grid.with(downbeatOffset: grid.downbeatOffset + beats)
    }

    // MARK: Song info

    /// Title from the song's tags (or the original file name); the library copy's file name is just an id.
    @Published private var songTitleOverride: String?

    var songTitle: String { songTitleOverride ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Largo" }

    /// "C major · 120 BPM", following transpose and speed; empty until analysis finishes.
    var keyAndTempo: String {
        var parts: [String] = []
        if let key = displayKey { parts.append(key.name) }
        if let grid = beatGrid {
            let original = Int(grid.bpm.rounded())
            let playing = Int((grid.bpm * Double(rate)).rounded())
            parts.append(playing == original ? "\(original) BPM" : "\(playing) BPM (orig. \(original))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Chord display (follows the transpose setting)

    var displayKey: MusicalKey? { chordAnalysis?.key?.transposed(by: semitones) }

    private var useFlats: Bool { displayKey?.usesFlats ?? false }

    func displayName(of chord: Chord) -> String {
        chord.transposed(by: semitones).name(useFlats: useFlats)
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard file != nil else { return }
        do {
            try activateAudioSession()
            if !engine.isRunning { try engine.start() }
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }
        if currentTime >= duration - 0.01 { currentTime = loopActive ? loopStart! : 0 }
        schedule(from: currentTime)
        playerNode.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        updateCurrentTime()
        stopInternal()
        saveSongSettings()
    }

    func stop() {
        stopInternal()
        currentTime = loopActive ? loopStart! : 0
    }

    func seek(to time: Double) {
        let t = min(max(0, time), duration)
        currentTime = t
        if isPlaying { reschedule(from: t) }
    }

    func skip(by seconds: Double) { seek(to: currentPosition() + seconds) }

    /// Jump back to the loop start (or the beginning).
    func returnToStart() { seek(to: loopActive ? loopStart! : 0) }

    // MARK: Loop editing

    func setLoopStartHere() {
        let t = currentPosition()
        loopStart = t
        if let b = loopEnd, b <= t { loopEnd = nil }
        loopChanged()
    }

    func setLoopEndHere() {
        let t = currentPosition()
        loopEnd = t
        if let a = loopStart, a >= t { loopStart = nil }
        if hasValidLoop { loopEnabled = true }
        loopChanged()
    }

    func setLoop(start: Double, end: Double) {
        loopStart = max(0, min(start, end))
        loopEnd = min(duration, max(start, end))
        loopEnabled = hasValidLoop
        loopChanged()
    }

    func clearLoop() {
        loopStart = nil
        loopEnd = nil
        loopEnabled = false
        loopChanged()
    }

    private func loopChanged() {
        if isPlaying { reschedule() }
    }

    func resetPitchAndSpeed() {
        rate = 1
        semitones = 0
        cents = 0
    }

    // MARK: Scheduling

    private var loopActive: Bool { loopEnabled && hasValidLoop }

    /// Restart scheduling at `time`, or at the current playhead when nil.
    private func reschedule(from time: Double? = nil) {
        guard isPlaying else { return }
        let t = time ?? currentPosition()
        currentTime = t
        playerNode.stop()
        schedule(from: t)
        playerNode.play()
    }

    private func schedule(from time: Double) {
        guard let file else { return }
        generation += 1
        let gen = generation
        var start = AVAudioFramePosition(time * sampleRate)

        if loopActive, let a = loopStart, let b = loopEnd {
            let la = AVAudioFramePosition(a * sampleRate)
            let lb = min(AVAudioFramePosition(b * sampleRate), file.length)
            // Starting outside the loop jumps into it.
            if start < la || start >= lb { start = la }
            scheduleStartFrame = start
            scheduledLoop = (la, lb)
            file.framePosition = 0
            playerNode.scheduleSegment(file, startingFrame: start,
                                       frameCount: AVAudioFrameCount(lb - start), at: nil)
            // Keep two loop passes queued; each finished pass queues another.
            enqueueLoopPass(gen: gen)
            enqueueLoopPass(gen: gen)
        } else {
            scheduleStartFrame = min(start, file.length)
            scheduledLoop = nil
            let remaining = file.length - scheduleStartFrame
            guard remaining > 0 else { return }
            playerNode.scheduleSegment(file, startingFrame: scheduleStartFrame,
                                       frameCount: AVAudioFrameCount(remaining), at: nil,
                                       completionCallbackType: .dataPlayedBack) { _ in
                // The player lives as long as the app, so capturing it strongly is fine.
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.stopInternal()
                    self.currentTime = self.duration
                }
            }
        }
    }

    private func enqueueLoopPass(gen: Int) {
        guard let file, let loop = scheduledLoop, generation == gen else { return }
        playerNode.scheduleSegment(file, startingFrame: loop.start,
                                   frameCount: AVAudioFrameCount(loop.end - loop.start), at: nil,
                                   completionCallbackType: .dataConsumed) { _ in
            Task { @MainActor in self.enqueueLoopPass(gen: gen) }
        }
    }

    private func stopInternal() {
        generation += 1
        playerNode.stop()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    // MARK: Position

    /// Current playhead position in seconds, derived from the player's sample clock.
    func currentPosition() -> Double {
        guard isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return currentTime }
        let elapsed = max(0, playerTime.sampleTime)
        let frame: AVAudioFramePosition
        if let loop = scheduledLoop {
            let first = loop.end - scheduleStartFrame
            if elapsed < first {
                frame = scheduleStartFrame + elapsed
            } else {
                frame = loop.start + (elapsed - first) % max(1, loop.end - loop.start)
            }
        } else {
            frame = scheduleStartFrame + elapsed
        }
        return min(Double(frame) / sampleRate, duration)
    }

    private func updateCurrentTime() { currentTime = currentPosition() }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in self.updateCurrentTime() }
        }
    }

    private func applyPitch() {
        timePitch.pitch = Float(semitones * 100 + cents)
    }
}

#if DEBUG
extension AudioPlayer {
    /// Fills in state without loading audio, for SwiftUI previews. See `Previews.swift`.
    func loadPreviewState(url: URL?, duration: Double, currentTime: Double, waveform: [Float],
                          chords: ChordAnalysis?, beats: BeatGrid?, analysisProgress: Double? = nil) {
        fileURL = url
        self.duration = duration
        self.currentTime = currentTime
        self.waveform = waveform
        chordAnalysis = chords
        beatGrid = beats
        self.analysisProgress = analysisProgress
    }
}
#endif
