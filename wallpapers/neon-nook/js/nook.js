/* Neon Nook – ein gemütlicher Fensterplatz über einer verregneten Neon-Stadt.
 *
 * Aufbau (alles Canvas 2D, ohne Bibliotheken, ohne Netz):
 *   Himmel + ferne Skyline (vorgerendert)  ->  Suchscheinwerfer, ferne Gleiter  ->  nahe Häuser (vorgerendert)
 *   ->  Neonschilder (je Schild vorgerendert, flackern)  ->  Werbetafel (tanzt zur Musik)  ->  nahe Gleiter, Regen
 *   ->  beschlagene Scheibe (Maus wischt frei, beschlägt langsam wieder)  ->  Tropfen auf dem Glas
 *   ->  Zimmer: Rahmen, Fensterbank, Lampe, Pflanze, Tasse mit Dampf, Radio mit Uhr, schlafende Katze.
 * Schnittstelle wie Wallpaper Engine: wallpaperPropertyListener, wallpaperRegisterAudioListener.
 */
(function () {
  'use strict';

  /* ================= Hilfen ================= */
  const TAU = Math.PI * 2;
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const lerp = (a, b, t) => a + (b - a) * t;
  function rng(seed) {
    let s = seed >>> 0;
    return function () { s = (s + 0x6D2B79F5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }
  function hex(c) { const n = parseInt(c.slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; }
  function mix(a, b, t) { const x = hex(a), y = hex(b); return '#' + [0, 1, 2].map(i => Math.round(lerp(x[i], y[i], t)).toString(16).padStart(2, '0')).join(''); }
  function rgba(c, a) { const x = hex(c); return 'rgba(' + x[0] + ',' + x[1] + ',' + x[2] + ',' + a + ')'; }
  function fromWE(s) { // "r g b" (0..1) -> #hex
    const p = String(s).trim().split(/\s+/).map(Number);
    if (p.length < 3 || p.some(isNaN)) return null;
    return '#' + p.slice(0, 3).map(v => Math.round(clamp(v, 0, 1) * 255).toString(16).padStart(2, '0')).join('');
  }
  function canvas(w, h) { const c = document.createElement('canvas'); c.width = Math.max(1, Math.ceil(w)); c.height = Math.max(1, Math.ceil(h)); return c; }
  function rrect(g, x, y, w, h, r) { g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r); g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath(); }
  const FONT = '"Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic", "Meiryo", "Avenir Next", "Segoe UI", sans-serif';
  const MONO = '"SF Mono", "Menlo", "Consolas", monospace';

  /* ================= Farbwelten ================= */
  const PALETTES = {
    neon:   { top: '#07031a', mid: '#1d0b3a', haze: '#5a1a5e', glow: '#ff4fa3', far: '#2a1146', near: '#0d0718', n: ['#ff2e88', '#00e5ff', '#ffc94d', '#b04dff'], win: ['#ffb35c', '#7fd8ff', '#ff7ab8'], wall: '#120c1c' },
    sunset: { top: '#120720', mid: '#3a1030', haze: '#8a3040', glow: '#ff8a3d', far: '#3a1532', near: '#140812', n: ['#ff6b35', '#b04dff', '#ffd23f', '#ff3d7f'], win: ['#ffbe6b', '#ff8f5a', '#e2a0ff'], wall: '#160c14' },
    toxic:  { top: '#020d0b', mid: '#06231e', haze: '#0f4a3c', glow: '#2bff9e', far: '#0b2a24', near: '#04100d', n: ['#39ff14', '#00ffd5', '#ff3df5', '#f6ff3d'], win: ['#b6ff8a', '#5affd9', '#ffd36b'], wall: '#0a1210' },
    ice:    { top: '#030817', mid: '#0b1a3a', haze: '#21406e', glow: '#7fb4ff', far: '#14254a', near: '#060c1c', n: ['#7df9ff', '#5e7cff', '#ff5ea0', '#e8f4ff'], win: ['#bfe6ff', '#ffd9a0', '#8fb0ff'], wall: '#0b0f1a' },
  };
  const CAT_COLORS = { black: '#17131c', ginger: '#b8642c', grey: '#62666f', white: '#cfcac2', calico: '#cfc4b4' };
  const SIGN_WORDS = ['RAMEN', 'ネオン', 'BAR', '茶', 'HOTEL', '夜', 'NOODLES', 'ARCADE', '喫茶', 'OPEN 24', '雨', 'KARAOKE', 'DINER', '猫', 'LO-FI', '電気'];

  /* ================= Einstellungen ================= */
  const cfg = {
    palette: 'neon', accent: null, rain: 0.6, glassdrops: true, fog: 0.35, lights: true, traffic: 14, searchlights: true,
    cat: true, catcolor: 'black', steam: true, lamp: 0.7, clock: 'radio', hour24: true, thunder: false,
    react: 0.6, parallax: 0.6, seed: 7, scale: 1, fpsCap: 0,
  };
  let P = PALETTES.neon;

  /* ================= Zustand ================= */
  const cv = document.getElementById('c');
  const ctx = cv.getContext('2d', { alpha: false });
  let W = 0, H = 0, S = 1, U = 1, M = 0;     // CSS-Pixel, Skalierung, Einheit, Rand für Parallaxe
  let L = {};                                  // Layout
  let sky, mid, intr, catC, dropSprite, glowW, glowR, staticDrops, fogMask, fogComp, blurC;
  let signs = [], cars = [], rainA = [], drops = [], trails = [], beams = [];
  let billboard = null, clockSign = null, clockText = '';
  const mouse = { x: 0.5, y: 0.5, sx: 0.5, sy: 0.5, px: -1, py: -1, inside: false };
  const audio = { bands: new Float32Array(128), bass: 0, mid: 0, high: 0, active: 0 };
  let flash = 0, nextThunder = 15, catWake = 0, catEar = 0, tailT = 0;
  let paused = false, last = 0, acc = 0, time = 0, refogT = 0;

  /* ================= Aufbau ================= */
  function resize() {
    const dpr = window.devicePixelRatio || 1;
    W = window.innerWidth; H = window.innerHeight;
    S = dpr * cfg.scale;
    U = Math.min(W, H) / 1000;
    M = Math.round(40 * U);
    cv.width = Math.round(W * S); cv.height = Math.round(H * S);
    layout();
    build();
  }

  function layout() {
    const x0 = W * 0.055, x1 = W * 0.945, y0 = H * 0.055, y1 = H * 0.72;
    L = {
      x0, x1, y0, y1, gw: x1 - x0, gh: y1 - y0,
      mullX: x0 + (x1 - x0) * 0.5, transY: y0 + (y1 - y0) * 0.3,
      sillTop: y1, sillFront: y1 + H * 0.075,
      frame: Math.max(8, 22 * U),
      horizon: y0 + (y1 - y0) * 0.78,
    };
    const base = L.y1 + H * 0.045;       // Standlinie der Dinge auf der Fensterbank
    L.base = base;
    L.lamp = { x: W * 0.16, y: base };
    L.mug = { x: W * 0.285, y: base };
    L.radio = { x: W * 0.6, y: base, w: 150 * U, h: 82 * U };
    L.cat = { x: W * 0.8, y: base, s: 1.15 * U };
  }

  function build() {
    const R = rng(cfg.seed * 7919 + 13);
    buildSky(R);
    buildMid(R);
    buildSprites();
    buildInterior();
    buildCat();
    buildRain();
    buildCars(R);
    buildDrops();
    buildFog();
    beams = [{ x: L.x0 + L.gw * 0.22, a: -1.2, s: 0.11 }, { x: L.x0 + L.gw * 0.71, a: -1.9, s: -0.08 }];
    clockText = '';
  }

  // ---------- Himmel und ferne Skyline ----------
  function buildSky(R) {
    const w = W + 2 * M, h = H + 2 * M;
    sky = canvas(w * S, h * S);
    const g = sky.getContext('2d');
    g.scale(S, S);
    g.translate(M, M);
    const gr = g.createLinearGradient(0, L.y0 - M, 0, L.horizon + 40 * U);
    gr.addColorStop(0, mix(P.top, '#000000', 0.3)); gr.addColorStop(0.5, P.top); gr.addColorStop(0.8, P.mid); gr.addColorStop(0.95, P.haze); gr.addColorStop(1, mix(P.haze, P.glow, 0.35));
    g.fillStyle = gr; g.fillRect(-M, -M, w, h);
    // Mond hinter Smog
    const mx = L.x0 + L.gw * (0.18 + R() * 0.6), my = L.y0 + L.gh * 0.17, mr = 34 * U;
    let rg = g.createRadialGradient(mx, my, mr * 0.6, mx, my, mr * 5);
    rg.addColorStop(0, rgba(mix('#ffffff', P.glow, 0.3), 0.22)); rg.addColorStop(1, rgba(P.glow, 0));
    g.fillStyle = rg; g.fillRect(mx - mr * 5, my - mr * 5, mr * 10, mr * 10);
    g.fillStyle = rgba(mix('#fff6e8', P.glow, 0.15), 0.85); g.beginPath(); g.arc(mx, my, mr, 0, TAU); g.fill();
    g.fillStyle = rgba(P.mid, 0.35); g.beginPath(); g.arc(mx + mr * 0.35, my - mr * 0.1, mr * 0.95, 0, TAU); g.fill();
    // Smogbänder
    for (let i = 0; i < 5; i++) {
      const y = L.y0 + L.gh * (0.1 + R() * 0.5), hh = 30 * U + R() * 60 * U;
      const sg = g.createLinearGradient(0, y - hh, 0, y + hh);
      sg.addColorStop(0, rgba(P.haze, 0)); sg.addColorStop(0.5, rgba(P.haze, 0.12 + R() * 0.12)); sg.addColorStop(1, rgba(P.haze, 0));
      g.fillStyle = sg; g.fillRect(-M, y - hh, w, hh * 2);
    }
    // drei Reihen ferner Häuser, je weiter desto dunstiger
    for (let band = 0; band < 3; band++) {
      const col = mix(P.far, P.haze, 0.55 - band * 0.2);
      const baseY = L.horizon + band * 22 * U;
      let x = -M;
      while (x < W + M) {
        const bw = (26 + R() * 70) * U * (1 + band * 0.25);
        const bh = (60 + R() * 220 + (R() < 0.12 ? 200 : 0)) * U * (1 - band * 0.12);
        const top = baseY - bh;
        g.fillStyle = col; g.fillRect(x, top, bw, H - top);
        if (R() < 0.3) { g.fillRect(x + bw * 0.45, top - 30 * U, 2 * U, 30 * U); } // Antenne
        // winzige Fenster
        const step = 7 * U;
        for (let yy = top + 6 * U; yy < baseY + 40 * U; yy += step) {
          for (let xx = x + 4 * U; xx < x + bw - 4 * U; xx += step * 0.9) {
            if (R() < 0.18 - band * 0.03) { g.fillStyle = rgba(P.win[(R() * 3) | 0], 0.25 + R() * 0.35 - band * 0.06); g.fillRect(xx, yy, 2.2 * U, 2.6 * U); }
          }
        }
        x += bw + R() * 6 * U;
      }
      // Dunst über jeder Reihe
      const hg = g.createLinearGradient(0, baseY - 260 * U, 0, baseY + 60 * U);
      hg.addColorStop(0, rgba(P.haze, 0)); hg.addColorStop(1, rgba(mix(P.haze, P.glow, 0.25), 0.35 - band * 0.08));
      g.fillStyle = hg; g.fillRect(-M, baseY - 260 * U, w, 320 * U);
    }
    // Glühen der Straßen von unten
    const sg = g.createLinearGradient(0, L.y1 - 120 * U, 0, L.y1 + 20 * U);
    sg.addColorStop(0, rgba(P.glow, 0)); sg.addColorStop(1, rgba(P.glow, 0.35));
    g.fillStyle = sg; g.fillRect(-M, L.y1 - 120 * U, w, 160 * U);
  }

  // ---------- nahe Häuser, Schilder, Werbetafel ----------
  function buildMid(R) {
    const w = W + 2 * M, h = H + 2 * M;
    mid = canvas(w * S, h * S);
    const g = mid.getContext('2d');
    g.scale(S, S); g.translate(M, M);
    signs = []; billboard = null; clockSign = null;
    const bld = [];
    let x = L.x0 - M - 20 * U;
    while (x < L.x1 + M) {
      const bw = (90 + R() * 160) * U;
      const top = L.y0 + L.gh * (0.28 + R() * 0.42);
      bld.push({ x, w: bw, top });
      x += bw + (10 + R() * 50) * U;
    }
    // Werbetafel-Fläche vorab reservieren (breitestes Haus in der Mitte)
    const taken = [], usedWords = new Set();
    const central0 = bld.filter(b => b.x + b.w > L.x0 + L.gw * 0.3 && b.x < L.x0 + L.gw * 0.7).sort((a, b) => b.w - a.w)[0];
    if (central0) { const bw = Math.min(central0.w * 0.85, 240 * U); taken.push({ x: central0.x + (central0.w - bw) / 2 - 8 * U, y: central0.top + 16 * U, w: bw + 16 * U, h: bw * 0.42 + 40 * U }); }
    bld.forEach((b, i) => {
      const shade = mix('#030208', P.near, 0.4 + R() * 0.6);
      const gr = g.createLinearGradient(b.x, 0, b.x + b.w, 0);
      gr.addColorStop(0, mix(shade, P.n[i % 2], 0.1)); gr.addColorStop(0.5, shade); gr.addColorStop(1, mix(shade, '#000000', 0.35));
      g.fillStyle = gr; g.fillRect(b.x, b.top, b.w, H - b.top + M);
      // Dachkante, Wassertank, Klimageräte
      g.fillStyle = mix(shade, '#000000', 0.4); g.fillRect(b.x - 3 * U, b.top - 4 * U, b.w + 6 * U, 5 * U);
      if (R() < 0.45) {
        const tx = b.x + b.w * (0.2 + R() * 0.5), tw = 24 * U, th = 26 * U;
        g.fillRect(tx, b.top - th - 10 * U, tw, th); g.fillRect(tx + 3 * U, b.top - 10 * U, 2 * U, 10 * U); g.fillRect(tx + tw - 5 * U, b.top - 10 * U, 2 * U, 10 * U);
      }
      // Fenster
      const cw = 9 * U, ch = 12 * U, gx = 7 * U, gy = 10 * U;
      for (let yy = b.top + 14 * U; yy < L.y1 + 20 * U; yy += ch + gy) {
        for (let xx = b.x + 8 * U; xx < b.x + b.w - cw - 6 * U; xx += cw + gx) {
          const r = R();
          if (r < 0.32) {
            const c = P.win[(R() * 3) | 0];
            g.fillStyle = rgba(c, 0.6 + R() * 0.4); g.fillRect(xx, yy, cw, ch);
            if (R() < 0.3) { g.fillStyle = rgba('#000000', 0.45); g.fillRect(xx, yy + ch * (0.3 + R() * 0.5), cw, ch); } // Jalousie
          } else {
            g.fillStyle = rgba('#000000', 0.25); g.fillRect(xx, yy, cw, ch);
          }
          if (R() < 0.03) { g.fillStyle = rgba('#000000', 0.5); g.fillRect(xx - 2 * U, yy + ch + 1 * U, cw + 4 * U, 5 * U); } // Klimagerät
        }
      }
      // Schilder an diesem Haus
      const nSign = R() < 0.85 ? 1 + ((R() * 2) | 0) : 0;
      for (let k = 0; k < nSign; k++) {
        let word = SIGN_WORDS[(R() * SIGN_WORDS.length) | 0];
        for (let t = 0; t < 6 && usedWords.has(word); t++) word = SIGN_WORDS[(R() * SIGN_WORDS.length) | 0];
        usedWords.add(word);
        const vertical = /[^\x00-\x7F]/.test(word) ? R() < 0.8 : R() < 0.15;
        const color = P.n[(R() * P.n.length) | 0];
        const size = (vertical ? 34 : 28 + R() * 16) * U;
        const sp = makeSign(word, color, vertical, size);
        // Platz suchen, der kein anderes Schild und nicht die Werbetafel überdeckt
        const sw = sp.c.width / S - 2 * sp.pad, sh = sp.c.height / S - 2 * sp.pad;
        let sx = 0, sy = 0, ok = false;
        for (let tries = 0; tries < 8 && !ok; tries++) {
          sx = b.x + R() * Math.max(4, b.w - sw * 0.7);
          sy = b.top + 30 * U + R() * Math.max(20 * U, (L.y1 - b.top) * 0.55);
          ok = !taken.some(t => sx < t.x + t.w + 12 * U && sx + sw + 12 * U > t.x && sy < t.y + t.h + 12 * U && sy + sh + 12 * U > t.y);
        }
        if (!ok) continue;
        taken.push({ x: sx, y: sy, w: sw, h: sh });
        signs.push({ c: sp.c, x: sx - sp.pad, y: sy - sp.pad, w: sp.c.width / S, h: sp.c.height / S, color, flick: R() * 0.6, off: 0, ph: R() * TAU, bass: R() < 0.5 });
      }
    });
    // Werbetafel auf dem breitesten Haus in der Mitte
    const central = bld.filter(b => b.x + b.w > L.x0 + L.gw * 0.3 && b.x < L.x0 + L.gw * 0.7).sort((a, b) => b.w - a.w)[0];
    if (central) {
      const bw = Math.min(central.w * 0.85, 240 * U), bh = bw * 0.42;
      const bx = central.x + (central.w - bw) / 2, by = central.top + 24 * U;
      g.fillStyle = '#05030a'; g.fillRect(bx - 4 * U, by - 4 * U, bw + 8 * U, bh + 8 * U);
      g.fillStyle = mix(P.near, '#000000', 0.5); g.fillRect(bx + bw * 0.2, by + bh + 4 * U, 3 * U, 20 * U); g.fillRect(bx + bw * 0.8, by + bh + 4 * U, 3 * U, 20 * U);
      billboard = { x: bx, y: by, w: bw, h: bh };
    }
    // Uhr-Schild auf dem Dach des höchsten Hauses
    const tallest = bld.filter(b => b.x > L.x0 && b.x + b.w < L.x1).sort((a, b) => a.top - b.top)[0];
    if (tallest) clockSign = { x: tallest.x + tallest.w / 2, y: tallest.top - 16 * U, color: P.n[1] };
  }

  function makeSign(text, color, vertical, size) {
    const pad = 40 * U;
    const g0 = canvas(10, 10).getContext('2d');
    g0.font = '700 ' + size + 'px ' + FONT;
    const chars = vertical ? Array.from(text) : [text];
    const tw = vertical ? size * 1.15 : g0.measureText(text).width + size * 0.9;
    const th = vertical ? chars.length * size * 1.12 + size * 0.5 : size * 1.6;
    const w = tw + pad * 2, h = th + pad * 2;
    const c = canvas(w * S, h * S);
    const g = c.getContext('2d');
    g.scale(S, S);
    // Lichthof
    g.shadowColor = color; g.shadowBlur = 34 * U; g.fillStyle = rgba(color, 0.22);
    g.fillRect(pad + 4 * U, pad + 4 * U, tw - 8 * U, th - 8 * U); g.shadowBlur = 0;
    // Rückplatte
    g.fillStyle = 'rgba(8,4,14,0.82)'; rrect(g, pad, pad, tw, th, 3 * U); g.fill();
    g.strokeStyle = rgba(color, 0.55); g.lineWidth = 1.4 * U; rrect(g, pad + 2 * U, pad + 2 * U, tw - 4 * U, th - 4 * U, 2 * U); g.stroke();
    g.font = '700 ' + size + 'px ' + FONT; g.textAlign = 'center'; g.textBaseline = 'middle';
    const draw = (style, blur) => {
      g.shadowColor = color; g.shadowBlur = blur; g.fillStyle = style;
      if (vertical) chars.forEach((ch, i) => g.fillText(ch, pad + tw / 2, pad + size * 0.8 + i * size * 1.12));
      else g.fillText(text, pad + tw / 2, pad + th / 2 + size * 0.04);
    };
    draw(color, 14 * U); draw(color, 6 * U); draw(mix(color, '#ffffff', 0.65), 2 * U);
    g.shadowBlur = 0;
    return { c, pad, w: w * S };
  }

  // ---------- Sprites ----------
  function buildSprites() {
    const s = 64;
    dropSprite = canvas(s, s);
    let g = dropSprite.getContext('2d');
    let rg = g.createRadialGradient(s * 0.5, s * 0.55, s * 0.05, s * 0.5, s * 0.5, s * 0.5);
    rg.addColorStop(0, 'rgba(255,255,255,0.10)'); rg.addColorStop(0.65, 'rgba(10,5,25,0.10)'); rg.addColorStop(0.92, 'rgba(0,0,0,0.42)'); rg.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = rg; g.beginPath(); g.arc(s / 2, s / 2, s / 2, 0, TAU); g.fill();
    g.fillStyle = rgba(mix('#ffffff', P.n[1], 0.3), 0.35); g.beginPath(); g.ellipse(s * 0.5, s * 0.74, s * 0.26, s * 0.12, 0, 0, TAU); g.fill();
    g.fillStyle = 'rgba(255,255,255,0.75)'; g.beginPath(); g.ellipse(s * 0.36, s * 0.32, s * 0.09, s * 0.06, -0.6, 0, TAU); g.fill();
    const glow = (c) => { const k = canvas(s, s), q = k.getContext('2d'); const r2 = q.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2); r2.addColorStop(0, rgba(c, 1)); r2.addColorStop(0.25, rgba(c, 0.45)); r2.addColorStop(1, rgba(c, 0)); q.fillStyle = r2; q.fillRect(0, 0, s, s); return k; };
    glowW = glow('#fff4dc'); glowR = glow('#ff2a3a');
  }

  // ---------- Zimmer ----------
  function buildInterior() {
    const w = W + 2 * M, h = H + 2 * M;
    intr = canvas(w * S, h * S);
    const g = intr.getContext('2d');
    g.scale(S, S); g.translate(M, M);
    const wall = P.wall, f = L.frame;
    // Wand
    g.fillStyle = wall; g.fillRect(-M, -M, w, h);
    const wg = g.createRadialGradient(W / 2, L.y0 + L.gh / 2, L.gw * 0.3, W / 2, L.y0 + L.gh / 2, L.gw * 0.75);
    wg.addColorStop(0, rgba(P.n[0], 0.16)); wg.addColorStop(1, rgba(P.n[0], 0));
    g.fillStyle = wg; g.fillRect(-M, -M, w, h);
    // Fensterausschnitt
    g.save(); g.globalCompositeOperation = 'destination-out'; g.fillStyle = '#000'; g.fillRect(L.x0, L.y0, L.gw, L.gh); g.restore();
    // Laibung (Tiefe des Fensters)
    const d = 14 * U;
    g.fillStyle = mix(wall, '#000000', 0.35);
    g.beginPath(); g.moveTo(L.x0 - d, L.y0 - d); g.lineTo(L.x1 + d, L.y0 - d); g.lineTo(L.x1, L.y0); g.lineTo(L.x0, L.y0); g.closePath(); g.fill();
    g.fillStyle = mix(wall, P.n[0], 0.18);
    g.beginPath(); g.moveTo(L.x0 - d, L.y0 - d); g.lineTo(L.x0, L.y0); g.lineTo(L.x0, L.y1); g.lineTo(L.x0 - d, L.y1); g.closePath(); g.fill();
    g.fillStyle = mix(wall, P.n[1], 0.16);
    g.beginPath(); g.moveTo(L.x1 + d, L.y0 - d); g.lineTo(L.x1, L.y0); g.lineTo(L.x1, L.y1); g.lineTo(L.x1 + d, L.y1); g.closePath(); g.fill();
    // Rahmen und Sprossen
    const fc = mix(wall, '#000000', 0.55);
    g.fillStyle = fc;
    g.fillRect(L.x0, L.y0, L.gw, f * 0.7); g.fillRect(L.x0, L.y0, f * 0.7, L.gh); g.fillRect(L.x1 - f * 0.7, L.y0, f * 0.7, L.gh);
    g.fillRect(L.mullX - f * 0.5, L.y0, f, L.gh);
    g.fillRect(L.x0, L.transY - f * 0.35, L.gw, f * 0.7);
    g.fillStyle = rgba(P.n[1], 0.35); g.fillRect(L.mullX + f * 0.5 - 1.2 * U, L.y0, 1.2 * U, L.gh);
    g.fillStyle = rgba(P.n[0], 0.3); g.fillRect(L.mullX - f * 0.5, L.y0, 1.2 * U, L.gh); g.fillRect(L.x0, L.transY + f * 0.35 - 1.2 * U, L.gw, 1.2 * U);
    // Fensterbank: Oberseite (perspektivisch) und Vorderkante
    const ext = 60 * U;
    const top = g.createLinearGradient(0, L.sillTop, 0, L.sillFront);
    top.addColorStop(0, mix('#3a2a2a', P.n[0], 0.25)); top.addColorStop(1, mix('#22161a', P.n[0], 0.1));
    g.fillStyle = top;
    g.beginPath(); g.moveTo(L.x0 - d, L.sillTop); g.lineTo(L.x1 + d, L.sillTop); g.lineTo(L.x1 + d + ext, L.sillFront); g.lineTo(L.x0 - d - ext, L.sillFront); g.closePath(); g.fill();
    g.fillStyle = rgba(P.n[1], 0.35); g.fillRect(L.x0 - d, L.sillTop, L.gw + 2 * d, 1.5 * U);
    const front = g.createLinearGradient(0, L.sillFront, 0, H + M);
    front.addColorStop(0, '#1a1013'); front.addColorStop(0.15, '#0e090c'); front.addColorStop(1, '#060406');
    g.fillStyle = front; g.fillRect(L.x0 - d - ext, L.sillFront, L.gw + 2 * (d + ext), H + M - L.sillFront);
    g.fillStyle = rgba(mix('#ffffff', P.n[0], 0.5), 0.12); g.fillRect(L.x0 - d - ext, L.sillFront, L.gw + 2 * (d + ext), 1.5 * U);
    // Lampenlicht auf der Fensterbank (warm)
    const lx = L.lamp.x + 40 * U, ly = L.base;
    const lg = g.createRadialGradient(lx, ly, 0, lx, ly, 330 * U);
    lg.addColorStop(0, rgba('#ffb46b', 0.42 * cfg.lamp)); lg.addColorStop(0.5, rgba('#ff9a50', 0.14 * cfg.lamp)); lg.addColorStop(1, 'rgba(255,150,80,0)');
    // Licht nicht ins Fenster (Glas bleibt frei, Rahmen bekommt es mit)
    g.save(); g.beginPath(); g.rect(-M, -M, w, h); g.rect(L.x0 + L.frame * 0.7, L.y0, L.gw - L.frame * 1.4, L.gh); g.clip('evenodd');
    g.globalCompositeOperation = 'lighter'; g.fillStyle = lg; g.fillRect(lx - 340 * U, ly - 340 * U, 680 * U, 680 * U); g.restore();

    drawPlant(g, W * 0.045, L.base + 4 * U, U);
    drawBooks(g, L.lamp.x - 30 * U, L.base, U);
    drawLamp(g, L.lamp.x, L.base - 26 * U, U);
    drawMug(g, L.mug.x, L.base, U);
    drawRadio(g, L.radio, U);
    // Abdunkeln der Ränder
    const vg = g.createRadialGradient(W / 2, H * 0.45, Math.min(W, H) * 0.45, W / 2, H * 0.5, Math.max(W, H) * 0.8);
    vg.addColorStop(0, 'rgba(0,0,0,0)'); vg.addColorStop(1, 'rgba(0,0,0,0.55)');
    g.save(); g.globalCompositeOperation = 'source-atop'; g.fillStyle = vg; g.fillRect(-M, -M, w, h); g.restore();
  }

  function rim(g, color, a) { g.save(); g.globalCompositeOperation = 'source-atop'; g.fillStyle = rgba(color, a); return g; }

  function drawPlant(g, x, y, u) {
    // Topf
    g.fillStyle = '#2a1a1e';
    g.beginPath(); g.moveTo(x - 46 * u, y - 70 * u); g.lineTo(x + 46 * u, y - 70 * u); g.lineTo(x + 36 * u, y); g.lineTo(x - 36 * u, y); g.closePath(); g.fill();
    g.fillStyle = rgba(P.n[1], 0.25); g.fillRect(x + 30 * u, y - 70 * u, 6 * u, 70 * u);
    g.fillStyle = '#1d1215'; g.fillRect(x - 50 * u, y - 78 * u, 100 * u, 10 * u);
    // Blätter (Monstera-artig)
    const R = rng(cfg.seed + 99);
    for (let i = 0; i < 9; i++) {
      const a = -Math.PI / 2 + (R() - 0.5) * 2.2, len = (90 + R() * 120) * u;
      const ex = x + Math.cos(a) * len, ey = y - 78 * u + Math.sin(a) * len;
      g.strokeStyle = '#0f1a12'; g.lineWidth = 3 * u; g.beginPath(); g.moveTo(x, y - 78 * u); g.quadraticCurveTo(x + Math.cos(a) * len * 0.3, ey + 30 * u, ex, ey); g.stroke();
      g.save(); g.translate(ex, ey); g.rotate(a + Math.PI / 2 + (R() - 0.5) * 0.6);
      const lw = (34 + R() * 26) * u, lh = (46 + R() * 30) * u;
      const lg = g.createLinearGradient(-lw, 0, lw, 0);
      lg.addColorStop(0, mix('#14301c', P.n[0], 0.25)); lg.addColorStop(0.6, '#10261a'); lg.addColorStop(1, mix('#0c1c12', P.n[1], 0.3));
      g.fillStyle = lg;
      g.beginPath(); g.ellipse(0, -lh * 0.5, lw, lh * 0.6, 0, 0, TAU); g.fill();
      g.strokeStyle = rgba('#000000', 0.35); g.lineWidth = 1.5 * u; g.beginPath(); g.moveTo(0, 0); g.lineTo(0, -lh); g.stroke();
      g.restore();
    }
  }

  function drawBooks(g, x, y, u) {
    const cols = ['#3b2140', '#1f3346', '#4a2a24'];
    let yy = y;
    for (let i = 0; i < 3; i++) {
      const bw = (120 - i * 12) * u, bh = 9 * u;
      g.fillStyle = cols[i]; g.fillRect(x - bw / 2 + i * 4 * u, yy - bh, bw, bh);
      g.fillStyle = 'rgba(255,220,180,0.18)'; g.fillRect(x - bw / 2 + i * 4 * u, yy - bh, bw, 1.4 * u);
      yy -= bh;
    }
  }

  function drawLamp(g, x, y, u) {
    g.fillStyle = '#1b1418';
    g.beginPath(); g.ellipse(x, y, 30 * u, 7 * u, 0, 0, TAU); g.fill();
    g.strokeStyle = '#231a1f'; g.lineWidth = 5 * u; g.lineCap = 'round';
    g.beginPath(); g.moveTo(x, y - 2 * u); g.lineTo(x - 18 * u, y - 70 * u); g.lineTo(x + 26 * u, y - 112 * u); g.stroke();
    // Schirm
    g.save(); g.translate(x + 26 * u, y - 112 * u); g.rotate(0.55);
    g.fillStyle = '#2a1e22';
    g.beginPath(); g.moveTo(-14 * u, -6 * u); g.lineTo(14 * u, -6 * u); g.lineTo(34 * u, 30 * u); g.lineTo(-34 * u, 30 * u); g.closePath(); g.fill();
    g.fillStyle = rgba('#ffcf8a', 0.95); g.beginPath(); g.ellipse(0, 30 * u, 34 * u, 6 * u, 0, 0, TAU); g.fill();
    g.restore();
    L.bulb = { x: x + 26 * u + Math.sin(0.55) * -30 * u, y: y - 112 * u + Math.cos(0.55) * 30 * u };
  }

  function drawMug(g, x, y, u) {
    const mw = 40 * u, mh = 48 * u;
    g.fillStyle = '#d9cfc4';
    rrect(g, x - mw / 2, y - mh, mw, mh, 6 * u); g.fill();
    g.strokeStyle = '#d9cfc4'; g.lineWidth = 7 * u; g.beginPath(); g.arc(x + mw / 2, y - mh * 0.52, 12 * u, -1.2, 1.2); g.stroke();
    // Schatten und Neonkante
    const sg = g.createLinearGradient(x - mw / 2, 0, x + mw / 2, 0);
    sg.addColorStop(0, rgba(P.n[0], 0.35)); sg.addColorStop(0.4, 'rgba(0,0,0,0.05)'); sg.addColorStop(1, 'rgba(0,0,0,0.5)');
    g.fillStyle = sg; rrect(g, x - mw / 2, y - mh, mw, mh, 6 * u); g.fill();
    g.fillStyle = '#2a160c'; g.beginPath(); g.ellipse(x, y - mh + 3 * u, mw / 2 - 3 * u, 4 * u, 0, 0, TAU); g.fill();
    // kleines Herz
    g.fillStyle = rgba(P.n[0], 0.85); g.font = '700 ' + 16 * u + 'px ' + FONT; g.textAlign = 'center'; g.fillText('♥', x - 3 * u, y - mh * 0.38);
    L.mugTop = { x, y: y - mh };
  }

  function drawRadio(g, r, u) {
    const x = r.x - r.w / 2, y = r.y - r.h;
    g.fillStyle = '#2b2026'; rrect(g, x, y, r.w, r.h, 8 * u); g.fill();
    g.fillStyle = rgba(P.n[1], 0.18); g.fillRect(x + r.w - 5 * u, y + 6 * u, 3 * u, r.h - 12 * u);
    // Lautsprecher
    g.fillStyle = '#18111a'; g.beginPath(); g.arc(x + r.w * 0.24, y + r.h * 0.55, r.h * 0.3, 0, TAU); g.fill();
    g.fillStyle = 'rgba(255,255,255,0.05)';
    for (let i = -3; i <= 3; i++) for (let j = -3; j <= 3; j++) if (i * i + j * j < 10) { g.beginPath(); g.arc(x + r.w * 0.24 + i * 5 * u, y + r.h * 0.55 + j * 5 * u, 1.2 * u, 0, TAU); g.fill(); }
    // Display
    r.lcd = { x: x + r.w * 0.47, y: y + r.h * 0.2, w: r.w * 0.44, h: r.h * 0.34 };
    g.fillStyle = '#05080a'; g.fillRect(r.lcd.x, r.lcd.y, r.lcd.w, r.lcd.h);
    r.leds = { x: r.lcd.x, y: y + r.h * 0.66, w: r.lcd.w, h: r.h * 0.16 };
    // Knöpfe und Antenne
    g.fillStyle = '#120c10'; g.beginPath(); g.arc(x + r.w * 0.85, y - 2 * u, 4 * u, 0, TAU); g.fill();
    g.strokeStyle = '#3a2f36'; g.lineWidth = 2 * u; g.beginPath(); g.moveTo(x + r.w * 0.85, y); g.lineTo(x + r.w * 1.05, y - r.h * 0.95); g.stroke();
  }

  // ---------- Katze ----------
  function buildCat() {
    const s = L.cat.s, w = 260 * s, h = 150 * s;
    catC = canvas(w * S, h * S);
    const g = catC.getContext('2d');
    g.scale(S, S);
    const col = CAT_COLORS[cfg.catcolor] || CAT_COLORS.black;
    const dark = mix(col, '#000000', 0.55);
    const cx = w * 0.5, by = h - 4 * s;
    // Körper (zusammengerollt)
    const bg = g.createLinearGradient(0, by - 90 * s, 0, by);
    bg.addColorStop(0, col); bg.addColorStop(1, dark);
    g.fillStyle = bg;
    g.beginPath(); g.ellipse(cx, by - 38 * s, 95 * s, 40 * s, 0, 0, TAU); g.fill();
    // Kopf links, auf den Pfoten
    g.beginPath(); g.ellipse(cx - 80 * s, by - 30 * s, 36 * s, 30 * s, -0.15, 0, TAU); g.fill();
    // Ohren
    const ear = (ex, ey, a) => { g.save(); g.translate(ex, ey); g.rotate(a); g.beginPath(); g.moveTo(-12 * s, 0); g.lineTo(0, -26 * s); g.lineTo(13 * s, 0); g.closePath(); g.fill(); g.restore(); };
    ear(cx - 100 * s, by - 52 * s, -0.5); ear(cx - 70 * s, by - 56 * s, 0.15);
    if (cfg.catcolor === 'calico') {
      g.save(); g.globalCompositeOperation = 'source-atop';
      g.fillStyle = '#b8642c'; g.beginPath(); g.ellipse(cx + 30 * s, by - 55 * s, 40 * s, 22 * s, 0.3, 0, TAU); g.fill();
      g.fillStyle = '#2a2224'; g.beginPath(); g.ellipse(cx - 20 * s, by - 60 * s, 26 * s, 16 * s, -0.2, 0, TAU); g.fill();
      g.fillStyle = '#2a2224'; g.beginPath(); g.ellipse(cx - 92 * s, by - 44 * s, 14 * s, 12 * s, 0, 0, TAU); g.fill();
      g.restore();
    }
    // Neonlicht von hinten (Fenster) als Kante oben
    g.save(); g.globalCompositeOperation = 'source-atop';
    const rg = g.createLinearGradient(0, by - 100 * s, 0, by - 50 * s);
    rg.addColorStop(0, rgba(P.n[0], 0.75)); rg.addColorStop(0.35, rgba(P.n[0], 0.15)); rg.addColorStop(1, rgba(P.n[0], 0));
    g.fillStyle = rg; g.fillRect(0, 0, w, h);
    const lg = g.createLinearGradient(0, 0, w, 0);
    lg.addColorStop(0, rgba('#ffb46b', 0.18 * cfg.lamp)); lg.addColorStop(0.5, 'rgba(0,0,0,0)');
    g.fillStyle = lg; g.fillRect(0, 0, w, h);
    g.restore();
    // Pfote vorne
    g.fillStyle = mix(col, '#ffffff', 0.08); g.beginPath(); g.ellipse(cx - 55 * s, by - 6 * s, 22 * s, 8 * s, 0, 0, TAU); g.fill();
    L.catBox = { w, h, headX: cx - 80 * s, headY: by - 30 * s, tailX: cx + 85 * s, tailY: by - 12 * s, col, dark };
  }

  function drawCat(t) {
    if (!cfg.cat) return;
    const s = L.cat.s, B = L.catBox;
    const x = L.cat.x - B.w / 2, y = L.cat.y - B.h + 6 * s;
    const breath = 1 + Math.sin(t * 1.3) * 0.018;
    ctx.save();
    ctx.translate(x, y + B.h); ctx.scale(1, breath); ctx.translate(0, -B.h);
    // Schwanz (wedelt ab und zu um den Körper)
    const wag = Math.sin(tailT) * 0.25;
    ctx.strokeStyle = B.col; ctx.lineWidth = 15 * s; ctx.lineCap = 'round';
    ctx.beginPath(); ctx.moveTo(B.tailX, B.tailY);
    ctx.bezierCurveTo(B.tailX + 40 * s, B.tailY + 5 * s, B.tailX + 30 * s, B.tailY + 22 * s * (1 + wag), B.tailX - 40 * s, B.tailY + 14 * s + wag * 20 * s);
    ctx.stroke();
    ctx.drawImage(catC, 0, 0, B.w, B.h);
    // Ohrzucken
    if (catEar > 0) {
      ctx.fillStyle = B.col;
      ctx.save(); ctx.translate(B.headX + 10 * s, B.headY - 26 * s); ctx.rotate(0.15 + Math.sin(catEar * 40) * 0.25);
      ctx.beginPath(); ctx.moveTo(-12 * s, 0); ctx.lineTo(0, -26 * s); ctx.lineTo(13 * s, 0); ctx.closePath(); ctx.fill(); ctx.restore();
    }
    // Augen: zu (Striche) oder wach (leuchtende Schlitze)
    const ex1 = B.headX - 14 * s, ex2 = B.headX + 12 * s, ey = B.headY - 4 * s;
    if (catWake > 0) {
      const open = clamp(Math.min(catWake, 3.2 - catWake) * 3, 0, 1);
      ctx.fillStyle = rgba(mix('#d8ff6a', P.n[1], 0.3), 0.95);
      for (const ex of [ex1, ex2]) { ctx.beginPath(); ctx.ellipse(ex, ey, 6 * s, 4.5 * s * open + 0.5 * s, 0, 0, TAU); ctx.fill(); }
      ctx.fillStyle = '#050305';
      for (const ex of [ex1, ex2]) { ctx.beginPath(); ctx.ellipse(ex + (mouse.sx - 0.5) * 4 * s, ey, 1.6 * s, 4 * s * open + 0.3 * s, 0, 0, TAU); ctx.fill(); }
    } else {
      ctx.strokeStyle = 'rgba(0,0,0,0.6)'; ctx.lineWidth = 1.8 * s;
      for (const ex of [ex1, ex2]) { ctx.beginPath(); ctx.arc(ex, ey - 2 * s, 5 * s, 0.3, Math.PI - 0.3); ctx.stroke(); }
    }
    ctx.restore();
    // Zzz, wenn er schläft
    if (catWake <= 0) {
      const ph = (t * 0.35) % 1;
      ctx.fillStyle = rgba(mix('#ffffff', P.n[3] || P.n[0], 0.4), 0.5 * Math.sin(ph * Math.PI));
      ctx.font = '600 ' + (12 + ph * 8) * U + 'px ' + FONT; ctx.textAlign = 'left';
      ctx.fillText('z', x + B.headX - 20 * s + ph * 22 * U, y + B.headY - 50 * s - ph * 40 * U);
    }
  }

  // ---------- Regen, Gleiter, Tropfen, Beschlag ----------
  function buildRain() {
    rainA = [];
    const n = Math.round(420 * cfg.rain * (W * H) / (1920 * 1080));
    for (let i = 0; i < n; i++) rainA.push({ x: Math.random() * (W + 200) - 100, y: Math.random() * H, l: (10 + Math.random() * 22) * U, v: (900 + Math.random() * 700) * U, near: Math.random() < 0.35 });
  }

  function buildCars(R) {
    cars = [];
    for (let i = 0; i < cfg.traffic; i++) cars.push(newCar(true));
  }
  function newCar(anywhere) {
    const depth = Math.random();
    const dir = Math.random() < 0.5 ? 1 : -1;
    const lane = L.y0 + L.gh * (0.15 + depth * 0.45 + Math.random() * 0.08);
    const sc = (0.7 + depth * 1.5) * U;
    return { x: anywhere ? L.x0 + Math.random() * L.gw : (dir > 0 ? L.x0 - 80 * U : L.x1 + 80 * U), y: lane, dir, v: (40 + depth * 120 + Math.random() * 60) * U, sc, depth, bob: Math.random() * TAU, col: P.n[(Math.random() * P.n.length) | 0] };
  }

  function buildDrops() {
    drops = []; trails = [];
    const area = L.gw * L.gh;
    staticDrops = canvas(L.gw * S, L.gh * S);
    if (!cfg.glassdrops) return;
    const g = staticDrops.getContext('2d');
    g.scale(S, S);
    const n = Math.round(area / 2600 * (0.35 + cfg.rain));
    for (let i = 0; i < n; i++) {
      const r = (0.6 + Math.pow(Math.random(), 3) * 3.4) * U * 1.4;
      g.globalAlpha = 0.5 + Math.random() * 0.5;
      g.drawImage(dropSprite, Math.random() * L.gw - r, Math.random() * L.gh - r, r * 2, r * 2 * (1 + Math.random() * 0.2));
    }
    g.globalAlpha = 1;
    const m = Math.round(8 + 26 * cfg.rain);
    for (let i = 0; i < m; i++) drops.push(newDrop(true));
  }
  function newDrop(anywhere) {
    return { x: L.x0 + Math.random() * L.gw, y: anywhere ? L.y0 + Math.random() * L.gh : L.y0 - 10 * U, r: (2.5 + Math.random() * 4) * U * 1.3, v: 0, stick: Math.random() * 3, wob: Math.random() * TAU };
  }

  function buildFog() {
    const k = 6;
    fogMask = canvas(Math.ceil(L.gw / k), Math.ceil(L.gh / k));
    fogComp = canvas(fogMask.width, fogMask.height);
    blurC = canvas(fogMask.width, fogMask.height);
    const g = fogMask.getContext('2d');
    g.fillStyle = '#000'; g.fillRect(0, 0, fogMask.width, fogMask.height);
  }
  function wipe(x, y, r, a) {
    if (!fogMask) return;
    const k = fogMask.width / L.gw;
    const g = fogMask.getContext('2d');
    const fx = (x - L.x0) * k, fy = (y - L.y0) * k, fr = r * k;
    const rg = g.createRadialGradient(fx, fy, 0, fx, fy, fr);
    rg.addColorStop(0, 'rgba(0,0,0,' + a + ')'); rg.addColorStop(0.6, 'rgba(0,0,0,' + a * 0.6 + ')'); rg.addColorStop(1, 'rgba(0,0,0,0)');
    g.globalCompositeOperation = 'destination-out'; g.fillStyle = rg; g.fillRect(fx - fr, fy - fr, fr * 2, fr * 2);
    g.globalCompositeOperation = 'source-over';
  }

  /* ================= Musik ================= */
  if (typeof window.wallpaperRegisterAudioListener === 'function') {
    window.wallpaperRegisterAudioListener(function (a) {
      if (!a || a.length < 128) return;
      for (let i = 0; i < 128; i++) audio.bands[i] = lerp(audio.bands[i], Math.min(1.2, a[i]), 0.5);
      let b = 0, m = 0, h = 0;
      for (let i = 0; i < 6; i++) b += a[i] + a[64 + i];
      for (let i = 10; i < 30; i++) m += a[i] + a[64 + i];
      for (let i = 34; i < 60; i++) h += a[i] + a[64 + i];
      audio.bass = lerp(audio.bass, b / 12, 0.4); audio.mid = lerp(audio.mid, m / 40, 0.3); audio.high = lerp(audio.high, h / 52, 0.3);
      audio.active = 3;
    });
  }

  /* ================= Bild zeichnen ================= */
  function frame(now) {
    if (paused) return;
    requestAnimationFrame(frame);
    let dt = Math.min(0.1, (now - last) / 1000 || 0);
    if (cfg.fpsCap > 0) { acc += dt; if (acc < 1 / cfg.fpsCap - 0.002) return; dt = acc; acc = 0; }
    last = now;
    step(dt);
    render();
  }

  function step(dt) {
    time += dt;
    mouse.sx = lerp(mouse.sx, mouse.x, Math.min(1, dt * 3));
    mouse.sy = lerp(mouse.sy, mouse.y, Math.min(1, dt * 3));
    audio.active = Math.max(0, audio.active - dt);
    if (audio.active <= 0) { audio.bass *= 0.9; audio.mid *= 0.9; audio.high *= 0.9; }
    // Gewitter
    if (cfg.thunder) { nextThunder -= dt; if (nextThunder <= 0) { flash = 1; nextThunder = 18 + Math.random() * 40; } }
    flash = Math.max(0, flash - dt * (flash > 0.6 ? 2.5 : 1.2));
    if (flash > 0.5 && flash < 0.55 && Math.random() < 0.5) flash = 0.9;
    // Katze
    catWake = Math.max(0, catWake - dt); catEar = Math.max(0, catEar - dt);
    if (Math.random() < dt * 0.05) catEar = 0.4;
    tailT += dt * (catWake > 0 ? 3 : 0.6);
    // Schilder flackern
    for (const s of signs) {
      if (s.off > 0) s.off -= dt;
      else if (Math.random() < dt * s.flick * 0.15) s.off = 0.05 + Math.random() * 0.4;
    }
    // Gleiter
    for (let i = 0; i < cars.length; i++) {
      const c = cars[i];
      c.x += c.dir * c.v * dt; c.bob += dt;
      if ((c.dir > 0 && c.x > L.x1 + 100 * U) || (c.dir < 0 && c.x < L.x0 - 100 * U)) cars[i] = newCar(false);
    }
    while (cars.length < cfg.traffic) cars.push(newCar(false));
    if (cars.length > cfg.traffic) cars.length = cfg.traffic;
    // Regen draußen
    const wind = 0.18;
    for (const r of rainA) {
      r.y += r.v * dt * (r.near ? 1.25 : 1); r.x += r.v * dt * wind;
      if (r.y > L.y1) { r.y = L.y0 - Math.random() * 60 * U; r.x = L.x0 - 100 + Math.random() * (L.gw + 200); }
    }
    // Tropfen auf dem Glas: kleben, rutschen ruckartig, hinterlassen eine freie Spur
    if (cfg.glassdrops) {
      for (let i = 0; i < drops.length; i++) {
        const d = drops[i];
        if (d.stick > 0) { d.stick -= dt; continue; }
        d.v = Math.min(d.v + 260 * U * dt * (d.r / (5 * U)), 240 * U);
        d.y += d.v * dt; d.wob += dt * 3; d.x += Math.sin(d.wob) * 6 * U * dt;
        wipe(d.x, d.y, d.r * 1.6, 0.5);
        if (Math.random() < dt * 4) { trails.push({ x: d.x + (Math.random() - 0.5) * 2 * U, y: d.y - d.r, r: d.r * (0.25 + Math.random() * 0.25), life: 6 + Math.random() * 8 }); d.r *= 0.985; }
        if (Math.random() < dt * 0.6) { d.stick = Math.random() * 1.5; d.v = 0; }
        if (d.y > L.y1 + 10 * U || d.r < 1.2 * U) drops[i] = newDrop(false);
      }
      for (let i = trails.length - 1; i >= 0; i--) { trails[i].life -= dt; if (trails[i].life <= 0) trails.splice(i, 1); }
      if (trails.length > 400) trails.splice(0, trails.length - 400);
    }
    // Scheibe beschlägt langsam wieder
    refogT += dt;
    if (refogT > 0.25 && fogMask) {
      const g = fogMask.getContext('2d');
      g.fillStyle = 'rgba(0,0,0,' + (0.012 * refogT * 4) + ')'; g.fillRect(0, 0, fogMask.width, fogMask.height);
      refogT = 0;
    }
    // Maus wischt
    if (mouse.inside && mouse.px >= 0) {
      const mx = mouse.x * W, my = mouse.y * H, ox = mouse.px * W, oy = mouse.py * H;
      const dist = Math.hypot(mx - ox, my - oy);
      if (dist > 0.5 && mx > L.x0 && mx < L.x1 && my > L.y0 && my < L.y1) {
        const n = Math.min(12, Math.ceil(dist / (14 * U)));
        for (let i = 1; i <= n; i++) wipe(lerp(ox, mx, i / n), lerp(oy, my, i / n), 46 * U, 0.35);
      }
    }
    mouse.px = mouse.x; mouse.py = mouse.y;
  }

  function render() {
    const g = ctx;
    g.setTransform(S, 0, 0, S, 0, 0);
    const px = (mouse.sx - 0.5) * cfg.parallax, py = (mouse.sy - 0.5) * cfg.parallax;
    const ox1 = -px * 6 * U, oy1 = -py * 4 * U, ox2 = -px * 16 * U, oy2 = -py * 8 * U, ox3 = px * 14 * U, oy3 = py * 6 * U;
    const beat = audio.bass * cfg.react;

    // ---- draußen (auf das Fenster beschnitten) ----
    g.save();
    g.beginPath(); g.rect(L.x0, L.y0, L.gw, L.gh); g.clip();
    g.drawImage(sky, -M + ox1, -M + oy1, W + 2 * M, H + 2 * M);
    if (flash > 0) { g.fillStyle = rgba(mix('#ffffff', P.glow, 0.3), flash * 0.45); g.fillRect(L.x0, L.y0, L.gw, L.gh); }
    // Suchscheinwerfer
    if (cfg.searchlights) {
      g.save(); g.globalCompositeOperation = 'lighter';
      for (const b of beams) {
        const a = b.a + Math.sin(time * b.s) * 0.5, len = L.gh * 1.3, bx = b.x + ox1, by = L.y1;
        const tx = bx + Math.cos(a) * len, ty = by + Math.sin(a) * len, wdt = 0.06;
        const lg = g.createLinearGradient(bx, by, tx, ty);
        lg.addColorStop(0, rgba(mix('#ffffff', P.glow, 0.4), 0.16)); lg.addColorStop(1, rgba(P.glow, 0));
        g.fillStyle = lg; g.beginPath(); g.moveTo(bx, by);
        g.lineTo(bx + Math.cos(a - wdt) * len, by + Math.sin(a - wdt) * len); g.lineTo(bx + Math.cos(a + wdt) * len, by + Math.sin(a + wdt) * len); g.closePath(); g.fill();
      }
      g.restore();
    }
    drawCars(g, false, ox1, oy1);
    g.drawImage(mid, -M + ox2, -M + oy2, W + 2 * M, H + 2 * M);
    // Neonschilder (additiv: leuchten wirklich)
    g.globalCompositeOperation = 'lighter';
    for (const s of signs) {
      let a = s.off > 0 ? 0.18 : 0.88 + Math.sin(time * 2 + s.ph) * 0.05;
      if (s.bass && s.off <= 0) a = Math.min(1, a + beat * 0.35);
      g.globalAlpha = a; g.drawImage(s.c, s.x + ox2, s.y + oy2, s.w, s.h);
    }
    g.globalAlpha = 1; g.globalCompositeOperation = 'source-over';
    drawBillboard(g, ox2, oy2);
    drawClockSign(g, ox2, oy2);
    drawCars(g, true, ox2, oy2);
    // Regen
    if (rainA.length) {
      g.lineCap = 'round';
      for (const near of [false, true]) {
        g.strokeStyle = near ? rgba(mix('#ffffff', P.n[1], 0.25), 0.5) : rgba(mix('#ffffff', P.glow, 0.3), 0.26);
        g.lineWidth = (near ? 1.8 : 1.0) * U;
        g.beginPath();
        for (const r of rainA) if (r.near === near) { const x = r.x + (near ? ox2 : ox1); g.moveTo(x, r.y); g.lineTo(x - r.l * 0.18, r.y - r.l); }
        g.stroke();
      }
    }
    // beschlagene Scheibe: unscharfe, aufgehellte Kopie der Stadt, nur wo noch Beschlag ist
    if (cfg.fog > 0.01 && fogMask) {
      const fw = fogMask.width, fh = fogMask.height, k = fw / L.gw;
      const bg = blurC.getContext('2d');
      bg.setTransform(1, 0, 0, 1, 0, 0);
      bg.drawImage(cv, L.x0 * S, L.y0 * S, L.gw * S, L.gh * S, 0, 0, fw, fh);
      const fc = fogComp.getContext('2d');
      fc.globalCompositeOperation = 'source-over'; fc.clearRect(0, 0, fw, fh);
      fc.filter = 'blur(2px)'; fc.drawImage(blurC, 0, 0); fc.filter = 'none';
      fc.fillStyle = rgba(mix('#c8cde0', P.glow, 0.15), 0.16); fc.fillRect(0, 0, fw, fh);
      fc.globalCompositeOperation = 'destination-in'; fc.drawImage(fogMask, 0, 0);
      const vg = fc.createLinearGradient(0, 0, 0, fh);
      vg.addColorStop(0, 'rgba(0,0,0,0.12)'); vg.addColorStop(0.55, 'rgba(0,0,0,0.45)'); vg.addColorStop(1, 'rgba(0,0,0,1)');
      fc.fillStyle = vg; fc.fillRect(0, 0, fw, fh);
      g.globalAlpha = clamp(cfg.fog * 1.4, 0, 1);
      g.imageSmoothingEnabled = true;
      g.drawImage(fogComp, L.x0, L.y0, L.gw, L.gh);
      g.globalAlpha = 1;
      void k;
    }
    // Tropfen
    if (cfg.glassdrops) {
      g.drawImage(staticDrops, L.x0, L.y0, L.gw, L.gh);
      for (const t of trails) { g.globalAlpha = Math.min(1, t.life / 3); g.drawImage(dropSprite, t.x - t.r, t.y - t.r, t.r * 2, t.r * 2); }
      g.globalAlpha = 1;
      for (const d of drops) g.drawImage(dropSprite, d.x - d.r, d.y - d.r * 1.15, d.r * 2, d.r * 2.3);
    }
    // Spiegelung der Lampe im Glas
    if (cfg.lamp > 0.02) {
      const rx = L.x0 + L.gw * 0.2 + ox3 * 0.5, ry = L.y1 - L.gh * 0.25;
      g.save(); g.globalCompositeOperation = 'lighter'; g.globalAlpha = 0.16 * cfg.lamp;
      g.drawImage(glowW, rx - 160 * U, ry - 160 * U, 320 * U, 320 * U); g.restore();
    }
    g.restore();

    // ---- Zimmer ----
    g.drawImage(intr, -M + ox3, -M + oy3, W + 2 * M, H + 2 * M);
    g.save(); g.translate(ox3, oy3);
    // Lampe glüht (leicht zur Musik)
    if (cfg.lamp > 0.02 && L.bulb) {
      g.save(); g.globalCompositeOperation = 'lighter'; g.globalAlpha = (0.5 + beat * 0.15) * cfg.lamp;
      const r = 120 * U; g.drawImage(glowW, L.bulb.x - r, L.bulb.y - r * 0.6, r * 2, r * 2); g.restore();
    }
    drawLights(g);
    drawSteam(g);
    drawRadioLive(g);
    drawCat(time);
    // Neonlicht, das bei Blitz und Bass das Zimmer streift
    if (flash > 0 || beat > 0.05) {
      g.globalCompositeOperation = 'lighter';
      g.fillStyle = rgba(P.n[0], Math.min(0.12, flash * 0.12 + beat * 0.05));
      g.fillRect(-M, L.sillTop - 10 * U, W + 2 * M, H - L.sillTop + M);
      g.globalCompositeOperation = 'source-over';
    }
    g.restore();
  }

  function drawCars(g, near, ox, oy) {
    g.save(); g.globalCompositeOperation = 'source-over';
    for (const c of cars) {
      if ((c.depth > 0.55) !== near) continue;
      const x = c.x + ox * (0.5 + c.depth), y = c.y + oy + Math.sin(c.bob * 1.4) * 2 * U;
      const s = c.sc, len = 46 * s, hh = 11 * s;
      // Körper
      g.fillStyle = mix(P.near, '#000000', 0.2);
      rrect(g, x - len / 2, y - hh / 2, len, hh, hh * 0.45); g.fill();
      g.fillStyle = rgba(c.col, 0.9); g.fillRect(x - len * 0.4, y + hh * 0.42, len * 0.8, 1.6 * s);   // Unterleuchte
      g.fillStyle = rgba('#9fd8ff', 0.35); g.fillRect(x - len * 0.15 + c.dir * len * 0.1, y - hh * 0.4, len * 0.3, hh * 0.35); // Fenster
      // Scheinwerfer vorne, Rücklicht hinten
      g.globalCompositeOperation = 'lighter';
      const fx = x + c.dir * len * 0.5, bx = x - c.dir * len * 0.5;
      g.drawImage(glowW, fx - 16 * s, y - 16 * s, 32 * s, 32 * s);
      g.drawImage(glowR, bx - 12 * s, y - 12 * s, 24 * s, 24 * s);
      const lg = g.createLinearGradient(fx, y, fx + c.dir * 120 * s, y);
      lg.addColorStop(0, 'rgba(255,245,220,0.25)'); lg.addColorStop(1, 'rgba(255,245,220,0)');
      g.fillStyle = lg; g.beginPath(); g.moveTo(fx, y - 2 * s); g.lineTo(fx + c.dir * 120 * s, y - 14 * s); g.lineTo(fx + c.dir * 120 * s, y + 14 * s); g.lineTo(fx, y + 2 * s); g.closePath(); g.fill();
      g.globalCompositeOperation = 'source-over';
    }
    g.restore();
  }

  function drawBillboard(g, ox, oy) {
    if (!billboard) return;
    const b = billboard, x = b.x + ox, y = b.y + oy;
    g.save(); g.beginPath(); g.rect(x, y, b.w, b.h); g.clip();
    const t = time;
    const bgc = g.createLinearGradient(x, y, x + b.w, y + b.h);
    bgc.addColorStop(0, mix(P.n[3] || P.n[0], '#000000', 0.55)); bgc.addColorStop(1, mix(P.n[1], '#000000', 0.6));
    g.fillStyle = bgc; g.fillRect(x, y, b.w, b.h);
    const bars = 32, bw = b.w / bars;
    const live = audio.active > 0 && cfg.react > 0;
    for (let i = 0; i < bars; i++) {
      let v;
      if (live) { const k = Math.floor(i * 1.6); v = (audio.bands[k] + audio.bands[64 + k]) * 0.5 * (0.6 + cfg.react * 0.8); }
      else v = 0.25 + 0.2 * Math.sin(t * 1.4 + i * 0.45) + 0.1 * Math.sin(t * 2.3 - i * 0.8);
      const hh = clamp(v, 0.03, 1) * b.h * 0.85;
      const c = mix(P.n[0], P.n[1], i / bars);
      g.fillStyle = rgba(c, 0.9); g.fillRect(x + i * bw + bw * 0.18, y + b.h - hh, bw * 0.64, hh);
    }
    // Rasterlinien wie ein alter Bildschirm
    g.fillStyle = 'rgba(0,0,0,0.25)';
    for (let yy = 0; yy < b.h; yy += 3 * U) g.fillRect(x, y + yy, b.w, 1 * U);
    g.restore();
    g.save(); g.globalCompositeOperation = 'lighter'; g.globalAlpha = 0.25 + audio.bass * cfg.react * 0.3;
    g.drawImage(glowW, x - b.w * 0.2, y - b.h * 0.5, b.w * 1.4, b.h * 2); g.restore();
  }

  function timeString() {
    const d = new Date(); let h = d.getHours(); const m = String(d.getMinutes()).padStart(2, '0');
    if (!cfg.hour24) { h = h % 12 || 12; }
    return (cfg.hour24 ? String(h).padStart(2, '0') : String(h)) + ':' + m;
  }

  function drawClockSign(g, ox, oy) {
    if (cfg.clock !== 'neon' || !clockSign) return;
    const txt = timeString();
    if (txt !== clockText || !clockSign.c) {
      clockText = txt;
      const sp = makeSign(txt, clockSign.color, false, 44 * U);
      clockSign.c = sp.c; clockSign.w = sp.c.width / S; clockSign.h = sp.c.height / S;
    }
    g.globalAlpha = 0.95;
    g.drawImage(clockSign.c, clockSign.x - clockSign.w / 2 + ox, clockSign.y - clockSign.h + oy, clockSign.w, clockSign.h);
    g.globalAlpha = 1;
  }

  // warme Lichterkette, in zwei Bögen über das Fenster gehängt
  function drawLights(g) {
    if (!cfg.lights) return;
    const pts = [];
    const segs = [[L.x0 + L.frame, L.mullX], [L.mullX, L.x1 - L.frame]];
    const yTop = L.y0 + L.frame * 1.2, sag = L.gh * 0.07;
    for (const [a, b] of segs) {
      const n = Math.max(8, Math.round((b - a) / (46 * U)));
      for (let i = 0; i <= n; i++) { const t = i / n; pts.push([lerp(a, b, t), yTop + Math.sin(t * Math.PI) * sag + Math.sin(time * 0.8 + i) * 0.6 * U]); }
    }
    g.strokeStyle = 'rgba(20,14,18,0.9)'; g.lineWidth = 1.6 * U;
    g.beginPath(); pts.forEach((p, i) => (i ? g.lineTo(p[0], p[1]) : g.moveTo(p[0], p[1]))); g.stroke();
    const warm = ['#ffcf7a', '#ffb35c', '#ffe2a8', '#ff9fb8'];
    g.save(); g.globalCompositeOperation = 'lighter';
    pts.forEach((p, i) => {
      const tw = 0.65 + 0.35 * Math.sin(time * (1.1 + (i % 5) * 0.23) + i * 1.7) + audio.high * cfg.react * 0.4;
      const r = 22 * U * tw;
      g.globalAlpha = 0.55 * tw; g.drawImage(glowW, p[0] - r, p[1] + 5 * U - r, r * 2, r * 2);
      g.globalAlpha = 1; g.fillStyle = warm[i % warm.length];
      g.beginPath(); g.ellipse(p[0], p[1] + 5 * U, 2.6 * U, 3.6 * U, 0, 0, TAU); g.fill();
    });
    g.restore();
  }

  function drawSteam(g) {
    if (!cfg.steam || !L.mugTop) return;
    const { x, y } = L.mugTop;
    g.save(); g.lineCap = 'round';
    for (let i = 0; i < 3; i++) {
      const ph = time * 0.6 + i * 2.1;
      const a = 0.16 + 0.08 * Math.sin(ph * 1.7);
      g.strokeStyle = 'rgba(235,225,255,' + a + ')'; g.lineWidth = (6 - i) * U;
      g.beginPath();
      const sx = x + (i - 1) * 8 * U;
      g.moveTo(sx, y - 4 * U);
      for (let k = 1; k <= 6; k++) {
        const yy = y - 4 * U - k * 16 * U;
        g.lineTo(sx + Math.sin(ph + k * 0.9) * (4 + k * 2.2) * U, yy);
      }
      g.stroke();
    }
    g.restore();
  }

  function drawRadioLive(g) {
    const r = L.radio;
    if (!r.lcd) return;
    const c = mix(P.n[1], '#ffffff', 0.15);
    // Uhr oder Sendername
    g.fillStyle = rgba(c, 0.92); g.font = '600 ' + (r.lcd.h * 0.72) + 'px ' + MONO; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.shadowColor = c; g.shadowBlur = 6 * U;
    g.fillText(cfg.clock === 'radio' ? timeString() : 'FM 88.4', r.lcd.x + r.lcd.w / 2, r.lcd.y + r.lcd.h / 2 + 1 * U);
    g.shadowBlur = 0;
    // LED-Pegel
    const n = 10, lw = r.leds.w / n;
    for (let i = 0; i < n; i++) {
      let v;
      if (audio.active > 0) { const k = 2 + i * 5; v = (audio.bands[k] + audio.bands[64 + k]) * 0.6 * (0.5 + cfg.react); }
      else v = 0.3 + 0.25 * Math.sin(time * 3 + i);
      const on = Math.max(1, Math.round(clamp(v, 0, 1) * 4));
      for (let j = 0; j < 4; j++) {
        g.fillStyle = j < on ? rgba(j === 3 ? P.n[0] : P.n[1], 0.9) : 'rgba(255,255,255,0.06)';
        g.fillRect(r.leds.x + i * lw + lw * 0.15, r.leds.y + r.leds.h - (j + 1) * r.leds.h / 4, lw * 0.7, r.leds.h / 4 - 1 * U);
      }
    }
  }

  /* ================= Maus ================= */
  window.addEventListener('mousemove', (e) => {
    mouse.x = e.clientX / W; mouse.y = e.clientY / H;
    if (!mouse.inside) { mouse.px = mouse.x; mouse.py = mouse.y; }
    mouse.inside = true;
  });
  document.addEventListener('mouseleave', () => { mouse.inside = false; mouse.px = -1; });
  window.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    const x = e.clientX, y = e.clientY;
    // Katze geweckt?
    if (cfg.cat && Math.abs(x - L.cat.x) < 150 * L.cat.s && y > L.cat.y - 130 * L.cat.s && y < L.cat.y + 20 * U) { catWake = 3.2; catEar = 0.5; return; }
    // aufs Glas: Spritzer aus Tropfen
    if (cfg.glassdrops && x > L.x0 && x < L.x1 && y > L.y0 && y < L.y1) {
      for (let i = 0; i < 7; i++) {
        const a = Math.random() * TAU, d = Math.random() * 30 * U;
        drops.push({ x: x + Math.cos(a) * d, y: y + Math.sin(a) * d, r: (2 + Math.random() * 4.5) * U * 1.3, v: 0, stick: 0.3 + Math.random() * 1.5, wob: Math.random() * TAU });
      }
      if (drops.length > 120) drops.splice(0, drops.length - 120);
      wipe(x, y, 26 * U, 0.6);
    }
  });

  /* ================= Wallpaper Engine ================= */
  window.wallpaperPropertyListener = {
    applyUserProperties: function (p) {
      const v = (k) => p[k].value;
      let rebuild = false, rain = false;
      if (p.palette) { cfg.palette = String(v('palette')); rebuild = true; }
      if (p.rain) { cfg.rain = (+v('rain')) / 100; rain = true; }
      if (p.glassdrops) { cfg.glassdrops = !!v('glassdrops'); rain = true; }
      if (p.fog) cfg.fog = (+v('fog')) / 100;
      if (p.lights) cfg.lights = !!v('lights');
      if (p.traffic) cfg.traffic = +v('traffic') | 0;
      if (p.searchlights) cfg.searchlights = !!v('searchlights');
      if (p.cat) cfg.cat = !!v('cat');
      if (p.catcolor) { cfg.catcolor = String(v('catcolor')); rebuild = true; }
      if (p.steam) cfg.steam = !!v('steam');
      if (p.lamp) { cfg.lamp = (+v('lamp')) / 100; rebuild = true; }
      if (p.clock) cfg.clock = String(v('clock'));
      if (p.hour24) { cfg.hour24 = !!v('hour24'); clockText = ''; }
      if (p.thunder) cfg.thunder = !!v('thunder');
      if (p.react) cfg.react = (+v('react')) / 100;
      if (p.parallax) cfg.parallax = (+v('parallax')) / 100;
      if (p.seed) { cfg.seed = +v('seed') | 0; rebuild = true; }
      if (p.renderscale) { cfg.scale = (+v('renderscale') || 100) / 100; rebuild = true; }
      P = PALETTES[cfg.palette] || PALETTES.neon;
      if (!W) return;
      if (rebuild) resize();
      else if (rain) { buildRain(); buildDrops(); }
    },
    applyGeneralProperties: function (p) { if (p.fps) cfg.fpsCap = +p.fps || 0; },
    setPaused: function (x) {
      const was = paused; paused = !!x;
      if (was && !paused) { last = performance.now(); requestAnimationFrame(frame); }
    },
  };

  window.addEventListener('resize', () => { resize(); });
  resize();
  last = performance.now();
  requestAnimationFrame(frame);
  // für Tests: Bild ohne Warten vorspulen
  window.NeonNook = { step: (dt, n) => { for (let i = 0; i < (n || 1); i++) step(dt); render(); }, cfg, audio, layer: (k) => ({ sky, mid, intr })[k], L: () => L };
})();
