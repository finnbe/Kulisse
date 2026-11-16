// Design "Grüne Füße".
// Zeiger: ein grüner Fußabdruck (Spitze des großen Zehs = Klickpunkt).
// Beim Bewegen entsteht eine Spur aus kleinen Fußabdrücken (links/rechts im Wechsel), die verblasst.
// Klick: der Fuß stampft auf, ein grüner Ring spritzt nach außen.
// Zeichenmodus: eine Fußspur aus größeren Abdrücken statt einer Linie (FootStamper).

import Cocoa

let FOOT_GREEN = NSColor(srgbRed: 0.18, green: 0.80, blue: 0.30, alpha: 1)
let FOOT_DARK = NSColor(srgbRed: 0.05, green: 0.42, blue: 0.16, alpha: 1)
let FOOT_TRAIL_STAY: Double = 0.7    // so lange bleibt ein Abdruck der Laufspur voll sichtbar
let FOOT_TRAIL_FADE: Double = 0.6

/// Fußabdruck als Bild, Zehen oben. Rechter Fuß: großer Zeh links. height = Höhe in Punkten.
/// Liefert auch, wo die Spitze des großen Zehs liegt (Anteil 0...1, Ursprung unten links).
func footImage(left: Bool, height: CGFloat) -> (CGImage, CGSize, CGPoint) {
    let scale: CGFloat = 3
    let h = height * scale, w = h * 0.62
    let ctx = CGContext(data: nil, width: Int(w.rounded(.up)), height: Int(h.rounded(.up)), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if left { ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1) }     // linker Fuß = gespiegelt
    let u = w                                                             // Einheit = Bildbreite
    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect {
        CGRect(x: (cx - rx) * u, y: (cy - ry) * u, width: 2 * rx * u, height: 2 * ry * u)
    }
    let shape = CGMutablePath()
    shape.addEllipse(in: ellipse(0.52, 0.30, 0.25, 0.28))                 // Ferse
    shape.addEllipse(in: ellipse(0.52, 0.86, 0.36, 0.36))                 // Ballen
    // Zehen: groß -> klein, im Bogen
    let toes: [(CGFloat, CGFloat, CGFloat)] = [(0.30, 1.33, 0.14), (0.53, 1.40, 0.10), (0.70, 1.35, 0.088),
                                              (0.83, 1.25, 0.078), (0.92, 1.12, 0.066)]
    for (x, y, r) in toes { shape.addEllipse(in: ellipse(x, y, r, r * 1.1)) }
    // Schatten-Rand + Füllung mit leichtem Verlauf
    ctx.setLineWidth(3 * scale / 3)
    ctx.addPath(shape)
    ctx.setStrokeColor(FOOT_DARK.cgColor)
    ctx.setLineWidth(scale * 1.4)
    ctx.strokePath()
    ctx.addPath(shape)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [FOOT_GREEN.blended(withFraction: 0.35, of: .white)!.cgColor, FOOT_GREEN.cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    let toeTip = CGPoint(x: left ? 1 - 0.30 : 0.30, y: (1.33 + 0.14 * 1.1) * u / h)
    return (ctx.makeImage()!, CGSize(width: w / scale, height: h / scale), toeTip)
}

/// Setzt entlang eines Weges Fußabdrücke im Wechsel links/rechts, in Laufrichtung gedreht.
final class FootStamper {
    let left: (CGImage, CGSize, CGPoint), right: (CGImage, CGSize, CGPoint)
    let spacing: CGFloat, side: CGFloat
    let fadeEach: Bool                 // Laufspur: jeder Abdruck verblasst für sich
    var last: CGPoint
    var dist: CGFloat = 0
    var nextLeft = true

    init(start: CGPoint, height: CGFloat, spacing: CGFloat, fadeEach: Bool) {
        left = footImage(left: true, height: height)
        right = footImage(left: false, height: height)
        self.spacing = spacing
        self.side = height * 0.28
        self.fadeEach = fadeEach
        last = start
    }

    func move(to p: CGPoint, into layer: CALayer) {
        var from = last
        var remaining = hypot(p.x - from.x, p.y - from.y)
        guard remaining > 0 else { return }
        let angle = atan2(p.y - from.y, p.x - from.x)
        let ux = cos(angle), uy = sin(angle)
        while dist + remaining >= spacing {
            let step = spacing - dist
            from = CGPoint(x: from.x + ux * step, y: from.y + uy * step)
            remaining -= step
            dist = 0
            stamp(at: from, angle: angle, into: layer)
        }
        dist += remaining
        last = p
    }

    func reset(to p: CGPoint) { last = p; dist = 0 }

    private func stamp(at p: CGPoint, angle: CGFloat, into layer: CALayer) {
        let img = nextLeft ? left : right
        let off = nextLeft ? side : -side                 // linker Fuß links der Laufrichtung
        nextLeft.toggle()
        let l = CALayer()
        l.contents = img.0
        l.bounds = CGRect(origin: .zero, size: img.1)
        l.position = CGPoint(x: p.x - sin(angle) * off, y: p.y + cos(angle) * off)
        l.transform = CATransform3DMakeRotation(angle - .pi / 2, 0, 0, 1)   // Zehen zeigen in Laufrichtung
        l.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        layer.addSublayer(l)
        guard fadeEach else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + FOOT_TRAIL_STAY
        fade.duration = FOOT_TRAIL_FADE
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

// ---------- Zeiger ----------
final class FeetFX {
    let root = CALayer()
    let trail = CALayer()
    let foot = CALayer()
    var stamper: FootStamper?
    var wasPressed = false
    var clicks = true

    init() {
        let (img, sz, tip) = footImage(left: false, height: 34)
        foot.contents = img
        foot.bounds = CGRect(origin: .zero, size: sz)
        foot.anchorPoint = tip                            // Spitze des großen Zehs = Klickpunkt
        foot.transform = CATransform3DMakeRotation(0.35, 0, 0, 1)   // leicht nach links geneigt wie ein Pfeil
        foot.shadowColor = NSColor.black.cgColor
        foot.shadowOpacity = 0.3
        foot.shadowRadius = 2.5
        foot.shadowOffset = CGSize(width: 1, height: -2)
        root.addSublayer(trail)
        root.addSublayer(foot)
        for l in [root, trail, foot] { l.actions = ["position": NSNull(), "hidden": NSNull()] }
        root.isHidden = true
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        if !v { stamper = nil }
    }

    func update(mouse: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        foot.position = mouse
        CATransaction.commit()
        // Laufspur: hinter dem Zeiger (etwas unterhalb der Zehenspitze, wo die Sohle ist)
        let sole = CGPoint(x: mouse.x + 6, y: mouse.y - 18)
        if stamper == nil { stamper = FootStamper(start: sole, height: 15, spacing: 20, fadeEach: true) }
        stamper?.move(to: sole, into: trail)

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { stomp(at: mouse) }
        wasPressed = pressed
    }

    /// Aufstampfen: Fuß drückt sich kurz zusammen, grüner Ring spritzt nach außen.
    func stomp(at p: CGPoint) {
        let squash = CAKeyframeAnimation(keyPath: "transform.scale")
        squash.values = [1, 0.78, 1.12, 1]
        squash.keyTimes = [0, 0.3, 0.7, 1]
        squash.duration = 0.3
        foot.add(squash, forKey: "stomp")

        let r: CGFloat = 22
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = CGPoint(x: p.x + 6, y: p.y - 14)
        ring.fillColor = nil
        ring.strokeColor = FOOT_GREEN.cgColor
        ring.lineWidth = 3
        ring.lineDashPattern = [6, 5]                  // gespritzt statt glatt
        ring.opacity = 0
        root.insertSublayer(ring, below: foot)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.55
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(g, forKey: "splash")
        CATransaction.commit()
    }
}
