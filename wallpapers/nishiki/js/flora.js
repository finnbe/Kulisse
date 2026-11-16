/* Alles, was auf dem Wasser liegt: Seerosenblätter, Blüten, treibende Blütenblätter, Futter, Glühwürmchen. */
(function () {
  'use strict';
  const N = window.Nishiki, U = N.util, TAU = U.TAU, A = N.art;
  const F = N.flora = {};

  const STRIDE = 8, MAXQ = 420;
  F.STRIDE = STRIDE;
  const buf = new Float32Array(MAXQ * 6 * STRIDE);
  F.buffer = buf;

  let pads = [], flowers = [], petals = [], flies = [];
  const pellets = F.pellets = [];
  let o = 0, asp = 1.78;
  const rnd = U.rng(90210);

  function vtx(x, y, u, v, lx, ly, kind, alpha) {
    buf[o++] = x; buf[o++] = y; buf[o++] = u; buf[o++] = v; buf[o++] = lx; buf[o++] = ly; buf[o++] = kind; buf[o++] = alpha;
  }
  function quad(x, y, r, rot, rc, kind, alpha) {
    if (o + 6 * STRIDE > buf.length) return;
    const c = Math.cos(rot), s = Math.sin(rot);
    const ax = -c + s, ay = -s - c, bx = c + s, by = s - c;       // Ecken (-1,-1) und (1,-1), gedreht
    vtx(x + ax * r, y + ay * r, rc.u0, rc.v0, ax, ay, kind, alpha);
    vtx(x + bx * r, y + by * r, rc.u1, rc.v0, bx, by, kind, alpha);
    vtx(x - ax * r, y - ay * r, rc.u1, rc.v1, -ax, -ay, kind, alpha);
    vtx(x + ax * r, y + ay * r, rc.u0, rc.v0, ax, ay, kind, alpha);
    vtx(x - ax * r, y - ay * r, rc.u1, rc.v1, -ax, -ay, kind, alpha);
    vtx(x - bx * r, y - by * r, rc.u0, rc.v1, -bx, -by, kind, alpha);
  }

  /* Blätter in zwei, drei Gruppen an den Rändern, dazu einzelne. */
  F.layout = function (cfg, aspect) {
    asp = aspect;
    const r = U.rng(cfg.seed * 977 + 13);
    pads = []; flowers = [];
    const anchors = [[0.10, 0.17], [0.90, 0.15], [0.88, 0.85], [0.12, 0.83], [0.52, 0.03], [0.50, 0.97], [0.02, 0.50], [0.98, 0.52]];
    for (let i = anchors.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); const t = anchors[i]; anchors[i] = anchors[j]; anchors[j] = t; }
    const nCl = cfg.pads <= 4 ? 1 : cfg.pads <= 10 ? 2 : 3;
    for (let i = 0; i < cfg.pads; i++) {
      let ok = false, x = 0, y = 0, rad = 0.05;
      for (let t = 0; t < 40 && !ok; t++) {
        rad = 0.042 + Math.pow(r(), 1.4) * 0.05;
        if (r() < 0.86) {
          const a = anchors[i % nCl], an = r() * TAU, d = Math.sqrt(r()) * (0.10 + 0.011 * cfg.pads);
          x = a[0] * asp + Math.cos(an) * d * 1.25; y = a[1] + Math.sin(an) * d;
        } else { x = r() * asp; y = r(); }
        ok = true;
        for (const p of pads) if (Math.hypot(p.hx - x, p.hy - y) < (p.r + rad) * 0.88) { ok = false; break; }
      }
      if (!ok) continue;
      pads.push({ x, y, hx: x, hy: y, vx: 0, vy: 0, r: rad, rot: r() * TAU, ph: r() * TAU, variant: Math.floor(r() * 4) });
    }
    if (cfg.flowers) {
      const bySize = pads.map((p, i) => i).sort((a, b) => pads[b].r - pads[a].r);
      const want = Math.max(pads.length >= 2 ? 1 : 0, Math.round(pads.length * 0.36));
      for (let k = 0; k < want; k++) {
        const pi = bySize[k], p = pads[pi], q = r();
        flowers.push({ pad: pi, a: r() * TAU, d: p.r * (0.35 + r() * 0.35), r: 0.044 + r() * 0.022, rot: r() * TAU, ph: r() * TAU, variant: q < 0.56 ? 0 : q < 0.84 ? 1 : 2 });
      }
    }
  };

  function resetPetal(q, entering) {
    q.x = rnd() * asp; q.y = rnd();
    if (entering) { if (rnd() < 0.7) q.x = -0.04; else q.y = -0.04; q.fall = 0; }
    q.vx = 0.010; q.vy = 0.004; q.rot = rnd() * TAU; q.vr = (rnd() - 0.5) * 0.25; q.ph = rnd() * 20;
  }
  F.setPetals = function (type, count, aspect) {
    asp = aspect;
    petals = [];
    if (type === 'none') return;
    for (let i = 0; i < count; i++) {
      const maple = type === 'maple' || (type === 'both' && i % 2 === 1);
      const q = { maple, variant: Math.floor(rnd() * (maple ? 3 : 4)), size: maple ? 0.017 + rnd() * 0.012 : 0.010 + rnd() * 0.007, fall: 0 };
      resetPetal(q, false);
      petals.push(q);
    }
  };
  F.setFlies = function (count, aspect) {
    asp = aspect;
    flies = [];
    for (let i = 0; i < count; i++) {
      flies.push({ cx: rnd() * asp, cy: rnd(), a: 0.03 + rnd() * 0.06, b: 0.03 + rnd() * 0.05, w1: 0.2 + rnd() * 0.35, w2: 0.2 + rnd() * 0.35, ph: rnd() * TAU, bl: 0.5 + rnd() * 0.8, bph: rnd() * TAU, dx: (rnd() - 0.5) * 0.006, dy: (rnd() - 0.5) * 0.006 });
    }
  };

  /* Futter streuen. */
  F.feed = function (x, y, drop) {
    const n = 4 + Math.floor(rnd() * 3);
    for (let i = 0; i < n; i++) {
      const a = rnd() * TAU, d = Math.sqrt(rnd()) * 0.035;
      const p = { x: x + Math.cos(a) * d, y: y + Math.sin(a) * d, vx: Math.cos(a) * 0.02, vy: Math.sin(a) * 0.02, age: -i * 0.05, eaten: false };
      pellets.push(p);
      drop(p.x, p.y, 0.008, 0.10);
    }
    while (pellets.length > 60) pellets.shift();
  };

  /* Eine Welle schiebt Blätter und Blütenblätter sanft an. */
  F.push = function (x, y, s) {
    if (s < 0.08) return;
    for (const p of pads) {
      const dx = p.x - x, dy = p.y - y, d = Math.hypot(dx, dy);
      if (d < 0.3) { const k = s * 0.010 / (d + 0.06); p.vx += dx / (d || 1) * k; p.vy += dy / (d || 1) * k; }
    }
    for (const q of petals) {
      const dx = q.x - x, dy = q.y - y, d = Math.hypot(dx, dy);
      if (d < 0.2) { const k = s * 0.012 / (d + 0.04); q.vx += dx / (d || 1) * k; q.vy += dy / (d || 1) * k; q.vr += (rnd() - 0.5) * s; }
    }
  };

  F.update = function (dt, env) {
    const t = env.time;
    asp = env.aspect;
    for (const p of pads) {
      p.vx += ((p.hx - p.x) * 1.1 - p.vx * 1.4) * dt; p.vy += ((p.hy - p.y) * 1.1 - p.vy * 1.4) * dt;
      p.x += p.vx * dt; p.y += p.vy * dt;
    }
    for (const q of petals) {
      if (q.fall > 0) {
        q.fall -= dt / 1.3;
        if (q.fall <= 0) { q.fall = 0; env.drop(q.x, q.y, 0.009, 0.10); }
        continue;
      }
      const a = Math.sin(q.x * 3.1 + t * 0.07 + q.ph) * 1.2 + Math.cos(q.y * 4.3 - t * 0.05 + q.ph) * 1.2;
      q.vx += (0.010 + Math.cos(a) * 0.005 - q.vx) * Math.min(1, dt * 0.7);
      q.vy += (0.004 + Math.sin(a) * 0.005 - q.vy) * Math.min(1, dt * 0.7);
      q.vr += ((q.variant - 1.5) * 0.05 - q.vr) * Math.min(1, dt * 0.4);
      q.x += q.vx * dt; q.y += q.vy * dt; q.rot += q.vr * dt;
      if (q.x > asp + 0.05 || q.y > 1.05 || q.x < -0.06 || q.y < -0.06) {
        const falling = rnd() < 0.5;
        resetPetal(q, !falling);
        if (falling) q.fall = 1;
      }
    }
    for (let i = pellets.length - 1; i >= 0; i--) {
      const p = pellets[i];
      p.age += dt;
      p.vx *= Math.pow(0.1, dt); p.vy *= Math.pow(0.1, dt);
      p.x += p.vx * dt + 0.004 * dt; p.y += p.vy * dt + 0.002 * dt;
      if (p.eaten || p.age > 32) pellets.splice(i, 1);
    }
    for (const f of flies) {
      f.cx += f.dx * dt; f.cy += f.dy * dt;
      if (f.cx < 0.05 || f.cx > asp - 0.05) f.dx = -f.dx;
      if (f.cy < 0.05 || f.cy > 0.95) f.dy = -f.dy;
    }
  };

  /* Ecken-Daten bauen. Reihenfolge: Blütenblätter, Blätter, Blüten (werfen Schatten), Futter, Glühwürmchen. */
  F.build = function (env) {
    const t = env.time, R = A.rects;
    o = 0;
    for (const q of petals) {
      const k = q.fall;
      quad(q.x - k * 0.02, q.y - k * 0.035, q.size * (1 + k * 0.9), q.rot + k * 2.5, (q.maple ? R.maple : R.sakura)[q.variant], 2, 1 - k);
    }
    for (const p of pads) quad(p.x, p.y, p.r * (1 + 0.012 * Math.sin(t * 0.6 + p.ph)), p.rot + Math.sin(t * 0.13 + p.ph) * 0.05, R.pad[p.variant], 0, 1);
    for (const f of flowers) {
      const p = pads[f.pad]; if (!p) continue;
      quad(p.x + Math.cos(f.a) * f.d, p.y + Math.sin(f.a) * f.d, f.r * 1.14 * (1 + 0.015 * Math.sin(t * 0.5 + f.ph)), f.rot + Math.sin(t * 0.11 + f.ph) * 0.04, R.flower[f.variant], 1, 1);
    }
    const nShadow = o / STRIDE;
    for (const p of pellets) {
      if (p.age < 0) continue;
      quad(p.x, p.y, 0.0058, 0, R.pellet, 3, Math.min(1, p.age * 6) * (1 - U.smooth(26, 32, p.age)));
    }
    const nSurface = o / STRIDE;
    if (env.fire > 0.01) {
      for (const f of flies) {
        const x = f.cx + Math.sin(t * f.w1 + f.ph) * f.a + Math.sin(t * f.w1 * 0.37 + f.ph * 2) * f.a * 0.6;
        const y = f.cy + Math.cos(t * f.w2 + f.ph * 1.3) * f.b + Math.sin(t * f.w2 * 0.41 + f.ph) * f.b * 0.6;
        const b = Math.pow(Math.max(0, Math.sin(t * f.bl + f.bph)), 2) * env.fire;
        if (b < 0.01) continue;
        quad(x, y, 0.055, 0, R.glow, 4, b * 0.30);
        quad(x, y, 0.014, 0, R.glow, 4, b);
      }
    }
    return { nShadow, nSurface, nTotal: o / STRIDE };
  };
})();
