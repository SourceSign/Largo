import Foundation

public enum ChordQuality: Int, CaseIterable, Codable, Sendable {
    case major, minor, dominant7, minor7, major7

    /// Semitone offsets from the root.
    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .minor7: return [0, 3, 7, 10]
        case .major7: return [0, 4, 7, 11]
        }
    }

    public var suffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .dominant7: return "7"
        case .minor7: return "m7"
        case .major7: return "maj7"
        }
    }
}

private let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
private let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

public func noteName(_ pitchClass: Int, useFlats: Bool) -> String {
    let pc = ((pitchClass % 12) + 12) % 12
    return useFlats ? flatNames[pc] : sharpNames[pc]
}

public struct Chord: Equatable, Hashable, Codable, Sendable {
    /// Pitch class 0 (C) ... 11 (B); nil means "no chord".
    public var root: Int?
    public var quality: ChordQuality

    public static let none = Chord(root: nil, quality: .major)

    public init(root: Int?, quality: ChordQuality) {
        self.root = root.map { (($0 % 12) + 12) % 12 }
        self.quality = quality
    }

    public func transposed(by semitones: Int) -> Chord {
        guard let root else { return self }
        return Chord(root: root + semitones, quality: quality)
    }

    public func name(useFlats: Bool = false) -> String {
        guard let root else { return "N.C." }
        return noteName(root, useFlats: useFlats) + quality.suffix
    }
}

public struct ChordSegment: Equatable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var chord: Chord

    public init(start: Double, end: Double, chord: Chord) {
        self.start = start
        self.end = end
        self.chord = chord
    }
}

public struct MusicalKey: Equatable, Codable, Sendable {
    public var tonic: Int
    public var isMinor: Bool

    public init(tonic: Int, isMinor: Bool) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.isMinor = isMinor
    }

    public func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(tonic: tonic + semitones, isMinor: isMinor)
    }

    /// Keys whose signature uses flats (F, B♭, E♭, A♭, D♭, G♭ major and their relative minors).
    public var usesFlats: Bool {
        let relativeMajor = isMinor ? (tonic + 3) % 12 : tonic
        return [5, 10, 3, 8, 1, 6].contains(relativeMajor)
    }

    public var name: String {
        noteName(tonic, useFlats: usesFlats) + (isMinor ? " minor" : " major")
    }
}

public struct ChordAnalysis: Codable, Sendable {
    public var segments: [ChordSegment]
    public var key: MusicalKey?
    /// Estimated deviation of the recording from A440, in cents.
    public var tuningCents: Double

    public init(segments: [ChordSegment], key: MusicalKey?, tuningCents: Double) {
        self.segments = segments
        self.key = key
        self.tuningCents = tuningCents
    }

    /// Index of the segment containing `time`, via binary search.
    public func segmentIndex(at time: Double) -> Int? {
        var lo = 0, hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = segments[mid]
            if time < s.start { hi = mid - 1 }
            else if time >= s.end { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }
}
