/* Koi: Zeichnung (Muster je Zuchtform), Schwimmverhalten und Körpernetz.
   Jeder Fisch ist eine Kette aus Gelenken, die dem Kopf folgt; darüber läuft die Schwimmwelle zum Schwanz. */
(function () {
  'use strict';
  const N = window.Nishiki, U = N.util, TAU = U.TAU;
  const K = N.koi = {};

  const NB = 16, NT = 5, NJ = NB + NT + 1;         // Körper- und Schwanzflossen-Segmente
  const STRIDE = 12;
  const VPF = NB * 6 + NT * 6 + 2 * 4 * 6 + 2 * 3 * 6; // Ecken pro Fisch
  const BODY = 0.78;                                // Anteil des Körpers an der Gesamtlänge
  const CW = 512, CH = 128, COLS = 4, ROWS = 10;
  K.STRIDE = STRIDE; K.MAX = COLS * ROWS;
  K.cell = [1 / COLS, 1 / ROWS];

  const COL = {
    white: [247, 241, 231], red: [216, 56, 30], orange: [241, 124, 36], sumi: [27, 27, 31], ki: [245, 202, 70],
    gold: [231, 166, 54], plat: [239, 237, 228], asagi: [108, 136, 168], cha: [150, 116, 70], beni: [226, 84, 36],
  };
  const VAR = {
    kohaku: { base: 'white', layers: [{ c: 'red', thr: 0.50, fu: 4.4, fv: 0.62, nose: true }], fin: [1.0, 0.97, 0.93], net: 0.05 },
    tancho: { base: 'white', spot: 'red', fin: [1.0, 0.97, 0.93], net: 0.04 },
    sanke: { base: 'white', layers: [{ c: 'red', thr: 0.50, fu: 4.0, fv: 0.62, nose: true }, { c: 'sumi', thr: 0.64, fu: 8.5, fv: 1.5, back: true }], fin: [1.0, 0.97, 0.93], net: 0.05 },
    showa: { base: 'sumi', layers: [{ c: 'red', thr: 0.46, fu: 4.2, fv: 0.7 }, { c: 'white', thr: 0.58, fu: 5.4, fv: 0.9 }], fin: [0.34, 0.33, 0.36], net: 0.03 },
    ogon: { base: 'gold', sheen: 0.30, fin: [1.0, 0.82, 0.48], net: 0.10 },
    plat: { base: 'plat', sheen: 0.12, fin: [0.98, 0.98, 0.96], net: 0.07 },
    orenji: { base: 'orange', sheen: 0.22, fin: [1.0, 0.72, 0.42], net: 0.09 },
    utsuri: { base: 'sumi', layers: [{ c: 'orange', thr: 0.49, fu: 4.6, fv: 0.8 }], fin: [0.34, 0.31, 0.30], net: 0.03 },
    bekko: { base: 'ki', layers: [{ c: 'sumi', thr: 0.63, fu: 8.5, fv: 1.6, back: true }], fin: [1.0, 0.90, 0.55], net: 0.07 },
    asagi: { base: 'asagi', sides: 'beni', headc: 'plat', fin: [1.0, 0.70, 0.50], net: 0.26 },
    chagoi: { base: 'cha', sheen: 0.10, fin: [0.80, 0.66, 0.46], net: 0.14 },
    beni: { base: 'beni', sheen: 0.10, fin: [1.0, 0.66, 0.44], net: 0.07 },
  };
  const MIX = {
    mixed: ['kohaku', 'kohaku', 'kohaku', 'sanke', 'sanke', 'showa', 'showa', 'tancho', 'ogon', 'ogon', 'plat', 'orenji', 'utsuri', 'bekko', 'asagi', 'chagoi', 'beni', 'kohaku'],
    classic: ['kohaku', 'kohaku', 'kohaku', 'sanke', 'sanke', 'tancho', 'tancho', 'plat', 'beni'],
    gold: ['ogon', 'ogon', 'ogon', 'plat', 'plat', 'orenji', 'bekko', 'chagoi'],
    dark: ['showa', 'showa', 'showa', 'utsuri', 'utsuri', 'sanke', 'asagi', 'chagoi'],
  };

  let atlas = null, ag = null;
  let fish = [];
  let sig = '';
  const buf = new Float32Array(K.MAX * VPF * STRIDE);
  K.buffer = buf;
  K.dirty = false;

  /* ----- Muster eines Fisches in seine Atlas-Zelle malen ----- */
  function paint(x0, y0, vr, seed) {
    const rnd = U.rng(seed), noise = U.makeNoise(seed * 3 + 11);
    const img = ag.createImageData(CW, CH), d = img.data;
    const base = COL[vr.base];
    const layers = vr.layers || [];
    const offs = layers.map(() => [rnd() * 60, rnd() * 60]);
    const thrJ = (rnd() - 0.5) * 0.09;
    const light = vr.base === 'white' || vr.base === 'plat';
    for (let y = 0; y < CH; y++) {
      const vv = (y / (CH - 1)) * 2 - 1, av = Math.abs(vv);
      for (let x = 0; x < CW; x++) {
        const u = x / (CW - 1);
        let r = base[0], g = base[1], b = base[2];
        for (let li = 0; li < layers.length; li++) {
          const Ly = layers[li], c = COL[Ly.c];
          const n = U.fbm(noise, u * Ly.fu + offs[li][0], vv * Ly.fv + offs[li][1], 4);
          let m = U.smooth(Ly.thr + thrJ - 0.022, Ly.thr + thrJ + 0.022, n);
          if (Ly.nose) m *= U.smooth(0.03, 0.08, u);
          if (Ly.back) m *= 1 - U.smooth(0.5, 0.9, av);
          r += (c[0] - r) * m; g += (c[1] - g) * m; b += (c[2] - b) * m;
        }
        if (vr.spot) {
          const c = COL[vr.spot], m = 1 - U.smooth(0.46, 0.56, Math.hypot((u - 0.115) * 9.4, vv));
          r += (c[0] - r) * m; g += (c[1] - g) * m; b += (c[2] - b) * m;
        }
        if (vr.sides) {
          const c = COL[vr.sides], m = U.smooth(0.52, 0.80, av) * U.smooth(0.16, 0.24, u);
          r += (c[0] - r) * m; g += (c[1] - g) * m; b += (c[2] - b) * m;
        }
        if (vr.headc) {
          const c = COL[vr.headc], m = 1 - U.smooth(0.15, 0.22, u);
          r += (c[0] - r) * m; g += (c[1] - g) * m; b += (c[2] - b) * m;
        }
        if (vr.sheen) { const s = Math.pow(1 - av, 2) * vr.sheen; r += (255 - r) * s; g += (255 - g) * s; b += (255 - b) * s; }
        if (light) { const m = (1 - U.smooth(0.0, 0.05, u)) * 0.45; r += (238 - r) * m; g += (176 - g) * m; b += (168 - b) * m; }
        // Schuppennetz hinter dem Kopf
        const sa = u * 44 + vv * 5.5, sb = u * 44 - vv * 5.5;
        const na = Math.abs(sa - Math.floor(sa) - 0.5), nb = Math.abs(sb - Math.floor(sb) - 0.5);
        const net = Math.max(0, 1 - Math.min(na, nb) * 7) * U.smooth(0.17, 0.27, u);
        const k = 1 - net * vr.net;
        const o = (y * CW + x) * 4;
        d[o] = r * k; d[o + 1] = g * k; d[o + 2] = b * k; d[o + 3] = 255;
      }
    }
    ag.putImageData(img, x0, y0);
    // Kiemendeckel und Augen
    ag.save();
    ag.beginPath(); ag.rect(x0, y0, CW, CH); ag.clip();
    ag.lineWidth = 2.4; ag.strokeStyle = vr.base === 'sumi' ? 'rgba(255,255,255,.10)' : 'rgba(40,20,10,.22)';
    const gx = x0 + CW * 0.085, gy = y0 + CH / 2, gr = CW * 0.115;
    ag.beginPath(); ag.arc(gx, gy, gr, -1.15, -0.30); ag.stroke();
    ag.beginPath(); ag.arc(gx, gy, gr, 0.30, 1.15); ag.stroke();
    for (const sgn of [-1, 1]) {
      const ex = x0 + CW * 0.082, ey = y0 + CH * (0.5 + sgn * 0.375), er = CH * 0.068;
      ag.fillStyle = '#0c0c10'; ag.beginPath(); ag.ellipse(ex, ey, er * 1.05, er, 0, 0, TAU); ag.fill();
      ag.strokeStyle = 'rgba(255,224,170,.55)'; ag.lineWidth = 1.6; ag.stroke();
      ag.fillStyle = 'rgba(255,255,255,.8)'; ag.beginPath(); ag.arc(ex - er * 0.3, ey - sgn * er * 0.25, er * 0.22, 0, TAU); ag.fill();
    }
    ag.restore();
  }

  function pickGoal(f, asp) {
    const r = f.r, m = r() < 0.18 ? -0.12 : 0.07;
    f.gx = m + r() * (asp - 2 * m); f.gy = m + r() * (1 - 2 * m); f.gt = 7 + r() * 9;
    if (f.kissing <= 0) f.depthT = 0.15 + r() * 0.7;
  }
  function layChain(f) {
    const cx = Math.cos(f.heading), cy = Math.sin(f.heading), L = f.L0;
    let d = 0;
    for (let j = 0; j < NJ; j++) {
      f.jx[j] = f.x - cx * d; f.jy[j] = f.y - cy * d;
      d += j < NB ? L * BODY / NB : L * 0.24 / NT;
    }
  }
  function spawn(i, cfg, asp) {
    const r = U.rng(cfg.seed * 131 + i * 7919 + 5);
    const names = MIX[cfg.varieties] || MIX.mixed;
    const name = names[Math.floor(r() * names.length)];
    const f = {
      i, r, vr: VAR[name],
      L0: 0.16 + Math.pow(r(), 1.6) * 0.16, L: 0.2,
      long: r() < 0.24, fat: 0.92 + r() * 0.18, temper: r(),
      x: r() * asp, y: r(), heading: r() * TAU, omega: 0, speed: 0.03,
      phase: r() * TAU, wob: r() * 50, depth: 0.2 + r() * 0.6, depthT: 0.2 + r() * 0.6,
      gx: 0, gy: 0, gt: 0, startle: 0, sx: 0, sy: 0, calm: 0, pause: 0,
      kiss: 6 + r() * 30, kissing: 0, wake: 0, curious: r() < 0.5 ? 1 : 0, curT: 10 + r() * 20, effort: 0.6,
      jx: new Float32Array(NJ), jy: new Float32Array(NJ),
      tx: (i % COLS) / COLS, ty: Math.floor(i / COLS) / ROWS, fr: r(),
    };
    pickGoal(f, asp); layChain(f);
    paint((i % COLS) * CW, Math.floor(i / COLS) * CH, f.vr, cfg.seed * 977 + i * 31 + 3);
    return f;
  }

  /* Anzahl oder Sorten geändert: Fische anlegen oder entfernen. */
  K.setup = function (cfg, asp) {
    if (!atlas) {
      atlas = document.createElement('canvas'); atlas.width = CW * COLS; atlas.height = CH * ROWS;
      ag = atlas.getContext('2d', { willReadFrequently: true });
      K.atlas = atlas;
    }
    const count = Math.max(0, Math.min(K.MAX, cfg.count | 0));
    const s = cfg.varieties + '|' + cfg.seed;
    if (s !== sig) { fish = []; sig = s; }
    while (fish.length > count) fish.pop();
    while (fish.length < count) { fish.push(spawn(fish.length, cfg, asp)); K.dirty = true; }
  };
  K.count = () => fish.length;
  K.list = () => fish;

  /* Schreck: Fische in der Nähe weichen kurz aus. */
  K.scare = function (x, y, radius) {
    for (const f of fish) {
      const dx = f.jx[4] - x, dy = f.jy[4] - y, d = Math.hypot(dx, dy);
      if (d < radius && f.calm <= 0) { f.startle = 0.4; f.calm = 2.5; f.sx = dx / (d || 1); f.sy = dy / (d || 1); }
    }
  };

  K.update = function (dt, env) {
    const cfg = env.cfg, asp = env.aspect, cur = env.cursor;
    for (const f of fish) {
      const L = f.L0 * cfg.size * (1 - 0.13 * f.depth);
      f.L = L;
      f.calm -= dt;
      let tx = f.gx, ty = f.gy, urgency = 0, bd = 9;

      // Futter riechen: je länger es schwimmt, desto weiter
      let best = null;
      for (const p of env.pellets) {
        if (p.eaten) continue;
        const d = Math.hypot(p.x - f.x, p.y - f.y);
        if (d < 0.24 + p.age * 0.32 && d < bd) { bd = d; best = p; }
      }
      f.curT -= dt;
      if (f.curT <= 0) { f.curT = 14 + f.r() * 16; f.curious = f.r() < 0.5 ? 1 : 0; }
      if (best) {
        tx = best.x; ty = best.y; urgency = 1; f.depthT = 0.04; f.gt = 1.5;
        if (bd < 0.012 + L * 0.05) { best.eaten = true; env.drop(best.x, best.y, 0.011, 0.32); f.pause = 0.3; }
      } else if (cfg.curious && cur.inside && cur.still > 1.0 && cur.still < 14 && f.curious && Math.hypot(cur.x - f.x, cur.y - f.y) < 0.5) {
        tx = cur.x + Math.cos(f.i * 2.4 + env.time * 0.35) * 0.06; ty = cur.y + Math.sin(f.i * 2.4 + env.time * 0.35) * 0.06;
        urgency = 0.3; f.depthT = 0.12; f.gt = 2;
      } else {
        f.gt -= dt;
        if (f.gt <= 0 || Math.hypot(tx - f.x, ty - f.y) < 0.06) { pickGoal(f, asp); tx = f.gx; ty = f.gy; }
      }
      // hastige Mausbewegung dicht am Fisch
      if (cfg.cursorripple && cur.inside && cur.speed > 1.4 && f.calm <= 0 && !best) {
        const dx = f.jx[4] - cur.x, dy = f.jy[4] - cur.y, d = Math.hypot(dx, dy);
        if (d < 0.06 && f.depth < 0.6) { f.startle = 0.35; f.calm = 4; f.sx = dx / (d || 1); f.sy = dy / (d || 1); }
      }

      let dx = tx - f.x, dy = ty - f.y;
      const dl = Math.hypot(dx, dy) || 1; dx /= dl; dy /= dl;
      for (const o of fish) {
        if (o === f || Math.abs(o.depth - f.depth) > 0.3) continue;
        const ox = f.x - o.jx[6], oy = f.y - o.jy[6], d = Math.hypot(ox, oy), rr = (L + o.L) * 0.28;
        if (d < rr && d > 1e-4) { const k = (1 - d / rr) * (urgency >= 1 ? 0.45 : 1.4); dx += ox / d * k; dy += oy / d * k; }
      }
      if (f.startle > 0) { f.startle -= dt; dx = f.sx * 3 + dx * 0.2; dy = f.sy * 3 + dy * 0.2; }

      f.wob += dt * (0.5 + f.temper * 0.5);
      const want = Math.atan2(dy, dx) + Math.sin(f.wob * 1.3 + f.i) * 0.38 * (1 - urgency);
      const diff = U.angDiff(want, f.heading);
      const maxTurn = (0.85 + 1.7 * urgency + (f.startle > 0 ? 3.2 : 0)) * (0.7 + 0.5 * cfg.speed);
      const tOm = U.clamp(diff * 2.2, -maxTurn, maxTurn);
      f.omega += (tOm - f.omega) * Math.min(1, dt * 5);
      f.heading += f.omega * dt;

      const cruise = L * (0.36 + 0.26 * f.temper) * cfg.speed * (1 + env.excite * 0.6);
      let vt = cruise * (0.72 + 0.38 * Math.sin(f.wob * 0.9 + f.i * 2.1));
      if (urgency >= 1) vt = cruise * (0.9 + 1.5 * U.smooth(0.03, 0.22, bd));
      if (f.startle > 0) vt = cruise * 4.4;
      if (f.pause > 0) { f.pause -= dt; vt *= 0.3; }
      vt *= 1 - 0.35 * Math.min(1, Math.abs(diff) / 1.5);
      f.speed += (vt - f.speed) * Math.min(1, dt * (vt > f.speed ? 2.8 : 0.9));
      f.x += Math.cos(f.heading) * f.speed * dt; f.y += Math.sin(f.heading) * f.speed * dt;

      // Kette nachziehen
      const jx = f.jx, jy = f.jy, segB = L * BODY / NB, segT = L * (f.long ? 0.36 : 0.25) / NT;
      jx[0] = f.x; jy[0] = f.y;
      for (let j = 1; j < NJ; j++) {
        let ex = jx[j] - jx[j - 1], ey = jy[j] - jy[j - 1];
        const d = Math.hypot(ex, ey) || 1e-6, seg = j <= NB ? segB : segT;
        jx[j] = jx[j - 1] + ex / d * seg; jy[j] = jy[j - 1] + ey / d * seg;
      }

      const push = U.clamp((vt - f.speed) / (cruise + 1e-6) * 1.5 + f.speed / (cruise + 1e-6) * 0.55, 0.2, 2.0);
      f.effort += (push - f.effort) * Math.min(1, dt * 3);
      f.phase += dt * (2.0 + 5.5 * f.speed / L);
      f.depth += (f.depthT - f.depth) * Math.min(1, dt * (urgency >= 1 ? 1.6 : 0.35));

      // ab und zu an die Oberfläche: kleiner Ring
      f.kiss -= dt;
      if (f.kiss <= 0) { f.kiss = 14 + f.r() * 40; if (!best) { f.depthT = 0.05; f.kissing = 2.6; } }
      if (f.kissing > 0) { f.kissing -= dt; if (f.kissing <= 0) { env.drop(f.x, f.y, 0.012, 0.2); f.depthT = 0.2 + f.r() * 0.6; } }
      // Kielwelle nahe der Oberfläche
      if (f.depth < 0.4) {
        f.wake -= dt;
        if (f.wake <= 0) {
          f.wake = 0.09;
          const k = (0.4 - f.depth) / 0.4 * U.clamp(f.speed / (L * 0.5), 0, 2.5);
          if (k > 0.05) env.drop(jx[NB], jy[NB], 0.011, 0.016 * k * (Math.sin(f.phase) > 0 ? 1 : -1));
        }
      }
    }
  };

  /* ----- Körpernetz ----- */
  function bodyW(s) {
    const hd = Math.pow(Math.sin(Math.min(1, s / 0.2) * Math.PI / 2), 0.6);
    const sh = 0.80 + 0.20 * U.smooth(0.05, 0.36, s);
    const tp = 1 - 0.80 * Math.pow(U.smooth(0.34, 1.0, s), 1.2);
    return hd * sh * tp;
  }
  const qx = new Float32Array(NJ), qy = new Float32Array(NJ), nx = new Float32Array(NJ), ny = new Float32Array(NJ), fx = new Float32Array(NJ), fy = new Float32Array(NJ);
  const cx5 = new Float32Array(6), cy5 = new Float32Array(6), cw5 = new Float32Array(6);
  let o = 0, cur = null, curPart = 0;
  function vtx(x, y, u, v) {
    const f = cur;
    buf[o++] = x; buf[o++] = y; buf[o++] = u; buf[o++] = v; buf[o++] = f.tx; buf[o++] = f.ty;
    buf[o++] = curPart; buf[o++] = f.depth; buf[o++] = f.vr.fin[0]; buf[o++] = f.vr.fin[1]; buf[o++] = f.vr.fin[2]; buf[o++] = f.fr;
  }
  /* Band entlang einer Mittellinie: n Punkte, Halbbreiten w, u läuft von u0 bis u1. */
  function ribbon(px, py, pw, n, u0, u1) {
    for (let k = 0; k < n - 1; k++) {
      const a = Math.max(k - 1, 0), b = Math.min(k + 1, n - 1), c = Math.min(k + 2, n - 1);
      const t0x = px[b] - px[a], t0y = py[b] - py[a], t1x = px[c] - px[k], t1y = py[c] - py[k];
      const d0 = Math.hypot(t0x, t0y) || 1, d1 = Math.hypot(t1x, t1y) || 1;
      const n0x = -t0y / d0, n0y = t0x / d0, n1x = -t1y / d1, n1y = t1x / d1;
      const ua = u0 + (u1 - u0) * (k / (n - 1)), ub = u0 + (u1 - u0) * ((k + 1) / (n - 1));
      const w0 = pw[k], w1 = pw[k + 1];
      const ax = px[k] + n0x * w0, ay = py[k] + n0y * w0, bx = px[k] - n0x * w0, by = py[k] - n0y * w0;
      const cx = px[k + 1] + n1x * w1, cy = py[k + 1] + n1y * w1, ex = px[k + 1] - n1x * w1, ey = py[k + 1] - n1y * w1;
      vtx(ax, ay, ua, 1); vtx(bx, by, ua, -1); vtx(cx, cy, ub, 1);
      vtx(bx, by, ua, -1); vtx(ex, ey, ub, -1); vtx(cx, cy, ub, 1);
    }
  }
  function fin(j, sgn, len, wid, ang, segs) {
    const f = cur, L = f.L;
    const bw = L * 0.105 * f.fat * bodyW(j / NB) * 0.78;
    const bx = qx[j] + nx[j] * sgn * bw, by = qy[j] + ny[j] * sgn * bw;
    for (let k = 0; k <= segs; k++) {
      const t = k / segs, a = ang - t * 0.22;
      const dxk = -fx[j] * Math.cos(a) + nx[j] * sgn * Math.sin(a), dyk = -fy[j] * Math.cos(a) + ny[j] * sgn * Math.sin(a);
      cx5[k] = bx + dxk * len * t; cy5[k] = by + dyk * len * t;
      cw5[k] = wid * Math.pow(Math.sin(Math.PI * Math.pow(t, 1.3)), 0.7) + wid * 0.10 * (1 - t);
    }
    curPart = 2;
    ribbon(cx5, cy5, cw5, segs + 1, 0, 1);
  }
  const bw = new Float32Array(NJ);
  function meshFish(f) {
    cur = f;
    const L = f.L, jx = f.jx, jy = f.jy, wMax = L * 0.105 * f.fat;
    const amp = L * (0.010 + 0.028 * f.effort);
    for (let j = 0; j < NJ; j++) {
      const a = Math.max(j - 1, 0), b = Math.min(j + 1, NJ - 1);
      const tx = jx[a] - jx[b], ty = jy[a] - jy[b], d = Math.hypot(tx, ty) || 1;
      const s = j <= NB ? j / NB : 1 + (j - NB) / NT * 0.45;
      const w = amp * (0.05 + 0.95 * Math.pow(s, 1.7)) * Math.sin(f.phase - s * 4.6);
      qx[j] = jx[j] + (-ty / d) * w; qy[j] = jy[j] + (tx / d) * w;
    }
    for (let j = 0; j < NJ; j++) {
      const a = Math.max(j - 1, 0), b = Math.min(j + 1, NJ - 1);
      const tx = qx[a] - qx[b], ty = qy[a] - qy[b], d = Math.hypot(tx, ty) || 1;
      fx[j] = tx / d; fy[j] = ty / d; nx[j] = -ty / d; ny[j] = tx / d;
    }
    // Brust- und Bauchflossen (liegen unter dem Körper)
    const lf = f.long ? 1.45 : 1.0;
    const spread = 0.95 - 0.28 * U.clamp(f.effort - 0.9, 0, 1);
    for (const sgn of [-1, 1]) {
      const flap = 0.22 * Math.sin(f.phase * 0.5 + sgn * 0.7) + sgn * U.clamp(f.omega, -1.5, 1.5) * 0.16;
      fin(3, sgn, L * 0.165 * lf, L * 0.052 * lf, spread + flap, 4);
      fin(9, sgn, L * 0.085 * lf, L * 0.028 * lf, 0.55 + 0.1 * Math.sin(f.phase * 0.5 + 1.0), 3);
    }
    // Schwanzflosse
    const w0 = wMax * bodyW(1);
    for (let k = 0; k <= NT; k++) {
      const j = NB + k, t = k / NT;
      const sw = 0.55 + 0.45 * Math.abs(Math.cos(f.phase - (1 + t * 0.45) * 4.6));
      bw[k] = w0 + (L * (0.030 + 0.050 * sw) * (f.long ? 1.3 : 1) - w0) * Math.pow(Math.sin(t * Math.PI / 2), 0.9);
      cx5[k] = qx[j]; cy5[k] = qy[j];
    }
    curPart = 1;
    ribbon(cx5, cy5, bw, NT + 1, 0, 1);
    // Körper
    for (let j = 0; j <= NB; j++) bw[j] = wMax * bodyW(j / NB);
    curPart = 0;
    ribbon(qx, qy, bw, NB + 1, 0, 1);
  }

  K.build = function () {
    const order = fish.slice().sort((a, b) => b.depth - a.depth);
    o = 0;
    for (const f of order) meshFish(f);
    return o / STRIDE;
  };
})();
