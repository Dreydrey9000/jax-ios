// Draws the app icon: the sky blue orb on near-black. Run: swift scripts/make-icon.swift
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

ctx.setFillColor(CGColor(red: 0x05 / 255.0, green: 0x05 / 255.0, blue: 0x08 / 255.0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

let center = CGPoint(x: 512, y: 512)
func sky(_ a: CGFloat) -> CGColor { CGColor(red: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0, alpha: a) }

// Soft glow, then the orb itself, lit from the upper left.
let glow = CGGradient(colorsSpace: space, colors: [sky(0.45), sky(0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 220, endCenter: center, endRadius: 500, options: [])
let orb = CGGradient(colorsSpace: space,
                     colors: [CGColor(red: 0.85, green: 0.96, blue: 1, alpha: 1), sky(1),
                              CGColor(red: 0.03, green: 0.2, blue: 0.4, alpha: 1)] as CFArray,
                     locations: [0, 0.45, 1])!
ctx.addEllipse(in: CGRect(x: 512 - 270, y: 512 - 270, width: 540, height: 540))
ctx.clip()
ctx.drawRadialGradient(orb, startCenter: CGPoint(x: 430, y: 610), startRadius: 10,
                       endCenter: center, endRadius: 300, options: [.drawsAfterEndLocation])

// App Store icons may not carry transparency: flatten to opaque RGB.
let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
let out = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try flat.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
