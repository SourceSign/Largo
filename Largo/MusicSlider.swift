import SwiftUI

/// A slider in the style of the Apple Music player: a thin capsule without a knob
/// that thickens while dragged. Dragging moves the value by how far you drag
/// (it doesn't jump to where you touch), and the optional end icons react to the drag.
struct MusicSlider<Leading: View, Trailing: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    /// Spoken by VoiceOver.
    var accessibilityText: String = ""
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var dragStartValue: Double?
    private var isDragging: Bool { dragStartValue != nil }

    var body: some View {
        HStack(spacing: 10) {
            leading()
                .foregroundStyle(.secondary)
                .scaleEffect(isDragging && fraction < 0.05 ? 1.2 : 1)
            GeometryReader { geo in
                let width = geo.size.width
                let height: CGFloat = isDragging ? 12 : 7
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(isDragging ? 0.2 : 0.14))
                    Capsule()
                        .fill(Color.primary.opacity(isDragging ? 0.85 : 0.6))
                        .frame(width: max(height, width * fraction))
                }
                .frame(height: height)
                .frame(maxHeight: .infinity) // vertically centered in a taller hit area
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragStartValue == nil { dragStartValue = value }
                            let delta = Double(g.translation.width / max(width, 1)) * span
                            value = snapped(dragStartValue! + delta)
                        }
                        .onEnded { _ in dragStartValue = nil }
                )
            }
            .frame(height: 28)
            trailing()
                .foregroundStyle(.secondary)
                .scaleEffect(isDragging && fraction > 0.95 ? 1.2 : 1)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            let delta = step ?? span / 20
            switch direction {
            case .increment: value = snapped(value + delta)
            case .decrement: value = snapped(value - delta)
            @unknown default: break
            }
        }
    }

    private var span: Double { range.upperBound - range.lowerBound }
    private var fraction: CGFloat { CGFloat((value - range.lowerBound) / span) }

    private func snapped(_ v: Double) -> Double {
        var v = min(max(v, range.lowerBound), range.upperBound)
        if let step { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
        return v
    }
}

extension MusicSlider where Leading == EmptyView, Trailing == EmptyView {
    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, accessibilityText: String = "") {
        self.init(value: value, range: range, step: step, accessibilityText: accessibilityText,
                  leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

#Preview("Music slider") {
    @Previewable @State var speed = 1.0
    @Previewable @State var fine = 0.0
    VStack(spacing: 24) {
        MusicSlider(value: $speed, range: 0.25...2, step: 0.05, accessibilityText: "Speed") {
            Image(systemName: "tortoise.fill")
        } trailing: {
            Image(systemName: "hare.fill")
        }
        MusicSlider(value: $fine, in: -50...50, step: 1)
    }
    .padding()
    .frame(width: 360)
}
