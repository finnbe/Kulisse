// Design "Yuzu Onsen ♨" – passend zum Live-Hintergrund Yuzu Onsen: gemalt, warm, ruhig.
// Zwei Zeiger:
//   normal     – Pfeil in Elfenbein mit Tusche-Kontur (wie die Teeschale im Bild), eine Kirschblüte am Flügel.
//                Klickpunkt = Pfeilspitze.
//   klickbar   – überall, wo macOS die Link-Hand zeigen würde: eine Yuzu mit Blatt, warmem Laternenschein und
//                feinem Dampf. Klickpunkt = Mitte der Yuzu. Wechsel mit kleinem Federn.
// Bewegung: ab und zu löst sich ein Kirschblütenblatt und segelt davon.
// Klick: Wasserringe laufen nach außen (flach, wie auf der Wasserfläche des Onsen).

import Cocoa

let YUZU_INK = NSColor(srgbRed: 0.17, green: 0.16, blue: 0.20, alpha: 1)        // Tusche-Kontur
let YUZU_IVORY = NSColor(srgbRed: 0.97, green: 0.94, blue: 0.85, alpha: 1)      // Teeschale
let YUZU_YELLOW = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.22, alpha: 1)
let YUZU_DEEP = NSColor(srgbRed: 0.96, green: 0.66, blue: 0.08, alpha: 1)
let YUZU_LEAF = NSColor(srgbRed: 0.26, green: 0.52, blue: 0.20, alpha: 1)
let YUZU_SAKURA = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.80, alpha: 1)
let YUZU_SAKURA_DEEP = NSColor(srgbRed: 0.88, green: 0.42, blue: 0.56, alpha: 1)
let YUZU_LANTERN = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.25, alpha: 1)     // Laternenschein
let YUZU_WATER = NSColor(srgbRed: 0.62, green: 0.90, blue: 0.95, alpha: 1)

final class YuzuFX {
    let root = CALayer()
    let arrow = CALayer()                 // Pfeil + Blüte, Ursprung = Pfeilspitze
    let fruit = CALayer()                 // Yuzu, Ursprung = Mitte
    let steam = CALayer()                 // Dampf über der Yuzu
    let petals = CAEmitterLayer()
    var overLink = false
    var clicks = true
    private var shownLink: Bool?
    private var lastMouse: CGPoint?
    private var lastTime = CACurrentMediaTime()
    private var speed: CGFloat = 0
    private var wasPressed = false

    init() {
        let still: [String: CAAction] = ["position": NSNull(), "transform": NSNull(), "hidden": NSNull(),
                                         "opacity": NSNull(), "emitterPosition": NSNull(), "birthRate": NSNull(),
                                         "shadowOpacity": NSNull(), "shadowRadius": NSNull()]
        buildArrow()
        buildFruit()
        // Kirschblütenblätter, die sich beim Bewegen lösen
        let cell = CAEmitterCell()
        cell.contents = YuzuFX.petalImage()
        cell.birthRate = 6
        cell.lifetime = 2.2
        cell.lifetimeRange = 0.6
        cell.velocity = 18
        cell.velocityRange = 10
        cell.emissionRange = .pi * 2
        cell.yAcceleration = -26                  // sinkt langsam
        cell.xAcceleration = 8                    // leichter Wind
        cell.spin = 1.4
        cell.spinRange = 2.5
        cell.scale = 0.42
        cell.scaleRange = 0.12
        cell.alphaSpeed = -0.4
        petals.emitterCells = [cell]
        petals.emitterShape = .point
        petals.birthRate = 0
        root.addSublayer(petals)
        root.addSublayer(arrow)
        root.addSublayer(fruit)
        for l in [root, arrow, fruit, steam, petals] as [CALayer] { l.actions = still }
        fruit.opacity = 0
        root.isHidden = true
    }

