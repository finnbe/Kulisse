// Zeichnet einen Totenkopf-Kopf für das Skelett-Design (Nadel oben = Klickpunkt, Totenkopf darunter).
// Stil wie der Skelett-Körper: schwarzer Knochen mit Leuchtrand, glühende Augenhöhlen.
//   swift src/make_skull.swift "#FF5F00" kopf.png
import Cocoa

let args = CommandLine.arguments
guard args.count == 3 else { print("Aufruf: swift make_skull.swift <#farbe> <ausgabe.png>"); exit(1) }
var hex = args[1]; if hex.hasPrefix("#") { hex.removeFirst() }
let v = UInt64(hex, radix: 16) ?? 0xFF5F00
let glow = NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
let hot = glow.blended(withFraction: 0.6, of: NSColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 1))!
let bone = NSColor(white: 12 / 255, alpha: 1)

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S), flipped: true) { _ in
    let cx: CGFloat = 512

    // Umriss des Schädels: Kalotte + Wangenknochen + Kiefer
    let cranium = NSBezierPath(ovalIn: NSRect(x: cx - 165, y: 330, width: 330, height: 300))
    let cheeks = NSBezierPath(roundedRect: NSRect(x: cx - 140, y: 520, width: 280, height: 90), xRadius: 45, yRadius: 45)
    let jaw = NSBezierPath(roundedRect: NSRect(x: cx - 100, y: 580, width: 200, height: 120), xRadius: 34, yRadius: 34)
    let skull = [cranium, cheeks, jaw]

    // Nadel
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: cx, y: 72))
    needle.line(to: NSPoint(x: cx + 24, y: 345))
    needle.line(to: NSPoint(x: cx - 24, y: 345))
    needle.close()

    // 1) weiches Leuchten um alles
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = glow.withAlphaComponent(0.9)
    sh.shadowBlurRadius = 34
    sh.shadowOffset = .zero
    sh.set()
    glow.setFill()
    needle.fill()
    for p in skull { p.lineWidth = 22; glow.setStroke(); p.stroke(); p.fill() }
    NSGraphicsContext.restoreGraphicsState()

    // 2) Leuchtrand, dann schwarzer Knochen
    for p in skull { p.lineWidth = 16; glow.setStroke(); p.stroke() }
    bone.setFill()
    for p in skull { p.fill() }

    // 3) Augenhöhlen: glühend von innen
    for ex in [cx - 68, cx + 68] {
        let r = NSRect(x: ex - 52, y: 455, width: 104, height: 112)
        let eye = NSBezierPath(ovalIn: r)
        NSGraphicsContext.saveGraphicsState()
        eye.addClip()
        NSGradient(colors: [hot, glow, glow.blended(withFraction: 0.55, of: .black)!])!
            .draw(in: eye, relativeCenterPosition: NSPoint(x: 0, y: -0.15))
        NSGraphicsContext.restoreGraphicsState()
    }

    // 4) Nasenloch (umgedrehtes Herz)
    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: cx, y: 590))
    nose.curve(to: NSPoint(x: cx - 26, y: 618), controlPoint1: NSPoint(x: cx - 10, y: 590), controlPoint2: NSPoint(x: cx - 30, y: 600))
    nose.line(to: NSPoint(x: cx, y: 640))
    nose.line(to: NSPoint(x: cx + 26, y: 618))
    nose.curve(to: NSPoint(x: cx, y: 590), controlPoint1: NSPoint(x: cx + 30, y: 600), controlPoint2: NSPoint(x: cx + 10, y: 590))
    glow.blended(withFraction: 0.25, of: .black)!.setFill()
    nose.fill()

    // 5) Zähne: Linie + Zahnzwischenräume
    glow.withAlphaComponent(0.85).setStroke()
    let mouth = NSBezierPath()
    mouth.move(to: NSPoint(x: cx - 72, y: 662))
    mouth.curve(to: NSPoint(x: cx + 72, y: 662), controlPoint1: NSPoint(x: cx - 30, y: 672), controlPoint2: NSPoint(x: cx + 30, y: 672))
    mouth.lineWidth = 6
    mouth.stroke()
    for i in -3...3 {
        let x = cx + CGFloat(i) * 20
        let t = NSBezierPath()
        t.move(to: NSPoint(x: x, y: 646))
        t.line(to: NSPoint(x: x, y: 684))
        t.lineWidth = 5
        t.lineCapStyle = .round
        t.stroke()
    }

    // 6) kleiner Riss oben auf der Kalotte
    let crack = NSBezierPath()
    crack.move(to: NSPoint(x: cx - 40, y: 340))
    crack.line(to: NSPoint(x: cx - 55, y: 385))
    crack.line(to: NSPoint(x: cx - 35, y: 405))
    crack.line(to: NSPoint(x: cx - 58, y: 440))
    crack.lineWidth = 5
    crack.lineJoinStyle = .round
    glow.withAlphaComponent(0.8).setStroke()
    crack.stroke()
    return true
}
let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("geschrieben:", args[2])
