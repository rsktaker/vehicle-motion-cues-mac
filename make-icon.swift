// Draws the app icon (cue dots on a dark tile) and writes AppIcon.icns.
// Run: swift make-icon.swift
import AppKit

let size = 1024.0
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Rounded tile with the standard macOS icon margins.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
context.clip()
let gradient = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1),
    CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1),
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

func dot(_ x: Double, _ y: Double, _ diameter: Double, _ alpha: Double) {
    let rect = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55 * alpha))
    context.fillEllipse(in: rect)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9 * alpha))
    context.setLineWidth(diameter * 0.11)
    context.strokeEllipse(in: rect.insetBy(dx: diameter * 0.055, dy: diameter * 0.055))
}

// Two staggered columns of dots on each side, fading toward the middle, like the on-screen cues.
for side in [-1.0, 1.0] {
    for row in 0..<4 {
        dot(512 + side * 290, 248 + Double(row) * 176, 104, 1)
    }
    for row in 0..<3 {
        dot(512 + side * 130, 336 + Double(row) * 176, 60, 0.55)
    }
}

let image = context.makeImage()!
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(_ pixels: Int, _ name: String) throws {
    let scaled = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                           space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let data = NSBitmapImageRep(cgImage: scaled.makeImage()!).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try write(points, "icon_\(points)x\(points).png")
    try write(points * 2, "icon_\(points)x\(points)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote AppIcon.icns")
