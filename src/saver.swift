// Bildschirmschoner "Kulisse": spielt den Live-Hintergrund der App auf jedem Bildschirm weiter.
//
// Wozu: Über dem Sperrbildschirm zeigt macOS nichts von fremden Apps. Ein Bildschirmschoner, der *vor* der Sperre
// läuft, bleibt aber sichtbar, bis jemand Maus oder Tastatur anfasst – erst dann kommt die (echte) Passwortabfrage
// von macOS. Mit "Passwort erforderlich nach Beginn des Bildschirmschoners: Sofort" ist der Mac dabei gesperrt.
//
// macOS lädt dieses Bündel in seinen eigenen Prozess (legacyScreenSaver, Sandbox mit Lesezugriff auf die Platte).
// Was gezeigt wird, schreibt die App nach ~/Library/Application Support/Kulisse/saver.json.
// Gebaut wird es von build.sh als eigenes Bündel (liegt in der App unter Resources/Kulisse.saver).

import AppKit
import ScreenSaver
import WebKit

private struct SaverConfig: Decodable {
    let folder: String          // Ordner des Hintergrunds
    let entry: String           // index.html darin (voller Pfad)
    let values: [String: SaverValue]
    let fps: Int
    let mainScreenOnly: Bool
    let devicePixelRatio: Double?

    /// der echte Benutzerordner (in der Sandbox zeigt NSHomeDirectory auf den Container)
    static var file: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Kulisse/saver.json")
    }
    static func read() -> SaverConfig? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SaverConfig.self, from: d)
    }
}

/// beliebiger JSON-Wert (Zahl, Text, Bool) – wird unverändert an die Seite gegeben
private enum SaverValue: Decodable {
    case num(Double), str(String), bool(Bool)
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .num(n) }
        else { self = .str(try c.decode(String.self)) }
    }
    var any: Any { switch self { case .num(let n): return n; case .str(let s): return s; case .bool(let b): return b } }
}

@objc(KulisseSaverView)
final class KulisseSaverView: ScreenSaverView, WKNavigationDelegate {
    private var web: WKWebView?
    private var config: SaverConfig?
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1          // die Seite zeichnet selbst
        // macOS beendet den Wirtsprozess nicht zuverlässig – sonst liefe der Teich unsichtbar weiter
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main) { [weak self] _ in
            self?.web?.removeFromSuperview()
            self?.web = nil
            if self?.isPreview == false { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) } }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, web == nil else { return }
        load()
    }

    private func load() {
        guard let cfg = SaverConfig.read() else {
            return note("Öffne einmal Kulisse und schalte den Live-Hintergrund ein.")
        }
        config = cfg
        if cfg.mainScreenOnly, let s = window?.screen, s != NSScreen.screens.first { return }   // nur Hauptbildschirm
        let folder = URL(fileURLWithPath: cfg.folder, isDirectory: true)
        let entry = URL(fileURLWithPath: cfg.entry)
        guard FileManager.default.isReadableFile(atPath: entry.path) else {
            return note("Der Bildschirmschoner kann die Dateien des Hintergrunds nicht lesen.")
        }
        let wc = WKWebViewConfiguration()
        wc.mediaTypesRequiringUserActionForPlayback = []
        wc.suppressesIncrementalRendering = true
        // Musik-Schnittstelle als leere Hülle, damit Seiten, die sich anmelden, nicht stolpern
        wc.userContentController.addUserScript(WKUserScript(source:
            "window.wallpaperRegisterAudioListener=function(){};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // welcher Bildschirm (von links gezählt) – für Hintergründe, die sich über mehrere Bildschirme erstrecken
        let all = (cfg.mainScreenOnly || isPreview) ? [] : NSScreen.screens
            .sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
        let idx = window?.screen.flatMap { s in all.firstIndex { $0 === s } } ?? 0
        wc.userContentController.addUserScript(WKUserScript(source:
            "window.kulisseScreen={index:\(idx),count:\(max(1, all.count))};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let dpr = cfg.devicePixelRatio, !isPreview {
            wc.userContentController.addUserScript(WKUserScript(source:
                "try{Object.defineProperty(window,'devicePixelRatio',{get:function(){return \(dpr)},configurable:true});}catch(e){}",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let w = WKWebView(frame: bounds, configuration: wc)
        w.autoresizingMask = [.width, .height]
        w.navigationDelegate = self
        w.setValue(false, forKey: "drawsBackground")
        // Fenster eines Bildschirmschoners gelten WebKit als verdeckt -> Animation stünde. Erkennung abschalten.
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if let m = class_getInstanceMethod(WKWebView.self, sel) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method_getImplementation(m), to: SetBool.self)(w, sel, false)
        }
        addSubview(w)
        web = w
        // alle Netzwerkzugriffe sperren; geht das nicht, bleibt es schwarz
        let rules = "[" + ["^https?://", "^wss?://", "^ftp://"]
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }.joined(separator: ",") + "]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "kulisse-saver-offline",
                                                                encodedContentRuleList: rules) { [weak self, weak w] list, _ in
            DispatchQueue.main.async {
                guard let self = self, let w = w, w === self.web else { return }
                guard let list = list else { return self.note("Netzsperre ging nicht – Hintergrund bleibt aus.") }
                w.configuration.userContentController.add(list)
                w.loadFileURL(entry, allowingReadAccessTo: folder)
            }
        }
    }

    // nur Dateien aus dem Ordner des Hintergrunds, kein Netz
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let cfg = config else { return decisionHandler(.cancel) }
        if ["about", "data", "blob"].contains(url.scheme ?? "") { return decisionHandler(.allow) }
        let root = URL(fileURLWithPath: cfg.folder).standardizedFileURL.path + "/"
        decisionHandler(url.isFileURL && url.standardizedFileURL.path.hasPrefix(root) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let cfg = config else { return }
        let obj = cfg.values.mapValues { ["value": $0.any] }
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) {
            webView.evaluateJavaScript("(function(p){var l=window.wallpaperPropertyListener;if(l&&l.applyUserProperties)l.applyUserProperties(p);})(\(s))")
        }
        webView.evaluateJavaScript("(function(){var l=window.wallpaperPropertyListener;if(l&&l.applyGeneralProperties)l.applyGeneralProperties({fps:\(cfg.fps)});})()")
    }

    private func note(_ text: String) {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: isPreview ? 10 : 18)
        l.alignment = .center
        l.frame = NSRect(x: 0, y: bounds.midY - 20, width: bounds.width, height: 40)
        l.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(l)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
    override func animateOneFrame() {}
}
