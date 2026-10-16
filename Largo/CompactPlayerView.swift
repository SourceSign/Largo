#if os(iOS)
import SwiftUI
import MediaPlayer
import LargoCore

/// iPhone layout in the style of the Podcasts "Now Playing" screen:
/// waveform square on top, title, song overview with times, then one row of controls.
struct CompactPlayerView: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { player.isImporterPresented = true } label: {
                    Label("Open…", systemImage: "folder").labelStyle(.iconOnly)
                }
            }
            .padding(.bottom, 6)

            // The "cover": scrolling waveform with the chord lane.
            ScrollingTimelineView(player: player)
                .aspectRatio(1, contentMode: .fit)

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                CoverArt(image: player.artwork, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.songTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(player.keyAndTempo.isEmpty ? " " : player.keyAndTempo)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 16)

            // Where Podcasts has its progress bar.
            OverviewView(player: player)
            HStack {
                Text(clock(player.currentTime))
                Spacer()
                Text("-" + clock(max(0, player.duration - player.currentTime)))
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.top, 6)

            Spacer(minLength: 16)

            controlsRow

            Spacer(minLength: 16)

            volumeRow
        }
    }

    /// System volume, like the slider at the bottom of the Podcasts player.
    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider()
                .frame(height: 34)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack {
            SpeedButton(player: player).frame(width: 56)
            Spacer()
            Button { player.skip(by: -5) } label: {
                Image(systemName: "gobackward.5").font(.system(size: 30))
            }
            .accessibilityLabel("Back 5 seconds")
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.skip(by: 5) } label: {
                Image(systemName: "goforward.5").font(.system(size: 30))
            }
            .accessibilityLabel("Forward 5 seconds")
            Spacer()
            KeyButton(player: player).frame(width: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.transport)
    }
}

/// The system volume slider (same volume as the side buttons and Control Center).
/// Apps can't set the system volume any other way; it also offers the AirPlay route button.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .label // filled part in the same color as the controls
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

#if DEBUG
#Preview("iPhone player") {
    CompactPlayerView(player: PreviewData.player())
        .padding(14)
}

#Preview("Pitch popover") {
    PitchPopover(player: PreviewData.player(semitones: 2))
}

#Preview("Speed popover") {
    SpeedPopover(player: PreviewData.player(rate: 0.7))
}
#endif // DEBUG
#endif
