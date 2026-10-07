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
case "spark-mask":
    let input = args.count > 3 ? args[3] : ""
    guard let src = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: input))) ?? Data()) else {
        print("cannot read \(input)"); exit(1)
    }
    let w = src.pixelsWide, h = src.pixelsHigh
    var minX = w, minY = h, maxX = 0, maxY = 0
    var alphas = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            let a = max(0, min(1, (lum - 0.68) / (0.88 - 0.68))) * c.alphaComponent
            let v = UInt8(a * 255)
            alphas[y * w + x] = v
            if v > 160 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    let side = max(maxX - minX, maxY - minY) + 8
    let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    guard let outRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    for y in 0..<side {
        for x in 0..<side {
            let sx = cx - side / 2 + x, sy = cy - side / 2 + y
            var a: UInt8 = 0
            if sx >= 0 && sx < w && sy >= 0 && sy < h { a = alphas[sy * w + sx] }
            outRep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: CGFloat(a) / 255), atX: x, y: y)
        }
    }
    try? outRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    print("spark mask \(side)x\(side)")
default:
    print("usage: render iconset|preview OUTDIR | spark-mask OUT.png IN.png")
}