    // ---------- Aufbau ----------
    private func buildArrow() {
        // klassische Pfeilform (Spitze im Ursprung, Fenster-Koordinaten: y nach oben), etwas größer als der Mac-Pfeil
        let k: CGFloat = 1.3
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 17.5), (4.1, 13.6), (6.9, 20.0), (9.6, 18.9), (6.9, 12.6), (12.4, 12.4)]
        let p = CGMutablePath()
        p.move(to: CGPoint(x: pts[0].0 * k, y: -pts[0].1 * k))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0 * k, y: -q.1 * k)) }
        p.closeSubpath()
        let body = CAShapeLayer()
        body.path = p
        body.fillColor = YUZU_IVORY.cgColor
        body.strokeColor = YUZU_INK.cgColor
        body.lineWidth = 1.6
        body.lineJoin = .round
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.35
        body.shadowRadius = 2
        body.shadowOffset = CGSize(width: 1, height: -1.5)
        // warmer Schimmer auf der linken Kante (gemalter Look)
        let sheen = CAShapeLayer()
        let s = CGMutablePath()
        s.move(to: CGPoint(x: 1.6, y: -3.5)); s.addLine(to: CGPoint(x: 1.6, y: -17 * k * 0.86))
        sheen.path = s
        sheen.strokeColor = NSColor(srgbRed: 1, green: 0.86, blue: 0.62, alpha: 0.8).cgColor
        sheen.lineWidth = 1.3
        sheen.lineCap = .round
        arrow.addSublayer(body)
        arrow.addSublayer(sheen)
        // Kirschblüte am Flügel
        let blossom = CALayer()
        blossom.contents = YuzuFX.blossomImage()
        blossom.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        blossom.position = CGPoint(x: 12.4 * k + 0.5, y: -12.4 * k - 0.5)
        blossom.shadowColor = NSColor.black.cgColor
        blossom.shadowOpacity = 0.3
        blossom.shadowRadius = 1
        blossom.shadowOffset = CGSize(width: 0.5, height: -0.5)
        arrow.addSublayer(blossom)
    }

    private func buildFruit() {
        let img = YuzuFX.yuzuImage()
        let y = CALayer()
        y.contents = img
        y.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        y.position = CGPoint(x: 1.5, y: 1.5)            // Bild hat oben rechts das Blatt -> Frucht genau auf der Mitte
        // Laternenschein (pulsiert sanft)
        let glow = CALayer()
        glow.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        glow.cornerRadius = 13
        glow.backgroundColor = YUZU_LANTERN.withAlphaComponent(0.22).cgColor
        glow.shadowColor = YUZU_LANTERN.cgColor
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 11
        glow.shadowOffset = .zero
        let pulse = CABasicAnimation(keyPath: "shadowRadius")
        pulse.fromValue = 8; pulse.toValue = 14
        pulse.duration = 1.4; pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "pulse")
        // Dampf: zwei feine Schwaden steigen über der Yuzu auf
        for i in 0..<2 {
            let w = CAShapeLayer()
            let p = CGMutablePath()
            p.move(to: .zero)
            p.addCurve(to: CGPoint(x: 0, y: 16), control1: CGPoint(x: 5, y: 5), control2: CGPoint(x: -5, y: 11))
            w.path = p
            w.fillColor = nil
            w.strokeColor = NSColor(white: 1, alpha: 0.85).cgColor
            w.lineWidth = 1.6
            w.lineCap = .round
            w.shadowColor = YUZU_INK.cgColor
            w.shadowOpacity = 0.35
            w.shadowRadius = 0.8
            w.shadowOffset = .zero
            w.position = CGPoint(x: CGFloat(i) * 8 - 4, y: 15)
            w.opacity = 0
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = 13; rise.toValue = 22
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0]; fade.keyTimes = [0, 0.35, 1]
            let g = CAAnimationGroup()
            g.animations = [rise, fade]
            g.duration = 1.8
            g.repeatCount = .infinity
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.9
            w.add(g, forKey: "steam")
            steam.addSublayer(w)
        }
        fruit.addSublayer(glow)
        fruit.addSublayer(steam)
        fruit.addSublayer(y)
    }

    // ---------- Bilder (einmal gemalt) ----------
    static func yuzuImage() -> CGImage? {
        NSImage(size: NSSize(width: 68, height: 68), flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 2, y: 2)
            let ctr = CGPoint(x: 15.5, y: 15.5), r: CGFloat = 11.5
            // Frucht: runder Farbverlauf, Licht von links oben
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor(srgbRed: 1, green: 0.95, blue: 0.55, alpha: 1).cgColor,
                                           YUZU_YELLOW.cgColor, YUZU_DEEP.cgColor] as CFArray,
                                  locations: [0, 0.45, 1])!
            c.saveGState()
            c.addEllipse(in: CGRect(x: ctr.x - r, y: ctr.y - r, width: 2 * r, height: 2 * r))
            c.clip()
            c.drawRadialGradient(grad, startCenter: CGPoint(x: ctr.x - 4, y: ctr.y + 4), startRadius: 0,
                                 endCenter: ctr, endRadius: r * 1.1, options: [.drawsAfterEndLocation])
            // Poren
            c.setFillColor(NSColor(srgbRed: 0.85, green: 0.55, blue: 0.05, alpha: 0.35).cgColor)
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<26 {
                let a = CGFloat.random(in: 0...(2 * .pi), using: &rng), d = CGFloat.random(in: 2...(r - 1), using: &rng)
                c.fillEllipse(in: CGRect(x: ctr.x + cos(a) * d - 0.5, y: ctr.y + sin(a) * d - 0.5, width: 1, height: 1))
            }
            // Glanzpunkt
            c.setFillColor(NSColor(white: 1, alpha: 0.8).cgColor)
            c.fillEllipse(in: CGRect(x: ctr.x - 6.5, y: ctr.y + 3, width: 4.5, height: 3))
            c.restoreGState()
            // Kontur
            c.setStrokeColor(YUZU_INK.cgColor)
            c.setLineWidth(1.4)
            c.strokeEllipse(in: CGRect(x: ctr.x - r, y: ctr.y - r, width: 2 * r, height: 2 * r))
            // Stiel und Blatt oben rechts
            c.setFillColor(YUZU_INK.cgColor)
            c.fillEllipse(in: CGRect(x: ctr.x + 2.5, y: ctr.y + r - 2.2, width: 2.6, height: 2.6))
            c.saveGState()
            c.translateBy(x: ctr.x + 8, y: ctr.y + r + 0.5)
            c.rotate(by: 0.5)
            let leaf = CGMutablePath()
            leaf.move(to: CGPoint(x: -6, y: 0))
            leaf.addQuadCurve(to: CGPoint(x: 6, y: 0), control: CGPoint(x: 0, y: 5.5))
            leaf.addQuadCurve(to: CGPoint(x: -6, y: 0), control: CGPoint(x: 0, y: -5.5))
            c.addPath(leaf)
            c.setFillColor(YUZU_LEAF.cgColor)
            c.fillPath()
            c.addPath(leaf)
            c.setStrokeColor(YUZU_INK.cgColor)
            c.setLineWidth(1.1)
            c.strokePath()
            c.move(to: CGPoint(x: -5, y: 0)); c.addLine(to: CGPoint(x: 4.5, y: 0))
            c.setStrokeColor(NSColor(srgbRed: 0.55, green: 0.78, blue: 0.4, alpha: 1).cgColor)
            c.setLineWidth(0.7)
            c.strokePath()
            c.restoreGState()
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func blossomImage() -> CGImage? {
        NSImage(size: NSSize(width: 26, height: 26), flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 2, y: 2)
            c.translateBy(x: 6.5, y: 6.5)
            for i in 0..<5 {
                c.saveGState()
                c.rotate(by: CGFloat(i) * 2 * .pi / 5 + 0.3)
                let p = CGMutablePath()                      // Blütenblatt mit Kerbe
                p.move(to: .zero)
                p.addCurve(to: CGPoint(x: -0.9, y: 5.6), control1: CGPoint(x: -3.2, y: 1.8), control2: CGPoint(x: -3, y: 5.2))
                p.addLine(to: CGPoint(x: 0, y: 4.7))
                p.addLine(to: CGPoint(x: 0.9, y: 5.6))
                p.addCurve(to: .zero, control1: CGPoint(x: 3, y: 5.2), control2: CGPoint(x: 3.2, y: 1.8))
                c.addPath(p)
                c.setFillColor(YUZU_SAKURA.cgColor)
                c.fillPath()
                c.addPath(p)
                c.setStrokeColor(YUZU_SAKURA_DEEP.cgColor)
                c.setLineWidth(0.6)
                c.strokePath()
                c.restoreGState()
            }
            c.setFillColor(YUZU_SAKURA_DEEP.cgColor)
            c.fillEllipse(in: CGRect(x: -1.3, y: -1.3, width: 2.6, height: 2.6))
            c.setFillColor(NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1).cgColor)
            c.fillEllipse(in: CGRect(x: -0.6, y: -0.6, width: 1.2, height: 1.2))
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func petalImage() -> CGImage? {
        NSImage(size: NSSize(width: 20, height: 24), flipped: false) { r in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 10, y: 2))
            p.curve(to: NSPoint(x: 7.5, y: 22), controlPoint1: NSPoint(x: 1, y: 8), controlPoint2: NSPoint(x: 2, y: 20))
            p.line(to: NSPoint(x: 10, y: 19))
            p.line(to: NSPoint(x: 12.5, y: 22))
            p.curve(to: NSPoint(x: 10, y: 2), controlPoint1: NSPoint(x: 18, y: 20), controlPoint2: NSPoint(x: 19, y: 8))
            YUZU_SAKURA.setFill(); p.fill()
            YUZU_SAKURA_DEEP.withAlphaComponent(0.7).setStroke(); p.lineWidth = 1; p.stroke()
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // ---------- Laufzeit ----------
    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        lastMouse = nil
        shownLink = nil
    }

    func update(mouse: CGPoint) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - lastTime))
        lastTime = now
        if let lm = lastMouse, dt > 0 {
            let v = hypot(mouse.x - lm.x, mouse.y - lm.y) / dt
            speed += (v - speed) * min(1, dt * 10)
        }
        lastMouse = mouse
        if shownLink != overLink { switchLook(toLink: overLink, animated: shownLink != nil) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.position = mouse
        fruit.position = mouse
        petals.emitterPosition = CGPoint(x: mouse.x + 14, y: mouse.y - 14)
        petals.birthRate = overLink ? 0 : Float(min(1, max(0, speed - 250) / 900))   // nur bei schneller Bewegung
        CATransaction.commit()

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { ripple(at: mouse) }
        wasPressed = pressed
    }

    /// Pfeil <-> Yuzu: kurz überblenden, die Yuzu federt beim Erscheinen
    func switchLook(toLink link: Bool, animated: Bool) {
        shownLink = link
        let (show, hide) = link ? (fruit, arrow) : (arrow, fruit)
        show.opacity = 1
        hide.opacity = 0
        guard animated else { return }
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0; fadeIn.toValue = 1; fadeIn.duration = 0.12
        show.add(fadeIn, forKey: "fade")
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = link ? 0.45 : 0.75
        pop.toValue = 1
        pop.damping = 11
        pop.stiffness = 260
        pop.duration = pop.settlingDuration
        show.add(pop, forKey: "pop")
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1; fadeOut.toValue = 0; fadeOut.duration = 0.1
        hide.add(fadeOut, forKey: "fade")
    }

    /// Klick: zwei flache Wasserringe laufen nach außen, die Yuzu/der Pfeil tippt kurz ein
    func ripple(at p: CGPoint) {
        for i in 0..<2 {
            let r: CGFloat = 14
            let l = CAShapeLayer()
            l.path = CGPath(ellipseIn: CGRect(x: -r, y: -r * 0.55, width: 2 * r, height: 2 * r * 0.55), transform: nil)
            l.position = p
            l.fillColor = nil
            l.strokeColor = (i == 0 ? YUZU_WATER : NSColor.white).withAlphaComponent(0.95).cgColor
            l.lineWidth = 1.6
            l.shadowColor = YUZU_INK.cgColor
            l.shadowOpacity = 0.5
            l.shadowRadius = 1
            l.shadowOffset = .zero
            l.opacity = 0
            root.insertSublayer(l, below: arrow)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4; grow.toValue = 3.0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0]; fade.keyTimes = [0, 0.12, 1]
            let w = CABasicAnimation(keyPath: "lineWidth")
            w.fromValue = 2.2; w.toValue = 0.5
            let g = CAAnimationGroup()
            g.animations = [grow, fade, w]
            g.duration = 0.95
            g.beginTime = CACurrentMediaTime() + 0.16 * Double(i)
            g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            l.add(g, forKey: "ripple")
            CATransaction.commit()
        }
        let tap = CAKeyframeAnimation(keyPath: "transform.scale")
        tap.values = [1, 0.82, 1.06, 1]
        tap.duration = 0.25
        (overLink ? fruit : arrow).add(tap, forKey: "tap")
    }
}
