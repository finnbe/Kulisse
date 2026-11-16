// Export / Import von Designs.
//
// Eine .pointertheme-Datei ist ein Zip mit einer theme.json und den Bildern. Beispiel:
//
// {
//   "format": 1,
//   "name": "Mein Zeigestock",
//   "base": "zeigestock",            // eingebautes Design als Grundlage (Effekte/Animationen kommen von dort):
//                                     // zeigestock, halter, waschbaer, halloween, spinne, addmore, zug, fuesse, ente,
//                                     // skelett (bei skelett ist "hand" der Kopf: Nadelspitze oben, Kopf unten)
//   "hand":   { "image": "hand.png", "height": 80 },          // optional: eigenes Handbild (Finger zeigt nach oben)
//   "holder": { "image": "halter.png", "gripX": 504, "gripWidth": 185, "anchorY": 297 },  // optional: Hand am Griff
//   "stick":  { "length": 500, "tilt": 45 },                  // optional: Stablänge / Neigung
//   "stroke": { "color": "#F36D03", "width": 6, "glow": 4, "opacity": 1, "stamp": "🐾" },  // optional: Strich im
//                                                              // Zeichenmodus; "stamp" = Emoji-Stempel statt Linie
//   "effect": { "color": "#FF5F00" }                          // optional: Leuchtfarbe des Effekts (z. B. Skelett)
// }
//
// Alles außer "name" und "base" ist optional – was fehlt, kommt vom Basis-Design.
// Importierte Designs liegen in ~/Library/Application Support/Kulisse/Themes/<Name>/

import Cocoa
import UniformTypeIdentifiers

let THEME_EXT = "pointertheme"

struct StrokeOverride {
    var color: NSColor?
    var width: CGFloat?
    var glow: CGFloat?
    var opacity: CGFloat?
    var stamp: String?
}

struct CustomTheme {
    let folder: URL
    let name: String
    let base: Theme
    var handImage: URL?
    var handHeight: CGFloat?
    var holderImage: URL?
    var holderMeta: (gripX: CGFloat, gripWidth: CGFloat, anchorY: CGFloat)?
    var stickLength: CGFloat?
    var tilt: CGFloat?
    var stroke: StrokeOverride?
    var effectColor: NSColor?        // "effect": {"color": "#FF5F00"} – Leuchtfarbe (z. B. Skelett)
}

enum ThemeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

func themesFolder() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Kulisse/Themes", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// ---------- Farben ----------
func hexColor(_ s: String) -> NSColor? {
    var h = s.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
    let hasAlpha = h.count == 8
    let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func hexString(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()),
                  Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
}

// ---------- Lesen ----------
func loadCustomTheme(folder: URL) throws -> CustomTheme {
    let jsonURL = folder.appendingPathComponent("theme.json")
    guard let data = try? Data(contentsOf: jsonURL) else { throw ThemeError.message("theme.json fehlt.") }
    guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw ThemeError.message("theme.json ist kein gültiges JSON.")
    }
    guard let name = j["name"] as? String, !name.isEmpty else { throw ThemeError.message("\"name\" fehlt in theme.json.") }
    guard let baseRaw = j["base"] as? String, let base = Theme(rawValue: baseRaw) else {
        let all = Theme.allCases.map(\.rawValue).joined(separator: ", ")
        throw ThemeError.message("\"base\" fehlt oder ist unbekannt. Erlaubt: \(all)")
    }
    func num(_ d: [String: Any]?, _ k: String) -> CGFloat? { (d?[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
    /// Bildpfad aus der JSON – nur Dateien innerhalb des Design-Ordners
    func image(_ d: [String: Any]?) throws -> URL? {
        guard let rel = d?["image"] as? String else { return nil }
        let u = folder.appendingPathComponent(rel).standardizedFileURL
        guard u.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw ThemeError.message("Ungültiger Bildpfad: \(rel)") }
        guard FileManager.default.fileExists(atPath: u.path) else { throw ThemeError.message("Bild fehlt: \(rel)") }
        return u
    }
    var t = CustomTheme(folder: folder, name: name, base: base)
    let hand = j["hand"] as? [String: Any]
    t.handImage = try image(hand)
    t.handHeight = num(hand, "height")
    let holder = j["holder"] as? [String: Any]
    t.holderImage = try image(holder)
    if let gx = num(holder, "gripX"), let gw = num(holder, "gripWidth"), let ay = num(holder, "anchorY") {
        t.holderMeta = (gx, gw, ay)
    }
    let stick = j["stick"] as? [String: Any]
    t.stickLength = num(stick, "length")
    t.tilt = num(stick, "tilt")
    if let e = j["effect"] as? [String: Any], let c = (e["color"] as? String).flatMap(hexColor) { t.effectColor = c }
    if let s = j["stroke"] as? [String: Any] {
        t.stroke = StrokeOverride(color: (s["color"] as? String).flatMap(hexColor), width: num(s, "width"),
                                  glow: num(s, "glow"), opacity: num(s, "opacity"), stamp: s["stamp"] as? String)
    }
    return t
}

func installedThemes() -> [CustomTheme] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: themesFolder(), includingPropertiesForKeys: nil)) ?? []
    return dirs.compactMap { try? loadCustomTheme(folder: $0) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}

