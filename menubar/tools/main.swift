import Cocoa

func renderPNG(size: CGFloat, to path: String, draw: () -> Void) {
    let px = Int(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : ""
let out = args.count > 2 ? args[2] : "."

switch mode {
case "iconset":
    let entries: [(String, CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, size) in entries {
        renderPNG(size: size, to: "\(out)/\(name).png") { drawAppIcon(size: size) }
    }
case "preview":
    for (name, kind) in [("asleep", MenuIconKind.asleep), ("awake", MenuIconKind.awake), ("waking", MenuIconKind.waking)] {
        renderPNG(size: 180, to: "\(out)/menu-\(name).png") {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 180, height: 180).fill()
            let t = NSAffineTransform()
            t.scale(by: 10)
            t.concat()
            drawMenuIcon(kind)
        }
    }
    renderPNG(size: 512, to: "\(out)/app-icon.png") { drawAppIcon(size: 512) }
default:
    print("usage: render iconset|preview OUTDIR")
}
