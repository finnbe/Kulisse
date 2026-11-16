// Design "Ente mit Küken".
// Zeiger: eine watschelnde Ente. Küken laufen im Gänsemarsch auf dem Weg der Maus hinterher.
// Steht die Maus still, schlafen die Küken nach DUCK_SLEEP_AFTER Sekunden ein (💤).
// Klick: "Quak!"-Sprechblase, die Küken hüpfen nacheinander hoch.
// Ab und zu taucht irgendwo ein 🥚 auf. Mit der Ente drüberfahren = einsammeln: es schlüpft ein Küken,
// das sich hinten in die Reihe einreiht.

import Cocoa

let DUCKLINGS = 3
let DUCKLING_GAP: CGFloat = 28       // Abstand im Gänsemarsch, in Punkten
let DUCK_SLEEP_AFTER: Double = 3     // Sekunden Stillstand, bis die Küken einschlafen
let EGG_EVERY: ClosedRange<Double> = 8...20   // so viele Sekunden bis zum nächsten Ei (zufällig)
let EGG_STAY: Double = 25            // nicht eingesammelte Eier verschwinden danach
let EGG_MAX = 2                      // höchstens so viele Eier gleichzeitig
let CHICKS_MAX = 40                  // mehr Küken passen nicht in die Reihe

/// Sprechblase mit Text als Bild.
func bubbleImage(_ text: String, tailRight: Bool = false) -> (CGImage, CGSize) {
    let scale: CGFloat = 3
    let font = NSFont.systemFont(ofSize: 15 * scale, weight: .heavy)
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    let ts = str.size()
    let pad = 9 * scale, tail = 9 * scale
    let size = CGSize(width: ts.width + 2 * pad, height: ts.height + pad + tail)
    let img = NSImage(size: size, flipped: false) { _ in
        let body = NSRect(x: 1.5 * scale, y: tail, width: size.width - 3 * scale, height: size.height - tail - 1.5 * scale)
        let p = NSBezierPath(roundedRect: body, xRadius: 12 * scale, yRadius: 12 * scale)
        // Spitze unten links (bzw. rechts): x-Werte bei tailRight spiegeln
        func mx(_ x: CGFloat) -> CGFloat { tailRight ? size.width - x : x }
        let t = NSBezierPath()
        t.move(to: NSPoint(x: mx(body.minX + 14 * scale), y: body.minY + 1))
        t.line(to: NSPoint(x: mx(body.minX + 6 * scale), y: 1.5 * scale))
        t.line(to: NSPoint(x: mx(body.minX + 26 * scale), y: body.minY + 1))
        p.append(t)
        NSColor.white.setFill(); p.fill()
        NSColor.black.setStroke(); p.lineWidth = 2 * scale; p.stroke()
        let gap = NSRect(x: body.minX + 14 * scale + 2, y: body.minY - 1, width: 11 * scale, height: 3 * scale)
        NSColor.white.setFill()
        NSRect(x: tailRight ? size.width - gap.maxX : gap.minX, y: gap.minY, width: gap.width, height: gap.height).fill()
        str.draw(at: NSPoint(x: pad, y: tail + pad * 0.4))
        return true
    }
    return (img.cgImage(forProposedRect: nil, context: nil, hints: nil)!, CGSize(width: size.width / scale, height: size.height / scale))
}

