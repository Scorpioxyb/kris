import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let output = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let sourceURL = root.appendingPathComponent("Resources/Brand/krislogo1.png")

guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Unable to load krislogo1.png")
}

struct Variant {
    let filename: String
    let pixels: Int
}

let variants = [
    Variant(filename: "AppIcon.png", pixels: 1024),
    Variant(filename: "AppIcon-Dark.png", pixels: 1024),
    Variant(filename: "AppIcon-Tinted.png", pixels: 1024),
] + [48, 55, 58, 80, 87, 88, 92, 100, 102, 108, 172, 196, 216, 234, 258].map {
    Variant(filename: "AppIcon-Watch-\($0).png", pixels: $0)
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.pixels
    let size = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Unable to create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to render \(variant.filename)")
    }
    try data.write(to: output.appendingPathComponent(variant.filename), options: .atomic)
}

print("Generated \(variants.count) Kris app icons from krislogo1.png")
