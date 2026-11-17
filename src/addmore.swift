// addmore-Design: Laserpointer in addmore-Orange.
// Die Maus ist ein leuchtender oranger Punkt mit weißem "+" (add more), dahinter ein kurzer
// Leuchtschweif, damit das Publikum der Bewegung folgen kann. Jeder Klick schickt Ringe nach außen.
//
// Außerdem hier: der Strich im Zeichenmodus je nach Design (strokeStyle / PawStamper).

import Cocoa

let ADDMORE_ORANGE = NSColor(srgbRed: 0xF3 / 255.0, green: 0x6D / 255.0, blue: 0x03 / 255.0, alpha: 1)
let LASER_DOT: CGFloat = 9          // Radius des Laserpunkts, in Punkten
let LASER_TRAIL: Double = 0.35      // so viele Sekunden lang ist der Leuchtschweif

final class LaserFX {
    let root = CALayer()
    let dot = CALayer()
    let plus = CAShapeLayer()
    let segments = (0..<40).map { _ in CAShapeLayer() }
    var history: [(p: CGPoint, t: Double)] = []
    var wasPressed = false
    var clicks = true

    init() {
        let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
                                         "opacity": NSNull(), "lineWidth": NSNull(), "hidden": NSNull()]
        for s in segments {
            s.strokeColor = ADDMORE_ORANGE.cgColor
            s.lineCap = .round
            s.fillColor = nil
            s.actions = still
            root.addSublayer(s)
        }
        dot.bounds = CGRect(x: 0, y: 0, width: LASER_DOT * 2, height: LASER_DOT * 2)
        dot.cornerRadius = LASER_DOT
        dot.backgroundColor = ADDMORE_ORANGE.cgColor
        dot.borderColor = NSColor(srgbRed: 1, green: 0.8, blue: 0.55, alpha: 1).cgColor
        dot.borderWidth = 1.5
        dot.shadowColor = ADDMORE_ORANGE.cgColor
        dot.shadowOpacity = 1
        dot.shadowRadius = 12
        dot.shadowOffset = .zero
        let pp = CGMutablePath()                         // weißes Plus in der Mitte
        let k = LASER_DOT * 0.5
        pp.move(to: CGPoint(x: LASER_DOT - k, y: LASER_DOT)); pp.addLine(to: CGPoint(x: LASER_DOT + k, y: LASER_DOT))
        pp.move(to: CGPoint(x: LASER_DOT, y: LASER_DOT - k)); pp.addLine(to: CGPoint(x: LASER_DOT, y: LASER_DOT + k))
        plus.path = pp
        plus.strokeColor = NSColor.white.cgColor
        plus.lineWidth = 2.2
        plus.lineCap = .round
        plus.frame = dot.bounds
        dot.addSublayer(plus)
        root.addSublayer(dot)
        for l in [root, dot] { l.actions = still }
        root.isHidden = true
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        if !v { history = [] }
    }

    func update(mouse: CGPoint) {
        let now = CACurrentMediaTime()
        if history.last?.p != mouse { history.append((mouse, now)) }
        history.removeAll { now - $0.t > LASER_TRAIL }
        if history.isEmpty || history.last!.p != mouse { history.append((mouse, now)) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = mouse
        // Schweif: jüngste Stücke dick und deckend, ältere dünn und blass
        let n = history.count
        for (i, s) in segments.enumerated() {
            let j = n - 2 - i                           // i = 0 ist das neueste Stück
            guard j >= 0 else { s.isHidden = true; continue }
            let a = history[j], b = history[j + 1]
            let age = CGFloat((now - a.t) / LASER_TRAIL)  // 0 = neu, 1 = gleich weg
            let path = CGMutablePath()
            path.move(to: a.p)
            path.addLine(to: b.p)
            s.path = path
            s.lineWidth = max(1, LASER_DOT * 1.4 * (1 - age))
            s.opacity = Float(0.85 * (1 - age))
            s.isHidden = false
        }
        CATransaction.commit()

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { ripple(at: mouse) }
        wasPressed = pressed
    }

    /// Zwei Ringe laufen vom Klickpunkt nach außen und verblassen.
    func ripple(at p: CGPoint) {
        for (i, delay) in [0.0, 0.12].enumerated() {
            let r: CGFloat = 26
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
            ring.position = p
            ring.fillColor = nil
            ring.strokeColor = ADDMORE_ORANGE.cgColor
            ring.lineWidth = i == 0 ? 3 : 2
            ring.opacity = 0
            root.insertSublayer(ring, below: dot)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.3
            grow.toValue = 2.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [grow, fade]
            g.duration = 0.65
            g.beginTime = CACurrentMediaTime() + delay
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            ring.add(g, forKey: "ripple")
            CATransaction.commit()
        }
    }
}

// ---------- Strich im Zeichenmodus, je nach Design ----------