final class DuckFX {
    let root = CALayer()
    let duck = CALayer()
    var chicks: [CALayer] = []
    var zzz: [CALayer] = []
    var path: [(p: CGPoint, d: CGFloat)] = []       // Weg der Maus, alle 2 Punkte ein Eintrag
    var lastMove = CACurrentMediaTime()
    var facing: CGFloat = .pi                       // Ente schaut nach links (pi) oder rechts (0)
    var wasPressed = false
    var clicks = true
    var asleep = false
    let quak = bubbleImage("Quak!")
    let quakRight = bubbleImage("Quak!", tailRight: true)
    let piep = bubbleImage("Piep!")
    let chickImg = emojiImage("🐤", size: 23)
    let zzzImg = emojiImage("💤", size: 13)
    let eggImg = emojiImage("🥚", size: 26)
    let hatchImg = emojiImage("🐣", size: 30)
    let still: [String: CAAction] = ["position": NSNull(), "transform": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
    var eggs: [(layer: CALayer, born: Double)] = []
    var nextEgg = CACurrentMediaTime() + Double.random(in: EGG_EVERY)

    init() {
        for _ in 0..<DUCKLINGS { addChick() }
        let (img, sz) = emojiImage("🦆", size: 40)
        duck.contents = img
        duck.bounds = CGRect(origin: .zero, size: sz)
        duck.actions = still
        duck.shadowColor = NSColor.black.cgColor
        duck.shadowOpacity = 0.3
        duck.shadowRadius = 2
        duck.shadowOffset = CGSize(width: 0, height: -1.5)
        root.addSublayer(duck)
        root.actions = still
        root.isHidden = true
    }

    /// Neues Küken hinten an die Reihe (unter der Ente einsortiert).
    @discardableResult
    func addChick(at start: CGPoint? = nil) -> CALayer {
        let c = CALayer()
        c.contents = chickImg.0
        c.bounds = CGRect(origin: .zero, size: chickImg.1)
        c.actions = still
        c.shadowColor = NSColor.black.cgColor
        c.shadowOpacity = 0.25
        c.shadowRadius = 1.5
        c.shadowOffset = CGSize(width: 0, height: -1)
        if let s = start { c.position = s }
        let z = CALayer()
        z.contents = zzzImg.0
        z.bounds = CGRect(origin: .zero, size: zzzImg.1)
        z.actions = still
        z.opacity = 0
        if duck.superlayer != nil {
            root.insertSublayer(c, below: duck)
            root.insertSublayer(z, below: duck)
        } else {
            root.addSublayer(c)
            root.addSublayer(z)
        }
        chicks.append(c)
        zzz.append(z)
        return c
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        if !v { path = [] }
    }

    /// Punkt auf dem bisherigen Weg, `back` Punkte hinter der Maus.
    func pointBehind(_ back: CGFloat) -> (CGPoint, CGFloat)? {
        guard let last = path.last else { return nil }
        let want = last.d - back
        // Weg noch zu kurz (z. B. frisch geschlüpftes Küken ganz hinten): am ältesten Punkt warten
        guard let i = path.lastIndex(where: { $0.d <= want }) else {
            guard path.count >= 2 else { return (path[0].p, 0) }
            return (path[0].p, atan2(path[1].p.y - path[0].p.y, path[1].p.x - path[0].p.x))
        }
        let a = path[i], b = path[min(i + 1, path.count - 1)]
        let f = b.d > a.d ? (want - a.d) / (b.d - a.d) : 0
        let dir = atan2(b.p.y - a.p.y, b.p.x - a.p.x)
        return (CGPoint(x: a.p.x + (b.p.x - a.p.x) * f, y: a.p.y + (b.p.y - a.p.y) * f), dir)
    }

    func update(mouse: CGPoint, bounds: CGRect) {
        let now = CACurrentMediaTime()
        if path.isEmpty {
            // Küken stehen zu Beginn ordentlich rechts hinter der Ente
            let back = CGFloat(DUCKLINGS + 1) * DUCKLING_GAP
            path = [(CGPoint(x: mouse.x + back, y: mouse.y), 0), (mouse, back)]
        }
        let last = path.last!
        let step = hypot(mouse.x - last.p.x, mouse.y - last.p.y)
        let moving = step >= 2
        if moving {
            path.append((mouse, last.d + step))
            if abs(mouse.x - last.p.x) > 0.3 { facing = mouse.x > last.p.x ? 0 : .pi }
            lastMove = now
            let keep = max(600, Int(CGFloat(chicks.count + 2) * DUCKLING_GAP / 2) + 100)   // reicht für alle Küken
            if path.count > keep { path.removeFirst(path.count - keep) }
        }
        let walking = now - lastMove < 0.15
        let sleeping = now - lastMove > DUCK_SLEEP_AFTER
        let t = CGFloat(now)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Ente: watschelt (wackelt hin und her) nur beim Laufen
        let waddle = walking ? sin(t * 18) * 0.18 : 0
        duck.position = CGPoint(x: mouse.x, y: mouse.y + (walking ? abs(sin(t * 18)) * 2.5 : 0))
        duck.transform = CATransform3DConcat(vehicleTransform(angle: facing), CATransform3DMakeRotation(waddle, 0, 0, 1))
        for (i, c) in chicks.enumerated() {
            guard let (p, dir) = pointBehind(CGFloat(i + 1) * DUCKLING_GAP) else { continue }
            let phase = t * 20 + CGFloat(i) * 1.7
            let hop = walking ? abs(sin(phase)) * 3 : 0
            c.position = CGPoint(x: p.x, y: p.y - 4 + hop)
            let face: CGFloat = cos(dir) >= 0 ? 0 : .pi
            let tilt = walking ? sin(phase) * 0.22 : (sleeping ? 0.35 : 0)        // schlafend: Kopf zur Seite
            c.transform = CATransform3DConcat(vehicleTransform(angle: face), CATransform3DMakeRotation(tilt, 0, 0, 1))
            // 💤 über schlafenden Küken, schwebt sanft
            let z = zzz[i]
            z.position = CGPoint(x: p.x + 9, y: p.y + 14 + sin(t * 2 + CGFloat(i)) * 2)
            z.opacity = sleeping ? Float(min(1, (now - lastMove - DUCK_SLEEP_AFTER) * 2)) : 0
        }
        CATransaction.commit()

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { quack(at: mouse) }
        wasPressed = pressed
        updateEggs(mouse: mouse, bounds: bounds, now: now)
    }

    // ---------- Eier ----------
    func updateEggs(mouse: CGPoint, bounds: CGRect, now: Double) {
        // neues Ei an zufälliger Stelle (mit Abstand zum Rand und zur Ente)
        if now >= nextEgg {
            nextEgg = now + Double.random(in: EGG_EVERY)
            if eggs.count < EGG_MAX && chicks.count < CHICKS_MAX && bounds.width > 200 && bounds.height > 200 {
                var p = CGPoint.zero
                for _ in 0..<10 {
                    p = CGPoint(x: CGFloat.random(in: bounds.minX + 80...bounds.maxX - 80),
                                y: CGFloat.random(in: bounds.minY + 80...bounds.maxY - 120))
                    if hypot(p.x - mouse.x, p.y - mouse.y) > 200 { break }
                }
                spawnEgg(at: p)
            }
        }
        for (i, e) in eggs.enumerated().reversed() {
            let l = e.layer
            if hypot(l.position.x - mouse.x, l.position.y - mouse.y) < 28 {
                eggs.remove(at: i)
                hatch(l)
            } else if now - e.born > EGG_STAY {
                eggs.remove(at: i)
                vanish(l)
            }
        }
    }

    func spawnEgg(at p: CGPoint) {
        let l = CALayer()
        l.contents = eggImg.0
        l.bounds = CGRect(origin: .zero, size: eggImg.1)
        l.position = p
        l.actions = still
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.35
        l.shadowRadius = 2
        l.shadowOffset = CGSize(width: 0, height: -2)
        root.insertSublayer(l, at: 0)
        // ploppt auf und wackelt dann, als wollte gleich etwas schlüpfen
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0, 1.25, 0.95, 1]
        pop.duration = 0.45
        l.add(pop, forKey: "pop")
        let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wobble.values = [0, 0.18, -0.18, 0.12, -0.12, 0, 0, 0, 0]
        wobble.duration = 1.6
        wobble.repeatCount = .infinity
        wobble.beginTime = CACurrentMediaTime() + 0.45
        l.add(wobble, forKey: "wobble")
        eggs.append((l, CACurrentMediaTime()))
    }

