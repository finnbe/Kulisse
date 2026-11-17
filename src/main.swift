// Kulisse (früher „Waschbär Pointer“) – Zeiger-Designs und Live-Hintergründe für macOS.
//
// Über allem Klickbaren (wo macOS die Link-Hand zeigt) wird stattdessen eine Hand auf einem Stab
// gezeichnet. Die Fingerspitze folgt der Maus; Hand und Stab sind immer um TILT_DEGREES
// nach unten rechts geneigt, der Stab hat eine feste Länge (STICK_LENGTH).
//
// Designs (im 🦝-Menü umschaltbar): Zeigestock (weiße Hand, "zeigestock-hand.png") und
// Waschbär ("waschbaer-hand.png"). Die Bilder werden zuerst neben der App gesucht, dann in der App.
// Finger zeigt nach oben, transparenter Hintergrund. Der Teleskopstab wird im Code gezeichnet.
//
// Tasten:  Ctrl+Option+P  Modus wechseln: nur über Links -> immer -> aus
//          Ctrl+Option+V  Zeichenmodus an/aus (fürs Präsentieren): mit gedrückter linker Maustaste
//                         malen, der Strich verschwindet DRAW_FADE_AFTER Sekunden nach dem Loslassen.
//                         Klicks gehen in dem Modus nicht an die Präsentation durch. Rechtsklick löscht alles.
//          Ctrl+Option+Q  beenden
// Außerdem gibt es ein 🦝-Menü in der Menüleiste.

import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// ---------- Einstellungen ----------
let TILT_DEGREES: CGFloat = 45     // Neigung: Hand und Stab zeigen immer so viel Grad nach unten rechts
let STICK_LENGTH: CGFloat = 500    // Länge des Stabs ab dem Handgelenk, in Punkten
let GRIP_WIDTH: CGFloat = 24      // Dicke des schwarzen Griffs, in Punkten (die Chromteile sind dünner)
let DRAW_COLOR = NSColor(srgbRed: 0xF3 / 255.0, green: 0x6D / 255.0, blue: 0x03 / 255.0, alpha: 1)  // addmore-Orange #F36D03
let DRAW_WIDTH: CGFloat = 6        // Strichdicke in Punkten
let DRAW_FADE_AFTER: Double = 2.5    // Sekunden nach dem Loslassen, bis der Strich verschwindet
let DRAW_FADE_TIME: Double = 0.6   // so lange dauert das Ausblenden

// Private (aber seit Jahren stabile) API: erlaubt das Ausblenden des Mauszeigers,
// obwohl die App nicht im Vordergrund ist.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// Hand-Design: Bilddatei und Größe (Fingerspitze bis unterer Rand des Bildes, in Punkten)
enum Theme: String, CaseIterable {
    case zeigestock, halter, waschbaer, halloween, spinne, addmore, zug, fuesse, ente, skelett, ufo, wueste, peitsche
    var title: String {
        switch self {
        case .zeigestock: return "Zeigestock"
        case .halter: return "Waschbär hält Stab"
        case .waschbaer: return "Waschbär"
        case .halloween: return "Halloween 🎃 (Taschenlampe)"
        case .spinne: return "Halloween 🕷️ (Spinne)"
        case .addmore: return "addmore (Laserpointer)"
        case .zug: return "Zug (Schienen malen)"
        case .fuesse: return "Grüne Füße"
        case .ente: return "Ente mit Küken"
        case .skelett: return "Skelett 💀"
        case .ufo: return "UFO-Kuh-Entführung 🛸"
        case .wueste: return "Wüstenplanet ✦"
        case .peitsche: return "Peitsche 🤠 (knallt beim Klicken)"
        }
    }
    var imageName: String { self == .waschbaer ? "waschbaer-hand" : "zeigestock-hand" }
    var handHeight: CGFloat { self == .waschbaer ? 150 : self == .skelett ? 100 : 80 }
    /// Bild einer Hand, die den Griff hält (+ gleichnamige .json von src/make_halter.swift)
    var holderName: String? { self == .halter ? "waschbaer-halter" : nil }
}

/// Hand am Griff: Bild + wo im Bild der Griff verläuft (Pixel, Ursprung oben links)
struct Holder {
    let image: CGImage
    let gripX: CGFloat, gripWidth: CGFloat, anchorY: CGFloat
}

func findResource(_ name: String, _ ext: String) -> URL? {
    let beside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
    if FileManager.default.fileExists(atPath: beside.path) { return beside }
    return Bundle.main.url(forResource: name, withExtension: ext)
}

func loadHolder(_ theme: Theme) -> Holder? {
    guard let name = theme.holderName, let png = findResource(name, "png"), let js = findResource(name, "json"),
          let img = NSImage(contentsOf: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = try? Data(contentsOf: js),
          let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
          let gx = meta["gripX"], let gw = meta["gripWidth"], let ay = meta["anchorY"] else { return nil }
    return Holder(image: img, gripX: gx, gripWidth: gw, anchorY: ay)
}

enum Mode: String, CaseIterable {
    case links, always, off
    var title: String {
        switch self {
        case .links: return "Nur über Links"
        case .always: return "Immer (ersetzt den Zeiger)"
        case .off: return "Aus"
        }
    }
}

// ---------- Bild laden & vorbereiten ----------
struct HandSprite {
    let image: CGImage
    let tip: CGPoint     // Pixel, Ursprung oben links
    let wrist: CGPoint
    let source: String
}

func loadSprite(_ theme: Theme) -> HandSprite? {
    let beside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(theme.imageName + ".png")
    let candidates: [URL?] = [beside,
                              Bundle.main.url(forResource: theme.imageName, withExtension: "png"),
                              Bundle.main.url(forResource: "platzhalter-hand", withExtension: "png")]
    for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
        if let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let s = prepare(img, source: url.lastPathComponent) {
            return s
        }
    }
    return nil
}

