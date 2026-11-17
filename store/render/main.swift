// Rendert die eingebauten Zeiger-Designs offscreen als Bildfolge – ohne Bildschirm, ohne echte Maus.
// Die Designs selbst kommen 1:1 aus src/*.swift; hier nur: simulierte Mausbahn + Klicks, CARenderer.
//
// Aufruf: store/render/render-pointers.sh [design …]
import Cocoa
import Metal
import QuartzCore
import ObjectiveC

// Theme, HandSprite, DRAW_WIDTH … kommen aus src/main.swift (generiert in shared.swift, siehe render-pointers.sh).

// ---------- Klicks simulieren: NSEvent.pressedMouseButtons liefert unseren Wert ----------
var fakeButtons = 0
extension NSEvent {
    @objc class func kulisseFakePressedMouseButtons() -> Int { fakeButtons }
}
if let a = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)),
   let b = class_getClassMethod(NSEvent.self, #selector(NSEvent.kulisseFakePressedMouseButtons)) {
    method_exchangeImplementations(a, b)
}

// ---------- Bühne ----------
let W: CGFloat = 400, H: CGFloat = 250, SCALE: CGFloat = 4   // Ausschnitt um den Zeiger, 4× gerendert
let FPS = 25.0, SECONDS = 6.0
let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "pointer-frames")
let all = ["halloween", "spinne", "addmore", "zug", "fuesse", "ente", "skelett", "ufo", "wueste", "peitsche"]
let wanted = args.count > 2 ? Array(args[2...]) : all

/// Mausbahn: liegende Acht mit einer Pause in der Mitte (Ente: Küken holen auf), periodisch über SECONDS.
func mouse(at t: Double, design: String) -> CGPoint {
    var u = t / SECONDS                                   // 0…1
    // 0.42…0.58: kurz stehen bleiben
    if u > 0.42 && u < 0.58 { u = 0.42 } else if u >= 0.58 { u = 0.42 + (u - 0.58) / 0.42 * 0.58 }
    let a = 2 * Double.pi * u
    // Höhe der Bahn (Anteil von H, y nach oben) und Ausschlag: UFO fliegt tief, damit es Kühe erwischt;
    // Skelett und Peitsche hängen unter dem Zeiger, also oben entlang
    let (level, swing): (Double, Double) = switch design {
    case "ufo": (0.36, 0.14)
    case "skelett": (0.84, 0.05)
    case "peitsche": (0.78, 0.08)
    default: (0.5, 0.24)
    }
    let cx = Double(W) / 2, cy = Double(H) * level
    return CGPoint(x: cx + Double(W) * 0.32 * sin(a), y: cy + Double(H) * swing * sin(2 * a))
}
/// Klicks bei 1,4 s und 3,9 s (je 0,15 s gedrückt)
func pressed(at t: Double) -> Bool { [1.4, 3.9].contains { t >= $0 && t < $0 + 0.15 } }

final class Stage {
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    let pw = Int(W * SCALE), ph = Int(H * SCALE)
    lazy var texture: MTLTexture = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pw, height: ph, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = .managed
        return device.makeTexture(descriptor: d)!
    }()
    lazy var renderer: CARenderer = {
        let r = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue,
                                                          kCARendererColorSpace as String: CGColorSpace(name: CGColorSpace.sRGB)!])
        r.bounds = CGRect(x: 0, y: 0, width: pw, height: ph)
        return r
    }()
    let top = CALayer(), canvas = CALayer()

    init() {
        top.frame = CGRect(x: 0, y: 0, width: W * SCALE, height: H * SCALE)
        top.backgroundColor = CGColor(srgbRed: 0.93, green: 0.945, blue: 0.96, alpha: 1)   // helle Folie
        canvas.anchorPoint = .zero
        canvas.bounds = CGRect(x: 0, y: 0, width: W, height: H)
        canvas.transform = CATransform3DMakeScale(SCALE, SCALE, 1)
        canvas.position = .zero
        top.addSublayer(canvas)
        renderer.layer = top
    }

    func snapshot() -> CGImage {
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.synchronize(resource: texture)
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
        texture.getBytes(&bytes, bytesPerRow: pw * 4, from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        return ctx.makeImage()!
    }
}

