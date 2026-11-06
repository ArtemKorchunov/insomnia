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

let sparkRays: [(angle: CGFloat, length: CGFloat)] = [
    (6, 1.0), (36, 0.7), (64, 0.93), (95, 0.66), (123, 0.98), (151, 0.76),
    (183, 0.9), (212, 0.69), (241, 1.0), (269, 0.74), (299, 0.95), (329, 0.67),
]

func sparkPath(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.windingRule = .nonZero
    let baseHalf = radius * 0.14
    let tipR = radius * 0.085
    for ray in sparkRays {
        let a = ray.angle * .pi / 180
        let dir = NSPoint(x: cos(a), y: sin(a))
        let normal = NSPoint(x: -sin(a), y: cos(a))
        let len = radius * ray.length
        let tip = NSPoint(x: center.x + dir.x * (len - tipR), y: center.y + dir.y * (len - tipR))
        let b1 = NSPoint(x: center.x + normal.x * baseHalf, y: center.y + normal.y * baseHalf)
        let b2 = NSPoint(x: center.x - normal.x * baseHalf, y: center.y - normal.y * baseHalf)
        let t1 = NSPoint(x: tip.x + normal.x * tipR, y: tip.y + normal.y * tipR)
        let blade = NSBezierPath()
        blade.move(to: b1)
        blade.line(to: t1)
        blade.appendArc(withCenter: tip, radius: tipR, startAngle: (ray.angle + 90), endAngle: (ray.angle - 90), clockwise: true)
        blade.line(to: b2)
        blade.close()
        path.append(blade)
    }
    path.appendOval(in: NSRect(x: center.x - baseHalf * 1.3, y: center.y - baseHalf * 1.3, width: baseHalf * 2.6, height: baseHalf * 2.6))
    return path
}

