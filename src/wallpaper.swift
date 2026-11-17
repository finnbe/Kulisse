// Live-Hintergrund: Web-Wallpaper laufen in einem Fenster hinter den Desktop-Symbolen.
//
// Ein Hintergrund ist ein Ordner im Format von Wallpaper Engine (Typ "web"): project.json + index.html + Rest.
// Die Einstellungen kommen aus project.json ("general.properties") und werden wie in Wallpaper Engine
// über window.wallpaperPropertyListener.applyUserProperties({...}) an die Seite gegeben – die Hintergründe
// laufen also unverändert auch weiter in Wallpaper Engine.
//
// Eingebaut:   wallpapers/<Ordner>/ neben der App (zum Entwickeln) bzw. in der App unter Resources/wallpapers/
// Importiert:  ~/Library/Application Support/Kulisse/Wallpapers/<Name>/
// Vorlagen:    presets.json im Hintergrund-Ordner (mitgeliefert) und
//              ~/Library/Application Support/Kulisse/Wallpaper-Presets/<Name>.json (eigene)
//
// .wallpapertheme-Datei = Zip mit
//   wallpaper.json  {"format": 1, "name": "Mondnacht", "wallpaper": "builtin/nishiki", "title": "...", "values": {...}}
//   files/          (optional) der komplette Hintergrund-Ordner – für Leute, die ihn noch nicht haben
// Importieren geht außerdem mit einem Wallpaper-Engine-Ordner (oder Zip davon) mit project.json.
//
// Sicherheit: die Seiten laufen ohne Internet (alle http/https/ws-Anfragen werden blockiert), dürfen nur
// Dateien aus ihrem eigenen Ordner lesen und haben keine Verbindung zur App.

import Cocoa
import WebKit
import ObjectiveC
import IOKit.ps
import UniformTypeIdentifiers

let WALLPAPER_EXT = "wallpapertheme"
let WP_FPS_CHOICES: [(title: String, fps: Int)] = [("15 fps", 15), ("30 fps", 30), ("60 fps", 60), ("Maximal", 240)]

// ---------- Beschreibung aus project.json ----------
struct WPOption { let label: String; let value: Any }

struct WPProperty {
    let key: String
    let type: String          // slider, bool, combo, color, textinput
    var label: String
    let defaultValue: Any
    var min = 0.0, max = 100.0, step = 1.0, fraction = false
    var options: [WPOption] = []
    var condition: String?
    var order = 0
}

struct WPPreset {
    let name: String
    let wallpaperID: String
    let values: [String: Any]
    var file: URL?            // nil = mitgelieferte Vorlage
}

func wpFolder(_ name: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Kulisse/\(name)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
func wallpapersFolder() -> URL { wpFolder("Wallpapers") }
func wallpaperPresetsFolder() -> URL { wpFolder("Wallpaper-Presets") }

/// Datei innerhalb eines Ordners (kein "../" heraus)
func wpInside(_ folder: URL, _ rel: String) -> URL? {
    let u = folder.appendingPathComponent(rel).standardizedFileURL
    return u.path.hasPrefix(folder.standardizedFileURL.path + "/") ? u : nil
}

private func stripHTML(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
    t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
        t = t.replacingOccurrences(of: a, with: b)
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

final class WallpaperPackage {
    let id: String
    let folder: URL
    let title: String
    let builtin: Bool
    let entry: URL
    let properties: [WPProperty]
    let presets: [WPPreset]
    let projectData: Data

    init(folder: URL, builtin: Bool) throws {
        let pj = folder.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: pj) else { throw ThemeError.message("project.json fehlt.") }
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ThemeError.message("project.json ist kein gültiges JSON.")
        }
        let type = (j["type"] as? String ?? "web").lowercased()
        guard type == "web" else {
            throw ThemeError.message("Nur Web-Hintergründe gehen (dieser ist vom Typ „\(type)“).")
        }
        let file = j["file"] as? String ?? "index.html"
        guard let entry = wpInside(folder, file), FileManager.default.fileExists(atPath: entry.path) else {
            throw ThemeError.message("Startdatei „\(file)“ fehlt.")
        }
        self.folder = folder
        self.builtin = builtin
        self.entry = entry
        self.projectData = data
        self.id = (builtin ? "builtin/" : "user/") + folder.lastPathComponent

        // Texte: Deutsch, sonst Englisch, sonst der Schlüssel selbst
        let general = j["general"] as? [String: Any] ?? [:]
        let loc = general["localization"] as? [String: [String: String]] ?? [:]
        var langs = Locale.preferredLanguages.map { $0.lowercased() }
        langs += langs.map { String($0.prefix(2)) } + ["de-de", "en-us"]
        let tables: [[String: String]] = langs.compactMap { l in loc[l] ?? loc.first(where: { $0.key.hasPrefix(l) })?.value }
        func text(_ key: String?) -> String {
            guard let key = key else { return "" }
            for t in tables { if let s = t[key] { return stripHTML(s) } }
            return stripHTML(key)
        }
        title = text(j["title"] as? String).isEmpty ? folder.lastPathComponent : text(j["title"] as? String)

        var props: [WPProperty] = []
        for (key, raw) in general["properties"] as? [String: Any] ?? [:] {
            guard key != "schemecolor", let d = raw as? [String: Any], let t = (d["type"] as? String)?.lowercased(),
                  ["slider", "bool", "combo", "color", "textinput"].contains(t) else { continue }
            var p = WPProperty(key: key, type: t, label: text(d["text"] as? String), defaultValue: d["value"] ?? "")
            p.order = (d["order"] as? NSNumber)?.intValue ?? 0
            p.condition = d["condition"] as? String
            if let v = d["min"] as? NSNumber { p.min = v.doubleValue }
            if let v = d["max"] as? NSNumber { p.max = v.doubleValue }
            p.fraction = d["fraction"] as? Bool ?? false
            if let v = d["step"] as? NSNumber { p.step = v.doubleValue } else { p.step = p.fraction ? 0.01 : 1 }
            if t == "combo" {
                p.options = (d["options"] as? [[String: Any]] ?? []).compactMap { o in
                    guard let v = o["value"] else { return nil }
                    return WPOption(label: text(o["label"] as? String ?? "\(v)"), value: v)
                }
            }
            if p.label.isEmpty { p.label = key }
            props.append(p)
        }
        properties = props.sorted { ($0.order, $0.key) < ($1.order, $1.key) }

        // mitgelieferte Vorlagen (optional): presets.json = [{"name": "...", "values": {...}}]
        var pre: [WPPreset] = []
        if let d = try? Data(contentsOf: folder.appendingPathComponent("presets.json")),
           let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            for e in arr {
                if let n = e["name"] as? String { pre.append(WPPreset(name: n, wallpaperID: id, values: e["values"] as? [String: Any] ?? [:])) }
            }
        }
        presets = pre
    }

    var defaults: [String: Any] {
        var d: [String: Any] = [:]
        for p in properties { d[p.key] = p.defaultValue }
        return d
    }
    func property(_ key: String) -> WPProperty? { properties.first { $0.key == key } }
}

