import Foundation
import CryptoKit
import LargoCore

/// Everything Largo remembers about a song. Stored as JSON in the song library.
struct SongSettings: Codable, Equatable {
    var version = 1
    var title: String
    var artist: String?
    var duration: Double
    /// iPhone/iPad: the library's own copy of the audio, relative to `SongLibrary.folder`.
    var audioFile: String?
    /// Mac: a security-scoped bookmark to the original file (songs aren't copied on the Mac).
    var bookmark: Data?

    var rate: Float = 1
    var semitones = 0
    var cents = 0
    var loopStart: Double?
    var loopEnd: Double?
    var loopEnabled = false
    /// Time signature and bar-line position (as detected, or as corrected by the user).
    var beatsPerBar: Int?
    var downbeatOffset: Int?
    var position: Double = 0
    var visibleSeconds: Double = 12
}

/// Songs Largo has opened, with their settings, in the app's own storage:
///
///     Application Support/Songs/<id>.json       settings
///     Application Support/Songs/<id>.mp3        iPhone/iPad only: copy of the audio
///     Caches/Songs/<id>.waveform                cached waveform peaks (raw Float32)
///     Caches/Songs/<id>.analysis-v1.json        cached chords, key and beats
///
/// The caches can be recomputed, so they live in Caches: the system may clear it when space
/// runs low, and it isn't backed up. Missing cache files are simply computed again.
///
/// A song's id is a fingerprint of title, artist and duration (to the second), so the same
/// song opened again from anywhere gets its settings back. Unknown songs simply start fresh.
enum SongLibrary {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let cacheFolder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func id(title: String, artist: String?, duration: Double) -> String {
        let fingerprint = [title.lowercased(), (artist ?? "").lowercased(), String(Int(duration.rounded()))]
            .joined(separator: "|")
        // Hashed so it's a safe file name whatever characters the title contains.
        return SHA256.hash(data: Data(fingerprint.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func settings(for id: String) -> SongSettings? {
        guard let data = try? Data(contentsOf: settingsURL(id)) else { return nil }
        return try? JSONDecoder().decode(SongSettings.self, from: data)
    }

    static func save(_ settings: SongSettings, for id: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsURL(id), options: .atomic)
    }

    /// Remembers where the song's audio is, so it can be reopened after a restart.
    /// iPhone/iPad copy it into the library, since permission to read a file from the Files app
    /// doesn't last. The Mac keeps a bookmark to the original file instead of a copy.
    static func rememberAudio(at url: URL, id: String, in settings: inout SongSettings) {
        #if os(macOS)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil) {
            settings.bookmark = bookmark
        }
        #else
        settings.audioFile = importAudio(from: url, id: id)
        #endif
    }

    /// Where to reopen the song from, or nil if the audio is gone (Mac: moved to another disk or deleted).
    static func audioURL(of settings: SongSettings) -> URL? {
        #if os(macOS)
        guard let bookmark = settings.bookmark else { return nil }
        var isStale = false // a fresh bookmark is saved whenever the song is opened
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #else
        guard let name = settings.audioFile else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #endif
    }

    #if os(iOS)
    /// Copies the audio into the library unless it's already there. Returns the copy's file name.
    private static func importAudio(from source: URL, id: String) -> String {
        let name = id + "." + (source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased())
        let destination = folder.appendingPathComponent(name)
        if source.standardizedFileURL != destination.standardizedFileURL,
           !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        return name
    }
    #endif

    // MARK: Analysis cache

    /// Bump when chord/beat detection or the waveform changes, so old results are recomputed.
    static let analysisVersion = 1

    static func cachedWaveform(for id: String) -> [Float]? {
        guard let data = try? Data(contentsOf: waveformURL(id)), !data.isEmpty,
              data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func saveWaveform(_ peaks: [Float], for id: String) {
        let data = peaks.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: waveformURL(id), options: .atomic)
    }

    static func cachedAnalysis(for id: String) -> SongAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL(id)) else { return nil }
        return try? JSONDecoder().decode(SongAnalysis.self, from: data)
    }

    static func saveAnalysis(_ analysis: SongAnalysis, for id: String) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: analysisURL(id), options: .atomic)
    }

    private static func waveformURL(_ id: String) -> URL {
        cacheFolder.appendingPathComponent("\(id).waveform")
    }

    private static func analysisURL(_ id: String) -> URL {
        cacheFolder.appendingPathComponent("\(id).analysis-v\(analysisVersion).json")
    }

    /// Run at launch: deletes analysis results from older detection versions, and moves cache
    /// files from where earlier builds kept them (next to the settings) into the Caches folder.
    static func cleanUpCaches() {
        let fm = FileManager.default
        let current = ".analysis-v\(analysisVersion).json"
        for oldFolder in [folder, cacheFolder] {
            for name in (try? fm.contentsOfDirectory(atPath: oldFolder.path)) ?? [] {
                let file = oldFolder.appendingPathComponent(name)
                let isAnalysis = name.contains(".analysis-v")
                if isAnalysis && !name.hasSuffix(current) {
                    try? fm.removeItem(at: file) // outdated detection version
                } else if oldFolder == folder && (isAnalysis || name.hasSuffix(".waveform")) {
                    let destination = cacheFolder.appendingPathComponent(name)
                    if fm.fileExists(atPath: destination.path) {
                        try? fm.removeItem(at: file)
                    } else {
                        try? fm.moveItem(at: file, to: destination)
                    }
                }
            }
        }
    }

    /// The song that was open last, reopened at launch.
    static var lastSongID: String? {
        get { UserDefaults.standard.string(forKey: "lastSongID") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSongID") }
    }

    private static func settingsURL(_ id: String) -> URL {
        folder.appendingPathComponent(id + ".json")
    }
}
