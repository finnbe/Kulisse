import Cocoa
import IOKit.pwr_mgt

/// "Anwesend bleiben" (⌃⌥A): hält Teams & Co. auf "Verfügbar", statt nach ein paar Minuten auf "Abwesend" zu springen.
/// Teams schaut auf die Leerlaufzeit des Systems (seit wann keine Maus/Tastatur). Alle WACH_INTERVAL Sekunden:
///  1. IOPMAssertionDeclareUserActivity – meldet macOS "Benutzer ist aktiv": setzt den Leerlauf-Zähler zurück,
///     verhindert Bildschirmschoner/Display-Schlaf. Braucht keine Freigabe.
///  2. Falls die App in Bedienungshilfen freigegeben ist: zusätzlich eine Mausbewegung um 0 Pixel an der aktuellen
///     Stelle (der Zeiger bewegt sich nicht) – zählt auch für Apps, die die letzte Eingabe direkt abfragen.
let WACH_INTERVAL: TimeInterval = 30

final class StayAwake {
    static let shared = StayAwake()
    private(set) var isOn = false
    private var timer: Timer?
    private var assertion: IOPMAssertionID = 0
    var onChange: (() -> Void)?

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        isOn = true
        tick()
        let t = Timer(timeInterval: WACH_INTERVAL, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        onChange?()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        timer?.invalidate()
        timer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        onChange?()
    }

    private func tick() {
        // gleiche ID wiederverwenden: macOS verlängert damit die bestehende Meldung statt neue anzulegen
        IOPMAssertionDeclareUserActivity("Kulisse: Anwesend bleiben" as CFString, kIOPMUserActiveLocal, &assertion)
        // Nur ausgelöst, wenn sich seit einer Weile niemand gerührt hat – sonst stört es nicht bei der Arbeit
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= WACH_INTERVAL - 1 && AXIsProcessTrusted() {
            let p = NSEvent.mouseLocation
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            let q = CGPoint(x: p.x, y: screenH - p.y)            // Cocoa (unten links) -> Quartz (oben links)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}
