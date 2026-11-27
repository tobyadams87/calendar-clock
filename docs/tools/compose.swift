// Screenshot helper for the README: frames a full-screen capture (taken over the backdrop
// wallpaper) as a slice of the desktop, with a clean menu bar drawn across the top.
//   compose <capture.png> <out.png> <iconCentreX> <menuClock e.g. "Fri 27 Nov  12:19">
import AppKit
import CoreImage

let args = CommandLine.arguments
let capture = NSImage(contentsOfFile: args[1])!
let iconX = CGFloat(Double(args[3])!)     // points, from the left of the screen
let clockText = args[4]

let screenW: CGFloat = 1470, menuH: CGFloat = 33
let left = iconX - 300                    // slice: 300 pt left of the icon to the screen's right edge
let size = NSSize(width: screenW - left, height: 430)
let scale: CGFloat = 2

guard let cg = capture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("bad capture") }
let slice = cg.cropping(to: CGRect(x: left * scale, y: 0, width: size.width * scale, height: size.height * scale))!
let menuStrip = cg.cropping(to: CGRect(x: left * scale, y: menuH * scale, width: size.width * scale, height: menuH * scale * 2))!

// Blurred wallpaper for the menu bar background.
let blurred: CGImage = {
    let ci = CIImage(cgImage: menuStrip).clampedToExtent().applyingGaussianBlur(sigma: 30)
        .cropped(to: CGRect(x: 0, y: 0, width: menuStrip.width, height: menuStrip.height))
    return CIContext().createCGImage(ci, from: ci.extent)!
}()

func glyph() -> NSImage {   // Calendar Clock's "App Icon Outline" menu bar icon
    NSImage(size: NSSize(width: 19, height: 18), flipped: true) { _ in
        let page = NSRect(x: 1.5, y: 1.5, width: 16, height: 15)
        let outline = NSBezierPath(roundedRect: page, xRadius: 3.5, yRadius: 3.5)
        NSColor.black.withAlphaComponent(0.85).set()
        outline.lineWidth = 1.4
        outline.stroke()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSRect(x: page.minX, y: page.minY, width: page.width, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        let c = NSPoint(x: page.midX, y: page.minY + 4 + (page.height - 4) / 2 + 0.3)
        for (deg, len) in [(305.0, 3.4), (60.0, 4.6)] {
            let a = deg * .pi / 180
            let p = NSBezierPath()
            p.move(to: c)
            p.line(to: NSPoint(x: c.x + sin(a) * len, y: c.y - cos(a) * len))
            p.lineWidth = 1.5
            p.lineCapStyle = .round
            p.stroke()
        }
        NSBezierPath(ovalIn: NSRect(x: c.x - 1.1, y: c.y - 1.1, width: 2.2, height: 2.2)).fill()
        return true
    }
}

func symbol(_ name: String, _ pt: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pt, weight: .medium)
        .applying(.init(paletteColors: [NSColor.black.withAlphaComponent(0.85)]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

let out = NSImage(size: size, flipped: true) { rect in
    let frame = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
    frame.addClip()
    NSImage(cgImage: slice, size: rect.size).draw(in: rect)

    // Menu bar
    let bar = NSRect(x: 0, y: 0, width: rect.width, height: menuH)
    NSImage(cgImage: blurred, size: NSSize(width: rect.width, height: menuH * 2))
        .draw(in: bar, from: NSRect(x: 0, y: menuH, width: rect.width, height: menuH), operation: .copy, fraction: 1)
    NSColor.white.withAlphaComponent(0.30).setFill()
    bar.fill(using: .sourceOver)

    // Calendar Clock's icon, highlighted because its drop-down is open
    let iconCentre = NSPoint(x: 300, y: menuH / 2)
    NSColor.white.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect: NSRect(x: iconCentre.x - 19, y: iconCentre.y - 12, width: 38, height: 24),
                 xRadius: 7, yRadius: 7).fill()
    let g = glyph()
    g.draw(in: NSRect(x: iconCentre.x - 9.5, y: iconCentre.y - 9, width: 19, height: 18))

    // Right-hand side: Wi-Fi, Control Centre, then the clock without seconds
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
        .foregroundColor: NSColor.black.withAlphaComponent(0.85)]
    let clock = NSAttributedString(string: clockText, attributes: attrs)
    let cs = clock.size()
    var x = rect.width - 14 - cs.width
    clock.draw(at: NSPoint(x: x, y: (menuH - cs.height) / 2))
    for name in ["switch.2", "wifi"] {
        let s = symbol(name, 14)
        x -= 18 + s.size.width
        s.draw(in: NSRect(x: x, y: (menuH - s.size.height) / 2, width: s.size.width, height: s.size.height))
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
out.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2])")
