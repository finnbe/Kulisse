/* Musik: Wallpaper Engine liefert 128 Werte (64 je Kanal). Daraus Bass, Pegel und Einsätze (Beats). */
(function () {
  'use strict';
  const N = window.Nishiki;
  const A = N.audio = { bass: 0, mid: 0, treble: 0, level: 0, beat: 0, active: false, got: false };

  const raw = new Float32Array(64), hist = [];
  let peak = 0.2, prev = 0, lastOnset = -9, lastSound = -9, now = 0, pending = 0, demo = 0;

  A.ingest = function (arr) {
    A.got = true;
    let m = 0;
    for (let i = 0; i < 64; i++) {
      const v = (Math.min(arr[i] || 0, 1.5) + Math.min(arr[i + 64] || 0, 1.5)) * 0.5;
      raw[i] = v; if (v > m) m = v;
    }
    peak = Math.max(m, peak * 0.997, 0.05);
    let b = 0; for (let i = 0; i < 6; i++) b += raw[i];
    const nb = b / 6 / peak;
    hist.push(nb); if (hist.length > 40) hist.shift();
    let mean = 0; for (const v of hist) mean += v; mean /= hist.length;
    let sd = 0; for (const v of hist) sd += (v - mean) * (v - mean); sd = Math.sqrt(sd / hist.length);
    const flux = nb - prev; prev = nb;
    if (nb > mean + sd * 1.1 && flux > 0.04 && nb > 0.25 && now - lastOnset > 0.22) {
      lastOnset = now;
      pending = Math.max(pending, Math.min(1, (nb - mean) / (sd * 3 + 0.05)));
    }
    if (m > 0.012) lastSound = now;
  };

  A.tick = function (dt, time) {
    now = time;
    A.active = time - lastSound < 1.5;
    let b = 0, mi = 0, tr = 0;
    for (let i = 0; i < 64; i++) {
      const v = A.active ? Math.min(1, raw[i] / peak) : 0;
      if (i < 6) b += v; else if (i < 24) mi += v; else tr += v;
    }
    const k = Math.min(1, dt * 10);
    A.bass += (b / 6 - A.bass) * k; A.mid += (mi / 18 - A.mid) * k; A.treble += (tr / 40 - A.treble) * k;
    A.level += ((A.bass * 0.5 + A.mid * 0.35 + A.treble * 0.15) - A.level) * Math.min(1, dt * 2.5);
    A.beat *= Math.pow(0.02, dt * 2.2);
  };

  /* Stärke des letzten Einsatzes abholen (0 = keiner). */
  A.takeBeat = function () {
    const p = pending; pending = 0;
    if (p > 0) A.beat = Math.max(A.beat, 0.5 + p * 0.5);
    return A.active ? p : 0;
  };

  /* Nur zum Ausprobieren im Browser (?audio=demo): gleichmäßiger Bass mit 110 Schlägen pro Minute. */
  A.startDemo = function () {
    clearInterval(demo);
    const arr = new Float32Array(128), beat = 60 / 110, t0 = performance.now() / 1000;
    demo = setInterval(() => {
      const t = performance.now() / 1000 - t0, ph = (t % beat) / beat, kick = Math.exp(-ph * 8);
      for (let i = 0; i < 64; i++) {
        const f = i / 63;
        const v = (kick * Math.max(0, 1 - f * 5) * 0.9 + 0.2 * Math.exp(-f * 2.4) * (0.6 + 0.4 * Math.sin(t * 1.1 + i * 0.5)) + Math.random() * 0.03) * 0.6;
        arr[i] = v; arr[i + 64] = v;
      }
      A.ingest(arr);
    }, 33);
  };

  if (typeof window.wallpaperRegisterAudioListener === 'function') window.wallpaperRegisterAudioListener(A.ingest);
})();