let sparkMask: NSImage? = {
    if let path = ProcessInfo.processInfo.environment["INSOMNIA_SPARK"], let img = NSImage(contentsOfFile: path) { return img }
    if let url = Bundle.main.url(forResource: "claude-spark", withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
    return nil
}()

func drawSparkMask(_ mask: NSImage, center: NSPoint, radius: CGFloat, color: NSColor) {
    let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let tinted = NSImage(size: rect.size, flipped: false) { r in
        mask.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

func drawMenuIcon(_ kind: MenuIconKind) {
    NSColor.black.set()
    switch kind {
    case .awake:
        if let mask = sparkMask {
            drawSparkMask(mask, center: NSPoint(x: 9, y: 9), radius: 3.5, color: .black)
        } else {
            NSColor.black.setFill()
            sparkPath(center: NSPoint(x: 9, y: 9), radius: 3.0).fill()
        }
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

// MARK: - App icon: a glass eye on a graphite squircle, the Claude spark as its iris.

private func iconColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Superellipse |x|^5 + |y|^5 = 1, the outline of macOS app icons.
private func squirclePath(_ r: NSRect) -> NSBezierPath {
    let n: CGFloat = 5, p = NSBezierPath()
    for i in 0...360 {
        let t = CGFloat(i) * .pi / 180, c = cos(t), sn = sin(t)
        let pt = NSPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: r.midY + r.height / 2 * (sn < 0 ? -1 : 1) * pow(abs(sn), 2 / n))
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

/// The outline of a stroke as a fillable path (works on macOS 13, unlike NSBezierPath.cgPath).
private func strokedOutline(_ path: NSBezierPath, width: CGFloat) -> NSBezierPath {
    let cg = CGMutablePath()
    var pts = [NSPoint](repeating: .zero, count: 3)
    for i in 0..<path.elementCount {
        switch path.element(at: i, associatedPoints: &pts) {
        case .moveTo: cg.move(to: pts[0])
        case .lineTo: cg.addLine(to: pts[0])
        case .curveTo, .cubicCurveTo: cg.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
        case .quadraticCurveTo: cg.addQuadCurve(to: pts[1], control: pts[0])
        case .closePath: cg.closeSubpath()
        @unknown default: break
        }
    }
    let out = NSBezierPath()
    cg.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).applyWithBlock { el in
        let e = el.pointee, q = e.points
        switch e.type {
        case .moveToPoint: out.move(to: q[0])
        case .addLineToPoint: out.line(to: q[0])
        case .addQuadCurveToPoint:
            let cur = out.currentPoint
            out.curve(to: q[1], controlPoint1: NSPoint(x: cur.x + 2 / 3 * (q[0].x - cur.x), y: cur.y + 2 / 3 * (q[0].y - cur.y)),
                      controlPoint2: NSPoint(x: q[1].x + 2 / 3 * (q[0].x - q[1].x), y: q[1].y + 2 / 3 * (q[0].y - q[1].y)))
        case .addCurveToPoint: out.curve(to: q[2], controlPoint1: q[0], controlPoint2: q[1])
        case .closeSubpath: out.close()
        @unknown default: break
        }
    }
    return out
}

// The eye, in the same 18-unit space as the menu bar icon.
private let eyeOpen: CGFloat = 5.8, eyeCorner: CGFloat = 2.6
private let upperLid: CGFloat = 1.2, lowerLid: CGFloat = 0.75, lashLength: CGFloat = 2.1
private let eyeP = (l: NSPoint(x: 1.5, y: 9), r: NSPoint(x: 16.5, y: 9),
                    c1: NSPoint(x: 1.5 + eyeCorner, y: 9 + eyeOpen), c2: NSPoint(x: 16.5 - eyeCorner, y: 9 + eyeOpen),
                    d1: NSPoint(x: 16.5 - eyeCorner, y: 9 - eyeOpen), d2: NSPoint(x: 1.5 + eyeCorner, y: 9 - eyeOpen))

/// A point on the upper lid at u (0...1) and the outward normal there.
private func upperLidPoint(_ u: CGFloat) -> (NSPoint, NSPoint) {
    let p0 = eyeP.l, p1 = eyeP.c1, p2 = eyeP.c2, p3 = eyeP.r, m = 1 - u
    let x = m*m*m*p0.x + 3*m*m*u*p1.x + 3*m*u*u*p2.x + u*u*u*p3.x
    let y = m*m*m*p0.y + 3*m*m*u*p1.y + 3*m*u*u*p2.y + u*u*u*p3.y
    let dx = 3*m*m*(p1.x-p0.x) + 6*m*u*(p2.x-p1.x) + 3*u*u*(p3.x-p2.x)
    let dy = 3*m*m*(p1.y-p0.y) + 6*m*u*(p2.y-p1.y) + 3*u*u*(p3.y-p2.y)
    let len = sqrt(dx*dx + dy*dy)
    return (NSPoint(x: x, y: y), NSPoint(x: -dy / len, y: dx / len))
}

func drawAppIcon(size: CGFloat) {
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = squirclePath(rect)

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
    sh.shadowBlurRadius = 14 * s; sh.shadowOffset = NSSize(width: 0, height: -8 * s); sh.set()
    iconColor(10, 11, 34).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [iconColor(92, 94, 108), iconColor(44, 45, 56), iconColor(18, 18, 24), iconColor(10, 10, 14)],
               atLocations: [0, 0.42, 0.78, 1], colorSpace: .deviceRGB)!.draw(in: rect, angle: -90)
    iconColor(255, 255, 255, 0.9).setFill(); NSBezierPath(ovalIn: NSRect(x: 268 * s, y: 790 * s, width: 13 * s, height: 13 * s)).fill()
    iconColor(255, 255, 255, 0.65).setFill(); NSBezierPath(ovalIn: NSRect(x: 752 * s, y: 836 * s, width: 9 * s, height: 9 * s)).fill()

    let k = 36 * s
    let t = NSAffineTransform(); t.translateX(by: 512 * s, yBy: 500 * s); t.scale(by: k); t.translateX(by: -9, yBy: -9)
    let up = NSBezierPath(); up.move(to: eyeP.l); up.curve(to: eyeP.r, controlPoint1: eyeP.c1, controlPoint2: eyeP.c2)
    let lo = NSBezierPath(); lo.move(to: eyeP.r); lo.curve(to: eyeP.l, controlPoint1: eyeP.d1, controlPoint2: eyeP.d2)
    let eye = NSBezierPath(); eye.move(to: eyeP.l)
    eye.curve(to: eyeP.r, controlPoint1: eyeP.c1, controlPoint2: eyeP.c2)
    eye.curve(to: eyeP.l, controlPoint1: eyeP.d1, controlPoint2: eyeP.d2); eye.close()
    for p in [up, lo, eye] { p.transform(using: t as AffineTransform) }
    let eb = eye.bounds
    let lid = strokedOutline(up, width: upperLid * k); lid.append(strokedOutline(lo, width: lowerLid * k))
    lid.windingRule = .nonZero

    // tight contact shadow under the eye
    NSGraphicsContext.saveGraphicsState()
    let es = NSShadow(); es.shadowColor = iconColor(4, 4, 24, 0.55)
    es.shadowBlurRadius = 8 * s; es.shadowOffset = NSSize(width: 0, height: -10 * s); es.set()
    iconColor(12, 12, 16).setFill(); lid.fill(); eye.fill()
    NSGraphicsContext.restoreGraphicsState()

    // the white of the eye, shaded a little under the upper lid
    NSGraphicsContext.saveGraphicsState()
    eye.addClip()
    NSGradient(colors: [iconColor(255, 255, 255), iconColor(242, 242, 246), iconColor(218, 218, 226)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!.draw(in: eb, angle: -90)
    NSGradient(colors: [iconColor(120, 120, 140, 0.45), iconColor(120, 120, 140, 0)])!
        .draw(in: NSRect(x: eb.minX, y: eb.maxY - eb.height * 0.32, width: eb.width, height: eb.height * 0.32), angle: -90)

    // the iris disc
    let c = NSPoint(x: 512 * s, y: 500 * s), r = 3.35 * k
    let iris = NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: iris).addClip()
    NSGradient(colors: [iconColor(80, 84, 104), iconColor(40, 42, 56), iconColor(20, 20, 28)], atLocations: [0, 0.6, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: NSPoint(x: c.x, y: c.y + r * 0.25), radius: 0, toCenter: c, radius: r, options: [])
    NSGraphicsContext.restoreGraphicsState()
    let ring = NSBezierPath(ovalIn: iris.insetBy(dx: 0.12 * k, dy: 0.12 * k))
    ring.lineWidth = 0.24 * k; iconColor(6, 6, 8).setStroke(); ring.stroke()

    // a sharp-edged reflection across the white, kept off the iris
    let shine = NSBezierPath(ovalIn: NSRect(x: eb.minX - eb.width * 0.05, y: eb.midY + eb.height * 0.02, width: eb.width * 1.1, height: eb.height * 1.3))
    shine.append(NSBezierPath(ovalIn: NSRect(x: eb.minX - eb.width * 0.1, y: eb.midY + eb.height * 0.2, width: eb.width * 1.2, height: eb.height * 1.4)).reversed)
    NSGraphicsContext.saveGraphicsState()
    let outside = NSBezierPath(rect: eb.insetBy(dx: -50 * s, dy: -50 * s))
    outside.append(NSBezierPath(ovalIn: iris).reversed)
    outside.addClip()
    NSColor.white.withAlphaComponent(0.55).setFill(); shine.fill()
    NSGraphicsContext.restoreGraphicsState()

    // the Claude spark, unchanged
    let claudeOrange = NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    if let mask = sparkMask {
        drawSparkMask(mask, center: c, radius: 2.9 * k, color: claudeOrange)
    } else {
        claudeOrange.setFill()
        sparkPath(center: c, radius: 2.6 * k).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // the lids, with one crisp gloss line inside the upper lid
    NSGraphicsContext.saveGraphicsState()
    lid.addClip()
    iconColor(14, 14, 20).setFill(); lid.fill()
    let gloss = up.copy() as! NSBezierPath
    let nudge = NSAffineTransform(); nudge.translateX(by: 0, yBy: upperLid * k * 0.12); gloss.transform(using: nudge as AffineTransform)
    iconColor(200, 200, 215, 0.35).setFill(); strokedOutline(gloss, width: upperLid * k * 0.14).fill()
    NSGraphicsContext.restoreGraphicsState()

    // lashes: glass pills curving out from the upper lid
    for u in [0.2, 0.5, 0.8] as [CGFloat] {
        let (p, n) = upperLidPoint(u)
        let start = NSPoint(x: p.x + n.x * upperLid * 0.2, y: p.y + n.y * upperLid * 0.2)
        let side: CGFloat = u < 0.5 ? -1 : (u > 0.5 ? 1 : 0)
        let end = NSPoint(x: start.x + n.x * lashLength + side * 0.45, y: start.y + n.y * lashLength)
        let lash = NSBezierPath(); lash.move(to: start)
        lash.curve(to: end, controlPoint1: NSPoint(x: start.x + n.x * lashLength * 0.5, y: start.y + n.y * lashLength * 0.5),
                   controlPoint2: NSPoint(x: end.x - side * 0.2, y: end.y - 0.3))
        lash.transform(using: t as AffineTransform)
        let pill = strokedOutline(lash, width: 1.05 * k)
        NSGraphicsContext.saveGraphicsState()
        let ps = NSShadow(); ps.shadowColor = iconColor(4, 4, 24, 0.4)
        ps.shadowBlurRadius = 2.5 * s; ps.shadowOffset = NSSize(width: 0, height: -4 * s); ps.set()
        iconColor(214, 214, 224).setFill(); pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); pill.addClip()
        NSGradient(colors: [iconColor(255, 255, 255), iconColor(214, 214, 224)])!.draw(in: pill.bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()

    // a hairline of light around the tile
    NSGraphicsContext.saveGraphicsState()
    strokedOutline(tile, width: 3 * s).addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0.05)])!.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}
