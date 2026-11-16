// Halloween-Design: statt eines Zeigers eine Taschenlampe.
// Der Bildschirm wird nachtdunkel, um die Maus leuchtet ein flackernder, warmer Lichtkegel.
// Die Maus ist ein 🎃, ein 👻 schwebt träge hinterher, bei jedem Klick flattern 🦇 davon.
// Praktisch beim Präsentieren: der Lichtkegel hebt genau die Stelle hervor, über die man spricht.

import Cocoa

// ---------- Einstellungen ----------
let LIGHT_RADIUS: CGFloat = 170        // Radius des hellen Lichtkegels, in Punkten
let LIGHT_FEATHER: CGFloat = 80        // weicher Rand des Lichtkegels
let NIGHT_COLOR = NSColor(srgbRed: 0.02, green: 0.01, blue: 0.07, alpha: 0.82)   // Dunkelheit

/// Rendert ein Emoji als Bild (CATextLayer zeichnet Farb-Emoji nicht zuverlässig)
func emojiImage(_ s: String, size: CGFloat) -> (CGImage, CGSize) {
    let scale: CGFloat = 3
    let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size * scale)])
    let sz = str.size()
    let img = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
    return (img.cgImage(forProposedRect: nil, context: nil, hints: nil)!, CGSize(width: sz.width / scale, height: sz.height / scale))
}

/// Kreisförmiger Verlauf als Bild: alpha(t) für t = 0 (Mitte) ... 1 (Rand); außerhalb des Kreises `outside`.
func radialImage(size: Int = 512, color: CGColor, alpha: (CGFloat) -> CGFloat, outside: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = color.converted(to: cs, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]   // immer RGB(A)
    ctx.setFillColor(red: c[0], green: c[1], blue: c[2], alpha: outside)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let steps = 32
    let colors = (0...steps).map { i -> CGColor in
        CGColor(red: c[0], green: c[1], blue: c[2], alpha: alpha(CGFloat(i) / CGFloat(steps)))
    }
    let locs = (0...steps).map { CGFloat($0) / CGFloat(steps) }
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
    let m = CGFloat(size) / 2
    ctx.setBlendMode(.copy)
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: m, y: m), startRadius: 0, endCenter: CGPoint(x: m, y: m), endRadius: m, options: [])
    return ctx.makeImage()!
}

func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

final class HalloweenFX {
    // Dunkelheit = eine Fläche über den ganzen Bildschirm, die über eine Maske um die Maus herum
    // stufenlos ausgeblendet wird (Maske: Kreis mit Verlauf + vier deckende Rechtecke drumherum).
    let night = CALayer()
    let mask = CALayer()
    let hole = CALayer()
    let around = (0..<4).map { _ in CALayer() }
    let glow = CALayer()               // warmer Kerzenschein-Ring im Lichtkegel
    let top = CALayer()                // Kürbis, Gespenst, Fledermäuse (über allem)
    let pumpkin = CALayer()
    let ghost = CALayer()
    let bat = emojiImage("🦇", size: 28)
    var ghostPos: CGPoint?
    var lastMouse = CGPoint.zero
    var lastTime = CACurrentMediaTime()
    var flicker: CGFloat = 1, flickerTarget: CGFloat = 1, nextFlicker = 0.0
    var wasPressed = false
    var bats = true                    // im Zeichenmodus aus, damit beim Malen nichts herumflattert

