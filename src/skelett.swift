// Design "Skelett" – portiert aus dem Windows-Lava-Pointer (skeleton.py).
// Ein Kopf mit Nadel (Nadelspitze = Klickpunkt), darunter hängt ein schwarzes, leuchtend umrandetes Skelett
// als kleine Verlet-Puppe: es rennt beim seitlichen Bewegen, reißt beim Hochfahren die Arme hoch,
// zappelt beim Runterfallen und pendelt aus, wenn die Maus stillsteht.
// Ohne eigenes Kopfbild (importiertes Design mit "hand") ist der Kopf ein 💀.

import Cocoa

// ---------- Einstellungen (wie im Original) ----------
let SK_BODY: CGFloat = 0.62        // Körpereinheit (etwa ein Kopf) als Anteil der Kopfhöhe
let SK_GRAVITY: CGFloat = 2600     // pt/s²
let SK_DAMP: CGFloat = 0.985       // Geschwindigkeit, die pro Schritt bleibt (höher = wackliger)
let SK_STEP = 1.0 / 120            // Physik-Schritt, s
let SK_ITERS = 8                   // Durchläufe für die Knochenlängen (mehr = steifer)
let SK_HEAD_FOLLOW: CGFloat = 0.6  // wie stark der Kopf mit dem Körper kippt
let SK_MAX_TILT: CGFloat = 0.6     // rad
let SK_DRIVE: CGFloat = 0.30       // wie stark Arme/Beine der Animation folgen, solange sich die Maus bewegt
let SK_DRIVE_IDLE: CGFloat = 0.004 // ... und im Stillstand
let SK_FULL_SPEED: CGFloat = 500   // Mausgeschwindigkeit (pt/s) für volle Animation
let SK_STRIDE: CGFloat = 0.9       // Körpereinheiten Mausweg pro halbem Laufschritt
let SK_DEFAULT_GLOW = NSColor(srgbRed: 1, green: 95 / 255, blue: 0, alpha: 1)   // Magma-Orange
let SK_BONE = NSColor(white: 12 / 255, alpha: 1)

// Ruhepose in Körpereinheiten relativ zum Hals (y nach unten). "neck" muss zuerst kommen (wird festgehalten).
let SK_NAMES = ["neck", "chest", "mid", "pelvis", "shL", "shR", "elL", "elR", "haL", "haR",
                "hipL", "hipR", "knL", "knR", "ftL", "ftR"]
let SK_REST: [CGPoint] = [(0, 0), (0, 0.42), (0, 0.80), (0, 1.15), (-0.40, 0.16), (0.40, 0.16), (-0.46, 0.62), (0.46, 0.62),
                          (-0.48, 1.02), (0.48, 1.02), (-0.20, 1.20), (0.20, 1.20), (-0.22, 1.78), (0.22, 1.78),
                          (-0.23, 2.34), (0.23, 2.34)].map { CGPoint(x: $0.0, y: $0.1) }
let SK_IDX: [String: Int] = Dictionary(uniqueKeysWithValues: SK_NAMES.enumerated().map { ($1, $0) })
let SK_RIGID: [(String, String)] = [("neck", "chest"), ("chest", "mid"), ("mid", "pelvis"),
    ("neck", "shL"), ("neck", "shR"), ("shL", "shR"), ("chest", "shL"), ("chest", "shR"),
    ("pelvis", "hipL"), ("pelvis", "hipR"), ("hipL", "hipR"), ("mid", "hipL"), ("mid", "hipR"),
    ("shL", "elL"), ("elL", "haL"), ("shR", "elR"), ("elR", "haR"),
    ("hipL", "knL"), ("knL", "ftL"), ("hipR", "knR"), ("knR", "ftR")]
let SK_SOFT: [(String, String, CGFloat)] = [("neck", "mid", 0.25), ("chest", "pelvis", 0.25),
    ("hipL", "ftL", 0.03), ("hipR", "ftR", 0.03), ("shL", "haL", 0.02), ("shR", "haR", 0.02)]

