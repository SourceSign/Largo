import SwiftUI
import LargoCore

/// Maps between song time and horizontal position for a window onto the song.
struct TimelineMapping {
    var start: Double
    var visible: Double
    var width: CGFloat

    /// A window of `visible` seconds with `time` in the center.
    static func centered(on time: Double, visible: Double, width: CGFloat) -> TimelineMapping {
        TimelineMapping(start: time - visible / 2, visible: visible, width: width)
    }

    var end: Double { start + visible }
    func x(_ time: Double) -> CGFloat { CGFloat((time - start) / visible) * width }
    func time(_ x: CGFloat) -> Double { start + Double(x / max(width, 1)) * visible }
}

/// Scrolling waveform and chord lane. The playhead stays centered and the song moves past it.
/// Click to seek, pinch to zoom. Loops work like Capo's regions: drag on the waveform to
/// create one, drag an edge to resize it, drag inside it to move it.
struct ScrollingTimelineView: View {
    @ObservedObject var player: AudioPlayer
    @State private var pinchBase: Double?

    /// What the current drag on the waveform does; decided where the drag starts.
    private enum LoopDrag {
        case newLoop(anchor: Double)
        case resizeStart(fixedEnd: Double)
        case resizeEnd(fixedStart: Double)
        case move(start: Double, end: Double, grabbedAt: Double)
    }
    @State private var drag: LoopDrag?
    /// The loop as it's being dragged; written to the player when the drag ends.
    @State private var draftLoop: (start: Double, end: Double)?
    @State private var dragMoved = false
    @State private var dragStartX: CGFloat?

    /// How close (in points) to a loop edge counts as grabbing it.
    #if os(macOS)
    private let edgeTolerance: CGFloat = 6
    #else
    private let edgeTolerance: CGFloat = 16
    #endif
    private let minimumLoopLength = 0.1