    init() {
        let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "transform": NSNull(),
                                         "locations": NSNull(), "hidden": NSNull(), "cornerRadius": NSNull()]
        night.backgroundColor = NIGHT_COLOR.cgColor
        let inner = LIGHT_RADIUS / (LIGHT_RADIUS + LIGHT_FEATHER)
        hole.contents = radialImage(color: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                    alpha: { smoothstep(inner * 0.85, 1, $0) }, outside: 1)
        mask.addSublayer(hole)
        for r in around { r.backgroundColor = CGColor(gray: 0, alpha: 1); mask.addSublayer(r) }
        night.mask = mask
        glow.contents = radialImage(color: CGColor(red: 1, green: 0.5, blue: 0.08, alpha: 1),
                                    alpha: { t in 0.16 * smoothstep(inner * 0.5, inner, t) * (1 - smoothstep(inner, 1, t)) },
                                    outside: 0)
        let (p, ps) = emojiImage("🎃", size: 30)
        pumpkin.contents = p
        pumpkin.bounds = CGRect(origin: .zero, size: ps)
        pumpkin.shadowColor = NSColor.orange.cgColor
        pumpkin.shadowOpacity = 0.8
        pumpkin.shadowRadius = 8
        pumpkin.shadowOffset = .zero
        let (g, gs) = emojiImage("👻", size: 44)
        ghost.contents = g
        ghost.bounds = CGRect(origin: .zero, size: gs)
        ghost.opacity = 0.88
        ghost.shadowColor = NSColor.white.cgColor
        ghost.shadowOpacity = 0.6
        ghost.shadowRadius = 10
        ghost.shadowOffset = .zero
        top.addSublayer(ghost)
        top.addSublayer(pumpkin)
        for l in [night, mask, hole, glow, top, pumpkin, ghost] + around { l.actions = still }
        setVisible(false)
    }

    func setVisible(_ v: Bool) {
        guard night.isHidden == v else { return }
        for l in [night, glow, top] as [CALayer] { l.isHidden = !v }
        if !v { ghostPos = nil }
    }

    /// Einmal pro Bildschirmbild. mouse in Fensterkoordinaten, bounds = Fenster.
    func update(mouse: CGPoint, bounds: CGRect) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastTime)
        lastTime = now

        // Kerzenflackern: alle 60–140 ms ein neues Ziel, weich dorthin
        if now > nextFlicker {
            flickerTarget = CGFloat.random(in: 0.92...1.05)
            nextFlicker = now + Double.random(in: 0.06...0.14)
        }
        flicker += (flickerTarget - flicker) * CGFloat(min(1, dt * 14))
        // auf ganze Punkte runden, damit Kreis und Rechtecke der Maske ohne Haarlinie aneinanderstoßen
        let R = ((LIGHT_RADIUS + LIGHT_FEATHER) * flicker).rounded()
        let c = CGPoint(x: mouse.x.rounded(), y: mouse.y.rounded())

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds.insetBy(dx: -20, dy: -20)
        night.frame = b
        mask.frame = CGRect(origin: .zero, size: b.size)
        let sq = CGRect(x: c.x - R - b.minX, y: c.y - R - b.minY, width: 2 * R, height: 2 * R)   // in Maskenkoordinaten
        hole.frame = sq
        around[0].frame = CGRect(x: 0, y: 0, width: b.width, height: max(0, sq.minY))                   // unten
        around[1].frame = CGRect(x: 0, y: sq.maxY, width: b.width, height: max(0, b.height - sq.maxY))   // oben
        around[2].frame = CGRect(x: 0, y: sq.minY, width: max(0, sq.minX), height: sq.height)           // links
        around[3].frame = CGRect(x: sq.maxX, y: sq.minY, width: max(0, b.width - sq.maxX), height: sq.height) // rechts
        glow.frame = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)

        // Kürbis = Zeiger (Mitte ist der Klickpunkt), wackelt ein bisschen
        pumpkin.position = mouse
        pumpkin.transform = CATransform3DMakeRotation(sin(CGFloat(now) * 2.2) * 0.12, 0, 0, 1)

        // Gespenst schwebt mit Verzögerung hinterher, auf und ab, neigt sich in Bewegungsrichtung
        let target = CGPoint(x: mouse.x - 60, y: mouse.y + 45)
        var gp = ghostPos ?? target
        let k = CGFloat(1 - exp(-dt * 2.5))
        let vx = (target.x - gp.x) * k
        gp.x += vx
        gp.y += (target.y - gp.y) * k
        ghostPos = gp
        ghost.position = CGPoint(x: gp.x, y: gp.y + sin(CGFloat(now) * 2.6) * 7)
        ghost.transform = CATransform3DMakeRotation(max(-0.35, min(0.35, -vx * 0.04)), 0, 0, 1)
        CATransaction.commit()

        // Klick -> Fledermäuse (Maustaste abfragen braucht keine Bedienungshilfen-Freigabe)
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && bats { spawnBats(at: mouse) }
        wasPressed = pressed
        lastMouse = mouse
    }

    func spawnBats(at p: CGPoint) {
        for _ in 0..<Int.random(in: 4...6) {
            let l = CALayer()
            let s = CGFloat.random(in: 0.6...1.1)
            l.contents = bat.0
            l.bounds = CGRect(x: 0, y: 0, width: bat.1.width * s, height: bat.1.height * s)
            l.position = p
            l.opacity = 0
            top.addSublayer(l)

            let dest = CGPoint(x: p.x + CGFloat.random(in: -200...200), y: p.y + CGFloat.random(in: 90...260))
            let mid = CGPoint(x: (p.x + dest.x) / 2 + CGFloat.random(in: -60...60), y: (p.y + dest.y) / 2)
            let move = CAKeyframeAnimation(keyPath: "position")
            let path = CGMutablePath()
            path.move(to: p)
            path.addQuadCurve(to: dest, control: mid)
            move.path = path
            let flap = CAKeyframeAnimation(keyPath: "transform.scale.x")      // Flügelschlag
            flap.values = [1, 0.45, 1]
            flap.duration = Double.random(in: 0.12...0.18)
            let grow = CABasicAnimation(keyPath: "transform.scale.y")
            grow.fromValue = 0.4
            grow.toValue = 1.2
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.7, 1]
            let group = CAAnimationGroup()
            group.animations = [move, grow, fade]
            group.duration = Double.random(in: 0.9...1.4)
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            flap.repeatCount = Float(group.duration / flap.duration)   // endlich, sonst kommt die Aufräum-Meldung nie
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            l.add(group, forKey: "fly")
            l.add(flap, forKey: "flap")
            CATransaction.commit()
        }
    }
}

