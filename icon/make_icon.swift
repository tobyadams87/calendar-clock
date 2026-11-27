// Renders the Calendar Clock app icon to a 1024×1024 PNG.
// A nod to Menu Bar Calendar: the white page with the pink-red header stays,
// but the smiley face becomes a clock at 10:10 (the "smiling" watch time),
// with a red second hand for the seconds clock.
// Usage: swift make_icon.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: [rgb(a), rgb(b)] as CFArray, locations: [0, 1])!
}

// macOS icon grid: 824pt tile centred in 1024, continuous-ish corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
let top = tile.maxY

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.30))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()

// Page
ctx.drawLinearGradient(gradient(0xFFFFFF, 0xE8E8ED), start: CGPoint(x: 0, y: top),
                       end: CGPoint(x: 0, y: tile.minY), options: [])

// Pink-red header
let headerHeight: CGFloat = 200
let header = CGRect(x: tile.minX, y: top - headerHeight, width: tile.width, height: headerHeight)
ctx.saveGState(); ctx.clip(to: header)
ctx.drawLinearGradient(gradient(0xFF6E84, 0xFF3D5E), start: CGPoint(x: 0, y: top),
                       end: CGPoint(x: 0, y: header.minY), options: [])
ctx.restoreGState()
// Soft shading where header meets page
ctx.drawLinearGradient(
    CGGradient(colorsSpace: cs, colors: [rgb(0x000000, 0.10), rgb(0x000000, 0)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: header.minY), end: CGPoint(x: 0, y: header.minY - 22), options: [])
ctx.restoreGState()

// Clock face on the page
let ink = rgb(0x2A2A30)
let red = rgb(0xFF3D5E)
let centre = CGPoint(x: 512, y: 408)
let dialRadius: CGFloat = 218

for i in 0..<12 {
    let a = Double(i) * .pi / 6
    let p = CGPoint(x: centre.x + sin(a) * dialRadius, y: centre.y + cos(a) * dialRadius)
    let quarter = i % 3 == 0
    let d: CGFloat = quarter ? 28 : 14
    ctx.setFillColor(quarter ? ink : rgb(0x2A2A30, 0.30))
    ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
}

func hand(_ degrees: Double, length: CGFloat, width: CGFloat, colour: CGColor, tail: CGFloat = 0) {
    let a = degrees * .pi / 180   // clockwise from 12
    ctx.setStrokeColor(colour); ctx.setLineWidth(width); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: centre.x - sin(a) * tail, y: centre.y - cos(a) * tail))
    ctx.addLine(to: CGPoint(x: centre.x + sin(a) * length, y: centre.y + cos(a) * length))
    ctx.strokePath()
}

// 10:10 — the hands make a smile.
hand(305, length: 128, width: 36, colour: ink)   // hour
hand(60, length: 182, width: 26, colour: ink)    // minute
hand(196, length: 196, width: 9, colour: red, tail: 46)  // second
ctx.setFillColor(ink); ctx.fillEllipse(in: CGRect(x: centre.x - 27, y: centre.y - 27, width: 54, height: 54))
ctx.setFillColor(red); ctx.fillEllipse(in: CGRect(x: centre.x - 11, y: centre.y - 11, width: 22, height: 22))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