func save(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Ein Design: Ebenen anlegen und eine Update-Funktion liefern, die die Maus setzt.
func makeDesign(_ name: String, on canvas: CALayer) -> (CGPoint) -> Void {
    let bounds = CGRect(x: 0, y: 0, width: W, height: H)
    switch name {
    case "halloween":
        let fx = HalloweenFX(); [fx.night, fx.glow, fx.top].forEach(canvas.addSublayer); fx.setVisible(true); fx.bats = true
        return { fx.update(mouse: $0, bounds: bounds) }
    case "spinne":
        let fx = SpiderFX(); canvas.addSublayer(fx.root); fx.setVisible(true); fx.clicks = true
        return { fx.update(mouse: $0, bounds: bounds) }
    case "addmore":
        let fx = LaserFX(); canvas.addSublayer(fx.root); fx.setVisible(true); fx.clicks = true
        return { fx.update(mouse: $0) }
    case "zug":
        let fx = TrainCursorFX(); canvas.addSublayer(fx.root); fx.setVisible(true)
        return { fx.update(mouse: $0) }
    case "fuesse":
        let fx = FeetFX(); canvas.addSublayer(fx.root); fx.setVisible(true); fx.clicks = true
        return { fx.update(mouse: $0) }
    case "ente":
        let fx = DuckFX(); canvas.addSublayer(fx.root); fx.setVisible(true); fx.clicks = true
        return { fx.update(mouse: $0, bounds: bounds) }
    case "skelett":
        let fx = SkeletonFX(); canvas.addSublayer(fx.root); fx.setVisible(true)
        // eingebauter 💀-Kopf, wie in Overlay.sprite (src/main.swift)
        if let head = prepare(skullHeadImage(glow: SK_DEFAULT_GLOW), source: "💀") { fx.setHead(head, height: Theme.skelett.handHeight) }
        return { fx.update(mouse: $0) }
    case "ufo":
        let fx = UfoFX(); canvas.addSublayer(fx.root); fx.setVisible(true); fx.clicks = true
        return { fx.update(mouse: $0, bounds: bounds) }
    case "wueste":
        let fx = DesertFX(); canvas.addSublayer(fx.root); fx.setVisible(true); fx.clicks = true
        return { fx.update(mouse: $0) }
    case "peitsche":
        let fx = WhipFX(); canvas.addSublayer(fx.root); fx.setVisible(true); fx.clicks = true; fx.flicks = true
        return { fx.update(mouse: $0) }
    default:
        fatalError("unbekanntes Design \(name)")
    }
}

// ---------- Ablauf: Echtzeit-Takt (die Designs rechnen mit CACurrentMediaTime) ----------
var queueOfDesigns = wanted
func runNext() {
    guard let name = queueOfDesigns.first else { exit(0) }
    queueOfDesigns.removeFirst()
    let stage = Stage()
    let update = makeDesign(name, on: stage.canvas)
    let dir = outDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let warmup = 2.0                                       // Küken, Kühe usw. erst einmal ankommen lassen
    let start = CACurrentMediaTime()
    var frame = 0
    var images: [CGImage] = []
    let timer = Timer(timeInterval: 1 / 120, repeats: true) { t in
        let elapsed = CACurrentMediaTime() - start
        let local = (elapsed - warmup).truncatingRemainder(dividingBy: SECONDS)
        let tt = elapsed < warmup ? elapsed.truncatingRemainder(dividingBy: SECONDS) : local
        fakeButtons = elapsed >= warmup && pressed(at: tt) ? 1 : 0
        update(mouse(at: tt, design: name))
        guard elapsed >= warmup else { return }
        let due = Int((elapsed - warmup) * FPS)
        if due >= frame {
            images.append(stage.snapshot())
            frame += 1
            if Double(frame) >= SECONDS * FPS {
                t.invalidate()
                for (i, img) in images.enumerated() { save(img, dir.appendingPathComponent(String(format: "%04d.png", i))) }
                print(name, images.count, "Bilder"); fflush(stdout)
                DispatchQueue.main.async(execute: runNext)
            }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async(execute: runNext)
app.run()