// ---------- Bedingungen ("clock.value == true", "floating.value != 'none'") ----------
func wpConditionMet(_ cond: String?, _ values: [String: Any]) -> Bool {
    guard let c = cond?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return true }
    let re = try! NSRegularExpression(pattern: "^\\s*!?\\s*(\\w+)\\.value\\s*(===|!==|==|!=|>=|<=|>|<)\\s*(.+?)\\s*$")
    func lit(_ s: String) -> Any {
        if s == "true" { return true }
        if s == "false" { return false }
        if let d = Double(s) { return d }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
    func clause(_ s: String) -> Bool {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let k = Range(m.range(at: 1), in: s), let o = Range(m.range(at: 2), in: s), let r = Range(m.range(at: 3), in: s),
              let v = values[String(s[k])] else { return true }            // unbekannt -> anzeigen
        let op = String(s[o]), rhs = lit(String(s[r]))
        var cmp: ComparisonResult = .orderedSame
        if let b = rhs as? Bool {
            let lv = (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)
            cmp = lv == b ? .orderedSame : .orderedAscending
        } else if let d = rhs as? Double, let lv = (v as? NSNumber)?.doubleValue ?? Double("\(v)") {
            cmp = lv < d ? .orderedAscending : lv > d ? .orderedDescending : .orderedSame
        } else {
            cmp = "\(v)" == "\(rhs)" ? .orderedSame : .orderedAscending
        }
        switch op {
        case "==", "===": return cmp == .orderedSame
        case "!=", "!==": return cmp != .orderedSame
        case ">": return cmp == .orderedDescending
        case "<": return cmp == .orderedAscending
        case ">=": return cmp != .orderedAscending
        case "<=": return cmp != .orderedDescending
        default: return true
        }
    }
    if c.contains("||") { return c.components(separatedBy: "||").contains { wpConditionMet($0, values) } }
    return c.components(separatedBy: "&&").allSatisfy(clause)
}

// ---------- ein Fenster pro Bildschirm ----------
final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WPScreenView {
    let window: WallpaperWindow
    let web: WKWebView
    let frame: NSRect
    var ready = false
    var covered = false          // Schreibtisch auf diesem Bildschirm komplett von Fenstern verdeckt
    var sentPaused: Bool?
    init(window: WallpaperWindow, web: WKWebView, frame: NSRect) { self.window = window; self.web = web; self.frame = frame }
    func js(_ s: String) { if ready { web.evaluateJavaScript(s, completionHandler: nil) } }
}

/// Hilfsfunktionen in der Seite: Mausereignisse nachbauen (die Fenster selbst bekommen keine Maus,
/// sonst könnte man die Desktop-Symbole nicht mehr anklicken).
private let WP_HELPER_JS = """
(function () {
  function fire(type, x, y) {
    var t = document.elementFromPoint(x, y) || document.body || document.documentElement;
    if (!t) return;
    var down = type === 'down', up = type === 'up';
    var o = { clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: down ? 1 : 0,
              bubbles: true, cancelable: true, view: window, pointerId: 1, pointerType: 'mouse', isPrimary: true };
    try { t.dispatchEvent(new PointerEvent('pointer' + type, o)); } catch (e) {}
    t.dispatchEvent(new MouseEvent('mouse' + type, o));
    if (up) t.dispatchEvent(new MouseEvent('click', o));
  }
  window.__wpMouse = fire;
  // Musik: wie Wallpaper Engine – der Hintergrund meldet sich an, die App liefert 128 Werte (src/wallpaper_audio.swift)
  window.wallpaperRegisterAudioListener = function (cb) { window.__wpAudioCb = cb; };
  window.__wpAudio = function (a) { if (window.__wpAudioCb) { try { window.__wpAudioCb(a); } catch (e) {} } };
  window.__wpLeave = function () {
    document.dispatchEvent(new MouseEvent('mouseleave', { bubbles: false }));
    try { document.documentElement.dispatchEvent(new PointerEvent('pointerleave', { bubbles: false })); } catch (e) {}
  };
})();
"""

