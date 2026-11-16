// Design "UFO-Kuh-Entführung" 🛸🐄
// Zeiger: ein wackelndes UFO mit blinkenden Lichtern und grünem Traktorstrahl.
// Unten am Bildschirm laufen Kühe herum und muhen. UFO tief genug über eine Kuh -> sie wird
// hochgebeamt (dreht sich, "MUUUH?!") und eingesaugt. Zieht man das UFO weg, fällt sie runter ("Aua!").
// Klick: Strahl blitzt, Kühe in der Nähe springen erschrocken hoch.
// Bei UFO_CAPACITY Kühen ist das UFO voll und wirft alle an Fallschirmen wieder ab.

import Cocoa

let UFO_BEAM_REACH: CGFloat = 280    // so weit reicht der Strahl nach unten (pt)
let UFO_CAPACITY = 5                  // so viele Kühe passen ins UFO
let UFO_MAX_COWS = 4                  // so viele Kühe laufen höchstens herum
let BEAM_GREEN = NSColor(srgbRed: 0.55, green: 1, blue: 0.45, alpha: 1)

final class UfoFX {
    enum CowState { case walking, lifted, falling, parachute }
    final class Cow {
        let layer = CALayer()
        var chute: CALayer?
        var p: CGPoint
        var vx: CGFloat
        var vy: CGFloat = 0
        var spin: CGFloat = 0
        var state: CowState = .walking
        var nextMoo: Double
        var screamed = false
        var phase = CGFloat.random(in: 0...6)
        init(p: CGPoint, vx: CGFloat, now: Double) { self.p = p; self.vx = vx; nextMoo = now + Double.random(in: 2...7) }
    }

    let root = CALayer()
    let beam = CAGradientLayer()
    let beamMask = CAShapeLayer()
    let ufo = CALayer()
    var lights: [CALayer] = []
    let badge = CALayer()
    var cows: [Cow] = []
    var collected = 0
    var lastTime = CACurrentMediaTime()
    var vx: CGFloat = 0
    var lastMouse: CGPoint?
    var nextCow = CACurrentMediaTime() + 0.5
    var wasPressed = false
    var clicks = true
    var flash: CGFloat = 0
    let cowImg = emojiImage("🐄", size: 34)
    let chuteImg = emojiImage("🪂", size: 30)
    let dizzyImg = emojiImage("💫", size: 18)
    var bubbles: [String: (CGImage, CGSize)] = [:]
    let still: [String: CAAction] = ["position": NSNull(), "transform": NSNull(), "hidden": NSNull(), "opacity": NSNull(),
                                     "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "colors": NSNull()]

    init() {
        beam.colors = [BEAM_GREEN.withAlphaComponent(0.55).cgColor, BEAM_GREEN.withAlphaComponent(0.08).cgColor]
        beam.startPoint = CGPoint(x: 0.5, y: 1)
        beam.endPoint = CGPoint(x: 0.5, y: 0)
        beam.mask = beamMask
        let (u, us) = emojiImage("🛸", size: 50)
        ufo.contents = u
        ufo.bounds = CGRect(origin: .zero, size: us)
        ufo.shadowColor = BEAM_GREEN.cgColor
        ufo.shadowOpacity = 0.7
        ufo.shadowRadius = 8
        ufo.shadowOffset = .zero
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemTeal, .systemPink].enumerated() {   // blinkende Lichter
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
            l.cornerRadius = 3
            l.backgroundColor = c.cgColor
            l.shadowColor = c.cgColor
            l.shadowOpacity = 1
            l.shadowRadius = 4
            l.shadowOffset = .zero
            l.position = CGPoint(x: us.width * (0.25 + 0.17 * CGFloat(i)), y: us.height * 0.33)
            l.actions = still
            ufo.addSublayer(l)
            lights.append(l)
        }
        root.addSublayer(beam)
        root.addSublayer(ufo)
        root.addSublayer(badge)
        for l in [root, beam, beamMask, ufo, badge] as [CALayer] { l.actions = still }
        badge.isHidden = true
        root.isHidden = true
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        lastMouse = nil
    }

