import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let sourceURL = resources.appendingPathComponent("AppIconSource.png")
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)

guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Missing icon source: \(sourceURL.path)")
}

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

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
    try writePNG(resized(source, to: size), to: iconset.appendingPathComponent(name))
}