    /// Eingesammelt: Ei springt auf (🐣, "Piep!"), ein neues Küken hüpft hinten an die Reihe.
    func hatch(_ egg: CALayer) {
        let p = egg.position
        egg.removeAllAnimations()
        egg.removeFromSuperlayer()

        let h = CALayer()
        h.contents = hatchImg.0
        h.bounds = CGRect(origin: .zero, size: hatchImg.1)
        h.position = p
        h.opacity = 0
        root.addSublayer(h)
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.4, 1.3, 1, 1]
        pop.keyTimes = [0, 0.25, 0.4, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.7, 1]
        let g = CAAnimationGroup()
        g.animations = [pop, fade]
        g.duration = 0.7
        CATransaction.begin()
        CATransaction.setCompletionBlock { h.removeFromSuperlayer() }
        h.add(g, forKey: "hatch")
        CATransaction.commit()

        let b = CALayer()
        b.contents = piep.0
        b.bounds = CGRect(origin: .zero, size: piep.1)
        b.anchorPoint = CGPoint(x: 0.1, y: 0)
        b.position = CGPoint(x: p.x + 6, y: p.y + 14)
        b.opacity = 0
        root.addSublayer(b)
        let bpop = CAKeyframeAnimation(keyPath: "transform.scale")
        bpop.values = [0.2, 1.1, 1, 1]
        bpop.keyTimes = [0, 0.15, 0.25, 1]
        let bfade = CAKeyframeAnimation(keyPath: "opacity")
        bfade.values = [0, 1, 1, 0]
        bfade.keyTimes = [0, 0.1, 0.75, 1]
        let bg = CAAnimationGroup()
        bg.animations = [bpop, bfade]
        bg.duration = 1.0
        CATransaction.begin()
        CATransaction.setCompletionBlock { b.removeFromSuperlayer() }
        b.add(bg, forKey: "piep")
        CATransaction.commit()

