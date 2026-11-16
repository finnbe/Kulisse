// Design "Peitsche 🤠" – Lederpeitsche am Zeiger.
// Zeiger: Messingring vorne am Griff = Klickpunkt, Griff zeigt nach unten rechts.
// Die geflochtene Schnur hängt mit Seil-Physik daran und schwingt bei jeder Bewegung mit.
// Normalbetrieb: Klicks gehen ganz normal durch, kein Knall.
// Zeichenmodus (⌃⌥V): Klick ODER Peitschen-Bewegung (schnell schwingen, abrupt stoppen/umkehren)
// lässt die Peitsche knallen – Schnur schnalzt, Blitz an der Spitze,
// KNALL (Geräusch wird beim Start selbst erzeugt). Es wird dabei kein Strich gezeichnet.

import Cocoa
import AVFoundation

let WHIP_SEGMENTS = 28                 // Glieder der Schnur
let WHIP_SEG_LEN: CGFloat = 6.5        // Länge eines Glieds (Schnur gesamt ≈ 180 px)
let WHIP_VOLUME: Float = 0.7           // Lautstärke des Knalls (0…1)
let WHIP_CRACK_AT: Double = 0.13       // eingebautes Ersatz-Geräusch: Knall nach 0,13 s
let WHIP_SOUND_FILE = "peitsche-knall"  // .mp3 neben der App oder in der App; fehlt sie -> eingebautes Geräusch
let WHIP_SOUND_BANG: Double = 0.37     // an dieser Stelle (Sekunden) knallt es in peitsche-knall.mp3
let WHIP_CLICK_LEAD: Double = 0.24     // Klick: so viel Zischen vor dem Knall (Sekunden)
let WHIP_FLICK_LEAD: Double = 0.04     // Peitschen-Bewegung: Knall praktisch sofort
let WHIP_GRAVITY: CGFloat = 1300
let WHIP_FLICK_SPEED: CGFloat = 1800   // px/s: so schnell muss man schwingen, damit es beim Abbremsen knallt
let WHIP_FLICK_WINDOW: Double = 0.2    // so kurz nach dem schnellsten Moment muss abgebremst werden
let WHIP_COOLDOWN: Double = 0.3        // Mindestabstand zwischen zwei Knallen
let LEATHER = NSColor(srgbRed: 0.45, green: 0.25, blue: 0.12, alpha: 1)
let LEATHER_DARK = NSColor(srgbRed: 0.20, green: 0.10, blue: 0.04, alpha: 1)
let LEATHER_LIGHT = NSColor(srgbRed: 0.78, green: 0.56, blue: 0.33, alpha: 1)
let BRASS = NSColor(srgbRed: 0.90, green: 0.72, blue: 0.32, alpha: 1)

/// Erzeugt einen Peitschenknall als WAV: kurzes Zischen, scharfer Überschall-Knall, etwas Hall.
func whipCrackWAV() -> Data {
    let sr = 44100.0
    let n = Int(sr * 0.45)
    var s = [Double](repeating: 0, count: n)
    // 1) Zischen: gefiltertes Rauschen, wird lauter und heller
    let swish = Int(sr * WHIP_CRACK_AT)
    var lp = 0.0
    for i in 0..<swish {
        let t = Double(i) / Double(swish)
        lp += (Double.random(in: -1...1) - lp) * (0.03 + 0.45 * t * t)
        s[i] = lp * 0.5 * t * t
    }
    // 2) Knall: N-Welle + sehr kurzes, helles Rauschen
    let c0 = swish
    let half = Int(sr * Double.random(in: 0.0004...0.0007))
    for i in 0..<(2 * half) { s[c0 + i] += i < half ? 1.0 - Double(i) / Double(half) * 0.3 : -0.75 }
    var prev = 0.0
    let tone = Double.random(in: 0.8...1.2)
    for i in 0..<Int(sr * 0.15) where c0 + i < n {
        let t = Double(i) / sr
        let r = Double.random(in: -1...1)
        let hp = r - prev; prev = r
        s[c0 + i] += hp * 0.55 * exp(-t / (0.008 * tone)) + r * 0.3 * exp(-t / (0.022 * tone))
    }
    // 3) Hall: ein paar leise Echos
    var out = s
    for (d, g) in [(0.017, 0.28), (0.033, 0.2), (0.058, 0.13), (0.087, 0.08), (0.12, 0.05)] {
        let k = Int(sr * d)
        for i in k..<n { out[i] += s[i - k] * g }
    }
    let peak = out.map(abs).max() ?? 1
    var pcm = Data()
    for v in out {
        var x = Int16(max(-1, min(1, v / peak * 0.95)) * 32767).littleEndian
        withUnsafeBytes(of: &x) { pcm.append(contentsOf: $0) }
    }
    var wav = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
    wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
    wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(UInt32(sr)); u32(UInt32(sr) * 2); u16(2); u16(16)
    wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    wav.append(pcm)
    return wav
}

