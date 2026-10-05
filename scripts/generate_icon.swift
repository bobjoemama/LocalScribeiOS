import CoreGraphics
import Foundation
import ImageIO

// Code-native LocalScribe monogram shared with the desktop branding.
// Draw into an explicit bitmap so command-line generation needs no AppKit
// graphics context or window server. iOS applies its own icon corner mask.
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let bitmap = CGContext(data: nil, width: size, height: size,
                             bitsPerComponent: 8, bytesPerRow: size * 4,
                             space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create icon bitmap")
}
bitmap.setFillColor(CGColor(srgbRed: 243 / 255, green: 241 / 255, blue: 237 / 255, alpha: 1))
bitmap.fill(CGRect(x: 0, y: 0, width: size, height: size))
bitmap.translateBy(x: 0, y: CGFloat(size))
bitmap.scaleBy(x: 1, y: -1)
bitmap.setFillColor(CGColor(srgbRed: 9 / 255, green: 9 / 255, blue: 9 / 255, alpha: 1))
bitmap.fill(CGRect(x: 328, y: 238, width: 146, height: 548))
bitmap.fill(CGRect(x: 328, y: 660, width: 390, height: 126))
guard let image = bitmap.makeImage() else { fatalError("Could not render icon") }
let destination = URL(fileURLWithPath: "LocalScribeApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not write icon")
}
CGImageDestinationAddImage(output, image, nil)
guard CGImageDestinationFinalize(output) else { fatalError("Could not finish icon") }
