import Cocoa

enum MenuIconKind {
    case asleep
    case awake
    case waking
}

func strokeLines(_ segments: [(NSPoint, NSPoint)], width: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    for (a, b) in segments {
        path.move(to: a)
        path.line(to: b)
    }
    path.stroke()
}

func drawZ(at origin: NSPoint, size: CGFloat, width: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: origin.x, y: origin.y + size))
    path.line(to: NSPoint(x: origin.x + size, y: origin.y + size))
    path.line(to: NSPoint(x: origin.x, y: origin.y))
    path.line(to: NSPoint(x: origin.x + size, y: origin.y))
    path.stroke()
}

func openEyePath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 1.5, y: 9))
    path.curve(to: NSPoint(x: 16.5, y: 9), controlPoint1: NSPoint(x: 5, y: 14.5), controlPoint2: NSPoint(x: 13, y: 14.5))
    path.curve(to: NSPoint(x: 1.5, y: 9), controlPoint1: NSPoint(x: 13, y: 3.5), controlPoint2: NSPoint(x: 5, y: 3.5))
    path.close()
    return path
}

func drawCrescentIris(center: NSPoint, radius: CGFloat, cutOffset: NSPoint, cutRadius: CGFloat, color: NSColor) {
    let irisRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let c = NSPoint(x: center.x + cutOffset.x, y: center.y + cutOffset.y)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: irisRect).addClip()
    let crescent = NSBezierPath(rect: irisRect.insetBy(dx: -1, dy: -1))
    crescent.appendOval(in: NSRect(x: c.x - cutRadius, y: c.y - cutRadius, width: cutRadius * 2, height: cutRadius * 2))
    crescent.windingRule = .evenOdd
    color.setFill()
    crescent.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func drawMenuIcon(_ kind: MenuIconKind) {
    NSColor.black.set()
    switch kind {
    case .awake:
        drawCrescentIris(center: NSPoint(x: 9, y: 9), radius: 3.4, cutOffset: NSPoint(x: 1.5, y: 1.1), cutRadius: 2.7, color: .black)
        NSColor.black.setStroke()
        let eye = openEyePath()
        eye.lineWidth = 1.4
        eye.lineJoinStyle = .round
        eye.stroke()
        strokeLines([
            (NSPoint(x: 4.83, y: 12.09), NSPoint(x: 3.8, y: 14.1)),
            (NSPoint(x: 9, y: 13.12), NSPoint(x: 9, y: 15.6)),
            (NSPoint(x: 13.17, y: 12.09), NSPoint(x: 14.2, y: 14.1)),
        ], width: 1.3)
    case .waking:
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: 1.5, y: 8))
        eye.curve(to: NSPoint(x: 16.5, y: 8), controlPoint1: NSPoint(x: 5, y: 11.2), controlPoint2: NSPoint(x: 13, y: 11.2))
        eye.curve(to: NSPoint(x: 1.5, y: 8), controlPoint1: NSPoint(x: 13, y: 3.2), controlPoint2: NSPoint(x: 5, y: 3.2))
        eye.close()
        NSGraphicsContext.saveGraphicsState()
        eye.addClip()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 9 - 3.2, y: 7.2 - 3.2, width: 6.4, height: 6.4)).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setStroke()
        eye.lineWidth = 1.4
        eye.lineJoinStyle = .round
        eye.stroke()
        for (i, x) in [5.5, 9.0, 12.5].enumerated() {
            let r: CGFloat = 0.85 + CGFloat(i) * 0.25
            NSBezierPath(ovalIn: NSRect(x: x - r, y: 14.2 - r, width: r * 2, height: r * 2)).fill()
        }
    case .asleep:
        NSColor.black.setStroke()
        let lid = NSBezierPath()
        lid.lineWidth = 1.5
        lid.lineCapStyle = .round
        lid.move(to: NSPoint(x: 2, y: 10))
        lid.curve(to: NSPoint(x: 16, y: 10), controlPoint1: NSPoint(x: 5.5, y: 5.5), controlPoint2: NSPoint(x: 12.5, y: 5.5))
        lid.stroke()
        strokeLines([
            (NSPoint(x: 5.17, y: 7.47), NSPoint(x: 4.1, y: 5.4)),
            (NSPoint(x: 9, y: 6.62), NSPoint(x: 9, y: 4.2)),
            (NSPoint(x: 12.83, y: 7.47), NSPoint(x: 13.9, y: 5.4)),
        ], width: 1.3)
        drawZ(at: NSPoint(x: 12.6, y: 13.4), size: 3.2, width: 1.25)
        drawZ(at: NSPoint(x: 8.9, y: 12.2), size: 2.0, width: 1.05)
    }
}

