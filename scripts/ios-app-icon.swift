// The iOS app icon from the Mac one: the rounded square cropped full-bleed,
// corners filled with its background (iOS applies its own mask).
//   sips -s format png -Z 1024 Resources/AppIcon.icns --out /tmp/mac-icon.png
//   swift scripts/ios-app-icon.swift /tmp/mac-icon.png iOS/SwarmeBot/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = image.width, h = image.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
// bounding box of opaque pixels
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 200 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
// the dark background, sampled inside the square near its left edge, mid height
let sx = minX + (maxX - minX) / 12, sy = (minY + maxY) / 2
let i = (sy * w + sx) * 4
let bg = CGColor(red: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255, blue: CGFloat(px[i + 2]) / 255, alpha: 1)
// inset past the light rim of the Mac shape
let inset = Int(Double(maxX - minX) * 0.025)
let crop = CGRect(x: minX + inset, y: h - 1 - maxY + inset, width: maxX - minX - 2 * inset, height: maxY - minY - 2 * inset)
let size = 1024
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
out.setFillColor(bg)
out.fill(CGRect(x: 0, y: 0, width: size, height: size))
let cropped = image.cropping(to: crop)!
out.interpolationQuality = .high
out.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
// the Mac shape's light rim survives in the corners: paint everything outside
// a slightly smaller rounded square with the background (iOS masks it anyway)
let inner = CGPath(roundedRect: CGRect(x: 14, y: 14, width: size - 28, height: size - 28), cornerWidth: 235, cornerHeight: 235, transform: nil)
let outside = CGMutablePath()
outside.addRect(CGRect(x: 0, y: 0, width: size, height: size))
outside.addPath(inner)
out.addPath(outside)
out.setFillColor(bg)
out.fillPath(using: .evenOdd)
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("box \(minX),\(minY)–\(maxX),\(maxY) inset \(inset) bg \(px[i]),\(px[i+1]),\(px[i+2])")