// ---------- Zip (über das eingebaute ditto) ----------
func runDitto(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = args
    let err = Pipe()
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw ThemeError.message("Zip fehlgeschlagen: \(msg)")
    }
}

func safeFolderName(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
    let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "Design" : String(cleaned.prefix(60))
}

/// Entpackt eine .pointertheme-Datei (oder nimmt einen Ordner) und legt sie unter Themes/ ab.
func importTheme(from src: URL) throws -> CustomTheme {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("pointertheme-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    var isDir: ObjCBool = false
    fm.fileExists(atPath: src.path, isDirectory: &isDir)
    if isDir.boolValue {
        try fm.copyItem(at: src, to: tmp)
    } else {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try runDitto(["-x", "-k", src.path, tmp.path])
    }
    // theme.json direkt oder einen Ordner tiefer (falls jemand den Ordner gezippt hat)
    var root = tmp
    if !fm.fileExists(atPath: tmp.appendingPathComponent("theme.json").path) {
        let subs = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        guard let sub = subs.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("theme.json").path) }) else {
            throw ThemeError.message("In der Datei ist keine theme.json.")
        }
        root = sub
    }
    let probe = try loadCustomTheme(folder: root)           // prüft alles, bevor etwas installiert wird
    var dest = themesFolder().appendingPathComponent(safeFolderName(probe.name))
    var n = 2
    while fm.fileExists(atPath: dest.path) {
        dest = themesFolder().appendingPathComponent("\(safeFolderName(probe.name)) \(n)")
        n += 1
    }
    try fm.copyItem(at: root, to: dest)
    return try loadCustomTheme(folder: dest)
}

// ---------- Menü-Aktionen ----------
extension Overlay {
    /// Bilddatei, die gerade als Hand benutzt wird (eigenes Design oder eingebautes Bild).
    func currentHandURL() -> URL? {
        if let u = custom?.handImage { return u }
        let beside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(theme.imageName + ".png")
        if FileManager.default.fileExists(atPath: beside.path) { return beside }
        return Bundle.main.url(forResource: theme.imageName, withExtension: "png")
    }

    func currentHolderFiles() -> (png: URL, meta: (CGFloat, CGFloat, CGFloat))? {
        if let u = custom?.holderImage, let m = custom?.holderMeta { return (u, (m.gripX, m.gripWidth, m.anchorY)) }
        guard custom?.holderImage == nil, let name = theme.holderName, let png = findResource(name, "png"),
              let h = holder else { return nil }
        return (png, (h.gripX, h.gripWidth, h.anchorY))
    }

    /// theme.json für das aktuelle Design – mit allen Werten ausgeschrieben, damit man sie leicht ändern kann.
    func currentThemeJSON(handFile: String?, holderFile: String?) -> [String: Any] {
        var j: [String: Any] = ["format": 1, "name": custom?.name ?? theme.title, "base": theme.rawValue]
        let usesStick = [.zeigestock, .halter, .waschbaer, .skelett].contains(theme)
        if usesStick {
            var hand: [String: Any] = ["height": Double(handHeight)]
            if let f = handFile { hand["image"] = f }
            j["hand"] = hand
            if theme != .skelett { j["stick"] = ["length": Double(stickLength), "tilt": Double(tiltDegrees)] }
        }
        if let f = holderFile, let h = currentHolderFiles() {
            j["holder"] = ["image": f, "gripX": Double(h.meta.0), "gripWidth": Double(h.meta.1), "anchorY": Double(h.meta.2)]
        }
        // Strich: so wie er gerade gezeichnet würde
        let probe = CAShapeLayer()
        strokeStyle(probe, theme: theme)
        applyStrokeOverride(probe)
        var stroke: [String: Any] = [:]
        if let stamp = custom?.stroke?.stamp ?? (theme == .waschbaer ? "🐾" : nil) {
            stroke["stamp"] = stamp
        } else if let c = probe.strokeColor, let ns = NSColor(cgColor: c) {
            stroke["color"] = hexString(ns)
            stroke["opacity"] = Double((ns.usingColorSpace(.sRGB) ?? ns).alphaComponent)
            stroke["width"] = Double(probe.lineWidth)
            stroke["glow"] = probe.shadowOpacity > 0 ? Double(probe.shadowRadius) : 0
        }
        if !stroke.isEmpty { j["stroke"] = stroke }
        if theme == .skelett { j["effect"] = ["color": hexString(custom?.effectColor ?? SK_DEFAULT_GLOW)] }
        return j
    }

