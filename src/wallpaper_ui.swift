// Live-Hintergrund: Untermenü im 🦝-Menü, Einstellungsfenster und Dialoge (Export/Import/Vorlagen).
// Die Logik steckt in src/wallpaper.swift.

import Cocoa
import UniformTypeIdentifiers

/// Hält eine Vorlage im representedObject eines Menüeintrags.
final class WPPresetRef: NSObject {
    let preset: WPPreset
    init(_ p: WPPreset) { preset = p }
}

/// Eine Einstellung (und ggf. der zu setzende Wert) eines Hintergrunds im Menü.
final class WPPropRef: NSObject {
    let pkgID: String, key: String, value: Any?
    init(_ pkgID: String, _ key: String, _ value: Any? = nil) { self.pkgID = pkgID; self.key = key; self.value = value }
}
private var wpColorTarget: WPPropRef?

// ---------- Menü ----------
extension WallpaperManager {
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "🌊 Live-Hintergrund", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.delegate = self
        sub.autoenablesItems = false
        item.submenu = sub
        fillMenu(sub)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fillMenu(menu) }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, on: Bool = false, obj: Any? = nil,
                     enabled: Bool = true, indent: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = obj
        i.isEnabled = enabled && sel != nil
        i.indentationLevel = indent
        menu.addItem(i)
        return i
    }

    func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Live-Hintergrund an", #selector(menuToggleEnabled), on: enabled)
        add(menu, "Pausieren" + (onBattery && pauseOnBattery ? "  (Akku: pausiert)" : ""), #selector(menuTogglePause), on: userPaused)
        add(menu, "Auf Musik reagieren", #selector(menuToggleAudio), on: audioEnabled)
        add(menu, "Auch auf dem Sperrbildschirm (Standbild)", #selector(menuToggleLock), on: lockScreen)
        add(menu, "Sperren – Hintergrund läuft weiter  (⌃⌥⌘L)", #selector(menuLockWithSaver), enabled: current != nil)
        if saverRenamed {
            add(menu, "⚠️ Bildschirmschoner heißt jetzt „Kulisse“ – in den Einstellungen neu wählen", #selector(menuSetupSaver), indent: 1)
        }
        if saverInstalled, saverLockCached() == false {
            add(menu, "⚠️ macOS sperrt dabei nicht sofort – siehe „Bildschirmschoner einrichten …“", nil, enabled: false, indent: 1)
        }
        if !occlusionWorkaroundOK { add(menu, "⚠️ Animation evtl. eingeschränkt – siehe Einstellungen", nil, enabled: false) }
        menu.addItem(.separator())
        add(menu, "Hintergrund", nil, enabled: false)
        if packages.isEmpty { add(menu, "keiner gefunden", nil, enabled: false, indent: 1) }
        for p in packages {
            let item = add(menu, (p.builtin ? "" : "⭐ ") + p.title, nil, on: p === current && enabled, indent: 1)
            item.isEnabled = true
            item.submenu = packageMenu(p)
        }
        let pre = presets(for: current)
        if !pre.isEmpty {
            menu.addItem(.separator())
            add(menu, "Vorlagen", nil, enabled: false)
            for p in pre { add(menu, (p.file != nil ? "⭐ " : "") + p.name, #selector(menuPickPreset(_:)), obj: WPPresetRef(p), indent: 1) }
        }
        menu.addItem(.separator())
        add(menu, "Einstellungen …", #selector(menuSettings))
        add(menu, "Als Vorlage speichern …", #selector(menuSavePreset), enabled: current != nil)
        add(menu, "Bildschirmschoner einrichten …", #selector(menuSetupSaver))
        menu.addItem(.separator())
        add(menu, "Hintergrund exportieren …", #selector(menuExport), enabled: current != nil)
        add(menu, "Hintergrund importieren …", #selector(menuImport))
        add(menu, "Importierte Hintergründe im Finder zeigen", #selector(menuShowFolder))
        if let c = current, !c.builtin { add(menu, "Diesen importierten Hintergrund löschen …", #selector(menuDeleteWallpaper)) }
    }

    /// Untermenü je Hintergrund: verwenden, Vorlagen, alle Effekte/Farben aus seiner project.json
    private func packageMenu(_ p: WallpaperPackage) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let active = p === current && enabled
        add(m, active ? "Wird verwendet" : "Diesen Hintergrund verwenden", #selector(menuPickWallpaper(_:)), on: active, obj: p.id)
        let pre = presets(for: p)
        if !pre.isEmpty {
            let pi = add(m, "Vorlagen", nil)
            pi.isEnabled = true
            let pm = NSMenu(); pm.autoenablesItems = false
            for x in pre { add(pm, (x.file != nil ? "⭐ " : "") + x.name, #selector(menuPickPreset(_:)), obj: WPPresetRef(x)) }
            pi.submenu = pm
        }
        let vals = values(for: p)
        let props = p.properties.filter { $0.type != "textinput" && wpConditionMet($0.condition, vals) }
        if !props.isEmpty { m.addItem(.separator()); add(m, "Effekte & Farben", nil, enabled: false) }
        for prop in props {
            let cur = vals[prop.key] ?? prop.defaultValue
            switch prop.type {
            case "bool":
                add(m, prop.label, #selector(menuSetProp(_:)), on: wpBool(cur), obj: WPPropRef(p.id, prop.key, !wpBool(cur)))
            case "combo":
                let curLabel = prop.options.first { "\($0.value)" == "\(cur)" }?.label ?? "\(cur)"
                let ci = add(m, "\(prop.label): \(curLabel)", nil); ci.isEnabled = true
                let cm = NSMenu(); cm.autoenablesItems = false
                for o in prop.options {
                    add(cm, o.label, #selector(menuSetProp(_:)), on: "\(o.value)" == "\(cur)", obj: WPPropRef(p.id, prop.key, o.value))
                }
                ci.submenu = cm
            case "slider":
                let x = (cur as? NSNumber)?.doubleValue ?? Double("\(cur)") ?? prop.min
                let si = add(m, "\(prop.label): \(wpFmt(x, prop))", nil); si.isEnabled = true
                let sm = NSMenu(); sm.autoenablesItems = false
                var steps = (0...4).map { prop.min + (prop.max - prop.min) * Double($0) / 4 }
                if let d = (prop.defaultValue as? NSNumber)?.doubleValue, !steps.contains(where: { abs($0 - d) < 1e-9 }) { steps.append(d); steps.sort() }
                let near = steps.min { abs($0 - x) < abs($1 - x) }
                for v in steps {
                    let r = prop.fraction ? v : v.rounded()
                    let isDef = (prop.defaultValue as? NSNumber).map { abs($0.doubleValue - v) < 1e-9 } ?? false
                    let t = (v == prop.min && prop.min == 0 ? "Aus (0)" : wpFmt(r, prop)) + (isDef ? "  (Standard)" : "")
                    add(sm, t, #selector(menuSetProp(_:)), on: v == near, obj: WPPropRef(p.id, prop.key, prop.fraction ? r as Any : Int(r) as Any))
                }
                si.submenu = sm
            case "color":
                add(m, prop.label + " …", #selector(menuPickColor(_:)), obj: WPPropRef(p.id, prop.key, cur))
            default: break
            }
        }
        m.addItem(.separator())
        add(m, "Alle Einstellungen …", #selector(menuPackageSettings(_:)), obj: p.id)
        add(m, "Auf Standard zurücksetzen", #selector(menuResetPackage(_:)), obj: p.id)
        return m
    }

    private func wpBool(_ v: Any) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? ("\(v)" == "true" || "\(v)" == "1")) }
    private func wpFmt(_ x: Double, _ p: WPProperty) -> String { p.fraction ? String(format: "%.2f", x) : String(Int(x.rounded())) }
    private func pkg(_ id: String) -> WallpaperPackage? { packages.first { $0.id == id } }

    @objc func menuSetProp(_ s: NSMenuItem) {
        guard let r = s.representedObject as? WPPropRef, let p = pkg(r.pkgID), let v = r.value else { return }
        setValue(r.key, v, for: p)
    }
    @objc func menuPickColor(_ s: NSMenuItem) {
        guard let r = s.representedObject as? WPPropRef else { return }
        wpColorTarget = r
        let parts = "\(r.value ?? "")".split(separator: " ").compactMap { Double($0) }
        let panel = NSColorPanel.shared
        panel.setTarget(nil); panel.setAction(nil)
        if parts.count >= 3 { panel.color = NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: 1) }
        panel.setTarget(self); panel.setAction(#selector(menuColorChanged(_:)))
        panel.isContinuous = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    @objc func menuColorChanged(_ panel: NSColorPanel) {
        guard let r = wpColorTarget, let p = pkg(r.pkgID) else { return }
        let c = panel.color.usingColorSpace(.sRGB) ?? panel.color
        setValue(r.key, String(format: "%.3f %.3f %.3f", c.redComponent, c.greenComponent, c.blueComponent), for: p)
    }
    @objc func menuPackageSettings(_ s: NSMenuItem) {
        if let id = s.representedObject as? String, let p = pkg(id), p !== current { select(p) }
        WallpaperSettings.shared.show()
    }
    @objc func menuResetPackage(_ s: NSMenuItem) {
        if let id = s.representedObject as? String, let p = pkg(id) { resetValues(for: p) }
    }

    @objc func menuToggleEnabled() { enabled.toggle() }
    @objc func menuTogglePause() { userPaused.toggle() }
    @objc func menuToggleAudio() { audioEnabled.toggle() }
    @objc func menuLockWithSaver() { uiLockWithSaver() }
    @objc func menuSetupSaver() { uiSetupSaver() }
    @objc func menuToggleLock() { lockScreen.toggle(); if lockScreen && !enabled { enabled = true } }
    @objc func menuPickWallpaper(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let p = packages.first(where: { $0.id == id }) else { return }
        select(p)
        if !enabled { enabled = true }
    }
    @objc func menuPickPreset(_ s: NSMenuItem) { if let r = s.representedObject as? WPPresetRef { apply(r.preset) } }
    @objc func menuSettings() { WallpaperSettings.shared.show() }
    @objc func menuSavePreset() { uiSavePreset() }
    @objc func menuExport() { uiExport() }
    @objc func menuImport() { uiImport() }
    @objc func menuShowFolder() { NSWorkspace.shared.activateFileViewerSelecting([wallpapersFolder()]) }
    @objc func menuDeleteWallpaper() { uiDeleteWallpaper() }

    // ---------- Dialoge ----------
    func uiSavePreset() {
        guard let pkg = current else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Als Vorlage speichern"
        a.informativeText = "Die aktuellen Einstellungen von „\(pkg.title)“ werden als eigene Vorlage (⭐) gespeichert."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        tf.placeholderString = "Name der Vorlage"
        a.accessoryView = tf
        a.addButton(withTitle: "Speichern")
        a.addButton(withTitle: "Abbrechen")
        a.window.initialFirstResponder = tf
        guard overlay.withSystemCursor({ a.runModal() }) == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do { try savePreset(name: name) } catch { overlay.showError("Speichern ging nicht", error) }
    }

    func uiDeletePreset() {
        let own = presets(for: current).filter { $0.file != nil }
        guard !own.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Eigene Vorlage löschen"
        a.informativeText = "Die Vorlage wird in den Papierkorb gelegt."
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        own.forEach { pop.addItem(withTitle: $0.name) }
        a.accessoryView = pop
        a.addButton(withTitle: "Löschen")
        a.addButton(withTitle: "Abbrechen")
        guard overlay.withSystemCursor({ a.runModal() }) == .alertFirstButtonReturn else { return }
        deletePreset(own[pop.indexOfSelectedItem])
    }

    func uiExport() {
        guard let pkg = current else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Hintergrund exportieren"
        panel.message = "Speichert „\(pkg.title)“ mit den aktuellen Einstellungen als .\(WALLPAPER_EXT)-Datei."
        panel.nameFieldStringValue = safeFolderName(pkg.title) + "." + WALLPAPER_EXT
        if let t = UTType(filenameExtension: WALLPAPER_EXT) { panel.allowedContentTypes = [t] }
        let embed = NSButton(checkboxWithTitle: "Hintergrund-Dateien mitschicken (für Leute, die ihn noch nicht haben)",
                             target: nil, action: nil)
        embed.state = pkg.builtin ? .off : .on
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 36))
        embed.frame = NSRect(x: 16, y: 8, width: 460, height: 20)
        box.addSubview(embed)
        panel.accessoryView = box
        guard overlay.withSystemCursor({ panel.runModal() }) == .OK, let dest = panel.url else { return }
        do {
            try export(to: dest, name: dest.deletingPathExtension().lastPathComponent, embedFiles: embed.state == .on)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch { overlay.showError("Export ging nicht", error) }
    }

    func uiImport() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Hintergrund importieren"
        panel.message = "Eine .\(WALLPAPER_EXT)-Datei, ein Zip oder einen Ordner mit project.json (Wallpaper Engine, Typ „web“) auswählen"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard overlay.withSystemCursor({ panel.runModal() }) == .OK, let src = panel.url else { return }
        importAndShow(src)
    }

    func importAndShow(_ src: URL) {
        do { activate(try importFile(src)) } catch {
            NSApp.activate(ignoringOtherApps: true)
            overlay.showError("Import ging nicht", error)
        }
    }

    /// ⌃⌥⌘L / Menü: Bildschirmschoner starten. Ist er noch nicht eingerichtet, erst die Anleitung.
    func uiLockWithSaver() {
        guard current != nil else { return }
        guard saverInstalled else { return uiSetupSaver() }
        startSaver()
    }

    private static var lockCache: (Bool?, Date)?
    /// sysadminctl nicht bei jedem Menü-Öffnen fragen
    func saverLockCached() -> Bool? {
        if let c = Self.lockCache, Date().timeIntervalSince(c.1) < 30 { return c.0 }
        let v = saverLocksImmediately()
        Self.lockCache = (v, Date())
        return v
    }

    func uiSetupSaver() {
        NSApp.activate(ignoringOtherApps: true)
        do { try installSaver() } catch {
            let a = NSAlert(); a.messageText = "Bildschirmschoner ging nicht"; a.informativeText = error.localizedDescription
            _ = overlay.withSystemCursor { a.runModal() }
            return
        }
        Self.lockCache = nil
        let immediate = saverLocksImmediately()
        let a = NSAlert()
        a.messageText = "Bildschirmschoner eingerichtet"
        a.informativeText = """
        Über dem Sperrbildschirm zeigt macOS nichts von anderen Apps. Ein Bildschirmschoner läuft aber auch bei gesperrtem Mac weiter,         bis du Maus oder Tastatur anfasst – dann kommt die normale Passwortabfrage von macOS.

        Zwei Einstellungen musst du selbst setzen (die App ändert keine Systemeinstellungen):
        1. Bildschirmschoner: „Kulisse“ wählen (unter „Andere“).
        2. Sperrbildschirm: „Passwort erforderlich nach Beginn des Bildschirmschoners …“ auf „Sofort“.\(immediate == true ? "  ✓ ist schon so" : immediate == false ? "  ⚠️ steht noch nicht auf „Sofort“" : "")

        Danach sperrt „Sperren – Hintergrund läuft weiter“ (⌃⌥⌘L) den Mac, und der Teich läuft weiter.         Die Touch-ID-Taste und ⌃⌘Q zeigen weiterhin den normalen Sperrbildschirm von macOS.
        """
        a.addButton(withTitle: "Bildschirmschoner-Einstellungen öffnen")
        a.addButton(withTitle: "Sperrbildschirm-Einstellungen öffnen")
        a.addButton(withTitle: "Fertig")
        let r = overlay.withSystemCursor { a.runModal() }
        let target: String? = r == .alertFirstButtonReturn ? "com.apple.ScreenSaver-Settings.extension"
            : r == .alertSecondButtonReturn ? "com.apple.Lock-Screen-Settings.extension" : nil
        if let t = target, let url = URL(string: "x-apple.systempreferences:\(t)") { NSWorkspace.shared.open(url) }
    }

    func uiDeleteWallpaper() {
        guard let p = current, !p.builtin else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "„\(p.title)“ löschen?"
        a.informativeText = "Der importierte Hintergrund wird in den Papierkorb gelegt. Eigene Vorlagen dafür bleiben erhalten."
        a.addButton(withTitle: "Löschen")
        a.addButton(withTitle: "Abbrechen")
        guard overlay.withSystemCursor({ a.runModal() }) == .alertFirstButtonReturn else { return }
        deleteCurrentImported()
    }
}

// ---------- Einstellungsfenster ----------
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class ActionTarget: NSObject {
    let fn: (NSControl) -> Void
    init(_ fn: @escaping (NSControl) -> Void) { self.fn = fn }
    @objc func fire(_ s: NSControl) { fn(s) }
}

final class WallpaperSettings: NSObject, NSWindowDelegate {
    static let shared = WallpaperSettings()
    private let m = WallpaperManager.shared
    private var window: NSWindow?
    private var content: NSStackView!
    private var targets: [ActionTarget] = []
    private var propRows: [(prop: WPProperty, row: NSGridRow)] = []
    private var rebuildQueued = false

    func show() {
        if window == nil { build() }
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Live-Hintergrund"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 420)
        w.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        w.contentView = scroll
        w.center()
        window = w
        m.onChange = { [weak self] in self?.queueRebuild() }
    }

    /// nur zum Testen (--settings-preview <png>): Fenster aufbauen und als Bild speichern
    func renderPreview(to path: String) {
        if window == nil { build() }
        rebuild()
        guard let w = window, let v = w.contentView else { return }
        w.setFrameOrigin(NSPoint(x: -5000, y: 0))
        w.orderFrontRegardless()
        v.layoutSubtreeIfNeeded()
        let doc = (v as? NSScrollView)?.documentView ?? v
        doc.layoutSubtreeIfNeeded()
        let size = NSSize(width: v.bounds.width, height: max(v.bounds.height, doc.fittingSize.height))
        doc.setFrameSize(size)
        guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
        doc.cacheDisplay(in: doc.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.orderOut(nil)
    }

    /// nach dem aktuellen Ereignis neu aufbauen (nicht mitten in der Aktion eines Knopfs)
    private func queueRebuild() {
        guard window?.isVisible == true, !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in self?.rebuildQueued = false; self?.rebuild() }
    }

    // ----- kleine Bausteine -----
    private func bind(_ c: NSControl, _ fn: @escaping (NSControl) -> Void) {
        let t = ActionTarget(fn)
        targets.append(t)
        c.target = t
        c.action = #selector(ActionTarget.fire(_:))
    }
    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.lineBreakMode = .byWordWrapping
        l.preferredMaxLayoutWidth = 190
        return l
    }
    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 14)
        return l
    }
    private func note(_ s: String, width: CGFloat = 560) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.preferredMaxLayoutWidth = width
        l.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return l
    }
    private func checkbox(_ title: String, _ on: Bool, _ fn: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        bind(b) { fn(($0 as! NSButton).state == .on) }
        return b
    }
    private func button(_ title: String, enabled: Bool = true, _ fn: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.isEnabled = enabled
        bind(b) { _ in fn() }
        return b
    }
    private func popup(_ items: [String], selected: Int, _ fn: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for t in items { p.menu?.addItem(NSMenuItem(title: t, action: nil, keyEquivalent: "")) }   // erlaubt doppelte Titel
        if selected >= 0 && selected < items.count { p.selectItem(at: selected) }
        bind(p) { fn(($0 as! NSPopUpButton).indexOfSelectedItem) }
        return p
    }
    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }
    private func grid() -> NSGridView {
        let g = NSGridView(numberOfColumns: 3, rows: 0)
        g.rowSpacing = 10
        g.columnSpacing = 10
        g.rowAlignment = .none
        return g
    }
    private func addRow(_ g: NSGridView, _ cells: [NSView]) -> NSGridRow {
        var c = cells
        while c.count < 3 { c.append(NSGridCell.emptyContentView) }
        let r = g.addRow(with: c)
        r.yPlacement = .center
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 0).width = 190
        return r
    }

    private static func color(fromWE s: Any) -> NSColor {
        let p = "\(s)".split(separator: " ").compactMap { Double($0) }
        guard p.count >= 3 else { return .white }
        return NSColor(srgbRed: p[0], green: p[1], blue: p[2], alpha: 1)
    }
    private static func weString(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "%.3f %.3f %.3f", s.redComponent, s.greenComponent, s.blueComponent)
    }
    private static func number(_ v: Any) -> Double { (v as? NSNumber)?.doubleValue ?? Double("\(v)") ?? 0 }
    private static func format(_ x: Double, _ p: WPProperty) -> String {
        p.fraction ? String(format: "%.2f", x) : String(Int(x.rounded()))
    }

    // ----- Inhalt -----
    private func rebuild() {
        guard let content = content else { return }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets = []
        propRows = []

        // Allgemein
        content.addArrangedSubview(header("Allgemein"))
        let g = grid()
        _ = addRow(g, [label("Live-Hintergrund:"), checkbox("An", m.enabled) { [m] in m.enabled = $0 }])
        let pk = m.packages
        let wpPop = popup(pk.map { ($0.builtin ? "" : "⭐ ") + $0.title }, selected: pk.firstIndex { $0 === m.current } ?? -1) { [m] i in
            m.select(pk[i]); if !m.enabled { m.enabled = true }
        }
        if let c = m.current, !c.builtin {
            _ = addRow(g, [label("Hintergrund:"), row(wpPop, button("Löschen …") { [m] in m.uiDeleteWallpaper() })])
        } else {
            _ = addRow(g, [label("Hintergrund:"), wpPop])
        }
        let pre = m.presets(for: m.current)
        let prePop = popup(["Vorlage wählen …"] + pre.map { ($0.file != nil ? "⭐ " : "") + $0.name }, selected: 0) { [m] i in
            if i > 0 { m.apply(pre[i - 1]) }
        }
        prePop.isEnabled = !pre.isEmpty
        _ = addRow(g, [label("Vorlage:"), row(prePop,
                                               button("Speichern …", enabled: m.current != nil) { [m] in m.uiSavePreset() },
                                               button("Löschen …", enabled: pre.contains { $0.file != nil }) { [m] in m.uiDeletePreset() })])
        let fpsIdx = WP_FPS_CHOICES.firstIndex { $0.fps == m.fps } ?? 1
        _ = addRow(g, [label("Bildrate:"), popup(WP_FPS_CHOICES.map(\.title), selected: fpsIdx) { [m] i in m.fps = WP_FPS_CHOICES[i].fps }])
        let qual: [(String, String)] = [("auto", "Automatisch (große Bildschirme sparsamer)"), ("retina", "Retina – am schärfsten, mehr GPU"),
                                        ("normal", "Normal – spart am meisten GPU")]
        _ = addRow(g, [label("Qualität:"), popup(qual.map(\.1), selected: qual.firstIndex { $0.0 == m.quality } ?? 0) { [m] i in m.quality = qual[i].0 }])
        let audioBox = checkbox("Auf Musik reagieren (hört den Systemton mit)", m.audioEnabled) { [m] in m.audioEnabled = $0 }
        _ = addRow(g, [label("Musik:"), audioBox])
        if let err = m.audioError {
            let n = note("⚠️ \(err) Prüfen: Systemeinstellungen → Datenschutz & Sicherheit → Audioaufnahme → Kulisse erlauben, dann Haken aus und wieder an.", width: 400)
            n.textColor = .systemOrange
            _ = addRow(g, [NSGridCell.emptyContentView, n])
        } else if m.audioEnabled {
            _ = addRow(g, [NSGridCell.emptyContentView, note("Beim ersten Mal fragt macOS nach der Freigabe „Audioaufnahme“. Es wird nichts gespeichert.", width: 400)])
        }
        _ = addRow(g, [label("Sperrbildschirm:"), checkbox("Auch beim Sperren zeigen (als Standbild)", m.lockScreen) { [m] in m.lockScreen = $0 }])
        if m.lockScreen {
            _ = addRow(g, [NSGridCell.emptyContentView, note("Bewegt geht es dort nicht – macOS lässt keine App auf den Sperrbildschirm zeichnen. "
                + "Darum wird alle 15 Minuten und nach jeder Änderung ein Standbild vom Teich als Schreibtischbild gesetzt; das zeigt macOS beim Sperren. "
                + "Haken aus = dein vorheriges Schreibtischbild kommt zurück.", width: 400)])
        }
        _ = addRow(g, [label("Bildschirme:"), checkbox("Auf allen Bildschirmen (sonst nur Hauptbildschirm)", m.allScreens) { [m] in m.allScreens = $0 }])
        _ = addRow(g, [label("Strom sparen:"), checkbox("Bei Akkubetrieb pausieren" + (m.onBattery ? "  (gerade Akku)" : ""), m.pauseOnBattery) { [m] in m.pauseOnBattery = $0 }])
        _ = addRow(g, [label("Pause:"), checkbox("Animation anhalten", m.userPaused) { [m] in m.userPaused = $0 }])
        content.addArrangedSubview(g)
        if !m.occlusionWorkaroundOK {
            let w = note("⚠️ Diese macOS-Version hat die WebKit-Funktion nicht mehr, die der Hintergrund zum Animieren braucht. "
                + "Der Teich kann deshalb stehen bleiben. Bitte melden – dann muss die App angepasst werden.")
            w.textColor = .systemOrange
            content.addArrangedSubview(w)
        }

        // Einstellungen des Hintergrunds
        if let pkg = m.current {
            content.addArrangedSubview(NSBox.separator())
            content.addArrangedSubview(header("Einstellungen – \(pkg.title)"))
            if pkg.properties.isEmpty {
                content.addArrangedSubview(note("Dieser Hintergrund hat keine Einstellungen."))
            } else {
                let pg = grid()
                let vals = m.values(for: pkg)
                for p in pkg.properties {
                    let v = vals[p.key] ?? p.defaultValue
                    var cells: [NSView] = [label(p.label + ":")]
                    switch p.type {
                    case "slider":
                        let s = NSSlider(value: Self.number(v), minValue: p.min, maxValue: p.max, target: nil, action: nil)
                        s.isContinuous = true
                        s.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
                        let vl = NSTextField(labelWithString: Self.format(Self.number(v), p))
                        vl.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                        vl.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
                        bind(s) { [weak self, m] c in
                            var x = (c as! NSSlider).doubleValue
                            x = p.step > 0 ? (x / p.step).rounded() * p.step : x
                            vl.stringValue = Self.format(x, p)
                            m.setValue(p.key, p.fraction ? x : Int(x.rounded()))
                            self?.updateConditions()
                        }
                        cells += [s, vl]
                    case "bool":
                        let on = (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)
                        cells.append(checkbox("", on) { [weak self, m] b in m.setValue(p.key, b); self?.updateConditions() })
                    case "combo":
                        let idx = p.options.firstIndex { "\($0.value)" == "\(v)" } ?? 0
                        cells.append(popup(p.options.map(\.label), selected: idx) { [weak self, m] i in
                            m.setValue(p.key, p.options[i].value); self?.updateConditions()
                        })
                    case "color":
                        let well = NSColorWell()
                        well.color = Self.color(fromWE: v)
                        well.widthAnchor.constraint(equalToConstant: 60).isActive = true
                        well.heightAnchor.constraint(equalToConstant: 26).isActive = true
                        bind(well) { [m] c in m.setValue(p.key, Self.weString((c as! NSColorWell).color)) }
                        cells.append(well)
                    default:                                    // textinput
                        let tf = NSTextField(string: "\(v)")
                        tf.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
                        bind(tf) { [m] c in m.setValue(p.key, (c as! NSTextField).stringValue) }
                        cells.append(tf)
                    }
                    propRows.append((p, addRow(pg, cells)))
                }
                content.addArrangedSubview(pg)
                updateConditions()
            }
        }

        // unten: Zurücksetzen, Export, Import
        content.addArrangedSubview(NSBox.separator())
        content.addArrangedSubview(row(
            button("Auf Standard zurücksetzen", enabled: m.current != nil) { [m] in m.replaceValues([:]) },
            button("Exportieren …", enabled: m.current != nil) { [m] in m.uiExport() },
            button("Importieren …") { [m] in m.uiImport() },
            button("Ordner zeigen") { [m] in m.menuShowFolder() }))
        content.addArrangedSubview(note("Exportieren speichert Hintergrund + Einstellungen als .\(WALLPAPER_EXT)-Datei (zum Weitergeben). "
            + "Importieren nimmt solche Dateien, aber auch Web-Hintergründe aus Wallpaper Engine (Ordner oder Zip mit project.json). "
            + "Hintergründe laufen ohne Internetzugriff. Klicks erreichen den Hintergrund nur, wenn kein Fenster darüber liegt."))
        for v in content.arrangedSubviews where v is NSBox {
            v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
        }
    }

    /// Einstellungen mit Bedingung (z. B. Uhr-Position nur, wenn die Uhr an ist) ein-/ausblenden
    private func updateConditions() {
        guard let pkg = m.current else { return }
        let vals = m.values(for: pkg)
        for (p, r) in propRows { r.isHidden = !wpConditionMet(p.condition, vals) }
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}