final class WhipFX {
    let root = CALayer()
    let handle = CALayer()               // Griff, gedreht nach unten rechts; (0,0) = Klickpunkt
    let lash = CAShapeLayer()            // Schnur als gefüllte, spitz zulaufende Fläche
    let braid = CAShapeLayer()           // Flechtmuster obendrauf
    let popper = CAShapeLayer()          // ausgefranste Spitze
    var pts: [CGPoint] = []
    var old: [CGPoint] = []
    var lastTime = CACurrentMediaTime()
    var acc: Double = 0
    var crackStart: Double = -1          // Simulationszeit, zu der ein Knall begann
    var crackDir = CGPoint(x: -0.75, y: 0.66)
    var simTime: Double = 0
    var wasPressed = false
    var clicks = true
    var flicks = true                    // Knall durch Peitschen-Bewegung (schwingen + abrupt stoppen)
    var muted = false
    var lastMouse: CGPoint?
    var lastMouseTime: Double = 0
    var vel = CGPoint.zero               // geglättete Mausgeschwindigkeit
    var peak = CGPoint.zero              // schnellste Geschwindigkeit des aktuellen Schwungs
    var peakTime: Double = 0
    var lastCrack: Double = -10
    var soundFile: URL?                  // peitsche-knall.mp3
    var sounds: [Data] = []              // Ersatz, falls die Datei fehlt
    var bang: Double = WHIP_CRACK_AT     // Knall-Zeitpunkt im verwendeten Geräusch
    var crackLead: Double = WHIP_CLICK_LEAD   // Zeit vom Auslösen bis zum Knall (Schnur-Welle + Blitz)
    var playing: [AVAudioPlayer] = []
    let handleAngle: CGFloat = -.pi / 4  // Griff zeigt nach unten rechts

