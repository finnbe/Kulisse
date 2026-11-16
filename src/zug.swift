// Zug-Design.
// Zeiger: eine kleine Dampflok, die beim Bewegen dampft.
// Zeichenmodus: der Strich wird zu Schienen mit Schwellen; TRAIN_DELAY Sekunden später fährt ein Zug
// (Lok + Waggons) die Strecke im selben Tempo nach, in dem sie gemalt wurde.

import Cocoa

let TRAIN_DELAY: Double = 1.0       // Verzögerung, mit der der Zug hinterherfährt
let TRAIN_GAUGE: CGFloat = 5        // halber Schienenabstand, in Punkten
let TRAIN_CAR_GAP: CGFloat = 30     // Abstand der Waggons entlang der Strecke
let TRAIN_WAGONS = 2

/// Emoji-Fahrzeug von der Seite so drehen, dass es in Fahrtrichtung zeigt und nie auf dem Kopf steht.
/// Apples 🚂 schaut nach links; facesLeft = true heißt: Bild zeigt von Haus aus nach links.
func vehicleTransform(angle: CGFloat, facesLeft: Bool = true) -> CATransform3D {
    if cos(angle) >= 0 {            // fährt nach rechts: spiegeln, dann neigen
        let flip = facesLeft ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        return CATransform3DConcat(flip, CATransform3DMakeRotation(angle, 0, 0, 1))
    } else {                        // fährt nach links: nur neigen
        let flip = facesLeft ? CATransform3DIdentity : CATransform3DMakeScale(-1, 1, 1)
        return CATransform3DConcat(flip, CATransform3DMakeRotation(angle - .pi, 0, 0, 1))
    }
}

/// Dampfwölkchen, das aufsteigt und verblasst.
func puff(at p: CGPoint, into layer: CALayer) {
    let r = CGFloat.random(in: 3...5)
    let l = CALayer()
    l.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
    l.cornerRadius = r
    l.backgroundColor = NSColor(white: 0.97, alpha: 0.9).cgColor
    l.borderColor = NSColor(white: 0.6, alpha: 0.5).cgColor
    l.borderWidth = 0.5
    l.position = p
    l.opacity = 0
    layer.addSublayer(l)
    let up = CABasicAnimation(keyPath: "position")
    up.fromValue = NSValue(point: p)
    up.toValue = NSValue(point: CGPoint(x: p.x + CGFloat.random(in: -8...8), y: p.y + CGFloat.random(in: 18...30)))
    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 0.6
    grow.toValue = 2.2
    let fade = CAKeyframeAnimation(keyPath: "opacity")
    fade.values = [0.9, 0.6, 0]
    let g = CAAnimationGroup()
    g.animations = [up, grow, fade]
    g.duration = 0.9
    CATransaction.begin()
    CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
    l.add(g, forKey: "puff")
    CATransaction.commit()
}

// ---------- Zeiger: kleine Lok ----------
final class TrainCursorFX {
    let root = CALayer()
    let loco = CALayer()
    var lastMouse: CGPoint?
    var angle: CGFloat = .pi           // schaut zu Beginn nach links
    var lastPuff = 0.0

    init() {
        let (img, sz) = emojiImage("🚂", size: 30)
        loco.contents = img
        loco.bounds = CGRect(origin: .zero, size: sz)
        loco.shadowColor = NSColor.black.cgColor
        loco.shadowOpacity = 0.3
        loco.shadowRadius = 2
        loco.shadowOffset = CGSize(width: 0, height: -1.5)
        root.addSublayer(loco)
        for l in [root, loco] { l.actions = ["position": NSNull(), "transform": NSNull(), "hidden": NSNull()] }
        root.isHidden = true
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        if !v { lastMouse = nil }
    }

    func update(mouse: CGPoint) {
        let now = CACurrentMediaTime()
        if let last = lastMouse, hypot(mouse.x - last.x, mouse.y - last.y) > 1.5 {
            // nur waagerechte Fahrtrichtung zählt, der Zeiger selbst bleibt gerade
            if abs(mouse.x - last.x) > 0.5 { angle = mouse.x > last.x ? 0 : .pi }
            if now - lastPuff > 0.12 {
                lastPuff = now
                let chimney = CGPoint(x: mouse.x + (angle == 0 ? 6 : -6), y: mouse.y + loco.bounds.height * 0.45)
                puff(at: chimney, into: root)
            }
        }
        lastMouse = mouse
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loco.position = mouse
        loco.transform = vehicleTransform(angle: angle)
        CATransaction.commit()
    }
}

// ---------- Zeichenmodus: Schienen + Zug ----------
final class TrainTrack {
    struct Sample { var p: CGPoint; var d: CGFloat; var t: Double }
    var samples: [Sample] = []
    let host: CALayer                  // der Strich-Layer: verblasst er, verblasst alles mit
    let sleepers = CAShapeLayer()
    let rails = CAShapeLayer()
    let sleeperPath = CGMutablePath()
    let leftRail = CGMutablePath()
    let rightRail = CGMutablePath()
    var nextSleeper: CGFloat = 0
    var cars: [CALayer] = []
    var lastPuff = 0.0
    var lastHead: CGFloat = -1