// ---------- Halloween 2: Spinne ----------
// Die Spinne ist der Zeiger (ihre Mitte ist der Klickpunkt) und hängt an einem Faden vom oberen
// Bildschirmrand. Der Aufhängepunkt folgt der Maus federnd – die Spinne schwingt wie ein Pendel nach.
// Jeder Klick spinnt an der Klickstelle ein kleines Netz, das nach WEB_STAY Sekunden verblasst
// (macht Klicks fürs Publikum sichtbar).

let WEB_RADIUS: CGFloat = 46        // Größe des Spinnennetzes, in Punkten
let WEB_STAY: Double = 2.5          // so lange bleibt das Netz stehen

final class SpiderFX {
    let root = CALayer()
    let thread = CAShapeLayer()
    let spider = CALayer()
    let webs = CALayer()
    var anchorX: CGFloat?
    var anchorV: CGFloat = 0
    var lastTime = CACurrentMediaTime()
    var lastMouse = CGPoint.zero
    var wasPressed = false
    var clicks = true

    init() {
        let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
                                         "transform": NSNull(), "hidden": NSNull()]
        thread.strokeColor = NSColor(white: 0.95, alpha: 0.85).cgColor
        thread.fillColor = nil
        thread.lineWidth = 1.3
        thread.shadowColor = NSColor.black.cgColor        // dunkler Rand: auch auf weißen Folien sichtbar
        thread.shadowOpacity = 0.7
        thread.shadowRadius = 1
        thread.shadowOffset = .zero
        let (img, sz) = emojiImage("🕷️", size: 34)
        spider.contents = img
        spider.bounds = CGRect(origin: .zero, size: sz)
        spider.shadowColor = NSColor.black.cgColor
        spider.shadowOpacity = 0.35
        spider.shadowRadius = 3
        spider.shadowOffset = CGSize(width: 1, height: -2)
        root.addSublayer(webs)
        root.addSublayer(thread)
        root.addSublayer(spider)
        for l in [root, thread, spider, webs] as [CALayer] { l.actions = still }
        root.isHidden = true
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        if !v { anchorX = nil; anchorV = 0 }
    }

    func update(mouse: CGPoint, bounds: CGRect) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - lastTime))
        lastTime = now

        // Aufhängepunkt: gedämpfte Feder Richtung Maus -> schwingt etwas über
        var ax = anchorX ?? mouse.x
        let accel = 9 * (mouse.x - ax) - 3.2 * anchorV
        anchorV += accel * dt
        ax += anchorV * dt
        anchorX = ax

        let top = CGPoint(x: ax, y: bounds.maxY + 4)
        let dx = top.x - mouse.x, dy = top.y - mouse.y
        let len = max(1, hypot(dx, dy))
        let speed = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) / max(dt, 0.001)
        lastMouse = mouse

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.move(to: top)
        // Faden endet am Hinterleib der Spinne, nicht in ihrer Mitte
        path.addLine(to: CGPoint(x: mouse.x + dx / len * 10, y: mouse.y + dy / len * 10))
        thread.path = path
        thread.frame = bounds
        // Kopf zeigt zum Faden hoch; beim Bewegen zappeln die Beine
        let zappeln = speed > 40 ? sin(CGFloat(now) * 28) * 0.12 : sin(CGFloat(now) * 2) * 0.03
        spider.position = mouse
        spider.transform = CATransform3DMakeRotation(-atan2(dx, dy) + zappeln, 0, 0, 1)
        CATransaction.commit()

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { spinWeb(at: mouse) }
        wasPressed = pressed
    }

    /// Netz aus Speichen und Ringen, wird in 0,4 s "gesponnen", bleibt stehen und verblasst.
    func spinWeb(at c: CGPoint) {
        let spokes = 9
        let angles = (0..<spokes).map { i in CGFloat(i) / CGFloat(spokes) * 2 * .pi + CGFloat.random(in: -0.15...0.15) }
        let path = CGMutablePath()
        for a in angles {
            path.move(to: c)
            path.addLine(to: CGPoint(x: c.x + cos(a) * WEB_RADIUS, y: c.y + sin(a) * WEB_RADIUS))
        }
        for ring in [0.22, 0.42, 0.62, 0.82, 0.98] as [CGFloat] {
            let r = WEB_RADIUS * ring
            let pts = angles.map { CGPoint(x: c.x + cos($0) * r, y: c.y + sin($0) * r) }
            path.move(to: pts[0])
            for i in 1...spokes {
                let p = pts[i % spokes], q = pts[i - 1]
                let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                let sag = CGPoint(x: c.x + (mid.x - c.x) * 0.86, y: c.y + (mid.y - c.y) * 0.86)  // Fäden hängen etwas durch
                path.addQuadCurve(to: p, control: sag)
            }
        }
        let web = CAShapeLayer()
        web.path = path
        web.fillColor = nil
        web.strokeColor = NSColor(white: 1, alpha: 0.95).cgColor
        web.lineWidth = 1.6
        web.lineCap = .round
        web.shadowColor = NSColor.black.cgColor
        web.shadowOpacity = 0.95
        web.shadowRadius = 1.2
        web.shadowOffset = .zero
        webs.addSublayer(web)

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.4
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = 0.4 + WEB_STAY
        fade.duration = 0.7
        fade.fillMode = .forwards
        let group = CAAnimationGroup()
        group.animations = [draw, fade]
        group.duration = 0.4 + WEB_STAY + 0.7
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { web.removeFromSuperlayer() }
        web.add(group, forKey: "web")
        CATransaction.commit()
    }
}
