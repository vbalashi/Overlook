import AppKit
import Foundation

struct IconImage {
    let filename: String
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appendingPathComponent("Overlook/Assets.xcassets/AppIcon.appiconset")

let images = [
    IconImage(filename: "app-icon-16.png", points: 16, scale: 1),
    IconImage(filename: "app-icon-16@2x.png", points: 16, scale: 2),
    IconImage(filename: "app-icon-32.png", points: 32, scale: 1),
    IconImage(filename: "app-icon-32@2x.png", points: 32, scale: 2),
    IconImage(filename: "app-icon-128.png", points: 128, scale: 1),
    IconImage(filename: "app-icon-128@2x.png", points: 128, scale: 2),
    IconImage(filename: "app-icon-256.png", points: 256, scale: 1),
    IconImage(filename: "app-icon-256@2x.png", points: 256, scale: 2),
    IconImage(filename: "app-icon-512.png", points: 512, scale: 1),
    IconImage(filename: "app-icon-512@2x.png", points: 512, scale: 2),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func drawRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawStroke(_ rect: CGRect, radius: CGFloat, color: NSColor, width: CGFloat) {
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

func drawLinkGlyph(in rect: CGRect, lineWidth: CGFloat) {
    let left = NSBezierPath()
    left.lineWidth = lineWidth
    left.lineCapStyle = .round
    left.move(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.midY))
    left.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.midY),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.maxY)
    )
    left.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.midY),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.minY)
    )

    let right = NSBezierPath()
    right.lineWidth = lineWidth
    right.lineCapStyle = .round
    right.move(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.midY))
    right.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.midY),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.64, y: rect.maxY),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.maxY)
    )
    right.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.midY),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.64, y: rect.minY)
    )

    color(236, 248, 255).setStroke()
    left.stroke()
    right.stroke()

    let bridge = NSBezierPath()
    bridge.lineWidth = lineWidth * 0.78
    bridge.lineCapStyle = .round
    bridge.move(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.midY))
    bridge.line(to: CGPoint(x: rect.minX + rect.width * 0.64, y: rect.midY))
    bridge.stroke()
}

func drawIcon(size: Int) throws -> NSBitmapImageRep {
    let dimension = CGFloat(size)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "OverlookIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create \(size)x\(size) bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    let canvas = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    NSColor.clear.setFill()
    canvas.fill()

    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: dimension * 0.055, dy: dimension * 0.055), xRadius: dimension * 0.215, yRadius: dimension * 0.215)
    let backgroundGradient = NSGradient(colors: [
        color(25, 31, 37),
        color(43, 50, 55),
        color(17, 21, 26)
    ])!
    backgroundGradient.draw(in: background, angle: -35)

    let screen = canvas.insetBy(dx: dimension * 0.16, dy: dimension * 0.19)
    drawRoundedRect(screen, radius: dimension * 0.09, color: color(7, 10, 14))

    let glow = NSBezierPath(roundedRect: screen.insetBy(dx: -dimension * 0.012, dy: -dimension * 0.012), xRadius: dimension * 0.105, yRadius: dimension * 0.105)
    color(36, 211, 238, 0.30).setStroke()
    glow.lineWidth = max(1, dimension * 0.024)
    glow.stroke()

    let video = screen.insetBy(dx: dimension * 0.055, dy: dimension * 0.060)
    let videoPath = NSBezierPath(roundedRect: video, xRadius: dimension * 0.055, yRadius: dimension * 0.055)
    let videoGradient = NSGradient(colors: [
        color(57, 224, 237),
        color(35, 129, 225),
        color(78, 71, 210)
    ])!
    videoGradient.draw(in: videoPath, angle: 30)

    let horizon = NSBezierPath()
    horizon.move(to: CGPoint(x: video.minX + video.width * 0.08, y: video.midY - video.height * 0.06))
    horizon.curve(
        to: CGPoint(x: video.maxX - video.width * 0.10, y: video.midY + video.height * 0.08),
        controlPoint1: CGPoint(x: video.minX + video.width * 0.30, y: video.midY + video.height * 0.11),
        controlPoint2: CGPoint(x: video.minX + video.width * 0.65, y: video.midY - video.height * 0.12)
    )
    horizon.lineWidth = max(1, dimension * 0.018)
    color(241, 253, 255, 0.36).setStroke()
    horizon.stroke()

    for xFactor in [0.26, 0.50, 0.74] {
        let line = NSBezierPath()
        line.lineWidth = max(1, dimension * 0.007)
        line.move(to: CGPoint(x: video.minX + video.width * xFactor, y: video.minY + video.height * 0.12))
        line.line(to: CGPoint(x: video.minX + video.width * xFactor, y: video.maxY - video.height * 0.12))
        color(255, 255, 255, 0.14).setStroke()
        line.stroke()
    }

    let dock = CGRect(x: dimension * 0.34, y: dimension * 0.117, width: dimension * 0.32, height: dimension * 0.055)
    drawRoundedRect(dock, radius: dimension * 0.025, color: color(10, 13, 16, 0.94))

    let badge = CGRect(x: dimension * 0.56, y: dimension * 0.56, width: dimension * 0.28, height: dimension * 0.22)
    drawRoundedRect(badge, radius: dimension * 0.06, color: color(15, 21, 26, 0.84))
    drawStroke(badge, radius: dimension * 0.06, color: color(194, 244, 255, 0.45), width: max(1, dimension * 0.010))
    drawLinkGlyph(in: badge.insetBy(dx: dimension * 0.045, dy: dimension * 0.055), lineWidth: max(1.2, dimension * 0.018))

    let shine = NSBezierPath(roundedRect: screen.insetBy(dx: dimension * 0.015, dy: dimension * 0.015), xRadius: dimension * 0.08, yRadius: dimension * 0.08)
    color(255, 255, 255, 0.12).setStroke()
    shine.lineWidth = max(1, dimension * 0.012)
    shine.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for icon in images {
    let bitmap = try drawIcon(size: icon.pixels)
    guard let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "OverlookIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render \(icon.filename)"])
    }

    try png.write(to: outputDirectory.appendingPathComponent(icon.filename))
}

let contents: [String: Any] = [
    "images": images.map { icon in
        [
            "idiom": "mac",
            "size": "\(icon.points)x\(icon.points)",
            "scale": "\(icon.scale)x",
            "filename": icon.filename
        ]
    },
    "info": [
        "author": "xcode",
        "version": 1
    ]
]

var json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
json.append(0x0A)
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))

print("Wrote \(images.count) app icon images to \(outputDirectory.path)")
