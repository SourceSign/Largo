import SwiftUI
import LargoCore

/// Detected chords on the same scrolling window as the waveform above it.
/// Click a chord to jump to its start.
struct ChordLaneView: View {
    @ObservedObject var player: AudioPlayer
    let map: TimelineMapping
    let now: Double

    var body: some View {
        ZStack {
            if let analysis = player.chordAnalysis {
                let current = analysis.segmentIndex(at: now)
                Canvas { ctx, size in
                    for (i, seg) in analysis.segments.enumerated()
                    where seg.end > map.start && seg.start < map.end {
                        let x0 = map.x(seg.start)
                        let x1 = map.x(seg.end)
                        let rect = CGRect(x: x0 + 0.5, y: 0, width: max(1, x1 - x0 - 1), height: size.height)
                        let isCurrent = i == current
                        let isNone = seg.chord.root == nil
                        let fill: Color = isCurrent ? .brand
                            : isNone ? .secondary.opacity(0.06)
                            : (i.isMultiple(of: 2) ? Color.secondary.opacity(0.16) : Color.secondary.opacity(0.24))
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill))

                        let label = player.displayName(of: seg.chord)
                        let text = ctx.resolve(Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isCurrent ? Color.white : (isNone ? Color.secondary : Color.primary)))
                        let textSize = text.measure(in: CGSize(width: 200, height: size.height))
                        if textSize.width + 6 <= rect.width {
                            // Keep the label visible while the chord's start has scrolled off the left edge.
                            let lx = min(max(rect.minX + 4, 4), rect.maxX - textSize.width - 4)
                            ctx.draw(text, at: CGPoint(x: lx, y: rect.midY), anchor: .leading)
                        }
                    }
                    // Bar lines, continuing the grid from the waveform above.
                    if let grid = player.beatGrid {
                        var bars = Path()
                        var i = grid.beatIndex(at: map.start) ?? 0
                        while i < grid.beats.count, grid.beats[i] <= map.end {
                            if grid.isDownbeat(i) {
                                bars.addRect(CGRect(x: map.x(grid.beats[i]) - 0.5, y: 0, width: 1, height: size.height))
                            }
                            i += 1
                        }
                        ctx.fill(bars, with: .color(.secondary.opacity(0.45)))
                    }
                    // Playhead
                    ctx.fill(Path(CGRect(x: map.x(now) - 0.75, y: 0, width: 1.5, height: size.height)),
                             with: .color(.primary.opacity(0.5)))
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if let i = analysis.segmentIndex(at: map.time(location.x)) {
                        player.seek(to: analysis.segments[i].start)
                    }
                }
            } else if let progress = player.analysisProgress {
                HStack(spacing: 8) {
                    Text("Detecting chords and beats…").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: progress).frame(width: 140)
                }
            } else if player.fileURL != nil {
                Text("Chord detection unavailable for this file")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .clipped()
    }
}