    var body: some View {
        // Redraw every display frame while playing so scrolling is smooth.
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            GeometryReader { geo in
                let now = player.isPlaying ? player.currentPosition() : player.currentTime
                let map = TimelineMapping.centered(on: now, visible: player.visibleSeconds, width: geo.size.width)
                VStack(spacing: 4) {
                    waveform(map: map, now: now)
                        .frame(maxHeight: .infinity)
                    ChordLaneView(player: player, map: map, now: now)
                }
            }
        }
        .gesture(MagnifyGesture()
            .onChanged { g in
                if pinchBase == nil { pinchBase = player.visibleSeconds }
                let v = pinchBase! / g.magnification
                player.visibleSeconds = min(max(v, AudioPlayer.zoomRange.lowerBound), AudioPlayer.zoomRange.upperBound)
            }
            .onEnded { _ in pinchBase = nil })
    }

    private func waveform(map: TimelineMapping, now: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                drawLoopRegion(ctx: ctx, size: size, map: map) // behind, so it doesn't tint the waveform
                drawBeatGrid(ctx: ctx, size: size, map: map)
                drawWaveform(ctx: ctx, size: size, map: map, now: now)
                drawLoopFrame(ctx: ctx, size: size, map: map)
                // Fixed playhead in the center
                let px = map.x(now)
                ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.primary))
            }
            if let a = player.loopStart, let b = player.loopEnd, draftLoop == nil {
                // Long press (right-click on the Mac) on the loop for its menu.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(1, map.x(b) - map.x(a)))
                    .frame(maxHeight: .infinity)
                    .offset(x: map.x(a))
                    .contextMenu { loopMenu } preview: { loopPreview(start: a, end: b) }
                    .accessibilityElement()
                    .accessibilityLabel("Loop")
                    .accessibilityActions { loopMenu }
            }
            if let (a, b) = displayedLoop, map.x(b) - map.x(a) >= 54 { // only when the label fits
                loopLabel
                    .position(x: (map.x(a) + map.x(b)) / 2, y: 18)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    // A new touch. (A long press that opens the loop menu cancels the gesture
                    // without onEnded, so don't rely on the previous one having been cleaned up.)
                    if drag == nil || dragStartX != g.startLocation.x {
                        drag = beginDrag(at: g.startLocation.x, map: map)
                        dragStartX = g.startLocation.x
                        draftLoop = nil
                        dragMoved = false
                    }
                    guard dragMoved || abs(g.translation.width) > 3 else { return }
                    dragMoved = true
                    updateDraft(to: clamp(map.time(g.location.x)))
                }
                .onEnded { g in
                    if dragMoved, let loop = draftLoop {
                        player.setLoop(start: loop.start, end: loop.end)
                        if case .newLoop = drag { player.seek(to: loop.start) }
                    } else {
                        player.seek(to: clamp(map.time(g.location.x))) // plain click
                    }
                    drag = nil
                    dragStartX = nil
                    draftLoop = nil
                    dragMoved = false
                }
        )
        #if os(macOS)
        .onContinuousHover { phase in
            // Show a resize cursor over loop edges.
            if case .active(let point) = phase, loopEdge(near: point.x, map: map) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        #endif
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.waveformBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .overlay {
            if player.fileURL != nil && player.waveform.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func clamp(_ t: Double) -> Double { min(max(0, t), player.duration) }

    // MARK: Loop editing

    private enum Edge { case start, end }

    /// The existing loop's edge under `x`, if any (the closer one when the loop is very narrow).
    private func loopEdge(near x: CGFloat, map: TimelineMapping) -> Edge? {
        guard let a = player.loopStart, let b = player.loopEnd else { return nil }
        let da = abs(x - map.x(a)), db = abs(x - map.x(b))
        guard min(da, db) <= edgeTolerance else { return nil }
        return da <= db ? .start : .end
    }

    private func beginDrag(at x: CGFloat, map: TimelineMapping) -> LoopDrag {
        let t = clamp(map.time(x))
        if let a = player.loopStart, let b = player.loopEnd {
            switch loopEdge(near: x, map: map) {
            case .start: return .resizeStart(fixedEnd: b)
            case .end: return .resizeEnd(fixedStart: a)
            case nil: if t > a && t < b { return .move(start: a, end: b, grabbedAt: t) }
            }
        }
        return .newLoop(anchor: t)
    }

    private func updateDraft(to t: Double) {
        switch drag {
        case .newLoop(let anchor):
            draftLoop = (min(anchor, t), max(anchor, t))
        case .resizeStart(let end):
            draftLoop = (min(t, end - minimumLoopLength), end)
        case .resizeEnd(let start):
            draftLoop = (start, max(t, start + minimumLoopLength))
        case .move(let start, let end, let grabbedAt):
            let length = end - start
            let newStart = min(max(0, start + t - grabbedAt), player.duration - length)
            draftLoop = (newStart, newStart + length)
        case nil:
            break
        }
    }

    private func drawWaveform(ctx: GraphicsContext, size: CGSize, map: TimelineMapping, now: Double) {
        guard !player.waveform.isEmpty, player.duration > 0 else { return }
        let shape = WaveformShape.path(peaks: player.waveform, duration: player.duration, map: map,
                                       height: size.height, inset: 4)
        // One shape, filled twice: light gray left of the playhead, the play button's color to the right.
        // Opaque base first so grid lines don't show through the translucent grays.
        ctx.fill(shape, with: .color(Color.waveformBackground))
        let playheadX = map.x(now)
        var played = ctx
        played.clip(to: Path(CGRect(x: 0, y: 0, width: max(0, playheadX), height: size.height)))
        played.fill(shape, with: .color(.secondary.opacity(0.3)))
        var unplayed = ctx
        unplayed.clip(to: Path(CGRect(x: playheadX, y: 0, width: max(0, size.width - playheadX), height: size.height)))
        unplayed.fill(shape, with: .color(.transport))
    }

    /// Faint beat lines, stronger bar lines, and bar numbers along the bottom.
    private func drawBeatGrid(ctx: GraphicsContext, size: CGSize, map: TimelineMapping) {
        guard let grid = player.beatGrid, let first = grid.beatIndex(at: map.start) ?? (grid.beats.isEmpty ? nil : 0)
        else { return }
        let beatWidth = map.x(60 / grid.bpm) - map.x(0)
        let barWidth = beatWidth * CGFloat(grid.beatsPerBar)
        // When zoomed out, label only every 2nd/4th/8th... bar so numbers don't overlap.
        var labelEvery = 1
        while barWidth * CGFloat(labelEvery) < 28 { labelEvery *= 2 }

        var beatLines = Path(), barLines = Path()
        var i = first
        while i < grid.beats.count, grid.beats[i] <= map.end {
            let x = map.x(grid.beats[i])
            if grid.isDownbeat(i) {
                barLines.addRect(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height))
                let bar = grid.position(ofBeat: i).bar
                if (bar - 1) % labelEvery == 0 {
                    let text = ctx.resolve(Text("\(bar)").font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary))
                    ctx.draw(text, at: CGPoint(x: x + 3, y: size.height - 3), anchor: .bottomLeading)
                }
            } else if beatWidth >= 6 {
                beatLines.addRect(CGRect(x: x - 0.25, y: 0, width: 0.5, height: size.height))
            }
            i += 1
        }
        ctx.fill(beatLines, with: .color(.secondary.opacity(0.18)))
        ctx.fill(barLines, with: .color(.secondary.opacity(0.5)))
    }

    /// The loop being dragged, or else the saved loop.
    private var displayedLoop: (Double, Double)? {
        if let draft = draftLoop { return (draft.start, draft.end) }
        if let a = player.loopStart, let b = player.loopEnd { return (a, b) }
        return nil
    }

    /// Strong while looping or being edited, faint when the loop is switched off.
    private var loopIsActive: Bool { player.loopEnabled || draftLoop != nil }

    private func drawLoopRegion(ctx: GraphicsContext, size: CGSize, map: TimelineMapping) {
        guard let (a, b) = displayedLoop else { return }
        ctx.fill(Path(CGRect(x: map.x(a), y: 0, width: max(1, map.x(b) - map.x(a)), height: size.height)),
                 with: .color(.brand.opacity(loopIsActive ? 0.16 : 0.06)))
    }

    /// Outline plus a "Loop" label at the top, drawn over the waveform.
    private func drawLoopFrame(ctx: GraphicsContext, size: CGSize, map: TimelineMapping) {
        guard let (a, b) = displayedLoop else { return }
        let rect = CGRect(x: map.x(a), y: 0, width: max(1, map.x(b) - map.x(a)), height: size.height)
        ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                   with: .color(.brand.opacity(loopIsActive ? 0.8 : 0.35)), lineWidth: 1)
    }

    /// "Loop" label at the top of the region. Taps go through, so dragging on it moves the loop.
    private var loopLabel: some View {
        Text("Loop")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.brand.opacity(loopIsActive ? 1 : 0.45)))
            .allowsHitTesting(false)
    }

    /// Menu for a long press (right-click on the Mac) on the loop.
    @ViewBuilder
    private var loopMenu: some View {
        Button(player.loopEnabled ? "Turn Loop Off" : "Turn Loop On",
               systemImage: player.loopEnabled ? "repeat.circle" : "repeat") {
            player.loopEnabled.toggle()
        }
        Button("Clear Loop", systemImage: "trash", role: .destructive) {
            player.clearLoop()
        }
    }

    /// Shown above the menu on iPhone/iPad while long-pressing.
    private func loopPreview(start: Double, end: Double) -> some View {
        Text("Loop  \(clock(start)) – \(clock(end))")
            .font(.headline)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.brand)
    }
}

