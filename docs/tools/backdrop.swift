// Screenshot helper for the README.
//   backdrop wallpaper <out.png>          draws an original macOS-style gradient wallpaper
//   backdrop show <wallpaper.png> <secs>  shows it full-screen (below menus and the drop-down)
import AppKit

let args = CommandLine.arguments

func wallpaper(size: CGSize) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [r, g, b, a])!
    }
    // Base: deep blue at the top to violet at the bottom.
    let base = CGGradient(colorsSpace: cs, colors: [c(0.10, 0.28, 0.78), c(0.45, 0.20, 0.72)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
    // Soft colour blobs.
    let blobs: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
        (0.78, 0.82, 0.55, c(0.20, 0.72, 0.98, 0.85)),   // sky blue, top right
        (0.15, 0.70, 0.50, c(0.36, 0.42, 0.98, 0.80)),   // periwinkle, top left
        (0.30, 0.18, 0.55, c(0.98, 0.42, 0.62, 0.75)),   // pink, bottom left
        (0.85, 0.15, 0.50, c(1.00, 0.62, 0.34, 0.70)),   // orange, bottom right
        (0.55, 0.50, 0.40, c(0.62, 0.38, 0.95, 0.55)),   // violet, centre
    ]
    for (x, y, r, colour) in blobs {
        let centre = CGPoint(x: x * size.width, y: y * size.height)
        let g = CGGradient(colorsSpace: cs, colors: [colour, colour.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre,
                               endRadius: r * max(size.width, size.height), options: [])
    }
    return ctx.makeImage()!
}

switch args.count > 1 ? args[1] : "" {
case "wallpaper":
    let image = wallpaper(size: CGSize(width: 2940, height: 1912))
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    print("Wrote \(args[2])")

case "show":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screen = NSScreen.main!
    let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .statusBar            // above apps, below menus and the drop-down (.popUpMenu)
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    let view = NSImageView(frame: screen.frame)
    view.image = NSImage(contentsOfFile: args[2])
    view.imageScaling = .scaleAxesIndependently
    window.contentView = view
    window.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(args[3]) ?? 20)) { app.terminate(nil) }
    app.run()

default:
    print("usage: backdrop wallpaper <out.png> | backdrop show <wallpaper.png> <seconds>")
}