        // neues Küken: startet am Ei und hüpft in einem Bogen zu seinem Platz in der Reihe
        let c = addChick(at: p)
        guard let (target, _) = pointBehind(CGFloat(chicks.count) * DUCKLING_GAP) else { return }
        let jump = CAKeyframeAnimation(keyPath: "transform.translation")
        let dx = p.x - target.x, dy = p.y - (target.y - 4)
        jump.values = [NSValue(size: CGSize(width: dx, height: dy)),
                       NSValue(size: CGSize(width: dx * 0.5, height: dy * 0.5 + 40)),
                       NSValue(size: .zero)]
        jump.duration = 0.55
        jump.isAdditive = true
        jump.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        c.add(jump, forKey: "join")
        lastMove = CACurrentMediaTime()                 // alle wach
    }

    func vanish(_ egg: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.8
        egg.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { egg.removeFromSuperlayer() }
        egg.add(fade, forKey: "vanish")
        CATransaction.commit()
    }

    func quack(at p: CGPoint) {
        lastMove = CACurrentMediaTime()            // weckt die Küken auf
        let b = CALayer()
        let img = facing != 0 ? quakRight : quak             // Spitze zur Ente hin
        b.contents = img.0
        b.bounds = CGRect(origin: .zero, size: img.1)
        // Blase auf der Seite, in die die Ente schaut (Spitze am Kopf) – so verdeckt sie die Küken nicht
        let left = facing != 0
        b.anchorPoint = CGPoint(x: left ? 0.9 : 0.1, y: 0)
        b.position = CGPoint(x: p.x + (left ? -6 : 6), y: p.y + 16)
        b.opacity = 0
        root.addSublayer(b)
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.2, 1.15, 1, 1]
        pop.keyTimes = [0, 0.15, 0.25, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.75, 1]
        let g = CAAnimationGroup()
        g.animations = [pop, fade]
        g.duration = 1.1
        CATransaction.begin()
        CATransaction.setCompletionBlock { b.removeFromSuperlayer() }
        b.add(g, forKey: "quak")
        CATransaction.commit()
        // Küken hüpfen nacheinander erschrocken hoch
        for (i, c) in chicks.enumerated() {
            let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
            jump.values = [0, 16, 0, 4, 0]
            jump.keyTimes = [0, 0.4, 0.75, 0.88, 1]
            jump.duration = 0.45
            jump.beginTime = CACurrentMediaTime() + 0.08 * Double(i + 1)
            jump.isAdditive = true
            c.add(jump, forKey: "jump")
        }
    }
}