/// Macht einen eventuell nicht-transparenten Hintergrund transparent (Flood-Fill von den Ecken),
/// schneidet auf die Hand zu und findet Fingerspitze (oben) und Handgelenk (unten).
func prepare(_ src: CGImage, source: String) -> HandSprite? {
    let w = src.width, h = src.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))   // Zeile 0 = oben

    @inline(__always) func a(_ i: Int) -> UInt8 { px[i * 4 + 3] }

    // Hintergrund ohne Transparenz? (alle Ecken deckend) -> von den Ecken aus wegfüllen
    let corners = [0, w - 1, (h - 1) * w, h * w - 1]
    if corners.allSatisfy({ a($0) > 250 }) {
        let ref = (0..<3).map { c in corners.map { Int(px[$0 * 4 + c]) }.reduce(0, +) / 4 }
        var seen = [Bool](repeating: false, count: w * h)
        var stack = corners
        let tol = 60
        while let i = stack.popLast() {
            if seen[i] { continue }
            seen[i] = true
            let d = abs(Int(px[i*4]) - ref[0]) + abs(Int(px[i*4+1]) - ref[1]) + abs(Int(px[i*4+2]) - ref[2])
            if d > tol { continue }
            px[i*4] = 0; px[i*4+1] = 0; px[i*4+2] = 0; px[i*4+3] = 0
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }
    }

    // Umriss der Hand (Schein/Glow mit wenig Deckkraft zählt nicht)
    let solid: UInt8 = 128
    var top = h, bottom = -1, left = w, right = -1
    for y in 0..<h { for x in 0..<w where a(y * w + x) > solid {
        top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
    } }
    guard bottom > top else { return nil }

    func centerX(rows: ClosedRange<Int>) -> CGFloat {
        var sum = 0, n = 0
        for y in rows { for x in 0..<w where a(y * w + x) > solid { sum += x; n += 1 } }
        return n > 0 ? CGFloat(sum) / CGFloat(n) : CGFloat(left + right) / 2
    }
    let handH = bottom - top
    let tipX = centerX(rows: top...min(bottom, top + max(2, handH / 40)))
    let wristX = centerX(rows: max(top, bottom - max(2, handH / 25))...bottom)

    // Rand für Glow/Schatten dazunehmen und zuschneiden
    let pad = max(4, handH / 12)
    let cx0 = max(0, left - pad), cy0 = max(0, top - pad)
    let cx1 = min(w, right + pad + 1), cy1 = min(h, bottom + pad + 1)
    guard let full = ctx.makeImage(),
          let cropped = full.cropping(to: CGRect(x: cx0, y: cy0, width: cx1 - cx0, height: cy1 - cy0))
    else { return nil }
    return HandSprite(image: cropped,
                      tip: CGPoint(x: tipX - CGFloat(cx0), y: CGFloat(top - cy0)),
                      wrist: CGPoint(x: wristX - CGFloat(cx0), y: CGFloat(bottom - cy0)),
                      source: source)
}

// ---------- Zeichenfläche (nimmt nur im Zeichenmodus Mausklicks an) ----------
final class DrawView: NSView {
    weak var owner: Overlay?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func global(_ e: NSEvent) -> CGPoint { window?.convertPoint(toScreen: e.locationInWindow) ?? NSEvent.mouseLocation }
    override func mouseDown(with e: NSEvent) { owner?.strokeBegan(global(e)) }
    override func mouseDragged(with e: NSEvent) { owner?.strokeMoved(global(e)) }
    override func mouseUp(with e: NSEvent) { owner?.strokeEnded() }
    override func rightMouseDown(with e: NSEvent) { owner?.clearStrokes() }
}