func menuIcon(_ kind: MenuIconKind) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        drawMenuIcon(kind)
        return true
    }
    image.isTemplate = true
    return image
}

func drawAppIcon(size: CGFloat) {
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor(calibratedRed: 0.08, green: 0.07, blue: 0.22, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.38, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.16, alpha: 1),
    ])?.draw(in: rect, angle: -90)

    let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (210, 790, 9), (300, 860, 5), (760, 840, 7), (840, 720, 5), (650, 880, 4),
        (180, 640, 4), (870, 560, 6), (420, 820, 4), (560, 800, 6), (250, 300, 4), (800, 260, 5),
    ]
    for (x, y, r) in stars {
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: (x - r) * s, y: (y - r) * s, width: r * 2 * s, height: r * 2 * s)).fill()
    }

    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 0.85, blue: 0.45, alpha: 0.35),
        NSColor(calibratedRed: 1, green: 0.85, blue: 0.45, alpha: 0),
    ])
    glow?.draw(fromCenter: NSPoint(x: 512 * s, y: 500 * s), radius: 0, toCenter: NSPoint(x: 512 * s, y: 500 * s), radius: 330 * s, options: [])

    let transform = NSAffineTransform()
    transform.translateX(by: 512 * s, yBy: 500 * s)
    transform.scale(by: 40 * s)
    transform.translateX(by: -9, yBy: -9)

    let eye = openEyePath()
    eye.transform(using: transform as AffineTransform)
    NSColor(calibratedRed: 0.97, green: 0.96, blue: 1, alpha: 1).setFill()
    eye.fill()

    NSGraphicsContext.saveGraphicsState()
    eye.addClip()
    let irisCenter = NSPoint(x: 512 * s, y: 500 * s)
    let irisR = 3.2 * 40 * s
    NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 0.88, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.2, alpha: 1),
    ])?.draw(in: NSBezierPath(ovalIn: NSRect(x: irisCenter.x - irisR, y: irisCenter.y - irisR, width: irisR * 2, height: irisR * 2)), angle: -60)
    let cutR = 2.55 * 40 * s
    let cut = NSPoint(x: irisCenter.x + 1.4 * 40 * s, y: irisCenter.y + 1.05 * 40 * s)
    NSColor(calibratedRed: 0.97, green: 0.96, blue: 1, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: cut.x - cutR, y: cut.y - cutR, width: cutR * 2, height: cutR * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor(calibratedRed: 0.1, green: 0.08, blue: 0.25, alpha: 1).setStroke()
    eye.lineWidth = 1.4 * 40 * s
    eye.lineJoinStyle = .round
    eye.stroke()

    let lashes = NSBezierPath()
    lashes.lineWidth = 1.3 * 40 * s
    lashes.lineCapStyle = .round
    for (a, b) in [
        (NSPoint(x: 4.83, y: 12.09), NSPoint(x: 3.8, y: 14.1)),
        (NSPoint(x: 9, y: 13.12), NSPoint(x: 9, y: 15.6)),
        (NSPoint(x: 13.17, y: 12.09), NSPoint(x: 14.2, y: 14.1)),
    ] {
        lashes.move(to: a)
        lashes.line(to: b)
    }
    lashes.transform(using: transform as AffineTransform)
    NSColor(calibratedRed: 0.97, green: 0.96, blue: 1, alpha: 1).setStroke()
    lashes.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
