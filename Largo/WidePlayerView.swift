import SwiftUI
import AVKit
import LargoCore

/// Mac and iPad layout in the style of the Podcasts app on the Mac: the scrolling waveform
/// fills the window, with a rounded command bar at the bottom.
struct WidePlayerView: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 14) {
            ScrollingTimelineView(player: player)
                .frame(maxHeight: .infinity)
            CommandBar(player: player)
        }
    }
}

/// Transport on the left, song with progress in the middle, more options on the right.
struct CommandBar: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 14) {
            transport
            nowPlaying
                .frame(maxWidth: .infinity)
            trailingControls
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: Left

    private var transport: some View {
        HStack(spacing: 10) {
            SpeedButton(player: player, font: .body.weight(.medium))
            barButton("gobackward.5", help: "Back 5 s (←)") { player.skip(by: -5) }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .help("Play / Pause (Space)")
            barButton("goforward.5", help: "Forward 5 s (→)") { player.skip(by: 5) }
            KeyButton(player: player, font: .body.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.transport)
    }

    // MARK: Middle

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            CoverArt(image: player.artwork, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(player.songTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(player.keyAndTempo)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(clock(player.currentTime) + "  -" + clock(player.duration - player.currentTime))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                SongProgressBar(player: player)
            }
        }
        .frame(minWidth: 240)
    }

    // MARK: Right

    private var trailingControls: some View {
        HStack(spacing: 12) {
            moreMenu
            AirPlayButton()
                .frame(width: 26, height: 26)
                .help("AirPlay")
            VolumeButton(player: player)
        }
        .foregroundStyle(Color.transport)
    }

    /// Everything that doesn't need a button of its own.
    private var moreMenu: some View {
        Menu {
            Picker("Time Signature", selection: Binding(get: { player.beatGrid?.beatsPerBar ?? 4 },
                                                        set: { player.setBeatsPerBar($0) })) {
                Text("3/4").tag(3)
                Text("4/4").tag(4)
            }
            .disabled(player.beatGrid == nil)
            Button("Move Bar Lines Earlier") { player.shiftDownbeat(by: -1) }
                .disabled(player.beatGrid == nil)
            Button("Move Bar Lines Later") { player.shiftDownbeat(by: 1) }
                .disabled(player.beatGrid == nil)
            Divider()
            Button("Zoom In") { player.zoom(by: 1.5) }
            Button("Zoom Out") { player.zoom(by: 1 / 1.5) }
            Divider()
            Toggle("Loop", isOn: $player.loopEnabled)
                .disabled(!player.hasValidLoop)
            Button("Clear Loop") { player.clearLoop() }
                .disabled(player.loopStart == nil && player.loopEnd == nil)
            Divider()
            Button("Open…") { player.isImporterPresented = true }
            Button("Open Demo Song") { player.openDemoSong() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .help(help)
    }
}

/// Thin progress line under the title, with the loop shaded. Click or drag to jump.
struct SongProgressBar: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = player.duration > 0 ? CGFloat(player.currentTime / player.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let a = player.loopStart, let b = player.loopEnd, player.duration > 0 {
                    Capsule()
                        .fill(Color.brand.opacity(player.loopEnabled ? 0.5 : 0.25))
                        .frame(width: max(3, CGFloat((b - a) / player.duration) * width))
                        .offset(x: CGFloat(a / player.duration) * width)
                }
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: max(3, fraction * width))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity) // centered in a taller click area
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard width > 0 else { return }
                player.seek(to: Double(min(max(0, g.location.x / width), 1)) * player.duration)
            })
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(clock(player.currentTime))
    }
}

/// Speaker button; click for a volume slider.
/// Mac: Largo's own volume (apps can't set the Mac's system volume); the icon follows the level.
/// iPad: the system volume, like the side buttons.
private struct VolumeButton: View {
    @ObservedObject var player: AudioPlayer
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Volume")
        .accessibilityLabel("Volume")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                #if os(macOS)
                MusicSlider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }),
                            in: 0...1, accessibilityText: "Volume")
                #else
                SystemVolumeSlider().frame(height: 34)
                #endif
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
            .frame(width: 260)
            .padding()
            .presentationCompactAdaptation(.popover)
        }
    }

    private var symbol: String {
        #if os(iOS)
        return "speaker.wave.2.fill" // the system volume isn't known to the app
        #else
        switch player.volume {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
        #endif
    }
}

/// The system AirPlay / output device picker.
#if os(macOS)
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#else
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

#if DEBUG
#Preview("Wide player (Mac, iPad)") {
    WidePlayerView(player: PreviewData.player())
        .padding(18)
        .frame(width: 960, height: 560)
}
#endif
