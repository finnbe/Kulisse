// Live-Hintergrund: Systemton mithören und als Spektrum an die Hintergründe geben (wie Wallpaper Engine:
// 128 Werte = 64 Frequenzbänder links + 64 rechts, tief -> hoch, ungefähr 0..1).
//
// Benutzt die Audio-Taps von macOS (ab 14.2): ein "globaler Tap" bekommt eine Kopie von allem, was der Mac abspielt,
// ohne den Ton zu verändern. macOS fragt beim ersten Mal nach der Freigabe "Audioaufnahme"
// (Systemeinstellungen → Datenschutz & Sicherheit → Audioaufnahme). Nichts wird gespeichert oder verschickt –
// die App rechnet nur die Lautstärke pro Frequenzband aus.

import Cocoa
import CoreAudio
import AudioToolbox
import Accelerate

let WP_FFT_SIZE = 2048
let WP_BANDS = 64

final class SystemAudioSpectrum {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "kulisse.wallpaper.audio", qos: .userInteractive)
    private var sampleRate: Double = 48000

    // Ringpuffer (wird vom Audio-Thread beschrieben, vom Haupt-Thread gelesen)
    private var lock = os_unfair_lock()
    private var ringL = [Float](repeating: 0, count: WP_FFT_SIZE)
    private var ringR = [Float](repeating: 0, count: WP_FFT_SIZE)
    private var writePos = 0

    private let dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(WP_FFT_SIZE), .FORWARD)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: WP_FFT_SIZE, isHalfWindow: false)
    private var outputListener: AudioObjectPropertyListenerBlock?
    var running: Bool { procID != nil }
    /// Diagnose: Anzahl Audio-Callbacks und lautestes Sample seit dem letzten Abruf
    private(set) var callbacks = 0
    private var peakSample: Float = 0
    func takeStats() -> (callbacks: Int, peak: Float) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let r = (callbacks, peakSample); callbacks = 0; peakSample = 0; return r
    }

    deinit { stop(); if let d = dft { vDSP_DFT_DestroySetup(d) } }

    // ---------- Start / Stop ----------
    func start() throws {
        guard !running else { return }
        guard #available(macOS 14.2, *) else { throw ThemeError.message("Musikreaktion braucht macOS 14.2 oder neuer.") }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Audio-Tap anlegen")
        tapID = tap

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt), "Tap-Format lesen")
        sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000
        let nonInterleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let isFloat = fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0 && fmt.mBitsPerChannel == 32
        guard isFloat else { throw ThemeError.message("Unerwartetes Audioformat vom Tap.") }

        let outUID = try defaultOutputUID()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kulisse Hintergrund-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var aggDev = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggDev), "Audio-Gerät anlegen")
        aggID = aggDev

        var pid: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, queue) { [weak self] _, input, _, _, _ in
            self?.ingest(input, nonInterleaved: nonInterleaved)
        }, "Audio-Verarbeitung anlegen")
        procID = pid
        try check(AudioDeviceStart(aggID, procID), "Audio starten")
        watchOutputDevice()
    }

    func stop() {
        if let l = outputListener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, l)
            outputListener = nil
        }
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        os_unfair_lock_lock(&lock)
        for i in 0..<WP_FFT_SIZE { ringL[i] = 0; ringR[i] = 0 }
        os_unfair_lock_unlock(&lock)
    }

    /// Kopfhörer an/aus -> anderes Ausgabegerät -> Tap neu aufbauen
    private func watchOutputDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, self.running else { return }
            self.stop()
            try? self.start()
        }
        outputListener = l
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, l)
    }

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { stop(); throw ThemeError.message("\(what) ging nicht (Fehler \(s)).") }
    }

    private func defaultOutputUID() throws -> String {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev), "Ausgabegerät finden")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid), "Geräte-ID lesen")
        guard let u = uid?.takeRetainedValue() else { throw ThemeError.message("Ausgabegerät hat keine ID.") }
        return u as String
    }

    // ---------- Audio-Thread: Samples in den Ringpuffer ----------
    private func ingest(_ list: UnsafePointer<AudioBufferList>, nonInterleaved: Bool) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, let d0 = first.mData else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        callbacks += 1
        if nonInterleaved {
            let n = Int(first.mDataByteSize) / 4
            let l = d0.assumingMemoryBound(to: Float.self)
            let r = (abl.count > 1 ? abl[1].mData : nil)?.assumingMemoryBound(to: Float.self) ?? l
            for i in 0..<n { ringL[writePos] = l[i]; ringR[writePos] = r[i]; peakSample = max(peakSample, abs(l[i])); writePos = (writePos + 1) % WP_FFT_SIZE }
        } else {
            let ch = max(1, Int(first.mNumberChannels))
            let n = Int(first.mDataByteSize) / 4 / ch
            let p = d0.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                ringL[writePos] = p[i * ch]
                ringR[writePos] = p[i * ch + (ch > 1 ? 1 : 0)]
                peakSample = max(peakSample, abs(p[i * ch]))
                writePos = (writePos + 1) % WP_FFT_SIZE
            }
        }
    }

    // ---------- Haupt-Thread: Spektrum ausrechnen ----------
    /// 128 Werte (64 links, 64 rechts) im Format von Wallpaper Engine
    func spectrum() -> [Float] {
        var l = [Float](repeating: 0, count: WP_FFT_SIZE), r = l
        os_unfair_lock_lock(&lock)
        let start = writePos
        for i in 0..<WP_FFT_SIZE { l[i] = ringL[(start + i) % WP_FFT_SIZE]; r[i] = ringR[(start + i) % WP_FFT_SIZE] }
        os_unfair_lock_unlock(&lock)
        return bands(l) + bands(r)
    }

    private func bands(_ samples: [Float]) -> [Float] {
        guard let dft = dft else { return [Float](repeating: 0, count: WP_BANDS) }
        let n = WP_FFT_SIZE, half = n / 2
        let windowed = vDSP.multiply(samples, window)
        var inR = [Float](repeating: 0, count: half), inI = inR, outR = inR, outI = inR
        for i in 0..<half { inR[i] = windowed[2 * i]; inI[i] = windowed[2 * i + 1] }
        vDSP_DFT_Execute(dft, inR, inI, &outR, &outI)
        var mag = [Float](repeating: 0, count: half)
        for k in 1..<half { mag[k] = (outR[k] * outR[k] + outI[k] * outI[k]).squareRoot() / Float(n) }
        // 64 Bänder, logarithmisch von 30 Hz bis 16 kHz; Wert = lautestes Frequenzstück im Band, in dB -> 0..1
        let binHz = sampleRate / Double(n)
        let lo = log(30.0), hi = log(16000.0)
        var out = [Float](repeating: 0, count: WP_BANDS)
        for b in 0..<WP_BANDS {
            let f0 = exp(lo + (hi - lo) * Double(b) / Double(WP_BANDS))
            let f1 = exp(lo + (hi - lo) * Double(b + 1) / Double(WP_BANDS))
            let k0 = max(1, Int(f0 / binHz)), k1 = min(half - 1, max(k0, Int(f1 / binHz)))
            var m: Float = 0
            for k in k0...k1 { m = max(m, mag[k]) }
            let db = 20 * log10(m + 1e-9)
            out[b] = min(1.5, max(0, (db + 70) / 55))
        }
        return out
    }
}