    init() {
        let still: [String: CAAction] = ["position": NSNull(), "transform": NSNull(), "hidden": NSNull(),
                                         "opacity": NSNull(), "path": NSNull(), "bounds": NSNull()]
        soundFile = findResource(WHIP_SOUND_FILE, "mp3")
        if soundFile != nil {
            bang = WHIP_SOUND_BANG
        } else {
            for _ in 0..<4 { sounds.append(whipCrackWAV()) }  // vier leicht unterschiedliche Knalle
        }

        // ---- Griff (lokal: läuft entlang +x vom Klickpunkt weg) ----
        let grip = CAShapeLayer()
        grip.path = CGPath(roundedRect: CGRect(x: 5, y: -5, width: 50, height: 10), cornerWidth: 4, cornerHeight: 4, transform: nil)
        grip.fillColor = LEATHER_DARK.cgColor
        grip.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        grip.lineWidth = 0.8
        let wraps = CAShapeLayer()                            // schräge Lederwicklung
        let wp = CGMutablePath()
        var x: CGFloat = 8
        while x < 52 { wp.move(to: CGPoint(x: x, y: -4.5)); wp.addLine(to: CGPoint(x: x + 3.5, y: 4.5)); x += 4 }
        wraps.path = wp
        wraps.strokeColor = LEATHER_LIGHT.withAlphaComponent(0.55).cgColor
        wraps.lineWidth = 1.1
        let knob = CAShapeLayer()                             // Knauf hinten
        knob.path = CGPath(ellipseIn: CGRect(x: 51, y: -7, width: 13, height: 14), transform: nil)
        knob.fillColor = LEATHER.cgColor
        knob.strokeColor = BRASS.cgColor
        knob.lineWidth = 1.5
        let ferrule = CAShapeLayer()                          // Messingring vorne = Klickpunkt
        ferrule.path = CGPath(roundedRect: CGRect(x: -2, y: -6, width: 9, height: 12), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ferrule.fillColor = BRASS.cgColor
        ferrule.strokeColor = BRASS.blended(withFraction: 0.5, of: .black)!.cgColor
        ferrule.lineWidth = 0.8
        let shine = CAShapeLayer()
        shine.path = CGPath(rect: CGRect(x: 7, y: 1.5, width: 44, height: 1.6), transform: nil)
        shine.fillColor = NSColor.white.withAlphaComponent(0.18).cgColor
        for l in [grip, wraps, shine, knob, ferrule] { handle.addSublayer(l) }
        handle.shadowColor = NSColor.black.cgColor
        handle.shadowOpacity = 0.5
        handle.shadowRadius = 2
        handle.shadowOffset = CGSize(width: 1, height: -1.5)
        handle.transform = CATransform3DMakeRotation(handleAngle, 0, 0, 1)

        // ---- Schnur ----
        lash.fillColor = LEATHER.cgColor
        lash.strokeColor = LEATHER_DARK.cgColor
        lash.lineWidth = 0.8
        lash.lineJoin = .round
        lash.shadowColor = NSColor.white.cgColor            // heller Hauch: auch auf dunklen Folien sichtbar
        lash.shadowOpacity = 0.35
        lash.shadowRadius = 1.5
        lash.shadowOffset = .zero
        braid.fillColor = nil
        braid.strokeColor = LEATHER_LIGHT.withAlphaComponent(0.7).cgColor
        braid.lineWidth = 1.3
        braid.lineDashPattern = [2.2, 2.8]
        braid.lineCap = .butt
        popper.fillColor = nil
        popper.strokeColor = NSColor(srgbRed: 0.93, green: 0.86, blue: 0.70, alpha: 1).cgColor
        popper.lineWidth = 1.1
        popper.lineCap = .round

        root.addSublayer(lash)
        root.addSublayer(braid)
        root.addSublayer(popper)
        root.addSublayer(handle)
        for l in [root, handle, lash, braid, popper] as [CALayer] { l.actions = still }
        root.isHidden = true
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        pts = []                                              // Schnur neu aufhängen
    }

    func update(mouse: CGPoint, now: Double = CACurrentMediaTime()) {
        if pts.isEmpty {
            pts = (0..<WHIP_SEGMENTS).map { CGPoint(x: mouse.x - CGFloat($0) * 1.5, y: mouse.y - CGFloat($0) * WHIP_SEG_LEN) }
            old = pts
            lastTime = now
        }
        acc += min(0.05, now - lastTime)
        lastTime = now
        let h = 1.0 / 240                                     // feste Schritte: stabile Physik
        var steps = 0
        while acc >= h && steps < 24 { simulate(anchor: mouse, dt: h); acc -= h; steps += 1 }
        if steps == 24 { acc = 0 }
        redraw(anchor: mouse)

        // Peitschen-Bewegung: erst schnell schwingen, dann abrupt abbremsen oder umkehren -> Knall
        if let lm = lastMouse, now > lastMouseTime {
            let dt = now - lastMouseTime
            let v = CGPoint(x: (mouse.x - lm.x) / CGFloat(dt), y: (mouse.y - lm.y) / CGFloat(dt))
            let k = CGFloat(min(1, dt * 25))
            vel = CGPoint(x: vel.x + (v.x - vel.x) * k, y: vel.y + (v.y - vel.y) * k)
        }
        lastMouse = mouse
        lastMouseTime = now
        let speed = hypot(vel.x, vel.y), peakSpeed = hypot(peak.x, peak.y)
        if speed >= peakSpeed || now - peakTime > WHIP_FLICK_WINDOW { peak = vel; peakTime = now }
        if flicks && peakSpeed > WHIP_FLICK_SPEED && now - peakTime < WHIP_FLICK_WINDOW && now - lastCrack > WHIP_COOLDOWN {
            let along = (vel.x * peak.x + vel.y * peak.y) / (peakSpeed * peakSpeed)   // 1 = gleich schnell weiter, <0 = Umkehr
            if along < 0.3 {
                crack(dir: CGPoint(x: peak.x / peakSpeed, y: peak.y / peakSpeed), now: now)
                peak = .zero
            }
        }

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !wasPressed && clicks { crack(now: now) }
        wasPressed = pressed
    }

    func simulate(anchor: CGPoint, dt: Double) {
        simTime += dt
        let d = CGFloat(dt)
        pts[0] = anchor; old[0] = anchor
        let n = pts.count
        let ct = crackStart >= 0 ? simTime - crackStart : -1
        if ct > crackLead + 0.6 { crackStart = -1 }
        for i in 1..<n {
            let f = CGFloat(i) / CGFloat(n - 1)
            let v = CGPoint(x: (pts[i].x - old[i].x) * 0.992, y: (pts[i].y - old[i].y) * 0.992)
            old[i] = pts[i]
            var a = CGPoint(x: 6 * sin(CGFloat(simTime) * 1.7 + f * 3) * f, y: -WHIP_GRAVITY)   // leichtes Wehen
            if ct >= 0 {
                // Welle läuft vom Griff zur Spitze: jedes Glied wird kurz nach vorne gerissen
                let ph = ct - Double(f) * crackLead * 0.75
                if ph >= 0 && ph < 0.035 {
                    let k: CGFloat = 26000 * (0.4 + f)
                    a.x += crackDir.x * k; a.y += crackDir.y * k
                }
            }
            pts[i] = CGPoint(x: pts[i].x + v.x + a.x * d * d, y: pts[i].y + v.y + a.y * d * d)
        }
        for _ in 0..<14 {                                    // Längen einhalten
            for i in 0..<(n - 1) {
                let dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y
                let len = max(0.001, hypot(dx, dy))
                let diff = (len - WHIP_SEG_LEN) / len
                if i == 0 {
                    pts[1].x -= dx * diff; pts[1].y -= dy * diff
                } else {
                    pts[i].x += dx * diff * 0.5; pts[i].y += dy * diff * 0.5
                    pts[i + 1].x -= dx * diff * 0.5; pts[i + 1].y -= dy * diff * 0.5
                }
            }
        }
        // Knall genau dann, wenn die Welle an der Spitze ankommt
        if ct >= 0 && ct < crackLead && ct + dt >= crackLead, let tip = pts.last {
            burst(at: tip)
        }
    }

    func redraw(anchor: CGPoint) {
        let n = pts.count
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<n {
            let a = pts[max(0, i - 1)], b = pts[min(n - 1, i + 1)]
            let tx = b.x - a.x, ty = b.y - a.y
            let l = max(0.001, hypot(tx, ty))
            let f = CGFloat(i) / CGFloat(n - 1)
            let w = (5.5 - 4.4 * f) / 2                        // dick am Griff, dünn an der Spitze
            left.append(CGPoint(x: pts[i].x - ty / l * w, y: pts[i].y + tx / l * w))
            right.append(CGPoint(x: pts[i].x + ty / l * w, y: pts[i].y - tx / l * w))
        }
        let outline = CGMutablePath()
        outline.addLines(between: left + right.reversed())
        outline.closeSubpath()
        let mid = CGMutablePath()
        mid.addLines(between: Array(pts.prefix(Int(Double(n) * 0.7))))
        let pop = CGMutablePath()
        if n >= 2 {
            let t = pts[n - 1], s = pts[n - 2]
            let ang = atan2(t.y - s.y, t.x - s.x)
            for da in [-0.45, -0.15, 0.2, 0.5] as [CGFloat] {
                pop.move(to: t)
                pop.addLine(to: CGPoint(x: t.x + cos(ang + da) * 7, y: t.y + sin(ang + da) * 7))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lash.path = outline
        braid.path = mid
        popper.path = pop
        handle.position = anchor
        CATransaction.commit()
    }

    /// Klick: Zischen + Knall, Schnur schnalzt nach vorne.
    /// dir: Richtung, in die die Schnur schnalzt (nil = nach oben links, leicht zufällig)
    func crack(sound: Bool = true, dir: CGPoint? = nil, now: Double = CACurrentMediaTime()) {
        crackStart = simTime
        lastCrack = now
        if let d = dir {
            crackDir = d
        } else {
            let base = atan2(CGFloat(0.66), CGFloat(-0.75)) + CGFloat.random(in: -0.25...0.25)
            crackDir = CGPoint(x: cos(base), y: sin(base))
        }
        crackLead = min(dir == nil ? WHIP_CLICK_LEAD : WHIP_FLICK_LEAD, bang)
        if sound && !muted {
            let player = soundFile.flatMap { try? AVAudioPlayer(contentsOf: $0) }
                ?? sounds.randomElement().flatMap { try? AVAudioPlayer(data: $0) }
            if let p = player {
                p.volume = WHIP_VOLUME
                p.currentTime = max(0, bang - crackLead)      // so starten, dass der Knall nach crackLead kommt
                playing.removeAll { !$0.isPlaying }
                playing.append(p)                             // Referenz halten, bis fertig gespielt
                p.play()
            }
        }
        let flick = CAKeyframeAnimation(keyPath: "transform.rotation.z")   // Griff schnellt mit
        flick.values = [0, 0.45, -0.12, 0]
        flick.keyTimes = [0, 0.35, 0.7, 1]
        flick.isAdditive = true
        flick.duration = 0.3
        handle.add(flick, forKey: "flick")
    }

    /// Blitz + Druckwelle + Funken an der Spitze.
    func burst(at p: CGPoint, frozen: Bool = false) {
        var layers: [(CALayer, CAAnimation)] = []
        // Stern-Blitz
        let star = CAShapeLayer()
        let sp = CGMutablePath()
        for i in 0..<16 {
            let a = CGFloat(i) * .pi / 8 + CGFloat.random(in: -0.1...0.1)
            let r: CGFloat = i % 2 == 0 ? CGFloat.random(in: 14...20) : 5
            let q = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { sp.move(to: q) } else { sp.addLine(to: q) }
        }
        sp.closeSubpath()
        star.path = sp
        star.position = p
        star.fillColor = NSColor(srgbRed: 1, green: 0.98, blue: 0.85, alpha: 1).cgColor
        star.shadowColor = NSColor(srgbRed: 1, green: 0.75, blue: 0.2, alpha: 1).cgColor
        star.shadowOpacity = 1
        star.shadowRadius = 6
        star.shadowOffset = .zero
        let sg = CAAnimationGroup()
        let s1 = CABasicAnimation(keyPath: "transform.scale"); s1.fromValue = 0.3; s1.toValue = 1.5
        let s2 = CABasicAnimation(keyPath: "opacity"); s2.fromValue = 1; s2.toValue = 0
        sg.animations = [s1, s2]; sg.duration = 0.22
        layers.append((star, sg))
        // Druckwelle
        for (i, rr) in [12, 7].enumerated() {
            let ring = CAShapeLayer()
            let r = CGFloat(rr)
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
            ring.position = p
            if frozen { ring.transform = CATransform3DMakeScale(2.2 + CGFloat(i), 2.2 + CGFloat(i), 1); ring.opacity = 0.7 }
            ring.fillColor = nil
            ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            ring.lineWidth = 2 - CGFloat(i) * 0.6
            ring.shadowColor = NSColor.black.cgColor
            ring.shadowOpacity = 0.5
            ring.shadowRadius = 1
            ring.shadowOffset = .zero
            let g = CAAnimationGroup()
            let a1 = CABasicAnimation(keyPath: "transform.scale"); a1.fromValue = 0.6; a1.toValue = 4.2
            let a2 = CABasicAnimation(keyPath: "opacity"); a2.fromValue = 0.9; a2.toValue = 0
            g.animations = [a1, a2]; g.duration = 0.38 + Double(i) * 0.1
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layers.append((ring, g))
        }
        // Funken
        for _ in 0..<9 {
            let a = CGFloat.random(in: 0..<(2 * .pi))
            let dist = CGFloat.random(in: 26...48)
            let spark = CAShapeLayer()
            let sp2 = CGMutablePath()
            sp2.move(to: .zero); sp2.addLine(to: CGPoint(x: cos(a) * 6, y: sin(a) * 6))
            spark.path = sp2
            spark.strokeColor = NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1).cgColor
            spark.lineWidth = 1.6
            spark.lineCap = .round
            let g = CAAnimationGroup()
            let m = CABasicAnimation(keyPath: "position")
            m.fromValue = NSValue(point: p); m.toValue = NSValue(point: CGPoint(x: p.x + cos(a) * dist, y: p.y + sin(a) * dist))
            let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 1; o.toValue = 0
            g.animations = [m, o]; g.duration = 0.3
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            spark.position = frozen ? CGPoint(x: p.x + cos(a) * dist * 0.5, y: p.y + sin(a) * dist * 0.5) : p
            layers.append((spark, g))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, anim) in layers {
            l.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull()]
            root.insertSublayer(l, below: handle)
            if frozen { continue }                            // Vorschaubild: Standbild
            l.opacity = 0
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            l.add(anim, forKey: "burst")
            CATransaction.commit()
        }
        CATransaction.commit()
    }
}
