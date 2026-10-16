import SwiftUI
import LargoCore
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var player: AudioPlayer
    @State private var isDropTargeted = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone (and narrow iPad split view): stack things vertically.
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    var body: some View {
        VStack(spacing: isCompact ? 10 : 14) {
            #if os(iOS)
            // Only while no song is open (for the Open button): once one is, the players
            // show the title themselves.
            if player.fileURL == nil { header }
            #endif
            if player.fileURL == nil {
                emptyState
            } else if isCompact {
                #if os(iOS)
                CompactPlayerView(player: player) // iPhone: Podcasts "Now Playing" style
                #endif
            } else {
                WidePlayerView(player: player) // Mac and iPad: waveform on top, command bar below
            }
        }
        .padding(isCompact ? 14 : 18)
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 460)
        .modifier(HiddenWindowTitle(title: player.songTitle))
        #endif
        .fileImporter(isPresented: $player.isImporterPresented, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { player.load(url: url) }
        }
        .onDrop(of: dropTypes, isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
            }
        }
        .alert("Error", isPresented: Binding(get: { player.errorMessage != nil },
                                             set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }

    // MARK: Sections

    /// "Song Title   C major · 120 BPM" on one line.
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(player.songTitle)
                .font(isCompact ? .title3.weight(.semibold) : .headline)
                .lineLimit(1)
            Text(player.keyAndTempo)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    #if os(iOS)
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            // One line when it fits; otherwise key and tempo go under the title.
            ViewThatFits(in: .horizontal) {
                titleLine
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.songTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(player.keyAndTempo)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { player.isImporterPresented = true } label: {
                Label("Open…", systemImage: "folder").labelStyle(.iconOnly)
            }
        }
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            #if os(macOS)
            Text("Drop an audio file here or press ⌘O")
                .font(.headline)
            #else
            Text("Tap Open to choose a song from Files")
                .font(.headline)
            #endif
            Text("MP3, M4A, WAV, AIFF, FLAC, CAF")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Demo Song") { player.openDemoSong() }
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Helpers

    #if os(macOS)
    private let dropTypes: [UTType] = [.fileURL]
    #else
    private let dropTypes: [UTType] = [.audio]
    #endif

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        #if os(macOS)
        // Finder drops hand us the file's location directly.
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in player.load(url: url) }
        }
        #else
        // On iPad the dropped file is only lent to us for the callback, so keep a copy.
        _ = provider.loadFileRepresentation(for: .audio, openInPlace: false) { url, _, _ in
            guard let url else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped", isDirectory: true)
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: copy)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
            Task { @MainActor in player.load(url: copy) }
        }
        #endif
        return true
    }
}

#if os(macOS)
/// The song title names the window (Window menu, Mission Control) but isn't shown in the
/// title bar, since the command bar already shows it. macOS 14 can't hide it, so it stays visible there.
private struct HiddenWindowTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.navigationTitle(title).toolbar(removing: .title)
        } else {
            content.navigationTitle(title)
        }
    }
}
#endif

extension Color {
    /// App accent (Apple Music–style red), from the AccentColor asset. Used instead of
    /// `Color.accentColor` so the Mac doesn't swap in the user's system accent color.
    static let brand = Color("AccentColor")

    /// Shared by the play button and the not-yet-played part of the waveform so they always match.
    static let transport = Color.primary

    /// Background behind the waveform: white in light mode, near-black in dark mode.
    #if os(macOS)
    static let waveformBackground = Color(nsColor: .textBackgroundColor)
    #else
    static let waveformBackground = Color(uiColor: .systemBackground)
    #endif
}