/// Seitwärts rennen; d = +1 rechts, -1 links
func skPoseRun(_ d: CGFloat, _ ph: CGFloat, _ t: CGFloat) -> [String: CGPoint] {
    var o: [String: CGPoint] = [:]
    for (side, sgn, off) in [("L", CGFloat(-1), CGFloat(0)), ("R", 1, .pi)] {
        let fwd = sin(ph + off), lift = max(0, cos(ph + off))
        o["ft" + side] = CGPoint(x: 0.08 * sgn + d * 0.50 * fwd, y: 2.25 - 0.35 * lift)
        o["kn" + side] = CGPoint(x: 0.12 * sgn + d * (0.25 * fwd + 0.18), y: 1.72 - 0.20 * lift)
        o["ha" + side] = CGPoint(x: 0.28 * sgn - d * 0.42 * fwd, y: 0.85 - 0.15 * max(0, -fwd))
        o["el" + side] = CGPoint(x: 0.36 * sgn - d * (0.18 * fwd + 0.08), y: 0.55)
    }
    return o
}

/// Aufsteigen: Arme hoch wie beim Fliegen, Beine flattern
func skPoseUp(_ d: CGFloat, _ ph: CGFloat, _ t: CGFloat) -> [String: CGPoint] {
    var o: [String: CGPoint] = [:]
    for (side, sgn) in [("L", CGFloat(-1)), ("R", 1)] {
        let kick = 0.10 * sin(t * 14 + sgn)
        o["ha" + side] = CGPoint(x: 0.30 * sgn, y: -0.55)
        o["el" + side] = CGPoint(x: 0.42 * sgn, y: -0.18)
        o["kn" + side] = CGPoint(x: 0.14 * sgn, y: 1.75 + kick * 0.3)
        o["ft" + side] = CGPoint(x: 0.10 * sgn + kick, y: 2.30)
    }
    return o
}

/// Fallen: Arme und Beine gespreizt, zappelnd
func skPoseDown(_ d: CGFloat, _ ph: CGFloat, _ t: CGFloat) -> [String: CGPoint] {
    var o: [String: CGPoint] = [:]
    for (side, sgn) in [("L", CGFloat(-1)), ("R", 1)] {
        let w = sin(t * 12) * sgn
        o["ha" + side] = CGPoint(x: 0.72 * sgn, y: -0.05 + 0.20 * w)
        o["el" + side] = CGPoint(x: 0.55 * sgn, y: 0.12 + 0.08 * w)
        o["kn" + side] = CGPoint(x: 0.40 * sgn, y: 1.60)
        o["ft" + side] = CGPoint(x: 0.50 * sgn, y: 2.05 - 0.15 * w)
    }
    return o
}

/// Verlet-Puppe. Rechnet mit y nach unten (wie das Original); umgerechnet wird erst beim Zeichnen.
final class Ragdoll {
    let u: CGFloat
    let rest: [CGPoint]
    var links: [(Int, Int, CGFloat, CGFloat)] = []
    var pos: [CGPoint]?
    var prev: [CGPoint] = []
    var neck = CGPoint.zero
    var t = 0.0, acc = 0.0
    var calm = 0
    var vx: CGFloat = 0, vy: CGFloat = 0, phase: CGFloat = 0, clock: CGFloat = 0
    var facing: CGFloat = 1
    var drive = SK_DRIVE_IDLE
    var targets: [CGPoint]
    let limb: [Bool]

    init(u: CGFloat) {
        self.u = u
        rest = SK_REST.map { CGPoint(x: $0.x * u, y: $0.y * u) }
        targets = rest
        limb = SK_NAMES.map { ["el", "ha", "kn", "ft"].contains(String($0.prefix(2))) }
        func link(_ a: String, _ b: String, _ k: CGFloat) -> (Int, Int, CGFloat, CGFloat) {
            let p = rest[SK_IDX[a]!], q = rest[SK_IDX[b]!]
            return (SK_IDX[a]!, SK_IDX[b]!, hypot(q.x - p.x, q.y - p.y), k)
        }
        links = SK_RIGID.map { link($0.0, $0.1, 1) } + SK_SOFT.map { link($0.0, $0.1, $0.2) }
    }

    func reset(_ n: CGPoint, now: Double) {
        pos = rest.map { CGPoint(x: n.x + $0.x, y: n.y + $0.y) }
        prev = pos!
        neck = n; t = now; acc = 0; calm = 0; vx = 0; vy = 0
    }

