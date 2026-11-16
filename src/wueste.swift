// Design "Wüstenplanet ✦" – dezent, futuristisch, Sand & Gewürz.
// Zeiger: feines HUD-Visier (Raute in der Mitte = Klickpunkt, dünner Ring, drei kreisende Bogensegmente).
// Bewegung: feiner Sand rieselt hinter der Maus und weht im Wind davon.
// Stillstand: die Raute glimmt in Gewürz-Blau.
// Klick: "Thumper" – drei feine Ringe laufen als Schwingung nach außen.

import Cocoa

let SAND_GOLD = NSColor(srgbRed: 0.89, green: 0.72, blue: 0.40, alpha: 1)
let SAND_DEEP = NSColor(srgbRed: 0.71, green: 0.42, blue: 0.18, alpha: 1)
let SPICE_BLUE = NSColor(srgbRed: 0.31, green: 0.64, blue: 1.0, alpha: 1)
let NEON_CORE = NSColor(srgbRed: 0.30, green: 0.04, blue: 0.55, alpha: 1)    // Mitte: dunkles Lila
let NEON_EDGE = NSColor(srgbRed: 0.78, green: 0.35, blue: 1.0, alpha: 1)     // heller Neon-Rand
let NEON_GLOW = NSColor(srgbRed: 0.62, green: 0.15, blue: 1.0, alpha: 1)     // violettes Leuchten
let DESERT_IDLE_AFTER: Double = 1.5     // Sekunden Stillstand, bis die Raute blau glimmt

final class DesertFX {
    let root = CALayer()
    let sand = CAEmitterLayer()
    let visor = CALayer()                // dreht/skaliert als Ganzes, Mitte = Klickpunkt
    let diamond = CAShapeLayer()
    let ring = CAShapeLayer()
    let arcs = CAShapeLayer()
    let spice = CALayer()                // blaues Glimmen im Stillstand
    var lastMouse: CGPoint?
    var lastTime = CACurrentMediaTime()
    var lastMove = CACurrentMediaTime()
    var speed: CGFloat = 0
    var arcAngle: CGFloat = 0
    var wasPressed = false
    var clicks = true

