/* Gezeichnete Grafiken (Canvas 2D), einmal beim Start: Seerosenblätter, Blüten, Kirschblüten, Ahornblätter,
   Futter und Lichtpunkt. Alles landet in einem Atlas, es gibt keine Bilddateien. */
(function () {
  'use strict';
  const N = window.Nishiki, U = N.util, TAU = U.TAU;
  const A = N.art = {};

  const AW = 2048, AH = 1024;
  A.rects = { pad: [], flower: [], sakura: [], maple: [], pellet: null, glow: null };

  function rect(x, y, w, h) { return { u0: x / AW, v0: y / AH, u1: (x + w) / AW, v1: (y + h) / AH }; }

  /* ----- Seerosenblatt ----- */
  const PAD_PAL = [
    { c: '#a6d05f', m: '#5ba745', e: '#2e7a3b', rim: 'rgba(18,58,26,.6)', vein: 'rgba(205,235,150,.42)' },
    { c: '#7db552', m: '#418c40', e: '#1e6034', rim: 'rgba(10,44,22,.6)', vein: 'rgba(180,220,140,.36)' },
    { c: '#bfd468', m: '#86b24a', e: '#587c34', rim: 'rgba(110,66,28,.6)', vein: 'rgba(225,238,160,.42)' },
    { c: '#86a550', m: '#517f3e', e: '#2b5631', rim: 'rgba(70,52,24,.6)', vein: 'rgba(190,215,140,.34)' },
  ];
  function padPath(g, R, notchA, notchW, wob, ph) {
    const steps = 96, a0 = notchA + notchW / 2, span = TAU - notchW;
    g.beginPath();
    g.moveTo(Math.cos(notchA) * R * 0.06, Math.sin(notchA) * R * 0.06);
    for (let i = 0; i <= steps; i++) {
      const t = i / steps, a = a0 + span * t;
      const r = R * (1 + wob * Math.sin(a * 7 + ph) + wob * 0.7 * Math.sin(a * 13 + ph * 2.1));
      g.lineTo(Math.cos(a) * r, Math.sin(a) * r);
    }
    g.closePath();
  }
  function drawPad(g, cx, cy, R, pal, rnd) {
    const notchA = rnd() * TAU, notchW = 0.20 + rnd() * 0.14, ph = rnd() * 9;
    g.save(); g.translate(cx, cy);
    padPath(g, R, notchA, notchW, 0.016, ph);
    const gr = g.createRadialGradient(0, 0, R * 0.04, 0, 0, R);
    gr.addColorStop(0, pal.c); gr.addColorStop(0.55, pal.m); gr.addColorStop(1, pal.e);
    g.fillStyle = gr; g.fill();
    g.save(); g.clip();
    // feine Maserung
    for (let i = 0; i < 150; i++) {
      const a = rnd() * TAU, r0 = R * (0.1 + rnd() * 0.5), r1 = r0 + R * (0.15 + rnd() * 0.35);
      g.strokeStyle = rnd() < 0.5 ? 'rgba(255,255,220,.045)' : 'rgba(0,40,10,.05)';
      g.lineWidth = R * 0.012;
      g.beginPath(); g.moveTo(Math.cos(a) * r0, Math.sin(a) * r0); g.lineTo(Math.cos(a) * r1, Math.sin(a) * r1); g.stroke();
    }
    // Blattadern, vom Zentrum zum Rand, mit Gabelung
    const nv = 15 + Math.floor(rnd() * 5);
    g.fillStyle = pal.vein; g.strokeStyle = pal.vein;
    for (let i = 0; i < nv; i++) {
      const a = notchA + notchW * 0.75 + (TAU - notchW * 1.5) * (i / (nv - 1)) + (rnd() - 0.5) * 0.06;
      const ca = Math.cos(a), sa = Math.sin(a), w = R * 0.016;
      g.beginPath();
      g.moveTo(-sa * w, ca * w); g.lineTo(ca * R * 0.97, sa * R * 0.97); g.lineTo(sa * w, -ca * w);
      g.closePath(); g.fill();
      for (const sgn of [-1, 1]) {
        const b = a + sgn * (0.13 + rnd() * 0.05), s0 = 0.52 + rnd() * 0.12;
        g.lineWidth = R * 0.008;
        g.beginPath(); g.moveTo(ca * R * s0, sa * R * s0); g.lineTo(Math.cos(b) * R * 0.96, Math.sin(b) * R * 0.96); g.stroke();
      }
    }
    // dunklerer Rand innen, heller Mittelpunkt
    const eg = g.createRadialGradient(0, 0, R * 0.72, 0, 0, R * 1.02);
    eg.addColorStop(0, 'rgba(0,0,0,0)'); eg.addColorStop(1, 'rgba(0,30,10,.30)');
    g.fillStyle = eg; g.fillRect(-R * 1.1, -R * 1.1, R * 2.2, R * 2.2);
    const cg = g.createRadialGradient(0, 0, 0, 0, 0, R * 0.14);
    cg.addColorStop(0, 'rgba(235,250,170,.55)'); cg.addColorStop(1, 'rgba(235,250,170,0)');
    g.fillStyle = cg; g.fillRect(-R * 0.2, -R * 0.2, R * 0.4, R * 0.4);
    // Wassertropfen
    for (let i = 0; i < 4; i++) {
      const a = rnd() * TAU, d = R * (0.25 + rnd() * 0.55), x = Math.cos(a) * d, y = Math.sin(a) * d, r = R * (0.018 + rnd() * 0.022);
      const dg = g.createRadialGradient(x - r * 0.3, y - r * 0.3, 0, x, y, r);
      dg.addColorStop(0, 'rgba(255,255,255,.75)'); dg.addColorStop(0.5, 'rgba(220,255,220,.22)'); dg.addColorStop(1, 'rgba(0,40,10,.25)');
      g.fillStyle = dg; g.beginPath(); g.arc(x, y, r, 0, TAU); g.fill();
    }
    g.restore();
    padPath(g, R, notchA, notchW, 0.016, ph);
    g.lineWidth = R * 0.028; g.strokeStyle = pal.rim; g.lineJoin = 'round'; g.stroke();
    g.restore();
  }

  /* ----- Seerosenblüte: drei Kränze spitzer Blütenblätter ----- */
  const FLOWER_PAL = [
    { rings: [['#f39ac0', '#fff1f7'], ['#ec74a8', '#fcd5e5'], ['#df4f8c', '#f8b6d1']], line: 'rgba(190,60,120,.28)', sh: 'rgba(90,10,60,.38)' },
    { rings: [['#dfe9ec', '#ffffff'], ['#f4ecd2', '#fffef6'], ['#f6e2a0', '#fff8dc']], line: 'rgba(150,150,120,.25)', sh: 'rgba(40,50,40,.35)' },
    { rings: [['#b274dc', '#f3e0ff'], ['#9a55cf', '#e2c1f7'], ['#8040bd', '#cf9df0']], line: 'rgba(90,40,150,.28)', sh: 'rgba(40,10,80,.40)' },
  ];
  function petalPath(g, len, w) {
    g.beginPath();
    g.moveTo(0, len * 0.05);
    g.bezierCurveTo(w * 1.05, len * 0.22, w * 0.95, len * 0.72, 0, len);
    g.bezierCurveTo(-w * 0.95, len * 0.72, -w * 1.05, len * 0.22, 0, len * 0.05);
    g.closePath();
  }
  function drawFlower(g, cx, cy, R, pal, rnd) {
    g.save(); g.translate(cx, cy);
    // weicher Schatten auf Blatt und Wasser
    const sg = g.createRadialGradient(R * 0.07, R * 0.10, R * 0.2, R * 0.07, R * 0.10, R * 1.02);
    sg.addColorStop(0, 'rgba(0,25,15,.42)'); sg.addColorStop(1, 'rgba(0,25,15,0)');
    g.fillStyle = sg; g.fillRect(-R * 1.2, -R * 1.2, R * 2.4, R * 2.4);
    const spec = [{ n: 10, len: 0.94, w: 0.21 }, { n: 8, len: 0.70, w: 0.20 }, { n: 6, len: 0.45, w: 0.17 }];
    let rot = rnd() * TAU;
    spec.forEach((sp, ri) => {
      const [c0, c1] = pal.rings[ri];
      for (let i = 0; i < sp.n; i++) {
        const a = rot + (i / sp.n) * TAU + (rnd() - 0.5) * 0.08, len = R * sp.len * (0.94 + rnd() * 0.08), w = R * sp.w;
        g.save(); g.rotate(a);
        g.shadowColor = pal.sh; g.shadowBlur = R * 0.07; g.shadowOffsetX = R * 0.012; g.shadowOffsetY = R * 0.018;
        const gr = g.createLinearGradient(0, 0, 0, len);
        gr.addColorStop(0, c0); gr.addColorStop(0.55, c0); gr.addColorStop(1, c1);
        petalPath(g, len, w); g.fillStyle = gr; g.fill();
        g.shadowColor = 'transparent';
        // Lichtkante und Mittelrippe
        const hg = g.createLinearGradient(-w, 0, w, 0);
        hg.addColorStop(0, 'rgba(255,255,255,.26)'); hg.addColorStop(0.5, 'rgba(255,255,255,0)'); hg.addColorStop(1, 'rgba(60,0,40,.10)');
        petalPath(g, len, w); g.fillStyle = hg; g.fill();
        g.strokeStyle = pal.line; g.lineWidth = R * 0.008;
        g.beginPath(); g.moveTo(0, len * 0.12); g.lineTo(0, len * 0.86); g.stroke();
        g.restore();
      }
      rot += Math.PI / sp.n + 0.2;
    });
    // Staubgefäße
    const yg = g.createRadialGradient(0, 0, 0, 0, 0, R * 0.2);
    yg.addColorStop(0, '#ffe98a'); yg.addColorStop(0.7, '#f6b53a'); yg.addColorStop(1, 'rgba(230,140,30,0)');
    g.fillStyle = yg; g.beginPath(); g.arc(0, 0, R * 0.2, 0, TAU); g.fill();
    for (let i = 0; i < 16; i++) {
      const a = (i / 16) * TAU + rnd() * 0.2, d = R * (0.07 + rnd() * 0.08);
      g.fillStyle = i % 2 ? '#fff3b0' : '#f2a531';
      g.beginPath(); g.arc(Math.cos(a) * d, Math.sin(a) * d, R * 0.02, 0, TAU); g.fill();
    }
    g.restore();
  }

  /* ----- Kirschblütenblatt ----- */
  const SAKURA_PAL = [['#ffe6ef', '#f8b3cf'], ['#fff0f5', '#f6a4c4'], ['#ffdbe8', '#f191b8'], ['#fff6f9', '#fac4d9']];
  function drawSakura(g, cx, cy, R, pal, rnd) {
    g.save(); g.translate(cx, cy); g.rotate(rnd() * TAU);
    const w = R * (0.62 + rnd() * 0.12);
    g.beginPath();
    g.moveTo(0, R * 0.92);
    g.bezierCurveTo(w * 1.25, R * 0.35, w * 1.0, -R * 0.75, w * 0.26, -R * 0.9);
    g.lineTo(0, -R * 0.62);
    g.lineTo(-w * 0.26, -R * 0.9);
    g.bezierCurveTo(-w * 1.0, -R * 0.75, -w * 1.25, R * 0.35, 0, R * 0.92);
    g.closePath();
    const gr = g.createLinearGradient(0, -R, 0, R);
    gr.addColorStop(0, pal[0]); gr.addColorStop(1, pal[1]);
    g.shadowColor = 'rgba(60,0,40,.25)'; g.shadowBlur = R * 0.12;
    g.fillStyle = gr; g.fill();
    g.shadowColor = 'transparent';
    g.strokeStyle = 'rgba(214,96,150,.35)'; g.lineWidth = R * 0.05;
    g.beginPath(); g.moveTo(0, R * 0.8); g.lineTo(0, -R * 0.4); g.stroke();
    g.restore();
  }

  /* ----- Ahornblatt (Momiji): sieben spitze Lappen ----- */
  const MAPLE_PAL = [['#b3261a', '#ea5a2a'], ['#d9651c', '#f4ae3c'], ['#c99a24', '#f3da76']];
  function drawMaple(g, cx, cy, R, pal, rnd) {
    g.save(); g.translate(cx, cy); g.rotate(rnd() * TAU);
    const lobes = [[0, 1.0], [0.62, 0.9], [-0.62, 0.9], [1.28, 0.72], [-1.28, 0.72], [2.0, 0.44], [-2.0, 0.44]];
    g.shadowColor = 'rgba(40,10,0,.3)'; g.shadowBlur = R * 0.1;
    const gr = g.createRadialGradient(0, 0, 0, 0, 0, R);
    gr.addColorStop(0, pal[0]); gr.addColorStop(1, pal[1]);
    g.fillStyle = gr;
    g.beginPath();
    // Umriss: zwischen den Lappen zurück zur Mitte
    const order = lobes.slice().sort((a, b) => a[0] - b[0]);
    order.forEach((lb, i) => {
      const a = lb[0] - Math.PI / 2, len = R * lb[1], w = 0.20;
      const tip = [Math.cos(a) * len, Math.sin(a) * len];
      const l = [Math.cos(a - w) * len * 0.42, Math.sin(a - w) * len * 0.42], r = [Math.cos(a + w) * len * 0.42, Math.sin(a + w) * len * 0.42];
      if (i === 0) g.moveTo(l[0], l[1]); else g.lineTo(l[0], l[1]);
      g.quadraticCurveTo(Math.cos(a - w * 0.7) * len * 0.75, Math.sin(a - w * 0.7) * len * 0.75, tip[0], tip[1]);
      g.quadraticCurveTo(Math.cos(a + w * 0.7) * len * 0.75, Math.sin(a + w * 0.7) * len * 0.75, r[0], r[1]);
    });
    g.closePath(); g.fill();
    g.shadowColor = 'transparent';
    g.strokeStyle = 'rgba(90,20,0,.35)'; g.lineWidth = R * 0.03; g.lineCap = 'round';
    lobes.forEach((lb) => { const a = lb[0] - Math.PI / 2; g.beginPath(); g.moveTo(0, 0); g.lineTo(Math.cos(a) * R * lb[1] * 0.85, Math.sin(a) * R * lb[1] * 0.85); g.stroke(); });
    g.beginPath(); g.moveTo(0, 0); g.lineTo(0, R * 0.55); g.stroke();
    g.restore();
  }

  A.build = function () {
    const cv = document.createElement('canvas'); cv.width = AW; cv.height = AH;
    const g = cv.getContext('2d');
    const rnd = U.rng(4711);
    const R = A.rects;
    R.pad.length = R.flower.length = R.sakura.length = R.maple.length = 0;
    for (let i = 0; i < 4; i++) { const x = i * 400, s = 400; drawPad(g, x + s / 2, s / 2, s * 0.47, PAD_PAL[i], rnd); R.pad.push(rect(x, 0, s, s)); }
    for (let i = 0; i < 3; i++) { const x = i * 340, y = 404, s = 340; drawFlower(g, x + s / 2, y + s / 2, s * 0.44, FLOWER_PAL[i], rnd); R.flower.push(rect(x, y, s, s)); }
    for (let i = 0; i < 4; i++) { const x = i * 100, y = 760, s = 100; drawSakura(g, x + s / 2, y + s / 2, s * 0.40, SAKURA_PAL[i], rnd); R.sakura.push(rect(x, y, s, s)); }
    for (let i = 0; i < 3; i++) { const x = 420 + i * 140, y = 760, s = 140; drawMaple(g, x + s / 2, y + s / 2, s * 0.44, MAPLE_PAL[i], rnd); R.maple.push(rect(x, y, s, s)); }
    // Futterkorn
    { const x = 1700, y = 16, s = 48, c = s / 2;
      const gr = g.createRadialGradient(x + c - 5, y + c - 6, 1, x + c, y + c, c * 0.8);
      gr.addColorStop(0, '#d9a868'); gr.addColorStop(0.6, '#9a6a36'); gr.addColorStop(1, '#5c3b1c');
      g.fillStyle = gr; g.beginPath(); g.arc(x + c, y + c, c * 0.78, 0, TAU); g.fill();
      R.pellet = rect(x, y, s, s); }
    // Lichtpunkt für Glühwürmchen
    { const x = 1780, y = 0, s = 160, c = s / 2;
      const gr = g.createRadialGradient(x + c, y + c, 0, x + c, y + c, c);
      gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.12, 'rgba(255,255,255,.75)'); gr.addColorStop(0.35, 'rgba(255,255,255,.22)'); gr.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = gr; g.fillRect(x, y, s, s);
      R.glow = rect(x, y, s, s); }
    A.canvas = cv;
    return cv;
  };
})();