    init(start: CGPoint, into host: CALayer) {
        self.host = host
        let still: [String: CAAction] = ["path": NSNull(), "position": NSNull(), "transform": NSNull(), "hidden": NSNull()]
        sleepers.strokeColor = NSColor(srgbRed: 0.45, green: 0.3, blue: 0.18, alpha: 1).cgColor   // Holzschwellen
        sleepers.lineWidth = 3.5
        sleepers.lineCap = .round
        sleepers.fillColor = nil
        rails.strokeColor = NSColor(white: 0.35, alpha: 1).cgColor                                  // Stahlschienen
        rails.lineWidth = 2
        rails.lineJoin = .round
        rails.fillColor = nil
        rails.shadowColor = NSColor.white.cgColor          // heller Rand: auch auf dunklen Folien sichtbar
        rails.shadowOpacity = 0.6
        rails.shadowRadius = 1
        rails.shadowOffset = .zero
        for l in [sleepers, rails] as [CALayer] { l.actions = still; host.addSublayer(l) }
        let names = ["🚂"] + Array(repeating: "🚃", count: TRAIN_WAGONS)
        for n in names {
            let (img, sz) = emojiImage(n, size: 26)
            let c = CALayer()
            c.contents = img
            c.bounds = CGRect(origin: .zero, size: sz)
            c.isHidden = true
            c.actions = still
            c.shadowColor = NSColor.black.cgColor
            c.shadowOpacity = 0.3
            c.shadowRadius = 2
            c.shadowOffset = CGSize(width: 0, height: -1.5)
            cars.append(c)
        }
        for c in cars.reversed() { host.addSublayer(c) }   // Lok obenauf
        samples.append(Sample(p: start, d: 0, t: CACurrentMediaTime()))
    }

    var alive: Bool { host.superlayer != nil }

    /// Neuer Mauspunkt: in 3-Punkt-Schritten abtasten, Schienen und Schwellen verlängern.
    func add(_ p: CGPoint) {
        let now = CACurrentMediaTime()
        guard var last = samples.last else { return }
        var dist = hypot(p.x - last.p.x, p.y - last.p.y)
        guard dist >= 3 else { return }
        let ux = (p.x - last.p.x) / dist, uy = (p.y - last.p.y) / dist
        let nx = -uy * TRAIN_GAUGE, ny = ux * TRAIN_GAUGE
        if samples.count == 1 {                           // erster Abschnitt: Schienen hier beginnen
            leftRail.move(to: CGPoint(x: last.p.x + nx, y: last.p.y + ny))
            rightRail.move(to: CGPoint(x: last.p.x - nx, y: last.p.y - ny))
        }
        let t0 = last.t
        let totalSteps = dist
        while dist >= 3 {
            let q = CGPoint(x: last.p.x + ux * 3, y: last.p.y + uy * 3)
            let d = last.d + 3
            // Zeit gleichmäßig über das Stück verteilen -> Zug fährt so gleichmäßig, wie gemalt wurde
            let t = t0 + (now - t0) * Double((totalSteps - dist + 3) / totalSteps)
            last = Sample(p: q, d: d, t: t)
            samples.append(last)
            leftRail.addLine(to: CGPoint(x: q.x + nx, y: q.y + ny))
            rightRail.addLine(to: CGPoint(x: q.x - nx, y: q.y - ny))
            if d >= nextSleeper {
                let w: CGFloat = 1.8
                sleeperPath.move(to: CGPoint(x: q.x + nx * w, y: q.y + ny * w))
                sleeperPath.addLine(to: CGPoint(x: q.x - nx * w, y: q.y - ny * w))
                nextSleeper = d + 9
            }
            dist -= 3
        }
        let both = CGMutablePath()
        both.addPath(leftRail)
        both.addPath(rightRail)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rails.path = both
        sleepers.path = sleeperPath
        CATransaction.commit()
    }

    /// Strecke, die bis zum Zeitpunkt t gemalt war.
    func distance(at t: Double) -> CGFloat? {
        guard let first = samples.first, t >= first.t else { return nil }
        guard let i = samples.lastIndex(where: { $0.t <= t }) else { return nil }
        if i == samples.count - 1 { return samples[i].d }
        let a = samples[i], b = samples[i + 1]
        let f = b.t > a.t ? CGFloat((t - a.t) / (b.t - a.t)) : 1
        return a.d + (b.d - a.d) * f
    }

    /// Punkt und Richtung bei Streckenlänge d.
    func point(at d: CGFloat) -> (CGPoint, CGFloat) {
        let i = max(0, min(samples.count - 2, Int(d / 3)))
        let a = samples[i], b = samples[i + 1]
        let f = max(0, min(1, (d - a.d) / 3))
        let ang = atan2(b.p.y - a.p.y, b.p.x - a.p.x)
        return (CGPoint(x: a.p.x + (b.p.x - a.p.x) * f, y: a.p.y + (b.p.y - a.p.y) * f), ang)
    }

    func update() {
        guard samples.count >= 2, let head = distance(at: CACurrentMediaTime() - TRAIN_DELAY) else { return }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, c) in cars.enumerated() {
            let d = head - CGFloat(i) * TRAIN_CAR_GAP
            guard d >= 0 else { c.isHidden = true; continue }
            let (p, ang) = point(at: d)
            c.isHidden = false
            c.position = CGPoint(x: p.x, y: p.y + 6)       // Räder auf den Schienen
            c.transform = vehicleTransform(angle: ang)
        }
        CATransaction.commit()
        if head > lastHead + 0.5, now - lastPuff > 0.15, let loco = cars.first, !loco.isHidden {
            lastPuff = now
            puff(at: CGPoint(x: loco.position.x, y: loco.position.y + 12), into: host)
        }
        lastHead = head
    }

    /// Nur für die Vorschau: so tun, als sei die Strecke in den letzten `seconds` Sekunden gemalt worden.
    func pretendDrawn(over seconds: Double) {
        let now = CACurrentMediaTime(), total = max(1, samples.last?.d ?? 1)
        for i in samples.indices { samples[i].t = now - seconds + seconds * Double(samples[i].d / total) }
    }
}
