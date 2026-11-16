// Bereitet das Bild "Hand hält den Griff" für die App vor:
//   swift src/make_halter.swift <eingabe.png> waschbaer-halter.png
// - schwarzer Hintergrund -> transparent (weicher Übergang, damit Fellhaare nicht hart abgeschnitten sind)
// - der schwarze Griff im Bild wird entfernt, die App zeichnet ihren eigenen Griff darunter
// - das Armende wird weich ausgeblendet
// Schreibt dazu waschbaer-halter.json (wo der Griff im Bild ist), das liest die App.
import Cocoa

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { print("Aufruf: swift make_halter.swift <eingabe.png> <ausgabe.png>"); exit(1) }

let w = src.width, h = src.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))   // Zeile 0 = oben
func m(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return max(Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }

// Griff finden: in einer Zeile weit oben (nur Griff, keine Pfote) die Spalten, die heller als der Hintergrund sind
let probeRow = h / 6
let gripCols = (0..<w).filter { m($0, probeRow) > 8 }
guard let gl = gripCols.first, let gr = gripCols.last else { print("Griff nicht gefunden"); exit(1) }
let gripX = Double(gl + gr) / 2, gripW = Double(gr - gl + 1)

// Faust: Zeilen, in denen rechts neben dem Griff Finger liegen
let fistRows = (0..<h).filter { y in (min(w - 1, gr + 5)...min(w - 1, gr + 120)).filter { m($0, y) > 60 }.count > 15 }
guard let f0 = fistRows.first, let f1 = fistRows.last else { print("Faust nicht gefunden"); exit(1) }
let anchorY = Double(f0 + f1) / 2

// Armende ausblenden: Schnittlinie vom linken Rand (Oberkante Arm) zum unteren Rand (rechte Kante Arm)
let leftEdgeY = (0..<h).first { y in (0..<8).contains { m($0, y) > 30 } } ?? h
let bottomEdgeX = (0..<w).last { x in x < gl && (h - 8..<h).contains { m(x, $0) > 30 } } ?? 0
let lx = 0.0, ly = Double(leftEdgeY), bx = Double(bottomEdgeX), by = Double(h)
var nx = -(by - ly), ny = bx - lx                      // Normale der Schnittlinie, zeigt nach außen (unten links)
let nl = (nx * nx + ny * ny).squareRoot(); nx /= nl; ny /= nl
let tCut = lx * nx + ly * ny
let fadeLen = 0.16 * Double(h)

// Echter Hintergrund = alles sehr Dunkle, das vom Bildrand aus zusammenhängt. Dunkle Stellen IN der Pfote
// (Schatten zwischen den Fingern, dunkles Fell) hängen nicht mit dem Rand zusammen und bleiben deckend.
var isBg = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
while let i = stack.popLast() {
    if isBg[i] { continue }
    let x = i % w, y = i / w
    if m(x, y) >= 10 { continue }
    isBg[i] = true
    if x > 0 { stack.append(i - 1) }
    if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }
    if y < h - 1 { stack.append(i + w) }
}

var out = [UInt8](repeating: 0, count: w * h * 4)
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let v = m(x, y)
        var f = 1.0
        // Griff entfernen: alles Dunkle im Griffbereich, und ganze Griffzeilen außerhalb der Faust
        // (in den Faust-Zeilen nur genau so breit wie der Griff, den die App darunter zeichnet –
        //  sonst entstehen neben dem Griff durchsichtige Streifen)
        let inFist = y >= f0 && y <= f1
        let margin = inFist ? 0 : 8
        if x >= gl - margin && x <= gr + margin {
            let edge = x < gl + 18 || x > gr - 14         // Kanten des alten Griffs (heller Rand)
            if y < f0 - 90 || y > f1 + 60 { f = 0 }        // nur Griff, keine Pfote
            else if v < 45 { f = 0 }                       // dunkel = Griff schaut durch
            else if edge && !inFist && v <= 185 { f = 0 }  // heller Griffrand über/unter den Fingern
        }
        let t = Double(x) * nx + Double(y) * ny
        f *= min(1, max(0, (tCut - t) / fadeLen))
        if f == 0 { continue }
        // Pfote deckend; nur am Rand zum Hintergrund weicher Übergang (Farbe ist dort schon "vormultipliziert")
        let a = (isBg[y * w + x] ? min(1.0, max(0, Double(v - 3) / 11.0)) : 1.0) * f
        out[i] = UInt8(Double(px[i]) * f); out[i + 1] = UInt8(Double(px[i + 1]) * f)
        out[i + 2] = UInt8(Double(px[i + 2]) * f); out[i + 3] = UInt8((a * 255).rounded())
    }
}

// auf den sichtbaren Teil zuschneiden
var x0 = w, y0 = h, x1 = 0, y1 = 0
for y in 0..<h { for x in 0..<w where out[(y * w + x) * 4 + 3] > 4 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
let octx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let cropped = octx.makeImage()!.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))!
let rep = NSBitmapImageRep(cgImage: cropped)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
let meta: [String: Double] = ["gripX": gripX - Double(x0), "gripWidth": gripW, "anchorY": anchorY - Double(y0)]
let json = try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: (args[2] as NSString).deletingPathExtension + ".json"))
print("Griff x=\(gripX) breite=\(gripW), Faust \(f0)-\(f1), Schnitt links y=\(leftEdgeY) unten x=\(bottomEdgeX), zugeschnitten \(x0),\(y0)-\(x1),\(y1)")
