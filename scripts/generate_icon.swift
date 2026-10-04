import AppKit
import Foundation

// Code-native icon artwork: the same ink/blue visual language as the app.
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.47, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.89, alpha: 1),
                          ending: NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.33, alpha: 1))!
gradient.draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)), angle: -45)
NSColor.white.setFill()
for (index, height) in [160, 300, 440, 300, 160].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 238 + index * 112, y: 570 - height / 2,
                                   width: 64, height: height), xRadius: 32, yRadius: 32).fill()
}
NSColor(calibratedRed: 0.78, green: 0.90, blue: 0.88, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 246, y: 235, width: 528, height: 42), xRadius: 21, yRadius: 21).fill()
NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: "LocalScribeApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