    @discardableResult
    func update(_ n: CGPoint, now: Double) -> Int {
        guard pos != nil else { reset(n, now: now); return 0 }
        acc = min(acc + now - t, 4 * SK_STEP)
        t = now
        let steps = Int(acc / SK_STEP)
        guard steps > 0 else { return 0 }
        acc -= Double(steps) * SK_STEP
        let n0 = neck
        let dt = CGFloat(Double(steps) * SK_STEP)
        let blend = 1 - exp(-dt / 0.08)                   // geglättete Mausgeschwindigkeit
        vx += ((n.x - n0.x) / dt - vx) * blend
        vy += ((n.y - n0.y) / dt - vy) * blend
        if abs(vx) > 40 { facing = vx > 0 ? 1 : -1 }
        phase += abs(vx) * dt / (SK_STRIDE * u) * .pi
        clock += dt
        computeTargets()
        for s in 0..<steps {
            let f = CGFloat(s + 1) / CGFloat(steps)
            step(CGPoint(x: n0.x + (n.x - n0.x) * f, y: n0.y + (n.y - n0.y) * f))
        }
        neck = n
        let move = zip(pos!, prev).map { abs($0.x - $1.x) + abs($0.y - $1.y) }.max() ?? 0
        calm = move < 0.03 ? calm + 1 : 0
        return steps
    }

    func computeTargets() {
        let speed = hypot(vx, vy)
        let act = min(1, speed / SK_FULL_SPEED)
        drive = SK_DRIVE_IDLE + (SK_DRIVE - SK_DRIVE_IDLE) * act
        var offs = rest
        if speed > 1 {
            let modes: [(CGFloat, (CGFloat, CGFloat, CGFloat) -> [String: CGPoint])] =
                [(abs(vx) / speed, skPoseRun), (max(0, -vy) / speed, skPoseUp), (max(0, vy) / speed, skPoseDown)]
            var mixed: [String: CGPoint] = [:]
            for (wgt, pose) in modes where wgt > 0.01 {
                for (n, p) in pose(facing, phase, clock) {
                    let m = mixed[n] ?? .zero
                    mixed[n] = CGPoint(x: m.x + p.x * wgt, y: m.y + p.y * wgt)
                }
            }
            for (n, p) in mixed {
                let i = SK_IDX[n]!
                offs[i].x += (p.x * u - offs[i].x) * act
                offs[i].y += (p.y * u - offs[i].y) * act
            }
        }
        targets = offs
    }

    func step(_ n: CGPoint) {
        guard var p = pos else { return }
        let g = SK_GRAVITY * CGFloat(SK_STEP * SK_STEP)
        for i in 1..<p.count {
            let v = CGPoint(x: (p[i].x - prev[i].x) * SK_DAMP, y: (p[i].y - prev[i].y) * SK_DAMP)
            prev[i] = p[i]
            p[i].x += v.x
            p[i].y += v.y + g
        }
        p[0] = n
        prev[0] = n
        for i in 1..<p.count {                             // zur Animationspose ziehen
            let k = limb[i] ? drive : drive * 0.25
            p[i].x += (n.x + targets[i].x - p[i].x) * k
            p[i].y += (n.y + targets[i].y - p[i].y) * k
        }
        for _ in 0..<SK_ITERS {
            for (i, j, rest, k) in links {
                let dx = p[j].x - p[i].x, dy = p[j].y - p[i].y
                let d = max(hypot(dx, dy), 1e-6)
                var c = (d - rest) / d * k
                if i == 0 {
                    p[j].x -= dx * c; p[j].y -= dy * c
                } else {
                    c *= 0.5
                    p[i].x += dx * c; p[i].y += dy * c
                    p[j].x -= dx * c; p[j].y -= dy * c
                }
            }
        }
        pos = p
    }
}

/// Eingebauter Kopf, wenn das Design kein eigenes Bild hat: Nadel + 💀.
func skullHeadImage(glow: NSColor) -> CGImage {
    let w: CGFloat = 600, h: CGFloat = 1000
    let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: w / 2, y: 20))
        needle.line(to: NSPoint(x: w / 2 + 28, y: 420))
        needle.line(to: NSPoint(x: w / 2 - 28, y: 420))
        needle.close()
        glow.setFill()
        needle.fill()
        let skull = NSAttributedString(string: "💀", attributes: [.font: NSFont.systemFont(ofSize: 470)])
        let sz = skull.size()
        skull.draw(at: NSPoint(x: (w - sz.width) / 2, y: 330))
        return true
    }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

