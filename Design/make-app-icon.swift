// Draws Largo's app icon and writes every size into the asset catalog.
//
//   swift Design/make-app-icon.swift
//
// iOS gets the full square (the system rounds the corners); the Mac gets Apple's icon grid:
// an 824 px rounded square with a soft shadow, centered on a 1024 px canvas.
import AppKit

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let red = CGColor(srgbRed: 250 / 255, green: 45 / 255, blue: 72 / 255, alpha: 1)      // #FA2D48, the app's accent
let redTop = CGColor(srgbRed: 1, green: 92 / 255, blue: 112 / 255, alpha: 1)           // lighter at the top
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let whiteFaded = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)                   // not yet played

/// Waveform bars as (center x, height) on a 1024 canvas; the playhead sits at `playheadX`.
let bars: [(x: CGFloat, h: CGFloat)] = [
    (211, 123), (279, 259), (348, 423), (416, 232), (484, 478),   // played
    (607, 314), (676, 178), (744, 369), (812, 150),               // still to come
]
let barWidth: CGFloat = 41
let playheadX: CGFloat = 546

func drawArtwork(in ctx: CGContext) {
    // Background: subtle top-to-bottom red gradient.
    let gradient = CGGradient(colorsSpace: space, colors: [redTop, red] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: .zero, options: [])

    let mid = CGFloat(size) / 2
    for bar in bars {
        let rect = CGRect(x: bar.x - barWidth / 2, y: mid - bar.h / 2, width: barWidth, height: bar.h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(bar.x < playheadX ? white : whiteFaded)
        ctx.fillPath()
    }

    // Playhead: a line with a small triangle on top (y grows upward in Core Graphics).
    ctx.setStrokeColor(white)
    ctx.setLineWidth(27)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: playheadX, y: mid - 287))
    ctx.addLine(to: CGPoint(x: playheadX, y: mid + 270))
    ctx.strokePath()
    ctx.setFillColor(white)
    ctx.move(to: CGPoint(x: playheadX - 58, y: mid + 307))
    ctx.addLine(to: CGPoint(x: playheadX + 58, y: mid + 307))
    ctx.addLine(to: CGPoint(x: playheadX, y: mid + 239))
    ctx.closePath()
    ctx.fillPath()
}

func context(opaque: Bool) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
}

func write(_ image: CGImage, pixels: Int, to url: URL) {
    let small = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: (image.alphaInfo == .noneSkipLast ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    small.interpolationQuality = .high
    small.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let rep = NSBitmapImageRep(cgImage: small.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// iOS: full square, no transparency (App Store requirement).
let ios = context(opaque: true)
drawArtwork(in: ios)
let iosImage = ios.makeImage()!

// macOS: rounded square on Apple's grid, with a soft shadow.
let mac = context(opaque: false)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
mac.saveGState()
mac.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.3))
mac.addPath(shape); mac.setFillColor(red); mac.fillPath()
mac.restoreGState()
mac.addPath(shape); mac.clip()
mac.draw(iosImage, in: body)
let macImage = mac.makeImage()!

let script = URL(fileURLWithPath: #filePath)
let iconSet = script.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Largo/Assets.xcassets/AppIcon.appiconset")
write(iosImage, pixels: 1024, to: iconSet.appendingPathComponent("icon-ios-1024.png"))
for px in [16, 32, 64, 128, 256, 512, 1024] {
    write(macImage, pixels: px, to: iconSet.appendingPathComponent("icon-mac-\(px).png"))
}
print("Wrote icons to \(iconSet.path)")