/// Welcher Bildschirm (von links gezählt) und wie viele: für Hintergründe, die sich über mehrere Bildschirme
/// erstrecken (z. B. Yuzu Onsen Panorama). Die Seite liest window.kulisseScreen = {index, count}.
func wpScreenJS(_ screen: NSScreen, among screens: [NSScreen]) -> String {
    let ordered = screens.sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
    let i = ordered.firstIndex { $0 === screen } ?? 0
    return "window.kulisseScreen={index:\(i),count:\(max(1, ordered.count))};"
}

/// Diagnose-Zeile nach ~/Library/Logs/Kulisse-Hintergrund.log
func wpDebugLog(_ line: String) {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Kulisse-Hintergrund.log")
    let text = "\(Date()) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close() }
    else { try? text.write(to: url, atomically: true, encoding: .utf8) }
}

// ---------- Verwaltung ----------
final class WallpaperManager: NSObject, WKNavigationDelegate, NSMenuDelegate {
    static let shared = WallpaperManager()
    private let ud = UserDefaults.standard

    var enabled: Bool {
        get { ud.bool(forKey: "wallpaperEnabled") }
        set { ud.set(newValue, forKey: "wallpaperEnabled"); refresh(); if !newValue { restoreDesktopPictures() }; changed() }
    }
    var allScreens: Bool {
        get { ud.object(forKey: "wallpaperAllScreens") as? Bool ?? true }
        set { ud.set(newValue, forKey: "wallpaperAllScreens"); refresh(); changed() }
    }
    var fps: Int {
        get { ud.object(forKey: "wallpaperFPS") as? Int ?? 30 }
        set { ud.set(newValue, forKey: "wallpaperFPS"); views.forEach(pushGeneral); changed() }
    }
    var pauseOnBattery: Bool {
        get { ud.object(forKey: "wallpaperPauseOnBattery") as? Bool ?? true }
        set { ud.set(newValue, forKey: "wallpaperPauseOnBattery"); updatePause(); changed() }
    }
    /// Systemton mithören und an die Hintergründe geben (fragt beim ersten Mal nach der Freigabe "Audioaufnahme")
    var audioEnabled: Bool {
        get { ud.bool(forKey: "wallpaperAudio") }
        set { ud.set(newValue, forKey: "wallpaperAudio"); audioError = nil; updateAudio(); changed() }
    }
    /// Pixeldichte: auto = große Bildschirme (ab 2000 pt Breite) mit 1x, Rest mit Retina; retina; normal = immer 1x
    var quality: String {
        get { ud.string(forKey: "wallpaperQuality") ?? "auto" }
        set { ud.set(newValue, forKey: "wallpaperQuality"); refresh(); changed() }
    }
    /// Sperrbildschirm: macOS lässt keine App auf den Sperrbildschirm zeichnen, zeigt dort aber das Schreibtischbild.
    /// Darum wird regelmäßig ein Standbild vom Hintergrund als Schreibtischbild gesetzt (aus = altes Bild zurück).
    var lockScreen: Bool {
        get { ud.bool(forKey: "wallpaperLockScreen") }
        set {
            ud.set(newValue, forKey: "wallpaperLockScreen")
            if newValue { scheduleLockPicture(delay: 0.5) } else { restoreDesktopPictures() }
            changed()
        }
    }
    private var lockWork: DispatchWorkItem?
    private(set) var audioError: String?
    /// false = die WebKit-Funktion zum Abschalten der Verdeckungs-Erkennung fehlt (z. B. nach macOS-Update)
    private(set) var occlusionWorkaroundOK = true
    private let audio = SystemAudioSpectrum()
    private var audioTimer: Timer?

    var userPaused: Bool {
        get { ud.bool(forKey: "wallpaperPaused") }
        set { ud.set(newValue, forKey: "wallpaperPaused"); updatePause(); changed() }
    }

    private(set) var packages: [WallpaperPackage] = []
    private(set) var current: WallpaperPackage?
    private var views: [WPScreenView] = []
    private var ruleList: WKContentRuleList?
    private var monitor: Any?
    private var lastMove = 0.0
    private weak var activeView: WPScreenView?
    private var asleep = false
    private var saverRunning = false     // eigener Bildschirmschoner zeigt den Hintergrund -> Fenster ruhen
    private(set) var onBattery = false
    private var pending: [String: Any] = [:]
    private var flushScheduled = false
    private var started = false
    private var rulesReady = false
    /// wird bei Änderungen aufgerufen (Einstellungsfenster aktualisieren)
    var onChange: (() -> Void)?
    private func changed() { onChange?(); writeSaverConfig() }