// ---------- Overlay ----------
final class Overlay: NSObject, NSApplicationDelegate {
    var window: NSPanel!
    let strokes = CALayer()            // Striche in globalen Bildschirmkoordinaten
    var currentStroke: CAShapeLayer?
    var currentPath: CGMutablePath?
    var drawItem: NSMenuItem?
    var drawing = false {
        didSet {
            window.ignoresMouseEvents = !drawing
            if !drawing { strokeEnded() }
            lastMouse = .zero
            refreshMenu()
        }
    }
    let stick = CALayer()              // Teleskopstab; oberes Ende (anchorPoint) sitzt in der Hand
    var themeItems: [Theme: NSMenuItem] = [:]
    var theme: Theme = Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .zeigestock {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            if theme != oldValue && !suppressFade { crossfadeTheme() }
        }
    }
    var suppressFade = false
    // importiertes Design (src/themes.swift): baut auf `theme` auf und überschreibt Bild, Stab, Strich
    var custom: CustomTheme?
    var customItems: [NSMenuItem] = []
    var deleteThemeItem: NSMenuItem?
    var handHeight: CGFloat { custom?.handHeight ?? theme.handHeight }
    var stickLength: CGFloat { custom?.stickLength ?? STICK_LENGTH }
    var tiltDegrees: CGFloat { custom?.tilt ?? TILT_DEGREES }

    func select(builtin t: Theme) {
        let changed = custom != nil || t != theme
        custom = nil
        UserDefaults.standard.removeObject(forKey: "customTheme")
        suppressFade = true; theme = t; suppressFade = false
        if changed { crossfadeTheme() } else { reloadImage() }   // nochmal anklicken = Bild neu laden
    }

    func select(custom c: CustomTheme) {
        custom = c
        UserDefaults.standard.set(c.folder.lastPathComponent, forKey: "customTheme")
        suppressFade = true; theme = c.base; suppressFade = false
        crossfadeTheme()
    }

    func loadCurrentSprite() -> HandSprite? {
        if theme == .skelett && custom?.handImage == nil {       // eingebauter 💀-Kopf
            return prepare(skullHeadImage(glow: custom?.effectColor ?? SK_DEFAULT_GLOW), source: "💀 (eingebaut)")
        }
        if let u = custom?.handImage, let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let s = prepare(img, source: u.lastPathComponent) { return s }
        return loadSprite(theme)
    }

    func loadCurrentHolder() -> Holder? {
        if let c = custom, let u = c.holderImage, let m = c.holderMeta,
           let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return Holder(image: img, gripX: m.gripX, gripWidth: m.gripWidth, anchorY: m.anchorY)
        }
        return loadHolder(theme)
    }
    var holder: Holder?
    let HOLD_AT: CGFloat = 0.55        // wo die Hand den Griff hält (0 = oberes Ende, 1 = unteres Ende)
    let hand = CALayer()
    let fx = HalloweenFX()             // Halloween-Designs (src/halloween.swift)
    let spiderFX = SpiderFX()
    let laserFX = LaserFX()            // addmore-Design (src/addmore.swift)
    var paws: PawStamper?              // Pfotenspur im Zeichenmodus (Waschbär-Designs)
    let trainFX = TrainCursorFX()      // Zug-Design (src/zug.swift)
    var tracks: [TrainTrack] = []      // gemalte Strecken, auf denen gerade ein Zug fährt
    var currentTrack: TrainTrack?
    let feetFX = FeetFX()              // Design "Grüne Füße" (src/fuesse.swift)
    var feet: FootStamper?             // Fußspur im Zeichenmodus
    let duckFX = DuckFX()              // Design "Ente mit Küken" (src/ente.swift)
    let skeletonFX = SkeletonFX()      // Design "Skelett" (src/skelett.swift)
    let ufoFX = UfoFX()                // Design "UFO-Kuh-Entführung" (src/ufo.swift)
    let whipFX = WhipFX()              // Design "Peitsche" (src/peitsche.swift)
    let desertFX = DesertFX()          // Design "Wüstenplanet" (src/wueste.swift)
    var sprite: HandSprite?
    var statusItem: NSStatusItem!
    var modeItems: [Mode: NSMenuItem] = [:]
    var loginItem: NSMenuItem?
    var cursorHidden = false
    var hideCount = 0
    var lastHideAssert = 0.0
    var overLink = false
    var lastCursorCheck = 0.0
    var lastMouse = CGPoint(x: -1, y: -1)
    var lastScreen: NSScreen?
    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .links {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode"); refreshMenu(); lastMouse = .zero }
    }
    lazy var pointingHand = NSCursor.pointingHand

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(),
                                     "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if let name = UserDefaults.standard.string(forKey: "customTheme"),
           let c = try? loadCustomTheme(folder: themesFolder().appendingPathComponent(name)) {
            custom = c
            suppressFade = true; theme = c.base; suppressFade = false
        }
        sprite = loadCurrentSprite()
        holder = loadCurrentHolder()
        buildWindow()
        buildMenu()
        registerHotKeys()
        watchForCursorResets()
        applySprite()
        // Kommandozeile: --export-theme <datei> / --import-theme <datei> (ohne Dialog, z. B. für Skripte)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-theme"), i + 1 < args.count {
            do { try exportCurrentTheme(to: URL(fileURLWithPath: args[i + 1])); print("Exportiert:", args[i + 1]) }
            catch { print("Fehler:", error.localizedDescription) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--import-theme"), i + 1 < args.count {
            do {
                let t = try importTheme(from: URL(fileURLWithPath: args[i + 1]))
                UserDefaults.standard.set(t.folder.lastPathComponent, forKey: "customTheme")
                UserDefaults.standard.set(t.base.rawValue, forKey: "theme")
                print("Importiert:", t.name, "->", t.folder.path)
            } catch { print("Fehler:", error.localizedDescription) }
            exit(0)
        }
        // Live-Hintergrund (src/wallpaper.swift): --import-wallpaper <datei> / --export-wallpaper <datei> [--embed]
        if let i = args.firstIndex(of: "--import-wallpaper"), i + 1 < args.count {
            let wm = WallpaperManager.shared
            wm.reloadPackages()
            do {
                switch try wm.importFile(URL(fileURLWithPath: args[i + 1])) {
                case .wallpaper(let p):
                    UserDefaults.standard.set(p.id, forKey: "wallpaper")
                    print("Hintergrund importiert:", p.title, "->", p.folder.path)
                case .preset(let pr):
                    UserDefaults.standard.set(pr.wallpaperID, forKey: "wallpaper")
                    print("Vorlage importiert:", pr.name, "->", pr.file?.path ?? "")
                }
            } catch { print("Fehler:", error.localizedDescription) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--export-wallpaper"), i + 1 < args.count {
            let wm = WallpaperManager.shared
            wm.reloadPackages()
            let dest = URL(fileURLWithPath: args[i + 1])
            do {
                try wm.export(to: dest, name: dest.deletingPathExtension().lastPathComponent, embedFiles: args.contains("--embed"))
                print("Exportiert:", dest.path)
            } catch { print("Fehler:", error.localizedDescription) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--settings-preview"), i + 1 < args.count {   // nur zum Testen
            WallpaperManager.shared.reloadPackages()
            WallpaperSettings.shared.renderPreview(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--menu-icon-preview"), i + 1 < args.count {   // nur zum Testen: Menüleisten-Symbol groß
            let icon = kulisseMenuIcon()
            let out = NSImage(size: NSSize(width: 400, height: 180))
            out.lockFocus()
            for (k, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
                bg.setFill(); NSRect(x: CGFloat(k) * 200, y: 0, width: 200, height: 180).fill()
                let tinted = NSImage(size: icon.size, flipped: false) { r in icon.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true }
                tinted.draw(in: NSRect(x: CGFloat(k) * 200 + 30, y: 25, width: 140, height: 126))
                tinted.draw(in: NSRect(x: CGFloat(k) * 200 + 150, y: 150, width: 20, height: 18))   // Originalgröße
            }
            out.unlockFocus()
            if let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t) { try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        if args.contains("--dump-wallpaper-menu") {   // nur zum Testen: Menüaufbau als Text
            WallpaperManager.shared.reloadPackages()
            func dump(_ m: NSMenu, _ d: Int) {
                for it in m.items {
                    if it.isSeparatorItem { print(String(repeating: "  ", count: d) + "—"); continue }
                    print(String(repeating: "  ", count: d) + (it.state == .on ? "✓ " : "  ") + it.title + (it.isEnabled ? "" : "  (grau)"))
                    if let sm = it.submenu { dump(sm, d + 1) }
                }
            }
            dump(WallpaperManager.shared.makeMenuItem().submenu!, 0)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
            renderPreview(to: CommandLine.arguments[i + 1])     // nur zum Testen: Bild statt Overlay
            exit(0)
        }
        startFrameLoop()
        WallpaperManager.shared.start()
        // falls die App beendet wird, muss der Zeiger zurück
        signal(SIGTERM) { _ in CGDisplayShowCursor(CGMainDisplayID()); exit(0) }
    }

    /// Doppelklick auf eine .pointertheme-Datei im Finder -> importieren und auswählen
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if u.pathExtension.lowercased() == WALLPAPER_EXT {            // Live-Hintergrund
                WallpaperManager.shared.start()
                WallpaperManager.shared.importAndShow(u)
                continue
            }
            do {
                let t = try importTheme(from: u)
                if statusItem != nil { rebuildCustomItems() }
                select(custom: t)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                showError("Import ging nicht", error)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) { setCursorHidden(false) }

    func buildWindow() {
        // nicht-aktivierendes Panel: Zeichnen holt die App nicht in den Vordergrund,
        // die Präsentation behält also die Tastatur (Pfeiltasten zum Weiterschalten)
        window = NSPanel(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = DrawView()
        view.owner = self
        view.wantsLayer = true
        view.layer = CALayer()
        window.contentView = view
        buildStick()
        hand.shadowOpacity = 0.3
        hand.shadowRadius = 5
        hand.shadowOffset = CGSize(width: 0, height: -2)
        for l in [stick, hand] as [CALayer] {           // Schatten zwischenspeichern statt jedes Frame neu zu rendern
            l.shouldRasterize = true
            l.rasterizationScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        }
        for l in [stick, hand] as [CALayer] { l.actions = ["position": NSNull(), "transform": NSNull(), "bounds": NSNull(),
                                                         "hidden": NSNull(), "contents": NSNull()] }
        strokes.actions = ["sublayerTransform": NSNull()]
        view.layer!.addSublayer(fx.night)
        view.layer!.addSublayer(fx.glow)
        view.layer!.addSublayer(strokes)
        view.layer!.addSublayer(stick)
        view.layer!.addSublayer(hand)
        view.layer!.addSublayer(fx.top)
        view.layer!.addSublayer(spiderFX.root)
        view.layer!.addSublayer(laserFX.root)
        view.layer!.addSublayer(trainFX.root)
        view.layer!.addSublayer(feetFX.root)
        view.layer!.addSublayer(duckFX.root)
        view.layer!.addSublayer(skeletonFX.root)
        view.layer!.addSublayer(ufoFX.root)
        view.layer!.addSublayer(desertFX.root)
        view.layer!.addSublayer(whipFX.root)
        window.orderFrontRegardless()
    }

    func applySprite() {
        guard let s = sprite else { return }
        skeletonFX.glow = custom?.effectColor ?? SK_DEFAULT_GLOW
        if theme == .skelett { skeletonFX.setHead(s, height: handHeight) }
        let scale = handHeight / max(1, s.wrist.y - s.tip.y)
        let iw = CGFloat(s.image.width), ih = CGFloat(s.image.height)
        hand.contents = s.image
        hand.contentsScale = 1 / scale
        hand.bounds = CGRect(x: 0, y: 0, width: iw * scale, height: ih * scale)
        hand.anchorPoint = CGPoint(x: s.tip.x / iw, y: 1 - s.tip.y / ih)   // Layer-y zeigt nach oben
        hand.minificationFilter = .trilinear
    }

    /// Teleskop-Zeigestock: oben dünne Chrom-Auszüge mit Ringen, unten ein schwarzer Schaumstoffgriff.
    func buildStick() {
        stick.sublayers?.forEach { $0.removeFromSuperlayer() }
        let overlap = handHeight * 0.12
        let total = stickLength + overlap
        stick.anchorPoint = CGPoint(x: 0.5, y: 1)
        stick.bounds = CGRect(x: 0, y: 0, width: GRIP_WIDTH + 4, height: total)
        stick.shadowOpacity = 0.35
        stick.shadowRadius = 4
        stick.shadowOffset = CGSize(width: 2, height: -3)
        let cx = stick.bounds.midX

        func chrome() -> [CGColor] {
            [NSColor(white: 0.35, alpha: 1), NSColor(white: 0.75, alpha: 1), NSColor(white: 0.98, alpha: 1),
             NSColor(white: 0.62, alpha: 1), NSColor(white: 0.85, alpha: 1), NSColor(white: 0.3, alpha: 1)].map { $0.cgColor }
        }
        func foam() -> [CGColor] {
            [NSColor(white: 0.02, alpha: 1), NSColor(white: 0.14, alpha: 1), NSColor(white: 0.24, alpha: 1),
             NSColor(white: 0.1, alpha: 1), NSColor(white: 0.01, alpha: 1)].map { $0.cgColor }
        }
        // ein Stück, gemessen von oben (Layer-y zeigt nach oben, daher umrechnen)
        func piece(top: CGFloat, length: CGFloat, width: CGFloat, colors: [CGColor], radius: CGFloat) {
            let g = CAGradientLayer()
            g.colors = colors
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            g.frame = CGRect(x: cx - width / 2, y: total - top - length, width: width, height: length)
            g.cornerRadius = radius
            stick.addSublayer(g)
        }
        let L = stickLength
        var y: CGFloat = 0
        // Chrom-Auszüge: von dünn (oben) nach dick, an jedem Übergang ein Ring
        let segments: [(len: CGFloat, w: CGFloat)] = [(overlap + L * 0.10, 5), (L * 0.09, 7), (L * 0.09, 9), (L * 0.06, 11)]
        for (i, seg) in segments.enumerated() {
            piece(top: y, length: seg.len, width: seg.w, colors: chrome(), radius: 1)
            y += seg.len
            if i < segments.count - 1 {
                piece(top: y - 3, length: 4, width: seg.w + 3, colors: chrome(), radius: 1.5)   // Ring
            }
        }
        // Griff mit abgerundetem Ende, dazwischen eine Chrom-Manschette
        let grip = total - y
        piece(top: y + 4, length: grip - 4, width: GRIP_WIDTH, colors: foam(), radius: GRIP_WIDTH * 0.45)
        piece(top: y - 1, length: 10, width: GRIP_WIDTH * 0.62, colors: chrome(), radius: 2)

        // Hand, die den Griff hält: Griff im Bild liegt genau auf dem gezeichneten Griff
        if let hd = holder {
            let k = GRIP_WIDTH / hd.gripWidth
            let iw = CGFloat(hd.image.width), ih = CGFloat(hd.image.height)
            let l = CALayer()
            l.contents = hd.image
            l.contentsScale = 1 / k
            l.minificationFilter = .trilinear
            l.bounds = CGRect(x: 0, y: 0, width: iw * k, height: ih * k)
            l.anchorPoint = CGPoint(x: hd.gripX / iw, y: 1 - hd.anchorY / ih)
            l.position = CGPoint(x: cx, y: total - (y + 4 + (grip - 4) * HOLD_AT))
            stick.addSublayer(l)
        }
    }

    /// Prüft, ob macOS gerade die Link-Hand zeigt.
    func systemShowsPointingHand() -> Bool {
        guard let cur = NSCursor.currentSystem else { return false }
        return cur.hotSpot == pointingHand.hotSpot && cur.image.size == pointingHand.image.size
    }

    /// Blendet den Systemzeiger aus/ein. macOS holt den Zeiger gern zurück (App-Wechsel, anderer Bildschirm,
    /// Programme, die ihren Zeiger neu setzen) – deshalb wird das Ausblenden alle 0,2 s erneuert.
    /// Jedes Ausblenden zählt hoch, beim Einblenden wird genauso oft wieder eingeblendet.
    func setCursorHidden(_ hide: Bool, force: Bool = false) {
        let now = CACurrentMediaTime()
        if hide {
            guard force || !cursorHidden || now - lastHideAssert > 0.1 else { return }
            _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(),
                                         "SetsCursorInBackground" as CFString, kCFBooleanTrue)
            CGDisplayHideCursor(CGMainDisplayID())
            hideCount += 1
            if hideCount > 400 {
                // Zähler klein halten: bis auf 2 zurück einblenden (bleibt dabei versteckt), dann wieder verstecken
                while hideCount > 2 { CGDisplayShowCursor(CGMainDisplayID()); hideCount -= 1 }
                CGDisplayHideCursor(CGMainDisplayID())
                hideCount += 1
            }
            lastHideAssert = now
            cursorHidden = true
        } else {
            guard cursorHidden else { return }
            while hideCount > 0 { CGDisplayShowCursor(CGMainDisplayID()); hideCount -= 1 }
            cursorHidden = false
        }
    }

    /// macOS blendet den Zeiger bei App-, Fenster- und Space-Wechseln gern wieder ein: sofort neu verstecken.
    func watchForCursorResets() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reassertHidden() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.reassertHidden() }
    }

    func reassertHidden() {
        guard cursorHidden else { return }
        setCursorHidden(true, force: true)
        // manche Apps setzen ihren Zeiger erst kurz nach dem Wechsel: noch ein paarmal nachfassen
        for delay in [0.05, 0.15, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if self?.cursorHidden == true { self?.setCursorHidden(true, force: true) }
            }
        }
    }

    // ---------- Design-Wechsel mit Überblendung ----------
    var fadeGeneration = 0
    func crossfadeTheme() {
        fadeGeneration += 1
        let gen = fadeGeneration
        fade(to: 0, duration: 0.3) { [weak self] in
            guard let self = self, gen == self.fadeGeneration else { return }   // schneller erneuter Wechsel
            self.reloadImage()
            self.lastMouse = .zero
            self.tick()
            self.fade(to: 1, duration: 0.3) {}
        }
    }

    func fade(to value: Float, duration: Double, done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        for l in [hand, stick, fx.night, fx.glow, fx.top, spiderFX.root, laserFX.root, trainFX.root, feetFX.root, duckFX.root, skeletonFX.root, ufoFX.root, desertFX.root, whipFX.root] {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = l.presentation()?.opacity ?? l.opacity
            a.toValue = value
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.opacity = value
            l.add(a, forKey: "fade")
        }
        CATransaction.commit()
    }

    // ---------- Pause für Dialoge und das Menü: normaler Mac-Zeiger statt eigenem ----------
    var suspendCount = 0
    func suspendOverlay() {
        suspendCount += 1
        setCursorHidden(false)
        window.orderOut(nil)
    }
    func resumeOverlay() {
        suspendCount = max(0, suspendCount - 1)
        guard suspendCount == 0 else { return }
        window.orderFrontRegardless()
        lastMouse = .zero
    }
    /// Führt einen Dialog mit dem normalen Mac-Zeiger aus (z. B. runModal).
    func withSystemCursor<T>(_ body: () -> T) -> T {
        suspendOverlay()
        defer { resumeOverlay() }
        return body()
    }

    // ---------- Bildrate ----------
    var displayLink: AnyObject?
    var lastTickAt: Double = 0
    /// Aktualisiert synchron zum Bildschirm (60 Hz auf normalen Monitoren, 120 Hz auf ProMotion),
    /// statt mit einem freien Timer, der gegen die Bildwiederholung "schwebt" und ruckelt.
    func startFrameLoop() {
        if #available(macOS 14.0, *) {
            let link = window.contentView!.displayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)       // .common: läuft auch, während Menüs offen sind
            displayLink = link
        }
        // Reserve-Takt: springt ein, wenn der Display-Link pausiert (Fenster versteckt, ältere macOS-Versionen)
        let backup = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.displayLink == nil || CACurrentMediaTime() - self.lastTickAt > 0.05 { self.tick() }
        }
        RunLoop.main.add(backup, forMode: .common)
    }
    @objc func frame(_ link: AnyObject) { tick() }

    var fpsCount = 0, fpsStart: Double = 0
    let fpsLog = ProcessInfo.processInfo.environment["WP_FPS"] != nil   // nur zum Messen: WP_FPS=1
    func tick() {
        lastTickAt = CACurrentMediaTime()
        if fpsLog {
            fpsCount += 1
            if lastTickAt - fpsStart >= 1 {
                print("Bilder/s:", fpsCount, "Bildschirm:", lastScreen?.localizedName ?? "-"); fflush(stdout)
                fpsCount = 0; fpsStart = lastTickAt
            }
        }
        guard suspendCount == 0 else { setCursorHidden(false); return }
        // Züge auf gemalten Strecken weiterfahren lassen (auch wenn die Maus stillsteht)
        tracks.removeAll { !$0.alive }
        tracks.forEach { $0.update() }
        let mouse = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        if mode == .links && (now - lastCursorCheck > 0.03 || mouse != lastMouse) {
            // während die eigene Hand sichtbar ist, ist der Systemzeiger versteckt – kurz einblenden
            // ist nicht nötig: currentSystem liefert trotzdem den Zeiger, den macOS zeigen würde
            lastCursorCheck = now
            overLink = systemShowsPointingHand()
        }
        let lamp = theme == .halloween, spin = theme == .spinne, laser = theme == .addmore, train = theme == .zug
        let walk = theme == .fuesse, ducks = theme == .ente, cowsUFO = theme == .ufo, desert = theme == .wueste
        let whip = theme == .peitsche
        let halloween = lamp || spin || laser || train || walk || ducks || cowsUFO || desert || whip        // Effekt-Designs: immer an, außer im Modus "Aus"
        let show = halloween ? (drawing || mode != .off)
                             : sprite != nil && (drawing || mode == .always || (mode == .links && overLink))
        let skel = theme == .skelett               // Skelett: Sichtbarkeit wie die Stab-Designs, eigener Kopf
        setCursorHidden(show)
        hand.isHidden = !show || halloween || skel
        stick.isHidden = !show || halloween || skel
        skeletonFX.setVisible(show && skel)
        fx.setVisible(show && lamp)
        fx.bats = !drawing
        spiderFX.setVisible(show && spin)
        spiderFX.clicks = !drawing
        laserFX.setVisible(show && laser)
        laserFX.clicks = !drawing
        trainFX.setVisible(show && train)
        feetFX.setVisible(show && walk)
        feetFX.clicks = !drawing
        duckFX.setVisible(show && ducks)
        duckFX.clicks = !drawing
        ufoFX.setVisible(show && cowsUFO)
        ufoFX.clicks = !drawing
        desertFX.setVisible(show && desert)
        desertFX.clicks = !drawing
        whipFX.setVisible(show && whip)
        whipFX.clicks = drawing                  // Peitsche knallt nur im Zeichenmodus
        whipFX.flicks = drawing
        guard show, halloween || skel || mouse != lastMouse || window.frame.isEmpty else { return }
        lastMouse = mouse

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        if screen != lastScreen {
            lastScreen = screen
            window.setFrame(screen.frame, display: false)
            strokes.sublayerTransform = CATransform3DMakeTranslation(-screen.frame.minX, -screen.frame.minY, 0)
        }
        let p = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)  // Fenster-Koordinaten
        if lamp {
            fx.update(mouse: p, bounds: CGRect(origin: .zero, size: screen.frame.size))
        } else if spin {
            spiderFX.update(mouse: p, bounds: CGRect(origin: .zero, size: screen.frame.size))
        } else if laser {
            laserFX.update(mouse: p)
        } else if train {
            trainFX.update(mouse: p)
        } else if walk {
            feetFX.update(mouse: p)
        } else if ducks {
            duckFX.update(mouse: p, bounds: CGRect(origin: .zero, size: screen.frame.size))
        } else if skel {
            skeletonFX.update(mouse: p)
        } else if cowsUFO {
            ufoFX.update(mouse: p, bounds: CGRect(origin: .zero, size: screen.frame.size))
        } else if desert {
            desertFX.update(mouse: p)
        } else if whip {
            whipFX.update(mouse: p)
        } else {
            placeHand(at: p)
        }
    }

    func placeHand(at tip: CGPoint) {
        guard let s = sprite else { return }
        // Winkel: Vektor Fingerspitze->Handgelenk im Bild soll fest nach unten rechts zeigen
        let scale = handHeight / max(1, s.wrist.y - s.tip.y)
        let imgVec = CGPoint(x: (s.wrist.x - s.tip.x) * scale, y: -(s.wrist.y - s.tip.y) * scale)
        let want = -(90 - tiltDegrees) * .pi / 180       // Richtung Fingerspitze -> Handgelenk: unten rechts
        let rot = want - atan2(imgVec.y, imgVec.x)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hand.position = tip
        hand.transform = CATransform3DMakeRotation(rot, 0, 0, 1)

        // Handgelenk auf dem Bildschirm, Stab von dort in derselben Richtung weiter
        let c = cos(rot), sn = sin(rot)
        let wrist = CGPoint(x: tip.x + imgVec.x * c - imgVec.y * sn, y: tip.y + imgVec.x * sn + imgVec.y * c)
        let dir = want                                     // Stab läuft in derselben Linie weiter
        let overlap = handHeight * 0.12                                         // Stab steckt etwas in der Faust
        let start = CGPoint(x: wrist.x - cos(dir) * overlap, y: wrist.y - sin(dir) * overlap)
        stick.position = start
        stick.transform = CATransform3DMakeRotation(dir + .pi / 2, 0, 0, 1)
        CATransaction.commit()
    }

    /// Zeichnet Hand + Stab einmal in eine PNG-Datei (weißer Hintergrund), ohne den Zeiger anzufassen.
    func renderPreview(to path: String) {
        let size = CGSize(width: 700, height: 700)
        window.setFrame(CGRect(origin: .zero, size: size), display: false)
        lastScreen = nil
        let layer = window.contentView!.layer!
        layer.frame = CGRect(origin: .zero, size: size)
        hand.isHidden = false
        stick.isHidden = false
        if theme == .peitsche {
            hand.isHidden = true
            stick.isHidden = true
            whipFX.setVisible(true)
            var t = CACurrentMediaTime()
            for i in 0...120 {                             // Bewegung nach links, dann Knall (Physik im Zeitraffer)
                t += 1.0 / 120
                whipFX.update(mouse: CGPoint(x: 420 - CGFloat(min(i, 60)) * 1.5, y: 360), now: t)
                if i == 90 { whipFX.crack(sound: false) }
            }
            let frames = Int(whipFX.crackLead * 120) - 1
            for _ in 0..<frames { t += 1.0 / 120; whipFX.update(mouse: CGPoint(x: 330, y: 360), now: t) }
            whipFX.root.sublayers?.forEach { if $0.animation(forKey: "burst") != nil { $0.removeFromSuperlayer() } }
            if let tip = whipFX.pts.last { whipFX.burst(at: tip, frozen: true) }
            whipFX.handle.removeAllAnimations()
        } else if theme == .wueste {
            hand.isHidden = true
            stick.isHidden = true
            desertFX.setVisible(true)
            desertFX.update(mouse: CGPoint(x: 330, y: 380))
            desertFX.lastMove -= 5                         // so tun, als stünde die Maus still (Gewürz-Glimmen)
            desertFX.update(mouse: CGPoint(x: 330, y: 380))
            desertFX.thump(at: CGPoint(x: 560, y: 470))
            desertFX.root.sublayers?.forEach { l in        // Thumper-Ringe als Standbild zeigen
                if l.animation(forKey: "thump") != nil { l.removeAllAnimations(); l.opacity = 0.8; l.transform = CATransform3DMakeScale(1.4 + CGFloat.random(in: 0...1.4), 1.4 + 0, 1) }
            }
            desertFX.visor.removeAllAnimations()
        } else if theme == .ufo {
            hand.isHidden = true
            stick.isHidden = true
            ufoFX.setVisible(true)
            let b = CGRect(origin: .zero, size: size)
            ufoFX.nextCow = .infinity
            ufoFX.spawnCow(bounds: b, now: CACurrentMediaTime(), at: CGPoint(x: 330, y: 20))
            ufoFX.spawnCow(bounds: b, now: CACurrentMediaTime(), at: CGPoint(x: 560, y: 20))
            ufoFX.spawnCow(bounds: b, now: CACurrentMediaTime(), at: CGPoint(x: 140, y: 330), parachute: true)
            ufoFX.cows[1].vx = -30
            ufoFX.collected = 3
            ufoFX.updateBadge()
            var mouse = CGPoint(x: 330, y: 250)
            for _ in 0..<70 {                              // Kuh wird gerade hochgebeamt
                ufoFX.lastTime -= 1.0 / 60
                ufoFX.update(mouse: mouse, bounds: b)
                mouse.x += 0.0
            }
            ufoFX.root.sublayers?.forEach { $0.removeAllAnimations() }
        } else if theme == .skelett {
            hand.isHidden = true
            stick.isHidden = true
            skeletonFX.setVisible(true)
            var t = CACurrentMediaTime()                   // 1,2 s nach rechts rennen (Physik im Zeitraffer)
            for i in 0...144 {
                t += 1.0 / 120
                skeletonFX.update(mouse: CGPoint(x: 150 + CGFloat(i) * 2.5, y: 560), now: t)
            }
        } else if theme == .ente {
            hand.isHidden = true
            stick.isHidden = true
            duckFX.setVisible(true)
            for i in 0...80 {                              // Gänsemarsch nach links oben
                let f = CGFloat(i) / 80
                duckFX.update(mouse: CGPoint(x: 560 - 300 * f, y: 260 + 60 * sin(f * 4)), bounds: CGRect(origin: .zero, size: size))
            }
            duckFX.quack(at: CGPoint(x: 260, y: 260 + 60 * sin(CGFloat(4))))
            duckFX.root.sublayers?.forEach { $0.removeAllAnimations(); if $0.opacity == 0 && $0.contents != nil { $0.opacity = 1 } }
            duckFX.zzz.forEach { $0.opacity = 0 }
            duckFX.spawnEgg(at: CGPoint(x: 520, y: 520))         // ein Ei zum Einsammeln
            duckFX.eggs.forEach { $0.layer.removeAllAnimations() }
            if CommandLine.arguments.contains("--hatch") {    // Test: Ente läuft übers Ei
                let from = CGPoint(x: 260, y: 260 + 60 * sin(CGFloat(4)))
                for i in 1...120 {
                    let f = CGFloat(i) / 120
                    duckFX.update(mouse: CGPoint(x: from.x + (520 - from.x) * f, y: from.y + (520 - from.y) * f),
                                  bounds: CGRect(origin: .zero, size: size))
                }
                duckFX.root.sublayers?.forEach { $0.removeAllAnimations() }
                print("Küken:", duckFX.chicks.count, "Eier übrig:", duckFX.eggs.count)
            }
        } else if theme == .fuesse {
            hand.isHidden = true
            stick.isHidden = true
            feetFX.setVisible(true)
            for i in 0...60 {                              // Laufspur wie nach einer Bewegung nach rechts oben
                let f = CGFloat(i) / 60
                feetFX.update(mouse: CGPoint(x: 120 + 260 * f, y: 330 + 120 * f * f))
            }
            feetFX.trail.sublayers?.forEach { $0.removeAllAnimations() }
        } else if theme == .zug {
            hand.isHidden = true
            stick.isHidden = true
            trainFX.setVisible(true)
            trainFX.update(mouse: CGPoint(x: 560, y: 520))
            trainFX.update(mouse: CGPoint(x: 540, y: 520))
        } else if theme == .addmore {
            hand.isHidden = true
            stick.isHidden = true
            laserFX.setVisible(true)
            let now = CACurrentMediaTime()                 // Schweif wie nach einer Bewegung von links unten
            laserFX.history = (0..<30).map { i in
                let f = CGFloat(i) / 29
                return (CGPoint(x: 160 + 170 * f, y: 300 + 80 * sin(f * 3)), now - LASER_TRAIL * Double(1 - f) * 0.95)
            }
            laserFX.update(mouse: CGPoint(x: 330, y: 300 + 80 * sin(CGFloat(3))))
        } else if theme == .spinne {
            hand.isHidden = true
            stick.isHidden = true
            spiderFX.setVisible(true)
            let b = CGRect(origin: .zero, size: size)
            spiderFX.anchorX = 250                         // wie mitten im Schwingen
            spiderFX.update(mouse: CGPoint(x: 330, y: 380), bounds: b)
            spiderFX.spinWeb(at: CGPoint(x: 520, y: 230))
            spiderFX.webs.sublayers?.forEach { $0.removeAllAnimations() }   // Netz fertig zeigen
        } else if theme == .halloween {
            hand.isHidden = true
            stick.isHidden = true
            fx.setVisible(true)
            fx.update(mouse: CGPoint(x: 330, y: 380), bounds: CGRect(origin: .zero, size: size))
            fx.ghostPos = CGPoint(x: 230, y: 450)        // Gespenst nicht direkt auf dem Ziel, wie in Bewegung
            fx.update(mouse: CGPoint(x: 330, y: 380), bounds: CGRect(origin: .zero, size: size))
        } else {
            placeHand(at: CGPoint(x: 150, y: 600))
        }
        if CommandLine.arguments.contains("--stroke") {          // Beispielstrich im Zeichenmodus
            strokeBegan(CGPoint(x: 80, y: 150))
            for i in 1...120 {
                let x = 80 + CGFloat(i) * 4.5
                strokeMoved(CGPoint(x: x, y: 150 + 45 * sin(CGFloat(i) / 14)))
            }
            if let t = currentTrack {                    // Zug wie nach 2 s Malen (+1 s Verzögerung) zeigen
                t.pretendDrawn(over: 2.0)
                for i in t.samples.indices { t.samples[i].t -= 0.6 }
                t.update()
            }
        }
        let scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        // angedeutete Folie: Überschrift und Textzeilen
        ctx.setFillColor(CGColor(red: 0.95, green: 0.43, blue: 0.01, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 600, width: 400, height: 36))
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
        for i in 0..<9 { ctx.fill(CGRect(x: 60, y: 520 - CGFloat(i) * 50, width: CGFloat(300 + (i * 97) % 260), height: 16)) }
        layer.render(in: ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    // ---------- Zeichnen ----------
    func strokeBegan(_ p: CGPoint) {
        strokeEnded()
        if theme == .peitsche { return }          // Peitsche: Zeichenmodus = knallen, kein Strich
        let path = CGMutablePath()
        path.move(to: p)
        path.addLine(to: p)                       // ein einzelner Klick ergibt einen Punkt
        let l = CAShapeLayer()
        l.actions = ["path": NSNull(), "opacity": NSNull()]
        l.path = path
        strokeStyle(l, theme: theme)              // Strich passend zum Design (src/addmore.swift)
        if theme == .skelett { l.shadowColor = skeletonFX.glow.cgColor }   // Knochen-Strich leuchtet in der Designfarbe
        applyStrokeOverride(l)                    // ... oder wie im importierten Design festgelegt
        strokes.addSublayer(l)
        if let stamp = custom?.stroke?.stamp {    // Emoji-Stempel statt Linie
            paws = PawStamper(start: p, into: l, emoji: stamp)
            currentTrack = nil
            feet = nil
        } else {
            paws = theme == .waschbaer ? PawStamper(start: p, into: l) : nil
            currentTrack = theme == .zug ? TrainTrack(start: p, into: l) : nil
            if let t = currentTrack { tracks.append(t) }
            feet = theme == .fuesse ? FootStamper(start: p, height: 24, spacing: 30, fadeEach: false) : nil
        }
        currentStroke = l
        currentPath = path
    }

    func strokeMoved(_ p: CGPoint) {
        guard let l = currentStroke, let path = currentPath else { return strokeBegan(p) }
        path.addLine(to: p)
        l.path = path
        paws?.move(to: p, into: l)
        currentTrack?.add(p)
        feet?.move(to: p, into: l)
    }

    func strokeEnded() {
        guard let l = currentStroke else { return }
        currentStroke = nil
        currentPath = nil
        paws = nil
        feet = nil
        // Zug-Strecken erst ausblenden, wenn der Zug angekommen ist (er fährt TRAIN_DELAY hinterher)
        let extra = currentTrack != nil ? TRAIN_DELAY : 0
        currentTrack = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + DRAW_FADE_AFTER + extra) { [weak l] in
            guard let l = l, l.superlayer != nil else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = DRAW_FADE_TIME
            l.opacity = 0
            l.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    func clearStrokes() {
        currentStroke = nil
        currentPath = nil
        strokes.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    @objc func toggleDrawing() { drawing.toggle() }

    // ---------- Menüleiste ----------
    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = kulisseMenuIcon()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = ""
        let menu = NSMenu()
        menu.addItem(WallpaperManager.shared.makeMenuItem())      // Untermenü Live-Hintergrund (src/wallpaper_ui.swift)
        menu.addItem(.separator())
        for t in Theme.allCases {
            let item = NSMenuItem(title: "Design: " + t.title, action: #selector(pickTheme(_:)), keyEquivalent: "")
            item.representedObject = t.rawValue
            item.target = self
            themeItems[t] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Export / Import (src/themes.swift); importierte Designs erscheinen oben unter den eingebauten
        for (title, sel) in [("Design exportieren …", #selector(exportTheme)),
                             ("Design importieren …", #selector(importThemeAction)),
                             ("Importierte Designs im Finder zeigen", #selector(showThemesFolder))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let del = NSMenuItem(title: "Dieses importierte Design löschen", action: #selector(deleteCustomTheme), keyEquivalent: "")
        del.target = self
        deleteThemeItem = del
        menu.addItem(del)
        menu.addItem(.separator())
        for m in Mode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.representedObject = m.rawValue
            item.target = self
            modeItems[m] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let draw = NSMenuItem(title: "Zeichenmodus  (⌃⌥V)", action: #selector(toggleDrawing), keyEquivalent: "")
        draw.target = self
        drawItem = draw
        menu.addItem(draw)
        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            let li = NSMenuItem(title: "Bei Anmeldung starten", action: #selector(toggleLogin), keyEquivalent: "")
            li.target = self
            loginItem = li
            menu.addItem(li)
        }
        menu.addItem(.separator())
        let info = NSMenuItem(title: "Bild: –", action: nil, keyEquivalent: "")
        info.isEnabled = false
        info.tag = 99
        menu.addItem(info)
        let quit = NSMenuItem(title: "Beenden  (⌃⌥Q)", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        menu.delegate = self                      // Menü offen -> normaler Mac-Zeiger
        rebuildCustomItems()
        refreshMenu()
    }

    func refreshMenu() {
        for (m, item) in modeItems { item.state = m == mode ? .on : .off }
        for (t, item) in themeItems { item.state = t == theme && custom == nil ? .on : .off }
        for item in customItems { item.state = (item.representedObject as? String) == custom?.folder.path ? .on : .off }
        deleteThemeItem?.isHidden = custom == nil
        drawItem?.state = drawing ? .on : .off
        // Menüleiste: immer das Kulisse-Symbol (Vorhang mit Mond), im Zeichenmodus mit Stift daneben
        statusItem?.button?.title = drawing ? " ✏️" : ""
        statusItem?.button?.appearsDisabled = mode == .off && !drawing
        statusItem?.menu?.item(withTag: 99)?.title = "Bild: " + (sprite?.source ?? "keins gefunden")
        if #available(macOS 13.0, *) { loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off }
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) { mode = m }
    }
    @objc func pickTheme(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = Theme(rawValue: raw) { select(builtin: t) }
    }
    @objc func nextMode() {
        let all = Mode.allCases
        mode = all[(all.firstIndex(of: mode)! + 1) % all.count]
    }
    @objc func reloadImage() {
        sprite = loadCurrentSprite()
        holder = loadCurrentHolder()
        applySprite()
        buildStick()
        lastMouse = .zero
        refreshMenu()
    }
    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Autostart ging nicht"
            alert.informativeText = "\(error.localizedDescription)\n\nAlternative: Systemeinstellungen → Allgemein → Anmeldeobjekte → „+“ und die App auswählen."
            withSystemCursor { _ = alert.runModal() }
        }
        refreshMenu()
    }
    @objc func quit() {
        setCursorHidden(false)
        NSApp.terminate(nil)
    }

    // ---------- globale Tastenkürzel (brauchen keine Bedienungshilfen-Freigabe) ----------
    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                switch id.id {
                case 1: overlay.nextMode()
                case 2: overlay.quit()
                case 3: overlay.toggleDrawing()
                case 4: WallpaperManager.shared.uiLockWithSaver()
                default: break
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_P), mods, EventHotKeyID(signature: 0x52434E50, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
        RegisterEventHotKey(UInt32(kVK_ANSI_Q), mods, EventHotKeyID(signature: 0x52434E50, id: 2),
                            GetApplicationEventTarget(), 0, &ref)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), mods, EventHotKeyID(signature: 0x52434E50, id: 3),
                            GetApplicationEventTarget(), 0, &ref)
        // Sperren, während der Live-Hintergrund als Bildschirmschoner weiterläuft
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(signature: 0x52434E50, id: 4),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

/// Symbol für die Menüleiste im Stil des App-Logos: Vorhang mit Mond und Welle.
/// Als Vorlage (isTemplate) gezeichnet -> macOS färbt es passend zu hellem/dunklem Modus, wie seine eigenen Symbole.
func kulisseMenuIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { r in
        NSColor.black.setFill()
        NSColor.black.setStroke()
        // Volant oben mit Bögen
        let val = NSBezierPath()
        val.move(to: NSPoint(x: 0.5, y: 0.8)); val.line(to: NSPoint(x: 19.5, y: 0.8)); val.line(to: NSPoint(x: 19.5, y: 3.0))
        for k in 0..<4 {
            let xa = 19.5 - CGFloat(k) * 19 / 4, xb = xa - 19 / 4
            val.curve(to: NSPoint(x: xb, y: 3.0), controlPoint1: NSPoint(x: xa - 1.0, y: 4.6), controlPoint2: NSPoint(x: xb + 1.0, y: 4.6))
        }
        val.close(); val.fill()
        // Vorhänge: oben breit, in der Mitte gerafft (Kordel = kleine Lücke), unten ausgestellt
        for side in [CGFloat(1), -1] {
            let x0: CGFloat = side > 0 ? 0.5 : 19.5
            let c = NSBezierPath()
            c.move(to: NSPoint(x: x0, y: 3.5))
            c.line(to: NSPoint(x: x0 + side * 4.6, y: 3.5))
            c.curve(to: NSPoint(x: x0 + side * 1.9, y: 10.2), controlPoint1: NSPoint(x: x0 + side * 4.2, y: 6.8), controlPoint2: NSPoint(x: x0 + side * 1.9, y: 8.6))
            c.line(to: NSPoint(x: x0, y: 10.2)); c.close(); c.fill()
            let f = NSBezierPath()
            f.move(to: NSPoint(x: x0, y: 11.4))
            f.line(to: NSPoint(x: x0 + side * 1.9, y: 11.4))
            f.curve(to: NSPoint(x: x0 + side * 3.2, y: 17.2), controlPoint1: NSPoint(x: x0 + side * 2.0, y: 13.5), controlPoint2: NSPoint(x: x0 + side * 3.2, y: 15.5))
            f.line(to: NSPoint(x: x0, y: 17.2)); f.close(); f.fill()
        }
        // Mondsichel oben rechts
        NSGraphicsContext.saveGraphicsState()
        let cut = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 20, height: 18))
        cut.append(NSBezierPath(ovalIn: NSRect(x: 12.1, y: 4.0, width: 4.0, height: 4.0)))
        cut.windingRule = .evenOdd
        cut.addClip()                                   // alles außer dem zweiten Kreis -> Sichel
        NSBezierPath(ovalIn: NSRect(x: 10.6, y: 4.9, width: 4.4, height: 4.4)).fill()
        NSGraphicsContext.restoreGraphicsState()
        // zwei Wellen (Teich)
        for (y, x0, x1) in [(CGFloat(12.8), CGFloat(5.6), CGFloat(14.4)), (15.6, 7.0, 13.0)] {
            let w = NSBezierPath()
            let m = (x0 + x1) / 2, q = (x1 - x0) / 4
            w.move(to: NSPoint(x: x0, y: y))
            w.curve(to: NSPoint(x: m, y: y), controlPoint1: NSPoint(x: x0 + q * 0.8, y: y - 1.3), controlPoint2: NSPoint(x: m - q * 0.8, y: y - 1.3))
            w.curve(to: NSPoint(x: x1, y: y), controlPoint1: NSPoint(x: m + q * 0.8, y: y + 1.3), controlPoint2: NSPoint(x: x1 - q * 0.8, y: y + 1.3))
            w.lineWidth = 1.15; w.lineCapStyle = .round
            w.stroke()
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Kulisse"
    return img
}

/// Umzug von „Waschbär Pointer“ (local.waschbaer.pointer) nach „Kulisse“: Einstellungen und
/// Application-Support-Ordner übernehmen. Der alte Ordner wird zum Verweis auf den neuen, damit Pfade
/// (z. B. ein gesetztes Sperrbildschirm-Standbild) gültig bleiben.
func migrateFromOldName() {
    let ud = UserDefaults.standard
    guard !ud.bool(forKey: "migratedFromWaschbaer") else { return }
    if let old = ud.persistentDomain(forName: "local.waschbaer.pointer") {
        for (k, v) in old where ud.object(forKey: k) == nil { ud.set(v, forKey: k) }
    }
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let o = base.appendingPathComponent("WaschbaerPointer"), n = base.appendingPathComponent("Kulisse")
    var isLink = false
    if let t = try? fm.attributesOfItem(atPath: o.path)[.type] as? FileAttributeType { isLink = t == .typeSymbolicLink }
    if fm.fileExists(atPath: o.path), !isLink, !fm.fileExists(atPath: n.path) {
        if (try? fm.moveItem(at: o, to: n)) != nil { try? fm.createSymbolicLink(at: o, withDestinationURL: n) }
    }
    ud.set(true, forKey: "migratedFromWaschbaer")
}
migrateFromOldName()

let app = NSApplication.shared
let overlay = Overlay()
app.delegate = overlay
app.setActivationPolicy(.accessory)
app.run()

extension Overlay: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { suspendOverlay() }
    func menuDidClose(_ menu: NSMenu) { resumeOverlay() }
}
