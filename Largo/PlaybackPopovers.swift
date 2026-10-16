import SwiftUI
import LargoCore

// Speed and key buttons with their popovers, shared by the iPhone player and the Mac command bar.

/// "1×" button: opens the speed popover; red when not at normal speed.
struct SpeedButton: View {
    @ObservedObject var player: AudioPlayer
    var font: Font = .headline
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Text(Double(player.rate).formatted(.number.precision(.fractionLength(0...2))) + "×")
                .font(font)
                .monospacedDigit()
                .foregroundStyle(player.rate == 1 ? Color.transport : Color.brand)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
        .help("Playback speed")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SpeedPopover(player: player)
                .presentationCompactAdaptation(.popover) // a bubble on iPhone too, not a sheet
        }
    }
}

/// Key button: shows the (transposed) key; opens the pitch popover. Red when transposed or detuned.
struct KeyButton: View {
    @ObservedObject var player: AudioPlayer
    var font: Font = .headline
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Text(shortKeyName)
                .font(font)
                .foregroundStyle(player.semitones == 0 && player.cents == 0 ? Color.transport : Color.brand)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Key and pitch")
        .help("Key and pitch")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PitchPopover(player: player)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// "C", "F♯m"…; before the key is known, the transposition instead (e.g. "+2").
    private var shortKeyName: String {
        if let key = player.displayKey {
            return noteName(key.tonic, useFlats: key.usesFlats) + (key.isMinor ? "m" : "")
        }
        return player.semitones == 0 ? "♮" : (player.semitones > 0 ? "+\(player.semitones)" : "\(player.semitones)")
    }
}

/// The song's embedded cover art, or a placeholder so the layout doesn't jump.
struct CoverArt: View {
    let image: Image?
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size / 7)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 7))
            .accessibilityHidden(true)
    }
}

/// m:ss, like the Podcasts player.
func clock(_ t: Double) -> String {
    let s = Int(t.isFinite ? max(0, t) : 0)
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// iPhone/iPad: two pages you swipe between, like in Podcasts. Mac (no swiping): both parts stacked.
struct TwoPartPopover<First: View, Second: View>: View {
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    var body: some View {
        #if os(iOS)
        TabView {
            first.tag(0)
            second.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: 340, height: 130)
        #else
        VStack(spacing: 14) {
            first
            Divider()
            second
        }
        .padding(.vertical, 18)
        .frame(width: 340)
        #endif
    }
}

/// Speed popover in the style of Podcasts: preset buttons, and a tick-mark ruler
/// between tortoise and hare for any speed.
struct SpeedPopover: View {
    @ObservedObject var player: AudioPlayer

    /// Practice speeds; anything else is on the ruler page.
    private let presets: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1]

    var body: some View {
        TwoPartPopover { presetsPage } second: { rulerPage }
    }

    private var rate: Double { Double(player.rate) }

    private var presetsPage: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    let selected = abs(rate - preset) < 0.001
                    Button { player.rate = Float(preset) } label: {
                        Text(preset.formatted(.number.precision(.fractionLength(0...2))) + (selected ? "×" : ""))
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(selected ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.18)))
                            .foregroundStyle(selected ? Color.waveformBackground : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.formatted() + "×")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            #if os(iOS)
            Text("Swipe for more speed options")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var rulerPage: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "tortoise.fill")
                TickRuler(value: Binding(get: { rate }, set: { player.rate = Float($0) }),
                          range: 0.25...2, step: 0.05, tickInterval: 0.1)
                    .accessibilityLabel("Playback speed")
                Image(systemName: "hare.fill")
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            Text("Adjust playback speed")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Tick-mark ruler (speed and fine tuning): the current value is a tall line; ticks to its
/// left are filled in. Drag sideways to change it (relative, like the other sliders); each step clicks.
struct TickRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tickInterval: Double
    @State private var dragStartValue: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { ctx, size in
                let mid = size.height / 2
                var t = (range.lowerBound / tickInterval).rounded(.up) * tickInterval
                while t <= range.upperBound + 0.0001 {
                    let x = xPosition(t, width: size.width)
                    let filled = t <= value + 0.0001
                    ctx.fill(Path(roundedRect: CGRect(x: x - 1.5, y: mid - 17, width: 3, height: 34), cornerRadius: 1.5),
                             with: .color(.primary.opacity(filled ? 0.45 : 0.15)))
                    t += tickInterval
                }
                let x = xPosition(value, width: size.width)
                ctx.fill(Path(roundedRect: CGRect(x: x - 2, y: mid - 24, width: 4, height: 48), cornerRadius: 2),
                         with: .color(.primary))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStartValue == nil { dragStartValue = value }
                        let delta = Double(g.translation.width / max(width, 1)) * (range.upperBound - range.lowerBound)
                        value = snapped(dragStartValue! + delta)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
        }
        .frame(height: 52)
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement()
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = snapped(value + step)
            case .decrement: value = snapped(value - step)
            @unknown default: break
            }
        }
    }

    private func xPosition(_ v: Double, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 4
        let f = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        return inset + CGFloat(f) * (width - 2 * inset)
    }

    private func snapped(_ v: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        return range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
    }
}

/// Pitch popover, built like the speed one: transpose in semitones with − / +,
/// and a tick ruler for fine tuning in cents.
struct PitchPopover: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        TwoPartPopover { transposePage } second: { fineTunePage }
    }

    private var transposePage: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                stepButton("minus", label: "Down a semitone", enabled: player.semitones > -12) {
                    player.semitones -= 1
                }
                VStack(spacing: 2) {
                    Text(player.displayKey?.name ?? signed(player.semitones))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Text(player.semitones == 0 ? "Original key"
                         : signed(player.semitones) + (abs(player.semitones) == 1 ? " semitone" : " semitones"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 130)
                stepButton("plus", label: "Up a semitone", enabled: player.semitones < 12) {
                    player.semitones += 1
                }
            }
            #if os(iOS)
            caption("Swipe for fine tuning", reset: player.semitones == 0 ? nil : { player.semitones = 0 })
            #else
            caption("Transpose", reset: player.semitones == 0 ? nil : { player.semitones = 0 })
            #endif
        }
    }

    private var fineTunePage: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Text("♭").font(.title2)
                TickRuler(value: Binding(get: { Double(player.cents) }, set: { player.cents = Int($0) }),
                          range: -50...50, step: 1, tickInterval: 5)
                    .accessibilityLabel("Fine tuning in cents")
                Text("♯").font(.title2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            caption("Fine tuning " + (player.cents == 0 ? "0" : signed(player.cents)) + " ¢",
                    reset: player.cents == 0 ? nil : { player.cents = 0 })
        }
    }

    /// Gray caption line, with a Reset button next to it once something is changed.
    private func caption(_ text: String, reset: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let reset {
                Button("Reset", action: reset)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
        }
    }

    private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.secondary.opacity(0.18)))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