final class SkeletonFX {
    let root = CALayer()
    let glowGroup = CALayer()
    let head = CALayer()
    // pro Farbe: 5 Strichgruppen (verschiedene Dicken) + 1 Füllung (Gelenke, Becken)
    var glowLayers: [CAShapeLayer] = []
    var boneLayers: [CAShapeLayer] = []
    var rag: Ragdoll
    var headHeight: CGFloat = 100
    var tip = CGPoint.zero              // Nadelspitze im Kopfbild (Anteil, für anchorPoint)
    var glow = SK_DEFAULT_GLOW { didSet { applyColors() } }

    init() {
        rag = Ragdoll(u: 100 * SK_BODY)
        let still: [String: CAAction] = ["position": NSNull(), "transform": NSNull(), "path": NSNull(),
                                         "lineWidth": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        for list in 0..<2 {
            for i in 0..<6 {
                let l = CAShapeLayer()
                l.lineCap = .round
                l.lineJoin = .round
                l.actions = still
                if i < 5 { l.fillColor = nil } else { l.strokeColor = nil }
                if list == 0 { glowLayers.append(l); glowGroup.addSublayer(l) } else { boneLayers.append(l); root.addSublayer(l) }
            }
        }
        glowGroup.shadowOpacity = 0.9
        glowGroup.shadowRadius = 4
        glowGroup.shadowOffset = .zero
        root.insertSublayer(glowGroup, at: 0)
        root.addSublayer(head)
        for l in [root, glowGroup, head] { l.actions = still }
        applyColors()
        root.isHidden = true
    }

    func applyColors() {
        let gc = glow.withAlphaComponent(170 / 255).cgColor
        for (i, l) in glowLayers.enumerated() { if i < 5 { l.strokeColor = gc } else { l.fillColor = gc } }
        for (i, l) in boneLayers.enumerated() { if i < 5 { l.strokeColor = SK_BONE.cgColor } else { l.fillColor = SK_BONE.cgColor } }
        glowGroup.shadowColor = glow.cgColor
    }

    /// Kopfbild setzen (wie die Hand bei den Stab-Designs: Nadelspitze oben, unterer Rand = height).
    func setHead(_ s: HandSprite, height: CGFloat) {
        headHeight = height
        let scale = height / max(1, s.wrist.y - s.tip.y)
        let iw = CGFloat(s.image.width), ih = CGFloat(s.image.height)
        head.contents = s.image
        head.contentsScale = 1 / scale
        head.minificationFilter = .trilinear
        head.bounds = CGRect(x: 0, y: 0, width: iw * scale, height: ih * scale)
        head.anchorPoint = CGPoint(x: s.tip.x / iw, y: 1 - s.tip.y / ih)
        rag = Ragdoll(u: height * SK_BODY)
    }

    func setVisible(_ v: Bool) {
        guard root.isHidden == v else { return }
        root.isHidden = !v
        if v { rag.pos = nil }           // aus der Ruhepose unter dem Zeiger starten
    }

    /// Kopfneigung (0 = aufrecht, + = Körper nach rechts geschwungen); alles in "y nach unten".
    func headAngle(_ cur: CGPoint) -> CGFloat {
        guard let p = rag.pos else { return 0 }
        let ch = p[SK_IDX["chest"]!]
        return max(-SK_MAX_TILT, min(SK_MAX_TILT, atan2(ch.x - cur.x, ch.y - cur.y) * SK_HEAD_FOLLOW))
    }

    func update(mouse: CGPoint, now: Double = CACurrentMediaTime()) {
        let cur = CGPoint(x: mouse.x, y: -mouse.y)          // in "y nach unten" umrechnen
        let ang = headAngle(cur)
        let L = headHeight * 0.97
        rag.update(CGPoint(x: cur.x + sin(ang) * L, y: cur.y + cos(ang) * L), now: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        head.position = mouse
        head.transform = CATransform3DMakeRotation(ang, 0, 0, 1)
        if let p = rag.pos { draw(p) }
        CATransaction.commit()
    }

    /// Knochen zeichnen – Geometrie wie im Original (y nach unten), beim Hinzufügen gespiegelt.
    func draw(_ pos: [CGPoint]) {
        let u = rag.u, w = u * 0.075
        func P(_ n: String) -> CGPoint { pos[SK_IDX[n]!] }
        func S(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: -p.y) }
        let nk = P("neck"), md = P("mid"), pv = P("pelvis")
        var ax = md.x - nk.x, ay = md.y - nk.y
        let n = max(hypot(ax, ay), 1)
        ax /= n; ay /= n                                   // Wirbelsäule (nach unten)
        let nx = -ay, ny = ax                              // quer zum Körper

        for (layers, extra) in [(glowLayers, CGFloat(2.5)), (boneLayers, CGFloat(0))] {
            let spine = CGMutablePath(), collar = CGMutablePath(), arms = CGMutablePath(),
                legs = CGMutablePath(), ribs = CGMutablePath(), fill = CGMutablePath()
            func line(_ path: CGMutablePath, _ pts: [CGPoint]) {
                path.move(to: S(pts[0]))
                for q in pts.dropFirst() { path.addLine(to: S(q)) }
            }
            func dot(_ p: CGPoint, _ r: CGFloat) {
                let rr = r + extra / 2
                fill.addEllipse(in: CGRect(x: p.x - rr, y: -p.y - rr, width: 2 * rr, height: 2 * rr))
            }
            // Beckenschale
            let hl = P("hipL"), hr = P("hipR")
            let bowl = [CGPoint(x: hl.x - ax * u * 0.10 - nx * u * 0.10, y: hl.y - ay * u * 0.10 - ny * u * 0.10),
                        CGPoint(x: hr.x - ax * u * 0.10 + nx * u * 0.10, y: hr.y - ay * u * 0.10 + ny * u * 0.10),
                        CGPoint(x: hr.x + ax * u * 0.04 - nx * u * 0.02, y: hr.y + ay * u * 0.04 - ny * u * 0.02),
                        CGPoint(x: pv.x + ax * u * 0.08, y: pv.y + ay * u * 0.08),
                        CGPoint(x: hl.x + ax * u * 0.04 + nx * u * 0.02, y: hl.y + ay * u * 0.04 + ny * u * 0.02)]
            fill.addLines(between: bowl.map(S))
            fill.closeSubpath()
            if extra > 0 { line(spine, bowl + [bowl[0]]) }
            // Wirbelsäule, Schlüsselbein, Arme, Beine, Füße, Gelenke
            line(spine, [P("neck"), P("chest"), P("mid"), P("pelvis")])
            line(collar, [P("shL"), P("shR")])
            for (side, out) in [("L", CGFloat(-1)), ("R", 1)] {
                line(arms, [P("sh" + side), P("el" + side), P("ha" + side)])
                line(legs, [P("hip" + side), P("kn" + side), P("ft" + side)])
                for (j, r) in [("sh", 0.6), ("el", 0.6), ("ha", 0.95), ("kn", 0.7), ("hip", 0.7)] as [(String, CGFloat)] {
                    dot(P(j + side), w * r)
                }
                let f = P("ft" + side)
                line(spine, [f, CGPoint(x: f.x + out * u * 0.13, y: f.y + u * 0.02)])
                dot(f, w * 0.7)
            }
            // Rippen
            for i in 0..<4 {
                let t = 0.22 + 0.2 * CGFloat(i)
                let bx = nk.x + (md.x - nk.x) * t, by = nk.y + (md.y - nk.y) * t
                let hw = u * (0.30 - 0.035 * CGFloat(i))
                for s in [CGFloat(-1), 1] {
                    line(ribs, [0, 0.35, 0.7, 0.9, 1.0].map { (f: CGFloat) in
                        CGPoint(x: bx + nx * hw * f * s + ax * u * 0.12 * f * f, y: by + ny * hw * f * s + ay * u * 0.12 * f * f)
                    })
                }
            }
            let groups: [(CGMutablePath, CGFloat)] = [(spine, w), (collar, w * 0.8), (arms, w * 0.75), (legs, w * 0.85), (ribs, w * 0.5)]
            for (i, (path, width)) in groups.enumerated() {
                layers[i].path = path
                layers[i].lineWidth = max(1, width + extra)
            }
            layers[5].path = fill
        }
    }
}
