// Renders the NotesFloat app icon and builds AppIcon.icns.  Run: swift Artwork/make-icon.swift
// Design: an Apple Notes–style page (white, yellow header, ruled lines) tilted and lifted off a warm yellow
// tile, with a soft ground shadow below the gap so it reads as floating. Same 1024 grid as macOS icons:
// 824pt rounded tile inset 100pt, corner radius 185.
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Top-left coordinates (like the design grid) → Core Graphics' bottom-left.
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: 1024 - y - h, width: w, height: h) }

func draw(_ c: CGContext, scale k: CGFloat) {  // shadow offsets/blur are in device pixels, so scale them by k
    // Tile: warm yellow gradient.
    let tile = CGPath(roundedRect: rect(100, 100, 824, 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.addPath(tile)
    c.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFF6CF), color(0xFFDC5E)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Ground shadow, with a gap under the page so it reads as hovering. Drawn off-canvas so only its blur lands.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 3000 * k), blur: 40 * k, color: color(0x9A6400, 0.45))
    c.fillEllipse(in: rect(312, 812 + 3000, 400, 52))
    c.restoreGState()

    // The page, tilted and lifted.
    let page = rect(272, 196, 480, 540)
    c.translateBy(x: 512, y: 1024 - 466)
    c.rotate(by: 7 * .pi / 180)
    c.translateBy(x: -512, y: -(1024 - 466))
    let pagePath = CGPath(roundedRect: page, cornerWidth: 64, cornerHeight: 64, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 34 * k, color: color(0x7A4A00, 0.28))
    c.addPath(pagePath)
    c.setFillColor(color(0xFFFFFF))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(pagePath)
    c.clip()
    c.setFillColor(color(0xFFC21A))  // Apple Notes' yellow header
    c.fill(rect(272, 196, 480, 112))
    c.setFillColor(color(0x000000, 0.08))
    c.fill(rect(272, 306, 480, 4))
    c.restoreGState()

    c.setFillColor(color(0xD3D3D8))  // ruled lines
    for (y, w) in [(392.0, 340.0), (464.0, 340.0), (536.0, 340.0), (608.0, 220.0)] {
        c.addPath(CGPath(roundedRect: rect(342, y, w, 24), cornerWidth: 12, cornerHeight: 12, transform: nil))
    }
    c.fillPath()
    c.restoreGState()
}

func png(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx, scale: CGFloat(px) / 1024)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try png(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try png(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try png(1024).write(to: dir.appendingPathComponent("NotesFloat-icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "Artwork/AppIcon.icns + NotesFloat-icon.png" : "iconutil failed")
