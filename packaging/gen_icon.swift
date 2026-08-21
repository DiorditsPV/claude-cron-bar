// Icon generator: app icon (.iconset → .icns via iconutil) and menu bar
// template glyphs. Run through `make icons`; output lands in packaging/icons.
//
// Design: a clock ring with hands at about ten past ten and a four-point spark
// at one o'clock - "time" plus the Claude spark. The spark is what separates it
// from every other clock in the menu bar at 16 px.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging/icons")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func png(_ image: NSImage, size: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func spark(center c: CGPoint, radius r: CGFloat, waist: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + waist, y: c.y + waist), controlPoint2: CGPoint(x: c.x + waist, y: c.y + waist))
    p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + waist, y: c.y - waist), controlPoint2: CGPoint(x: c.x + waist, y: c.y - waist))
    p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - waist, y: c.y - waist), controlPoint2: CGPoint(x: c.x - waist, y: c.y - waist))
    p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - waist, y: c.y + waist), controlPoint2: CGPoint(x: c.x - waist, y: c.y + waist))
    p.close()
    return p
}

func hand(from c: CGPoint, angleDeg: CGFloat, length: CGFloat, width: CGFloat) -> NSBezierPath {
    let a = angleDeg * .pi / 180
    let end = CGPoint(x: c.x + sin(a) * length, y: c.y + cos(a) * length)
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.move(to: c)
    p.line(to: end)
    return p
}

// --- app icon ---------------------------------------------------------------

let appIcon = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    // macOS icon grid: 824 pt rounded square on a 1024 canvas
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.80, green: 0.42, blue: 0.30, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // terracotta gradient, lighter at the top
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.93, green: 0.60, blue: 0.46, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 0.73, green: 0.36, blue: 0.25, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -90)

    // soft top highlight
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let hi = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    hi.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let c = CGPoint(x: 512, y: 500)
    NSColor.white.setStroke()
    NSColor.white.setFill()

    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 236, y: c.y - 236, width: 472, height: 472))
    ring.lineWidth = 58
    ring.stroke()

    hand(from: c, angleDeg: 0, length: 168, width: 52).stroke()    // minute: 12
    hand(from: c, angleDeg: 300, length: 118, width: 52).stroke()  // hour: ~10
    NSBezierPath(ovalIn: NSRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80)).fill()

    // spark at one o'clock, sitting on the ring
    spark(center: CGPoint(x: 728, y: 712), radius: 96, waist: 22).fill()
    return true
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    png(appIcon, size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    png(appIcon, size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
png(appIcon, size: 512, to: outDir.appendingPathComponent("AppIcon-512.png"))

// --- menu bar glyphs (template: black + alpha, 18 pt) -----------------------

func menuGlyph(_ state: String) -> NSImage {
    NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let c = CGPoint(x: 8.5, y: 8.5)
        NSColor.black.setStroke()
        NSColor.black.setFill()
        if state == "running" {
            NSBezierPath(ovalIn: NSRect(x: c.x - 7.6, y: c.y - 7.6, width: 15.2, height: 15.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            hand(from: c, angleDeg: 0, length: 5.2, width: 1.7).stroke()
            hand(from: c, angleDeg: 300, length: 3.7, width: 1.7).stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 6.7, y: c.y - 6.7, width: 13.4, height: 13.4))
            ring.lineWidth = 1.7
            ring.stroke()
            hand(from: c, angleDeg: 0, length: 4.8, width: 1.7).stroke()
            hand(from: c, angleDeg: 300, length: 3.4, width: 1.7).stroke()
        }
        // the spark, one o'clock, slightly outside the ring
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: NSRect(x: 11.4, y: 11.4, width: 7, height: 7)).fill()   // clear a halo first
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        spark(center: CGPoint(x: 14.9, y: 14.9), radius: 3.1, waist: 0.75).fill()
        if state == "failure" {
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 9.6, y: -0.6, width: 9.2, height: 9.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 10.4, y: 0.2, width: 7.6, height: 7.6)).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let bang = NSBezierPath(roundedRect: NSRect(x: 13.55, y: 3.1, width: 1.3, height: 3.3), xRadius: 0.65, yRadius: 0.65)
            bang.fill()
            NSBezierPath(ovalIn: NSRect(x: 13.5, y: 1.25, width: 1.4, height: 1.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        return true
    }
}

for state in ["idle", "running", "failure"] {
    let img = menuGlyph(state)
    png(img, size: 18, to: outDir.appendingPathComponent("menubar-\(state).png"))
    png(img, size: 36, to: outDir.appendingPathComponent("menubar-\(state)@2x.png"))
}
print("icons written to \(outDir.path)")