    // ---------- Sprechblasen ----------
    func say(_ text: String, at p: CGPoint, duration: Double = 1.0) {
        let img = bubbles[text] ?? bubbleImage(text)
        bubbles[text] = img
        let b = CALayer()
        b.contents = img.0
        b.bounds = CGRect(origin: .zero, size: img.1)
        b.anchorPoint = CGPoint(x: 0.1, y: 0)
        b.position = p
        b.opacity = 0
        root.addSublayer(b)
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.2, 1.15, 1, 1]
        pop.keyTimes = [0, 0.15, 0.25, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.8, 1]
        let g = CAAnimationGroup()
        g.animations = [pop, fade]
        g.duration = duration
        CATransaction.begin()
        CATransaction.setCompletionBlock { b.removeFromSuperlayer() }
        b.add(g, forKey: "say")
        CATransaction.commit()
    }

    // ---------- Kühe ----------
    func spawnCow(bounds: CGRect, now: Double, at: CGPoint? = nil, parachute: Bool = false) {
        let fromLeft = Bool.random()
        let ground = bounds.minY + 20
        let p = at ?? CGPoint(x: fromLeft ? bounds.minX - 30 : bounds.maxX + 30, y: ground)
        let c = Cow(p: p, vx: (fromLeft ? 1 : -1) * CGFloat.random(in: 25...45), now: now)
        c.layer.contents = cowImg.0
        c.layer.bounds = CGRect(origin: .zero, size: cowImg.1)
        c.layer.actions = still
        c.layer.position = p
        if parachute {
            c.state = .parachute
            c.vx = CGFloat.random(in: -20...20)
            let ch = CALayer()
            ch.contents = chuteImg.0
            ch.bounds = CGRect(origin: .zero, size: chuteImg.1)
            ch.actions = still
            root.insertSublayer(ch, below: ufo)
            c.chute = ch
        }
        root.insertSublayer(c.layer, below: beam)
        cows.append(c)
    }

    /// Halbe Breite des Strahls auf Höhe y (Strahl wird nach unten breiter).
    func beamHalfWidth(top: CGFloat, y: CGFloat) -> CGFloat { 16 + (top - y) * 0.32 }

    func update(mouse: CGPoint, bounds: CGRect) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - lastTime))
        lastTime = now
        if let lm = lastMouse, dt > 0 { vx += ((mouse.x - lm.x) / dt - vx) * min(1, dt * 8) }
        lastMouse = mouse
        let t = CGFloat(now)
        let ground = bounds.minY + 20
        let beamTop = mouse.y - 10
        let reach = min(UFO_BEAM_REACH, max(0, beamTop - (ground - 22)))
        let beamOn = beamTop - (ground - 22) <= UFO_BEAM_REACH + 1          // Strahl erreicht den Boden
        flash = max(0, flash - dt * 3)

        if now > nextCow && cows.count < UFO_MAX_COWS {
            nextCow = now + Double.random(in: 5...10)
            spawnCow(bounds: bounds, now: now)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // UFO: wackelt, neigt sich in Flugrichtung, Lichter laufen reihum
        ufo.position = CGPoint(x: mouse.x, y: mouse.y + sin(t * 4) * 2)
        ufo.transform = CATransform3DMakeRotation(sin(t * 3) * 0.06 - max(-0.35, min(0.35, vx * 0.0007)), 0, 0, 1)
        for (i, l) in lights.enumerated() { l.opacity = (Int(t * 8) % lights.count == i) ? 1 : 0.25 }
        // Strahl
        let hwBottom = beamHalfWidth(top: beamTop, y: beamTop - reach)
        beam.frame = CGRect(x: mouse.x - hwBottom, y: beamTop - reach, width: 2 * hwBottom, height: max(1, reach))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: hwBottom - 16, y: reach))
        path.addLine(to: CGPoint(x: hwBottom + 16, y: reach))
        path.addLine(to: CGPoint(x: 2 * hwBottom, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        beamMask.path = path
        let lifting = cows.contains { $0.state == .lifted }
        beam.opacity = Float(min(1, (beamOn ? 0.55 : 0.25) + (lifting ? 0.35 + sin(t * 20) * 0.1 : 0) + flash))

        // Kühe
        for c in cows {
            let hw = beamHalfWidth(top: beamTop, y: c.p.y)
            let inBeam = beamOn && c.p.y < beamTop && beamTop - c.p.y <= UFO_BEAM_REACH && abs(c.p.x - mouse.x) < hw
            switch c.state {
            case .walking:
                c.phase += dt * 9
                c.p.x += c.vx * dt
                c.p.y = ground + abs(sin(c.phase)) * 2
                if (c.p.x < bounds.minX + 20 && c.vx < 0) || (c.p.x > bounds.maxX - 20 && c.vx > 0)
                    || CGFloat.random(in: 0...1) < dt * 0.12 { c.vx = -c.vx }
                if now > c.nextMoo {
                    c.nextMoo = now + Double.random(in: 4...10)
                    say(["Muh!", "Muuh.", "Muh?", "MUH!"].randomElement()!, at: CGPoint(x: c.p.x + 6, y: c.p.y + 16))
                }
                if inBeam { c.state = .lifted; c.screamed = false }
            case .lifted:
                if !inBeam { c.state = .falling; c.vy = 0; break }
                if !c.screamed { c.screamed = true; say("MUUUH?!", at: CGPoint(x: c.p.x + 8, y: c.p.y + 18)) }
                c.p.y += 120 * dt
                c.p.x += (mouse.x - c.p.x) * min(1, dt * 3)
                c.spin += dt * 6
                if hypot(mouse.x - c.p.x, mouse.y - c.p.y) < 26 { collect(c, bounds: bounds) }
            case .falling:
                c.vy -= 900 * dt
                c.p.y += c.vy * dt
                c.spin *= max(0, 1 - dt * 4)
                if inBeam && c.vy < 0 { c.state = .lifted }
                if c.p.y <= ground {
                    c.p.y = ground
                    if c.vy < -250 { landed(c, hard: true) } else { landed(c, hard: false) }
                    c.vy = 0
                    c.spin = 0
                    c.state = .walking
                }
            case .parachute:
                c.p.y -= 55 * dt
                c.p.x += c.vx * dt + sin(t * 2 + c.phase) * 0.6
                c.spin = sin(t * 2 + c.phase) * 0.15
                if c.p.y <= ground {
                    c.p.y = ground
                    c.chute?.removeFromSuperlayer()
                    c.chute = nil
                    c.state = .walking
                    c.vx = (Bool.random() ? 1 : -1) * CGFloat.random(in: 25...45)
                    say("Juhu!", at: CGPoint(x: c.p.x + 6, y: c.p.y + 16))
                }
            }
            // Kleiner werden, je näher am UFO
            let near = c.state == .lifted ? max(0.35, min(1, (mouse.y - c.p.y) / 150)) : 1
            c.layer.position = c.p
            c.layer.transform = CATransform3DConcat(
                CATransform3DConcat(vehicleTransform(angle: c.vx >= 0 ? 0 : .pi), CATransform3DMakeRotation(c.spin, 0, 0, 1)),
                CATransform3DMakeScale(near, near, 1))
            c.chute?.position = CGPoint(x: c.p.x, y: c.p.y + 30)
            c.chute?.transform = CATransform3DMakeRotation(c.spin * 0.5, 0, 0, 1)
        }
        // Kühe, die weit vom Bildschirm weg sind, aufräumen
        cows.removeAll { c in
            let gone = c.state == .walking && (c.p.x < bounds.minX - 80 || c.p.x > bounds.maxX + 80)
            if gone { c.layer.removeFromSuperlayer() }
            return gone
        }
        badge.position = CGPoint(x: mouse.x + 34, y: mouse.y + 22)
        CATransaction.commit()

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { zap(mouse: mouse) }
        wasPressed = pressed
    }

    func landed(_ c: Cow, hard: Bool) {
        let squash = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squash.values = [1, 0.55, 1.15, 1]
        squash.duration = 0.35
        squash.isAdditive = false
        c.layer.add(squash, forKey: "squash")
        guard hard else { return }
        say(["Aua!", "Uff!", "Mööp!"].randomElement()!, at: CGPoint(x: c.p.x + 6, y: c.p.y + 16))
        let d = CALayer()                                  // 💫 kreist kurz über dem Kopf
        d.contents = dizzyImg.0
        d.bounds = CGRect(origin: .zero, size: dizzyImg.1)
        d.position = CGPoint(x: c.p.x, y: c.p.y + 22)
        root.addSublayer(d)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 4
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        let g = CAAnimationGroup()
        g.animations = [spin, fade]
        g.duration = 1.2
        d.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { d.removeFromSuperlayer() }
        d.add(g, forKey: "dizzy")
        CATransaction.commit()
    }

    func collect(_ c: Cow, bounds: CGRect) {
        cows.removeAll { $0 === c }
        c.layer.removeFromSuperlayer()
        collected += 1
        let hop = CAKeyframeAnimation(keyPath: "transform.scale")       // UFO schluckt
        hop.values = [1, 1.3, 0.9, 1]
        hop.duration = 0.3
        hop.isAdditive = false
        ufo.add(hop, forKey: "gulp")
        say(["Plopp!", "Hab dich!", "Lecker Milch!", "Beam me up!"].randomElement()!, at: CGPoint(x: ufo.position.x + 14, y: ufo.position.y + 20))
        updateBadge()
        if collected >= UFO_CAPACITY {
            let drop = ufo.position
            collected = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self = self else { return }
                self.say("Zu viele Kühe!", at: CGPoint(x: drop.x + 14, y: drop.y + 20), duration: 1.4)
                for i in 0..<UFO_CAPACITY {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(i)) {
                        self.spawnCow(bounds: bounds, now: CACurrentMediaTime(),
                                      at: CGPoint(x: self.ufo.position.x + CGFloat.random(in: -30...30), y: self.ufo.position.y - 20),
                                      parachute: true)
                    }
                }
                self.updateBadge()
            }
        }
    }

    func updateBadge() {
        guard collected > 0 else { badge.isHidden = true; return }
        let img = bubbleImage("🐄 × \(collected)")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.contents = img.0
        badge.bounds = CGRect(origin: .zero, size: img.1)
        badge.anchorPoint = CGPoint(x: 0.1, y: 0)
        badge.isHidden = false
        CATransaction.commit()
    }

    /// Klick: Strahl blitzt, Kühe in der Nähe springen hoch.
    func zap(mouse: CGPoint) {
        flash = 1
        for c in cows where c.state == .walking && abs(c.p.x - mouse.x) < 220 {
            c.state = .falling
            c.vy = CGFloat.random(in: 320...420)
            c.spin = CGFloat.random(in: -0.5...0.5)
            say(["Muh?!", "Hä?!", "Huch!"].randomElement()!, at: CGPoint(x: c.p.x + 6, y: c.p.y + 18), duration: 0.8)
        }
    }
}