/// Thin full-song waveform with the visible window outlined. Click or drag to jump.
struct OverviewView: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        GeometryReader { geo in
            let full = TimelineMapping(start: 0, visible: max(player.duration, 0.001), width: geo.size.width)
            Canvas { ctx, size in
                if !player.waveform.isEmpty {
                    let shape = WaveformShape.path(peaks: player.waveform, duration: player.duration, map: full,
                                                   height: size.height, inset: 1)
                    ctx.fill(shape, with: .color(.secondary.opacity(0.5)))
                }
                if let a = player.loopStart, let b = player.loopEnd {
                    ctx.fill(Path(CGRect(x: full.x(a), y: 0, width: max(1, full.x(b) - full.x(a)), height: size.height)),
                             with: .color(.brand.opacity(player.loopEnabled ? 0.25 : 0.1)))
                }
                // Visible window
                let half = player.visibleSeconds / 2
                let wx0 = full.x(player.currentTime - half), wx1 = full.x(player.currentTime + half)
                ctx.stroke(Path(roundedRect: CGRect(x: wx0, y: 0.5, width: wx1 - wx0, height: size.height - 1), cornerRadius: 3),
                           with: .color(.brand), lineWidth: 1)
                ctx.fill(Path(CGRect(x: full.x(player.currentTime) - 0.5, y: 0, width: 1, height: size.height)),
                         with: .color(.primary))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                player.seek(to: min(max(0, full.time(g.location.x)), player.duration))
            })
        }
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Builds a smooth, mirrored waveform outline.
enum WaveformShape {
    /// Pixels between outline points; curves fill in between.
    static let step: CGFloat = 1