    // ----- Start -----
    func start() {
        guard !started else { return }
        started = true
        reloadPackages()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wc = NSWorkspace.shared.notificationCenter
        for (name, sleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                              (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.asleep = sleep; self?.updatePause() }
        }
        checkBattery()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkBattery() }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkCovered() }
        // Sperrbild aktuell halten (Tageszeit-Modus ändert sich) und beim Sperren noch einmal versuchen
        Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.updateLockPicture() }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.updateLockPicture()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.updateLockPicture(); self?.saverRunning = true; self?.updatePause()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            self?.saverRunning = false; self?.updatePause()
        }
        // macOS merkt sich das Schreibtischbild je Space -> beim Wechsel das Standbild nachtragen
        wc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reapplyLockPicture()
        }
        updateSaverIfNeeded()
        // Diagnose: defaults write local.kulisse.app wallpaperDebug -bool true -> alle 3 s Bildrate je Bildschirm
        if ud.bool(forKey: "wallpaperDebug") {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                for (i, v) in self.views.enumerated() {
                    v.web.evaluateJavaScript("(function(){var n=window.__dbgN||0;if(!window.__dbgOn){window.__dbgOn=1;(function f(){window.__dbgN=(window.__dbgN||0)+1;requestAnimationFrame(f)})();}window.__dbgN=0;return n;})()") { r, _ in
                        let spec = self.audio.running ? self.audio.spectrum() : []
                        if i == 0 {
                            let st = self.audio.takeStats()
                            v.web.evaluateJavaScript("JSON.stringify({angemeldet: !!window.__wpAudioCb, got: !!(window.Nishiki&&Nishiki.audio.got), active: !!(window.Nishiki&&Nishiki.audio.active), level: window.Nishiki?Math.round(Nishiki.audio.level*100)/100:null, dpr: window.devicePixelRatio})") { j, _ in
                                wpDebugLog("Audio: callbacks/3s=\(st.callbacks) lautestesSample=\(st.peak) seite=\(j ?? "-")")
                            }
                        }
                        let bass = spec.prefix(6).reduce(0, +) / 6, peak = spec.max() ?? 0
                        wpDebugLog("Bildschirm \(i): \(Int(v.frame.width))x\(Int(v.frame.height)) verdeckt=\(v.covered) pausiert=\(v.sentPaused ?? false) rAF/3s=\(r ?? "-") audio=\(self.audio.running) fehler=\(self.audioError ?? "-") bass=\(String(format: "%.2f", bass)) max=\(String(format: "%.2f", peak))")
                    }
                }
            }
        }
        // alle Netzwerkzugriffe der Hintergründe sperren
        let rules = "[" + ["^https?://", "^wss?://", "^ftp://"]
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }.joined(separator: ",") + "]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "kulisse-wallpaper-offline",
                                                                encodedContentRuleList: rules) { [weak self] list, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let list = list else {          // ohne Netzsperre keine fremden Seiten laden
                    NSLog("Wallpaper: Netzsperre ging nicht, Hintergrund bleibt aus: \(String(describing: err))")
                    return
                }
                self.ruleList = list
                self.rulesReady = true
                self.refresh()
            }
        }
    }

    func reloadPackages() {
        var list: [WallpaperPackage] = []
        var seen = Set<String>()
        let beside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpapers")
        let inside = Bundle.main.resourceURL?.appendingPathComponent("wallpapers")
        for dir in [beside, inside].compactMap({ $0 }) {
            let subs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for s in subs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !seen.contains(s.lastPathComponent) {
                if let p = try? WallpaperPackage(folder: s, builtin: true) { list.append(p); seen.insert(s.lastPathComponent) }
            }
        }
        let user = (try? FileManager.default.contentsOfDirectory(at: wallpapersFolder(), includingPropertiesForKeys: nil)) ?? []
        list += user.compactMap { try? WallpaperPackage(folder: $0, builtin: false) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        packages = list
        let id = current?.id ?? ud.string(forKey: "wallpaper")
        current = packages.first { $0.id == id } ?? packages.first
        writeSaverConfig()
    }

    func select(_ p: WallpaperPackage) {
        current = p
        ud.set(p.id, forKey: "wallpaper")
        refresh()
        changed()
    }

    // ----- Fenster -----
    @objc private func screensChanged() { refresh() }

    func refresh() {
        guard started, rulesReady else { return }
        views.forEach { $0.web.navigationDelegate = nil; $0.window.orderOut(nil); $0.window.close() }
        views = []
        activeView = nil
        guard enabled, let pkg = current else { stopMouse(); updateAudio(); return }
        let screens = allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        for screen in screens {
            let w = WallpaperWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.hasShadow = false
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.alphaValue = 0                       // erst einblenden, wenn Einstellungen drin sind
            let cfg = WKWebViewConfiguration()
            cfg.mediaTypesRequiringUserActionForPlayback = []
            cfg.suppressesIncrementalRendering = true
            if let r = ruleList { cfg.userContentController.add(r) }
            cfg.userContentController.addUserScript(WKUserScript(source: WP_HELPER_JS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            cfg.userContentController.addUserScript(WKUserScript(source: wpScreenJS(screen, among: screens),
                                                                 injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let dpr = pixelRatio(for: screen)
            if dpr != screen.backingScaleFactor {      // weniger Pixel rendern -> viel weniger GPU-Last
                cfg.userContentController.addUserScript(WKUserScript(source:
                    "try{Object.defineProperty(window,'devicePixelRatio',{get:function(){return \(dpr)},configurable:true});}catch(e){}",
                    injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: cfg)
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            web.setValue(false, forKey: "drawsBackground")
            // macOS meldet Fenster auf Schreibtisch-Ebene immer als „verdeckt“ – dann hält WebKit die Animation an.
            // Darum WebKits Erkennung aus und selbst prüfen, ob etwas zu sehen ist (checkCovered).
            let occSel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if let m = class_getInstanceMethod(WKWebView.self, occSel) {
                typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(m), to: SetBool.self)(web, occSel, false)
                occlusionWorkaroundOK = true
            } else {
                occlusionWorkaroundOK = false
                NSLog("Wallpaper: _setWindowOcclusionDetectionEnabled fehlt – Animation kann stehen bleiben")
            }
            w.contentView = web
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            web.loadFileURL(pkg.entry, allowingReadAccessTo: pkg.folder)
            views.append(WPScreenView(window: w, web: web, frame: screen.frame))
        }
        startMouse()
        updateAudio()
    }

    private func view(for web: WKWebView) -> WPScreenView? { views.first { $0.web === web } }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let v = view(for: webView), let pkg = current else { return }
        v.ready = true
        push(values(for: pkg), to: v)
        pushGeneral(v)
        v.sentPaused = nil
        updatePause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.8; v.window.animator().alphaValue = 1 }
        }
        scheduleLockPicture()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let pkg = current else { return decisionHandler(.cancel) }
        if ["about", "data", "blob"].contains(url.scheme ?? "") { return decisionHandler(.allow) }
        let ok = url.isFileURL && url.standardizedFileURL.path.hasPrefix(pkg.folder.standardizedFileURL.path + "/")
        decisionHandler(ok ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let v = view(for: webView), let pkg = current else { return }
        v.ready = false
        webView.loadFileURL(pkg.entry, allowingReadAccessTo: pkg.folder)
    }

    // ----- Werte -----
    func values(for p: WallpaperPackage) -> [String: Any] {
        var v = p.defaults
        if let saved = ud.dictionary(forKey: "wallpaperValues")?[p.id] as? [String: Any] {
            for (k, x) in saved where v[k] != nil { v[k] = x }
        }
        return v
    }

    private func save(_ vals: [String: Any], for p: WallpaperPackage) {
        var all = ud.dictionary(forKey: "wallpaperValues") ?? [:]
        all[p.id] = vals
        ud.set(all, forKey: "wallpaperValues")
    }

    /// Einstellung eines beliebigen Hintergrunds (Menü): der aktive bekommt sie sofort, andere merken sie sich
    func setValue(_ key: String, _ value: Any, for p: WallpaperPackage) {
        if p === current { setValue(key, value) } else { var v = values(for: p); v[key] = value; save(v, for: p) }
        changed()
    }
    func resetValues(for p: WallpaperPackage) {
        if p === current { replaceValues([:]) } else { save(p.defaults, for: p); changed() }
    }

    /// eine Einstellung ändern (Regler etc.) – wird gesammelt und kurz danach an die Seite gegeben
    func setValue(_ key: String, _ value: Any) {
        guard let p = current else { return }
        var v = values(for: p)
        v[key] = value
        save(v, for: p)
        pending[key] = value
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.flushScheduled = false
            let send = self.pending
            self.pending = [:]
            self.views.forEach { self.push(send, to: $0) }
            self.scheduleLockPicture()
            self.writeSaverConfig()
        }
    }

    /// alle Einstellungen ersetzen (Vorlage, Zurücksetzen); was fehlt, kommt vom Standard
    func replaceValues(_ new: [String: Any]) {
        guard let p = current else { return }
        var v = p.defaults
        for (k, x) in new where v[k] != nil { v[k] = x }
        save(v, for: p)
        views.forEach { push(v, to: $0) }
        scheduleLockPicture()
        changed()
    }

    private func push(_ vals: [String: Any], to v: WPScreenView) {
        guard !vals.isEmpty else { return }
        let obj = vals.mapValues { ["value": $0] }
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        v.js("(function(p){var l=window.wallpaperPropertyListener;if(l&&l.applyUserProperties)l.applyUserProperties(p);})(\(s))")
    }

    private func pushGeneral(_ v: WPScreenView) {
        v.js("(function(){var l=window.wallpaperPropertyListener;if(l&&l.applyGeneralProperties)l.applyGeneralProperties({fps:\(fps)});})()")
    }

    // ----- Pausieren -----
    var isPaused: Bool { userPaused || asleep || saverRunning || (pauseOnBattery && onBattery) }

    private func updatePause() {
        for v in views where v.ready {
            let p = isPaused || v.covered
            guard p != v.sentPaused else { continue }
            v.sentPaused = p
            v.js("window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused&&window.wallpaperPropertyListener.setPaused(\(p))")
        }
        updateAudio()
    }

    func pixelRatio(for screen: NSScreen) -> CGFloat {
        switch quality {
        case "retina": return screen.backingScaleFactor
        case "normal": return 1
        default: return screen.frame.width >= 2000 ? 1 : screen.backingScaleFactor
        }
    }

    // ----- Sperrbildschirm -----
    private func displayID(_ s: NSScreen) -> String? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { "\($0)" }
    }
    private var lockFolder: URL { wpFolder("Sperrbildschirm") }

    /// nach Änderungen kurz warten (Regler ziehen), dann Standbild machen
    func scheduleLockPicture(delay: Double = 4) {
        lockWork?.cancel()
        guard lockScreen, enabled else { return }
        let w = DispatchWorkItem { [weak self] in self?.updateLockPicture() }
        lockWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Standbild jedes Bildschirms als dessen Schreibtischbild setzen
    func updateLockPicture() {
        guard lockScreen, enabled else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        for v in views where v.ready {
            guard let screen = NSScreen.screens.first(where: { $0.frame == v.frame }), let id = displayID(screen) else { continue }
            v.web.takeSnapshot(with: nil) { [weak self] img, err in
                guard let self = self, self.lockScreen, self.enabled else { return }
                guard let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                    NSLog("Wallpaper: Standbild ging nicht: \(String(describing: err))"); return
                }
                // neuer Dateiname bei jedem Bild, sonst nimmt macOS das zwischengespeicherte alte
                let url = self.lockFolder.appendingPathComponent("\(id)-\(stamp).jpg")
                do {
                    try jpg.write(to: url)
                    var orig = self.ud.dictionary(forKey: "wallpaperLockOriginals") as? [String: String] ?? [:]
                    if orig[id] == nil, let cur = NSWorkspace.shared.desktopImageURL(for: screen),
                       !cur.path.hasPrefix(self.lockFolder.path) {
                        orig[id] = cur.path
                        self.ud.set(orig, forKey: "wallpaperLockOriginals")
                    }
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
                    self.cleanLockFolder(prefix: "\(id)-", keep: url.lastPathComponent)
                } catch {
                    NSLog("Wallpaper: Sperrbild setzen ging nicht: \(error)")
                }
            }
        }
    }

    /// neuester Standbild-Dateiname je Bildschirm erneut eintragen (z. B. in einem anderen Space)
    private func reapplyLockPicture() {
        guard lockScreen, enabled else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: lockFolder, includingPropertiesForKeys: nil)) ?? []
        for screen in NSScreen.screens {
            guard let id = displayID(screen),
                  let f = files.filter({ $0.lastPathComponent.hasPrefix("\(id)-") }).max(by: { $0.lastPathComponent < $1.lastPathComponent }),
                  NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != f.standardizedFileURL else { continue }
            var orig = ud.dictionary(forKey: "wallpaperLockOriginals") as? [String: String] ?? [:]
            if orig[id] == nil, let cur = NSWorkspace.shared.desktopImageURL(for: screen), !cur.path.hasPrefix(lockFolder.path) {
                orig[id] = cur.path; ud.set(orig, forKey: "wallpaperLockOriginals")
            }
            try? NSWorkspace.shared.setDesktopImageURL(f, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
        }
    }

    // ----- Bildschirmschoner: Sperren, während der Hintergrund weiterläuft -----
    static let saverName = "Kulisse.saver"
    static let oldSaverName = "Waschbaer Hintergrund.saver"     // Name vor der Umbenennung
    var saverEmbedded: URL? { Bundle.main.resourceURL?.appendingPathComponent(Self.saverName) }
    var saverInstalledURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/\(Self.saverName)")
    }
    /// true = beim Start wurde der alte Bildschirmschoner ersetzt; in den Systemeinstellungen neu wählen
    private(set) var saverRenamed = false
    var saverInstalled: Bool { FileManager.default.fileExists(atPath: saverInstalledURL.path) }

    /// Fingerabdruck eines Hintergrund-Ordners: jüngste Änderung, Anzahl und Gesamtgröße aller Dateien.
    /// (Nur project.json anzuschauen reicht nicht – sonst bleibt die Kopie alt, wenn sich z. B. nur ein Skript ändert.)
    private func folderStamp(_ folder: URL) -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var newest = 0.0, count = 0, size = 0
        if let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let u as URL in en {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                newest = max(newest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                count += 1; size += v.fileSize ?? 0
            }
        }
        return "\(Int(newest))|\(count)|\(size)"
    }

    /// Was der Bildschirmschoner zeigen soll (er liest das selbst, siehe saver.swift)
    func writeSaverConfig() {
        guard let p = current else { return }
        let main = NSScreen.screens.first
        // Der Bildschirmschoner darf ~/Documents, Schreibtisch usw. evtl. nicht lesen (Datenschutz von macOS):
        // Hintergründe von dort in eine eigene Kopie unter Application Support legen
        var folder = p.folder, entry = p.entry
        let base = wpFolder("")
        if !p.folder.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path) {
            let dest = base.appendingPathComponent("Bildschirmschoner-Hintergrund", isDirectory: true)
            let mark = dest.appendingPathComponent(".quelle")
            let stamp = p.folder.path + "|" + folderStamp(p.folder)
            if (try? String(contentsOf: mark, encoding: .utf8)) != stamp {
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: p.folder, to: dest)) != nil else { return }
                try? stamp.write(to: mark, atomically: true, encoding: .utf8)
            }
            folder = dest
            entry = dest.appendingPathComponent(String(p.entry.standardizedFileURL.path.dropFirst(p.folder.standardizedFileURL.path.count + 1)))
        }
        var cfg: [String: Any] = ["folder": folder.path, "entry": entry.path, "values": values(for: p),
                                  "fps": fps, "mainScreenOnly": !allScreens]
        if let m = main, pixelRatio(for: m) != m.backingScaleFactor || quality == "normal" { cfg["devicePixelRatio"] = Double(pixelRatio(for: m)) }
        guard let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = wpFolder("").appendingPathComponent("saver.json")
        if (try? Data(contentsOf: url)) != d { try? d.write(to: url, options: .atomic) }
    }

    func installSaver() throws {
        guard let src = saverEmbedded, FileManager.default.fileExists(atPath: src.path) else {
            throw ThemeError.message("In dieser Fassung der App liegt kein Bildschirmschoner (build.sh neu laufen lassen).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: saverInstalledURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: saverInstalledURL.path) { try fm.removeItem(at: saverInstalledURL) }
        try fm.copyItem(at: src, to: saverInstalledURL)
        writeSaverConfig()
        // ein noch laufender Wirtsprozess (Vorschau in den Systemeinstellungen) hielte die alte Fassung fest
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-f", "legacyScreenSaver"]
        try? k.run()
    }

    /// nach einem Neubau den eingerichteten Bildschirmschoner nachziehen
    private func updateSaverIfNeeded() {
        // alter Bildschirmschoner von vor der Umbenennung -> durch "Kulisse" ersetzen
        let old = saverInstalledURL.deletingLastPathComponent().appendingPathComponent(Self.oldSaverName)
        if FileManager.default.fileExists(atPath: old.path) {
            try? installSaver()
            try? FileManager.default.removeItem(at: old)
            saverRenamed = true
            return
        }
        guard saverInstalled, let src = saverEmbedded else { return }
        let bin = "Contents/MacOS/KulisseSaver"
        if (try? Data(contentsOf: src.appendingPathComponent(bin))) != (try? Data(contentsOf: saverInstalledURL.appendingPathComponent(bin))) {
            try? installSaver()
        }
    }

    /// Startet den in macOS gewählten Bildschirmschoner (kurz warten: Loslassen der Kürzel-Tasten beendet ihn sonst)
    func startSaver() {
        writeSaverConfig()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Ist "Passwort erforderlich nach Beginn des Bildschirmschoners" auf "Sofort"? (nur lesen; setzen tut der Benutzer)
    func saverLocksImmediately() -> Bool? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl"); p.arguments = ["-screenLock", "status"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if out.contains("immediate") { return true }
        return out.contains("screenLock") ? false : nil
    }

    private func cleanLockFolder(prefix: String?, keep: String?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: lockFolder, includingPropertiesForKeys: nil)) ?? []
        for f in files where (prefix == nil || f.lastPathComponent.hasPrefix(prefix!)) && f.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// vorherige Schreibtischbilder zurück
    func restoreDesktopPictures() {
        lockWork?.cancel()
        let orig = ud.dictionary(forKey: "wallpaperLockOriginals") as? [String: String] ?? [:]
        guard !orig.isEmpty else { return }
        var left: [String: String] = [:]
        for (id, path) in orig {
            guard let screen = NSScreen.screens.first(where: { displayID($0) == id }) else { left[id] = path; continue }
            let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            if (try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: opts)) == nil {
                NSLog("Wallpaper: altes Schreibtischbild \(path) ging nicht zurück")
            }
        }
        // Bildschirme, die gerade nicht angeschlossen sind, beim nächsten Mal
        if left.isEmpty { ud.removeObject(forKey: "wallpaperLockOriginals"); cleanLockFolder(prefix: nil, keep: nil) }
        else { ud.set(left, forKey: "wallpaperLockOriginals") }
    }

    // ----- Musik -----
    /// Tap nur laufen lassen, wenn eingeschaltet und mindestens ein Hintergrund sichtbar und nicht pausiert ist
    private func updateAudio() {
        let want = audioEnabled && enabled && views.contains { $0.ready && $0.sentPaused == false }
        if want && !audio.running && audioError == nil {
            do { try audio.start() } catch { audioError = error.localizedDescription; changed() }
        } else if !want && audio.running {
            audio.stop()
        }
        if audio.running && audioTimer == nil {
            audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.sendAudio() }
        } else if !audio.running, let t = audioTimer {
            t.invalidate(); audioTimer = nil
        }
    }

    private func sendAudio() {
        let spec = audio.spectrum().map { String(format: "%.3f", $0) }.joined(separator: ",")
        for v in views where v.sentPaused == false { v.js("window.__wpAudio&&__wpAudio([\(spec)])") }
    }

    /// Ist vom Schreibtisch noch etwas zu sehen? Prüft ein Raster von Punkten gegen alle normalen Fenster.
    /// Vollbild-Apps und maximierte Fenster -> Bildschirm pausiert.
    private func checkCovered() {
        guard !views.isEmpty else { return }
        let rects = normalWindowRects()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for v in views {
            let area = NSScreen.screens.first(where: { $0.frame == v.frame })?.visibleFrame ?? v.frame
            var visible = false
            outer: for iy in 0..<9 {
                for ix in 0..<14 {
                    let x = area.minX + area.width * (CGFloat(ix) + 0.5) / 14
                    let y = primaryTop - (area.minY + area.height * (CGFloat(iy) + 0.5) / 9)
                    if !rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { visible = true; break outer }
                }
            }
            v.covered = !visible
        }
        updatePause()
    }

    /// Rahmen aller sichtbaren normalen Fenster anderer Apps (oben-links-Koordinaten wie CGWindowList)
    private func normalWindowRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        return list.compactMap { w in
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer >= 0, layer < dock, (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != me else { return nil }
            if let a = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, a < 0.05 { return nil }
            guard let b = w[kCGWindowBounds as String] else { return nil }
            return CGRect(dictionaryRepresentation: b as! CFDictionary)
        }
    }

    private func checkBattery() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let battery = type == "Battery Power"
        if battery != onBattery { onBattery = battery; updatePause(); changed() }
    }

    // ----- Maus: Bewegungen immer, Klicks nur, wenn darunter wirklich der Schreibtisch ist -----
    private func startMouse() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] e in
            self?.handleMouse(e)
        }
    }
    private func stopMouse() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handleMouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        guard let v = views.first(where: { NSMouseInRect(p, $0.frame, false) }) else { leaveActive(); return }
        if v !== activeView { leaveActive(); activeView = v }
        let x = Int(p.x - v.frame.minX), y = Int(v.frame.maxY - p.y)
        switch e.type {
        case .mouseMoved, .leftMouseDragged:
            let now = CACurrentMediaTime()
            guard now - lastMove > 1.0 / 60 else { return }
            lastMove = now
            v.js("window.__wpMouse&&__wpMouse('move',\(x),\(y))")
        case .leftMouseDown:
            if desktopIsUnder(p) { v.js("window.__wpMouse&&__wpMouse('down',\(x),\(y))") }
        case .leftMouseUp:
            v.js("window.__wpMouse&&__wpMouse('up',\(x),\(y))")
        default: break
        }
    }

    private func leaveActive() {
        activeView?.js("window.__wpLeave&&__wpLeave()")
        activeView = nil
    }

    /// Liegt an der Stelle kein normales Fenster (Finder, Browser …) über dem Schreibtisch?
    private func desktopIsUnder(_ p: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              NSMouseInRect(p, screen.visibleFrame, false) else { return false }        // Menüleiste / Dock
        let cg = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
        return !normalWindowRects().contains { $0.contains(cg) }
    }

    // ----- Vorlagen -----
    func userPresets() -> [WPPreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: wallpaperPresetsFolder(), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let name = j["name"] as? String, let wid = j["wallpaper"] as? String else { return nil }
            return WPPreset(name: name, wallpaperID: wid, values: j["values"] as? [String: Any] ?? [:], file: f)
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func presets(for p: WallpaperPackage?) -> [WPPreset] {
        guard let p = p else { return [] }
        return p.presets + userPresets().filter { $0.wallpaperID == p.id }
    }

    func apply(_ preset: WPPreset) {
        if let p = packages.first(where: { $0.id == preset.wallpaperID }), p !== current { select(p) }
        replaceValues(preset.values)
        if !enabled { enabled = true }
    }

    private func presetJSON(name: String, pkg: WallpaperPackage, values: [String: Any]) throws -> Data {
        let j: [String: Any] = ["format": 1, "name": name, "wallpaper": pkg.id, "title": pkg.title, "values": values]
        return try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    @discardableResult
    func savePreset(name: String, wallpaperID: String? = nil, values: [String: Any]? = nil) throws -> WPPreset {
        guard let pkg = packages.first(where: { $0.id == (wallpaperID ?? current?.id) }) else {
            throw ThemeError.message("Kein Hintergrund ausgewählt.")
        }
        let vals = values ?? self.values(for: pkg)
        var dest = wallpaperPresetsFolder().appendingPathComponent(safeFolderName(name) + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = wallpaperPresetsFolder().appendingPathComponent("\(safeFolderName(name)) \(n).json"); n += 1
        }
        try presetJSON(name: name, pkg: pkg, values: vals).write(to: dest)
        changed()
        return WPPreset(name: name, wallpaperID: pkg.id, values: vals, file: dest)
    }

    func deletePreset(_ p: WPPreset) {
        guard let f = p.file else { return }
        try? FileManager.default.trashItem(at: f, resultingItemURL: nil)
        changed()
    }

    // ----- Export -----
    /// Schreibt den aktuellen Hintergrund mit seinen Einstellungen als .wallpapertheme.
    func export(to dest: URL, name: String, embedFiles: Bool) throws {
        guard let pkg = current else { throw ThemeError.message("Kein Hintergrund ausgewählt.") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("wallpapertheme-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try presetJSON(name: name, pkg: pkg, values: values(for: pkg)).write(to: tmp.appendingPathComponent("wallpaper.json"))
        if embedFiles { try fm.copyItem(at: pkg.folder, to: tmp.appendingPathComponent("files")) }
        try? fm.removeItem(at: dest)
        try runDitto(["-c", "-k", "--norsrc", tmp.path, dest.path])
    }

    // ----- Import -----
    enum ImportResult { case wallpaper(WallpaperPackage), preset(WPPreset) }

    /// .wallpapertheme, Zip oder Ordner (eigene Datei oder Wallpaper-Engine-Hintergrund mit project.json)
    func importFile(_ src: URL) throws -> ImportResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("wallpapertheme-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { throw ThemeError.message("Datei nicht gefunden.") }
        if isDir.boolValue { try fm.copyItem(at: src, to: tmp) } else {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            do { try runDitto(["-x", "-k", src.path, tmp.path]) } catch {
                throw ThemeError.message("„\(src.lastPathComponent)“ ist keine .\(WALLPAPER_EXT)- oder Zip-Datei.")
            }
        }
        func has(_ dir: URL, _ f: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(f).path) }
        var root = tmp
        if !has(tmp, "wallpaper.json") && !has(tmp, "project.json") {
            let subs = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
            guard let sub = subs.first(where: { has($0, "wallpaper.json") || has($0, "project.json") }) else {
                throw ThemeError.message("In der Datei ist weder eine wallpaper.json noch eine project.json.")
            }
            root = sub
        }
        if has(root, "wallpaper.json") {
            guard let d = try? Data(contentsOf: root.appendingPathComponent("wallpaper.json")),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                throw ThemeError.message("wallpaper.json ist kein gültiges JSON.")
            }
            let title = j["title"] as? String ?? ""
            var pkg: WallpaperPackage?
            let files = root.appendingPathComponent("files")
            if has(files, "project.json") { pkg = try install(files) }
            if pkg == nil { pkg = packages.first { $0.id == (j["wallpaper"] as? String) } ?? packages.first { $0.title == title } }
            guard let p = pkg else {
                throw ThemeError.message("Der Hintergrund „\(title)“ ist hier nicht installiert und nicht in der Datei enthalten.")
            }
            let name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? src.deletingPathExtension().lastPathComponent
            return .preset(try savePreset(name: name, wallpaperID: p.id, values: j["values"] as? [String: Any] ?? [:]))
        }
        return .wallpaper(try install(root))
    }

    /// Hintergrund-Ordner installieren – gibt es ihn schon (gleiche project.json), wird der vorhandene genommen.
    private func install(_ folder: URL) throws -> WallpaperPackage {
        let probe = try WallpaperPackage(folder: folder, builtin: false)
        if let same = packages.first(where: { $0.projectData == probe.projectData }) { return same }
        let fm = FileManager.default
        var dest = wallpapersFolder().appendingPathComponent(safeFolderName(probe.title))
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = wallpapersFolder().appendingPathComponent("\(safeFolderName(probe.title)) \(n)"); n += 1 }
        try fm.copyItem(at: folder, to: dest)
        reloadPackages()
        guard let p = packages.first(where: { !$0.builtin && $0.folder.lastPathComponent == dest.lastPathComponent }) else {
            throw ThemeError.message("Hintergrund konnte nicht geladen werden.")
        }
        changed()
        return p
    }

    /// nach dem Import: anzeigen
    func activate(_ r: ImportResult) {
        switch r {
        case .wallpaper(let p): select(p); if !enabled { enabled = true }
        case .preset(let pr): apply(pr)
        }
    }

    func deleteCurrentImported() {
        guard let p = current, !p.builtin else { return }
        try? FileManager.default.trashItem(at: p.folder, resultingItemURL: nil)
        current = nil
        ud.removeObject(forKey: "wallpaper")
        reloadPackages()
        refresh()
        changed()
    }
}