    init() {
        let still: [String: CAAction] = ["position": NSNull(), "transform": NSNull(), "hidden": NSNull(),
                                         "opacity": NSNull(), "emitterPosition": NSNull(), "birthRate": NSNull(),
                                         "shadowRadius": NSNull(), "fillColor": NSNull(), "shadowColor": NSNull(),
                                         "strokeColor": NSNull()]
        // Sand: winzige Körner, die vom Wind nach rechts getragen werden und absinken
        let grain = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill(); return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
        var cells: [CAEmitterCell] = []
        for c in [SAND_GOLD, SAND_DEEP, SAND_GOLD.blended(withFraction: 0.4, of: .white)!] {
            let cell = CAEmitterCell()
            cell.contents = grain
            cell.color = c.cgColor
            cell.birthRate = 30
            cell.lifetime = 1.3
            cell.lifetimeRange = 0.5
            cell.velocity = 22
            cell.velocityRange = 14
            cell.emissionRange = .pi * 2
            cell.xAcceleration = 55               // Wind
            cell.yAcceleration = -28              // sinkt ab
            cell.scale = 0.22
            cell.scaleRange = 0.1
            cell.alphaSpeed = -0.75
            cells.append(cell)
        }
        sand.emitterCells = cells
        sand.emitterShape = .point
        sand.birthRate = 0

        spice.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        spice.cornerRadius = 20
        spice.backgroundColor = SPICE_BLUE.withAlphaComponent(0.25).cgColor
        spice.shadowColor = SPICE_BLUE.cgColor
        spice.shadowOpacity = 1
        spice.shadowRadius = 12
        spice.shadowOffset = .zero
        spice.opacity = 0

        // Raute (Klickpunkt)
        let d: CGFloat = 4.5
        let dp = CGMutablePath()
        dp.move(to: CGPoint(x: 0, y: d)); dp.addLine(to: CGPoint(x: d, y: 0))
        dp.addLine(to: CGPoint(x: 0, y: -d)); dp.addLine(to: CGPoint(x: -d, y: 0)); dp.closeSubpath()
        diamond.path = dp
        diamond.fillColor = NEON_CORE.cgColor     // Mitte: dunkles Lila-Neon
        diamond.strokeColor = NEON_EDGE.cgColor
        diamond.lineWidth = 1.2
        diamond.lineJoin = .round
        diamond.shadowColor = NEON_GLOW.cgColor
        diamond.shadowOpacity = 1
        diamond.shadowRadius = 6
        diamond.shadowOffset = .zero
        // dünner Ring
        ring.path = CGPath(ellipseIn: CGRect(x: -11, y: -11, width: 22, height: 22), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = SAND_GOLD.withAlphaComponent(0.75).cgColor
        ring.lineWidth = 1
        // drei Bogensegmente + kleine Markierungen
        let ap = CGMutablePath()
        for i in 0..<3 {
            let a0 = CGFloat(i) * 2 * .pi / 3
            ap.addArc(center: .zero, radius: 18, startAngle: a0, endAngle: a0 + .pi / 3, clockwise: false)
            ap.move(to: CGPoint(x: cos(a0 + .pi / 2) * 15.5, y: sin(a0 + .pi / 2) * 15.5))
            ap.addLine(to: CGPoint(x: cos(a0 + .pi / 2) * 20.5, y: sin(a0 + .pi / 2) * 20.5))
        }
        arcs.path = ap
        arcs.fillColor = nil
        arcs.strokeColor = SAND_GOLD.withAlphaComponent(0.85).cgColor
        arcs.lineWidth = 1.4
        arcs.lineCap = .round
        for l in [ring, arcs] {                    // feiner dunkler Rand: auch auf hellen Folien sichtbar
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.45
            l.shadowRadius = 1
            l.shadowOffset = .zero
        }
        visor.addSublayer(spice)
        visor.addSublayer(ring)
        visor.addSublayer(arcs)
        visor.addSublayer(diamond)
        root.addSublayer(sand)
        root.addSublayer(visor)
        for l in [root, sand, visor, diamond, ring, arcs, spice] as [CALayer] { l.actions = still }
        root.isHidden = true
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        lastMouse = nil
    }

    func update(mouse: CGPoint) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - lastTime))
        lastTime = now
        if let lm = lastMouse, dt > 0 {
            let v = hypot(mouse.x - lm.x, mouse.y - lm.y) / dt
            speed += (v - speed) * min(1, dt * 10)
            if v > 5 { lastMove = now }
        }
        lastMouse = mouse
        let idle = now - lastMove
        let t = CGFloat(now)
        arcAngle += dt * (0.35 + min(3, speed / 400))            // dreht schneller, wenn die Maus fliegt
        let widen = 1 + min(0.3, speed / 3000)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        visor.position = mouse
        arcs.transform = CATransform3DConcat(CATransform3DMakeRotation(arcAngle, 0, 0, 1), CATransform3DMakeScale(widen, widen, 1))
        ring.transform = CATransform3DMakeScale(1 / widen, 1 / widen, 1)
        sand.emitterPosition = mouse
        sand.birthRate = Float(min(1, speed / 600))              // nur bei Bewegung, ein Hauch
        // Gewürz-Glimmen im Stillstand
        let glowIn = Float(max(0, min(1, (idle - DESERT_IDLE_AFTER) * 1.5)))
        let pulse = Float(0.55 + 0.45 * sin(t * 2.2))
        spice.opacity = glowIn * pulse
        // Neon flackert leicht wie eine Röhre; im Stillstand leuchtet es stärker
        let flicker = 0.85 + 0.15 * sin(t * 13) * sin(t * 7.3) + (Int(t * 30) % 47 == 0 ? -0.35 : 0)
        diamond.shadowRadius = (6 + 4 * CGFloat(glowIn) * CGFloat(pulse)) * flicker
        diamond.opacity = Float(min(1, 0.75 + 0.25 * flicker))
        CATransaction.commit()

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { thump(at: mouse) }
        wasPressed = pressed
    }

    /// "Thumper": drei feine Ringe laufen nacheinander nach außen.
    func thump(at p: CGPoint) {
        lastMove = CACurrentMediaTime()
        for i in 0..<3 {
            let r: CGFloat = 20
            let l = CAShapeLayer()
            l.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
            l.position = p
            l.fillColor = nil
            l.strokeColor = (i == 1 ? SPICE_BLUE : SAND_GOLD).withAlphaComponent(0.9).cgColor
            l.lineWidth = 1.2
            l.opacity = 0
            root.insertSublayer(l, below: visor)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.5
            grow.toValue = 3.2
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0]
            fade.keyTimes = [0, 0.15, 1]
            let w = CABasicAnimation(keyPath: "lineWidth")
            w.fromValue = 1.6
            w.toValue = 0.4
            let g = CAAnimationGroup()
            g.animations = [grow, fade, w]
            g.duration = 1.1
            g.beginTime = CACurrentMediaTime() + 0.13 * Double(i)
            g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            l.add(g, forKey: "thump")
            CATransaction.commit()
        }
        let tap = CAKeyframeAnimation(keyPath: "transform.scale")   // Visier zuckt kurz zusammen
        tap.values = [1, 0.8, 1.05, 1]
        tap.duration = 0.25
        visor.add(tap, forKey: "tap")
    }
}