    /// `peaks` cover the whole song evenly. Samples are taken on a grid fixed to song time
    /// (not to the screen), so the shape doesn't shimmer while it scrolls.
    static func path(peaks: [Float], duration: Double, map: TimelineMapping,
                     height: CGFloat, inset: CGFloat) -> Path {
        let perSecond = Double(peaks.count) / duration
        let secondsPerSample = map.visible / Double(max(map.width, 1)) * Double(step)
        let first = max(0, Int(floor(map.start / secondsPerSample)) - 3)
        let last = min(Int(ceil(duration / secondsPerSample)),
                       Int(ceil(map.end / secondsPerSample)) + 3)
        guard first < last else { return Path() }

        var xs: [CGFloat] = []
        var amps: [CGFloat] = []
        for k in first...last {
            let t0 = Double(k) * secondsPerSample
            let lo = min(peaks.count - 1, Int(t0 * perSecond))
            let hi = min(peaks.count, max(lo + 1, Int((t0 + secondsPerSample) * perSecond)))
            var p: Float = 0
            for i in lo..<hi { p = max(p, peaks[i]) }
            xs.append(map.x(min(t0, duration)))
            amps.append(CGFloat(p))
        }
        amps = smoothed(amps)
        amps[0] = 0                      // close the shape at the song start
        if last == Int(ceil(duration / secondsPerSample)) { amps[amps.count - 1] = 0 } // and end

        let mid = height / 2
        let scale = height / 2 - inset
        let top = zip(xs, amps).map { CGPoint(x: $0, y: mid - max(0.5, $1 * scale)) }
        let bottom = zip(xs, amps).map { CGPoint(x: $0, y: mid + max(0.5, $1 * scale)) }.reversed()

        var path = Path()
        path.move(to: top[0])
        addCurve(through: top, to: &path)
        path.addLine(to: bottom.first!)
        addCurve(through: Array(bottom), to: &path)
        path.closeSubpath()
        return path
    }

    /// Quadratic curves through the midpoints between samples, which gives a smooth line
    /// that never overshoots the sample values.
    private static func addCurve(through points: [CGPoint], to path: inout Path) {
        guard points.count > 1 else { return }
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
    }

    /// Light [1 2 3 2 1] blur that softens spikes but keeps the beat shape.
    private static func smoothed(_ v: [CGFloat]) -> [CGFloat] {
        let kernel: [CGFloat] = [1, 2, 3, 2, 1]
        return v.indices.map { i in
            var sum: CGFloat = 0, weight: CGFloat = 0
            for (j, k) in kernel.enumerated() {
                let idx = i + j - 2
                if idx >= 0 && idx < v.count { sum += v[idx] * k; weight += k }
            }
            // Blend with the raw peak so loud hits stay visible.
            return max(sum / weight, v[i] * 1)
        }
    }
}
