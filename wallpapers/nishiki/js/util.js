/* Hilfsfunktionen: Zufall mit Startwert, Rauschen, Winkel, Farben. */
(function () {
  'use strict';
  const N = window.Nishiki = window.Nishiki || {};
  const U = N.util = {};

  U.TAU = Math.PI * 2;
  U.clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  U.lerp = (a, b, t) => a + (b - a) * t;
  U.smooth = (a, b, v) => { const t = U.clamp((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
  U.angDiff = (a, b) => { let d = (a - b) % U.TAU; if (d > Math.PI) d -= U.TAU; if (d < -Math.PI) d += U.TAU; return d; };

  /* Zufallsgenerator mit Startwert (mulberry32), damit jeder Fisch und jedes Blatt gleich bleibt. */
  U.rng = function (seed) {
    let a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  };

  /* Wert-Rauschen in 2D, 0..1. */
  U.makeNoise = function (seed) {
    const r = U.rng(seed), n = 256, tab = new Float32Array(n * n);
    for (let i = 0; i < tab.length; i++) tab[i] = r();
    const at = (x, y) => tab[((y & 255) << 8) | (x & 255)];
    return function (x, y) {
      const xi = Math.floor(x), yi = Math.floor(y);
      let fx = x - xi, fy = y - yi;
      fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
      const a = at(xi, yi), b = at(xi + 1, yi), c = at(xi, yi + 1), d = at(xi + 1, yi + 1);
      return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
    };
  };
  U.fbm = function (noise, x, y, oct) {
    let s = 0, a = 0.5, n = 0;
    for (let i = 0; i < oct; i++) { s += a * noise(x, y); n += a; x = x * 2.03 + 17.1; y = y * 2.03 + 9.7; a *= 0.5; }
    return s / n;
  };

  /* Wallpaper Engine liefert Farben als "r g b" mit Werten 0..1. */
  U.parseColor = function (str) {
    if (typeof str !== 'string') return null;
    const p = str.trim().split(/\s+/).map(Number);
    if (p.length < 3 || p.some((v) => !isFinite(v))) return null;
    return [U.clamp(p[0], 0, 1), U.clamp(p[1], 0, 1), U.clamp(p[2], 0, 1)];
  };

  U.mix3 = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
})();
