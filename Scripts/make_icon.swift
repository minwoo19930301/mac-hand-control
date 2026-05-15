import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

private func point(_ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> CGPoint {
    CGPoint(x: x * scale, y: y * scale)
}

private func drawLine(_ joints: [CGPoint], width: CGFloat, color: NSColor) {
    guard let first = joints.first else { return }

    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: first)

    for joint in joints.dropFirst() {
        path.line(to: joint)
    }

    color.setStroke()
    path.stroke()
}

private func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: CGSize(width: size, height: size))
    image.lockFocus()

    let scale = size / 1024
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let backgroundRect = canvas.insetBy(dx: 62 * scale, dy: 62 * scale)
    let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 230 * scale, yRadius: 230 * scale)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 34 * scale
    shadow.shadowOffset = CGSize(width: 0, height: -18 * scale)
    shadow.set()

    NSColor(calibratedRed: 0.78, green: 0.9, blue: 0.93, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.9, green: 0.98, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.45, green: 0.77, blue: 0.86, alpha: 1)
    ])
    gradient?.draw(in: background, angle: -35)

    NSGraphicsContext.saveGraphicsState()
    background.addClip()

    NSColor.white.withAlphaComponent(0.25).setStroke()
    for x in stride(from: 162, through: 862, by: 140) {
        drawLine(
            [point(CGFloat(x), 112, scale: scale), point(CGFloat(x) + 78, 912, scale: scale)],
            width: 3 * scale,
            color: NSColor.white.withAlphaComponent(0.2)
        )
    }
    for y in stride(from: 190, through: 830, by: 128) {
        drawLine(
            [point(110, CGFloat(y), scale: scale), point(914, CGFloat(y) + 28, scale: scale)],
            width: 3 * scale,
            color: NSColor.white.withAlphaComponent(0.16)
        )
    }

    let glass = NSBezierPath(roundedRect: backgroundRect.insetBy(dx: 30 * scale, dy: 30 * scale), xRadius: 195 * scale, yRadius: 195 * scale)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    glass.lineWidth = 10 * scale
    glass.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let wrist = point(407, 215, scale: scale)
    let thumbCMC = point(485, 318, scale: scale)
    let thumbMP = point(563, 397, scale: scale)
    let thumbIP = point(633, 468, scale: scale)
    let thumbTip = point(694, 544, scale: scale)
    let indexMCP = point(478, 506, scale: scale)
    let indexPIP = point(566, 618, scale: scale)
    let indexDIP = point(650, 620, scale: scale)
    let indexTip = point(726, 578, scale: scale)
    let middleMCP = point(393, 520, scale: scale)
    let middlePIP = point(402, 646, scale: scale)
    let middleDIP = point(418, 744, scale: scale)
    let middleTip = point(450, 850, scale: scale)
    let ringMCP = point(316, 492, scale: scale)
    let ringPIP = point(287, 614, scale: scale)
    let ringDIP = point(265, 714, scale: scale)
    let ringTip = point(236, 810, scale: scale)
    let littleMCP = point(260, 438, scale: scale)
    let littlePIP = point(193, 526, scale: scale)
    let littleDIP = point(154, 614, scale: scale)
    let littleTip = point(111, 704, scale: scale)

    let boneColor = NSColor(calibratedRed: 0.02, green: 0.78, blue: 0.95, alpha: 1)
    let boneShadow = NSShadow()
    boneShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    boneShadow.shadowBlurRadius = 18 * scale
    boneShadow.shadowOffset = CGSize(width: 0, height: -6 * scale)
    boneShadow.set()

    let chains = [
        [wrist, thumbCMC, thumbMP, thumbIP, thumbTip],
        [wrist, indexMCP, indexPIP, indexDIP, indexTip],
        [wrist, middleMCP, middlePIP, middleDIP, middleTip],
        [wrist, ringMCP, ringPIP, ringDIP, ringTip],
        [wrist, littleMCP, littlePIP, littleDIP, littleTip],
        [indexMCP, middleMCP, ringMCP, littleMCP]
    ]

    for chain in chains {
        drawLine(chain, width: 34 * scale, color: boneColor)
    }

    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0)

    let joints = [
        wrist, thumbCMC, thumbMP, thumbIP, thumbTip,
        indexMCP, indexPIP, indexDIP, indexTip,
        middleMCP, middlePIP, middleDIP, middleTip,
        ringMCP, ringPIP, ringDIP, ringTip,
        littleMCP, littlePIP, littleDIP, littleTip
    ]

    for joint in joints {
        let dot = NSBezierPath(ovalIn: NSRect(x: joint.x - 24 * scale, y: joint.y - 24 * scale, width: 48 * scale, height: 48 * scale))
        NSColor.white.setFill()
        dot.fill()
        NSColor.black.withAlphaComponent(0.09).setStroke()
        dot.lineWidth = 3 * scale
        dot.stroke()
    }

    let pinchMid = CGPoint(x: (thumbTip.x + indexTip.x) / 2, y: (thumbTip.y + indexTip.y) / 2)
    let halo = NSBezierPath(ovalIn: NSRect(x: pinchMid.x - 74 * scale, y: pinchMid.y - 74 * scale, width: 148 * scale, height: 148 * scale))
    NSColor.systemYellow.withAlphaComponent(0.28).setFill()
    halo.fill()

    drawLine([thumbTip, indexTip], width: 24 * scale, color: NSColor.systemYellow)
    for tip in [thumbTip, indexTip] {
        let dot = NSBezierPath(ovalIn: NSRect(x: tip.x - 21 * scale, y: tip.y - 21 * scale, width: 42 * scale, height: 42 * scale))
        NSColor.systemYellow.setFill()
        dot.fill()
        NSColor.white.setStroke()
        dot.lineWidth = 7 * scale
        dot.stroke()
    }

    image.unlockFocus()
    return image
}

private func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
    let output = NSImage(size: CGSize(width: size, height: size))
    output.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    output.unlockFocus()
    return output
}

private func writePNG(_ image: NSImage, to url: URL) throws {
    let width = Int(image.size.width.rounded())
    let height = Int(image.size.height.rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "MacHandControlIcon", code: 1)
    }

    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MacHandControlIcon", code: 2)
    }

    try data.write(to: url, options: .atomic)
}

let base = makeIcon(size: 1024)
let entries: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in entries {
    try writePNG(resized(base, to: size), to: iconset.appendingPathComponent(name))
}