    /// Wendet die Strich-Einstellungen eines importierten Designs an (nach dem eingebauten Stil).
    func applyStrokeOverride(_ l: CAShapeLayer) {
        guard let s = custom?.stroke else { return }
        if s.stamp != nil { l.strokeColor = nil; return }
        var color = s.color ?? l.strokeColor.flatMap { NSColor(cgColor: $0) }
        if let o = s.opacity, let c = color { color = c.withAlphaComponent(o) }
        if let c = color { l.strokeColor = c.cgColor; l.shadowColor = c.withAlphaComponent(1).cgColor }
        if let w = s.width { l.lineWidth = w }
        if let g = s.glow { l.shadowRadius = g; l.shadowOpacity = g > 0 ? 0.8 : 0 }
    }

    @objc func exportTheme() {
        drawing = false
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Design exportieren"
        panel.nameFieldStringValue = safeFolderName(custom?.name ?? theme.title) + "." + THEME_EXT
        if let t = UTType(filenameExtension: THEME_EXT) { panel.allowedContentTypes = [t] }
        guard withSystemCursor({ panel.runModal() }) == .OK, let dest = panel.url else { return }
        do {
            try exportCurrentTheme(to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            showError("Export ging nicht", error)
        }
    }

    /// Schreibt das aktuelle Design als .pointertheme (Zip mit theme.json + Bildern).
    func exportCurrentTheme(to dest: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pointertheme-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            var handFile: String?, holderFile: String?
            if [.zeigestock, .halter, .waschbaer].contains(theme) || custom?.handImage != nil, let u = currentHandURL() {
                handFile = "hand.png"
                try fm.copyItem(at: u, to: tmp.appendingPathComponent("hand.png"))
            }
            if let h = currentHolderFiles() {
                holderFile = "halter.png"
                try fm.copyItem(at: h.png, to: tmp.appendingPathComponent("halter.png"))
            }
            let json = try JSONSerialization.data(withJSONObject: currentThemeJSON(handFile: handFile, holderFile: holderFile),
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try json.write(to: tmp.appendingPathComponent("theme.json"))
            try? fm.removeItem(at: dest)
            try runDitto(["-c", "-k", "--norsrc", tmp.path, dest.path])
        }
    }

    @objc func importThemeAction() {
        drawing = false
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Design importieren"
        panel.message = "Eine .\(THEME_EXT)-Datei (oder einen Ordner mit theme.json) auswählen"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard withSystemCursor({ panel.runModal() }) == .OK, let src = panel.url else { return }
        do {
            let t = try importTheme(from: src)
            rebuildCustomItems()
            select(custom: t)
        } catch {
            showError("Import ging nicht", error)
        }
    }

    @objc func pickCustomTheme(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let t = try? loadCustomTheme(folder: URL(fileURLWithPath: path)) else { return }
        select(custom: t)
    }

    @objc func showThemesFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([themesFolder()])
    }

    @objc func deleteCustomTheme() {
        guard let c = custom else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "„\(c.name)“ löschen?"
        a.informativeText = "Das importierte Design wird in den Papierkorb gelegt."
        a.addButton(withTitle: "Löschen")
        a.addButton(withTitle: "Abbrechen")
        guard withSystemCursor({ a.runModal() }) == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: c.folder, resultingItemURL: nil)
        select(builtin: c.base)
        rebuildCustomItems()
    }

    func showError(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        withSystemCursor { _ = a.runModal() }
    }

    /// Menüeinträge der importierten Designs (direkt unter den eingebauten) neu aufbauen.
    func rebuildCustomItems() {
        guard let menu = statusItem?.menu else { return }
        customItems.forEach { menu.removeItem($0) }
        customItems = []
        guard let lastBuiltin = Theme.allCases.last.flatMap({ themeItems[$0] }) else { return }
        var index = menu.index(of: lastBuiltin) + 1
        for t in installedThemes() {
            let item = NSMenuItem(title: "Design: ⭐ " + t.name, action: #selector(pickCustomTheme(_:)), keyEquivalent: "")
            item.representedObject = t.folder.path
            item.target = self
            menu.insertItem(item, at: index)
            customItems.append(item)
            index += 1
        }
        refreshMenu()
    }
}