/// Aussehen des Strichs. Die Waschbär-Designs zeichnen keine Linie, sondern Pfotenabdrücke (PawStamper).
func strokeStyle(_ l: CAShapeLayer, theme: Theme) {
    l.fillColor = nil
    l.lineCap = .round
    l.lineJoin = .round
    l.shadowOffset = .zero
    switch theme {
    case .zeigestock, .halter:                          // Neon-Orange: helle Linie mit kräftigem Leuchten
        let neon = NSColor(srgbRed: 1, green: 0.45, blue: 0.05, alpha: 1)
        l.strokeColor = neon.blended(withFraction: 0.25, of: NSColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 1))!.cgColor
        l.lineWidth = DRAW_WIDTH
        l.shadowColor = neon.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 9
    case .waschbaer:                                    // Pfotenspur: Linie selbst unsichtbar
        l.strokeColor = nil
    case .halloween:                                    // giftgrüner, leuchtender Schleim
        let slime = NSColor(srgbRed: 0.45, green: 1, blue: 0.1, alpha: 1)
        l.strokeColor = slime.cgColor
        l.lineWidth = 8
        l.shadowColor = slime.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 10
    case .spinne:                                       // Spinnenfaden: dünn, weiß, dunkler Rand
        l.strokeColor = NSColor(white: 1, alpha: 0.95).cgColor
        l.lineWidth = 2.5
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.9
        l.shadowRadius = 1.3
    case .ente:                                         // Teich-Blau mit sanftem Schimmer
        let water = NSColor(srgbRed: 0.15, green: 0.6, blue: 0.95, alpha: 1)
        l.strokeColor = water.cgColor
        l.lineWidth = 7
        l.shadowColor = water.cgColor
        l.shadowOpacity = 0.7
        l.shadowRadius = 6
    case .peitsche:                                     // Peitsche zeichnet nicht, sie knallt nur
        l.strokeColor = nil
    case .yuzu:                                         // Yuzu-Gelb mit warmem Laternenschein
        l.strokeColor = YUZU_YELLOW.cgColor
        l.lineWidth = 6
        l.shadowColor = YUZU_LANTERN.cgColor
        l.shadowOpacity = 0.9
        l.shadowRadius = 6
    case .wueste:                                       // feine goldene Linie mit warmem Schimmer
        l.strokeColor = SAND_GOLD.cgColor
        l.lineWidth = 2.5
        l.shadowColor = SAND_DEEP.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 5
    case .ufo:                                          // Kuhflecken: schwarz gestrichelt mit weißem Rand
        l.strokeColor = NSColor.black.cgColor
        l.lineWidth = 9
        l.lineDashPattern = [14, 9, 6, 11]
        l.shadowColor = NSColor.white.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 3
    case .skelett:                                      // schwarzer Knochen-Strich mit Leuchtrand
        l.strokeColor = SK_BONE.cgColor
        l.lineWidth = 6
        l.shadowColor = SK_DEFAULT_GLOW.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 3
    case .fuesse:                                       // Fußspur zeichnet FootStamper (src/fuesse.swift)
        l.strokeColor = nil
    case .zug:                                          // Schienen zeichnet TrainTrack (src/zug.swift)
        l.strokeColor = nil
    case .addmore:                                      // Textmarker in addmore-Orange, halbdurchsichtig
        l.strokeColor = ADDMORE_ORANGE.withAlphaComponent(0.42).cgColor
        l.lineWidth = 22
        l.lineCap = .square
        l.shadowOpacity = 0
    }
}

/// Setzt entlang des Strichs abwechselnd links/rechts Pfotenabdrücke, in Laufrichtung gedreht.
final class PawStamper {
    let paw: (CGImage, CGSize)
    let spacing: CGFloat = 26
    var last: CGPoint
    var dist: CGFloat = 0
    var left = true

    init(start: CGPoint, into layer: CALayer, emoji: String = "🐾") {
        paw = emojiImage(emoji, size: 20)
        last = start
        stamp(at: start, angle: .pi / 2, into: layer)
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

    private func stamp(at p: CGPoint, angle: CGFloat, into layer: CALayer) {
        let side: CGFloat = left ? 7 : -7                // abwechselnd links/rechts der Laufrichtung
        left.toggle()
        let l = CALayer()
        l.contents = paw.0
        l.bounds = CGRect(origin: .zero, size: paw.1)
        l.position = CGPoint(x: p.x - sin(angle) * side, y: p.y + cos(angle) * side)
        l.transform = CATransform3DMakeRotation(angle - .pi / 4, 0, 0, 1)   // 🐾 zeigt nach oben rechts
        l.shadowColor = NSColor.white.cgColor            // heller Rand: auch auf dunklen Folien sichtbar
        l.shadowOpacity = 0.8
        l.shadowRadius = 1.5
        l.shadowOffset = .zero
        l.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        layer.addSublayer(l)
    }
}
