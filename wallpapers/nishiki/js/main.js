/* Ablauf: Einstellungen aus Wallpaper Engine, Tageszeit, Maus, Musik, Uhr und die Bildschleife. */
(function () {
  'use strict';
  const N = window.Nishiki, U = N.util, P = N.pond, K = N.koi, F = N.flora, A = N.audio;
  const $ = (id) => document.getElementById(id);
  const qs = new URLSearchParams(location.search);

  const WATER_DEFAULT = [0.34, 0.76, 0.80];
  const cfg = {
    timemode: 'auto', water: WATER_DEFAULT.slice(),
    fishcount: 16, fishsize: 1, fishspeed: 1, varieties: 'mixed',
    feed: true, cursorripple: true, curious: true,
    pads: 16, flowers: true, layout: 5,
    floating: 'sakura', floatcount: 22,
    rain: 0, react: 0.6, caustics: 0.8, floordetail: 0.75,
    fireflies: true, moon: true,
    clock: false, clockpos: 'c', timeformat: '24', showdate: true,
    scale: 1, fpsCap: 0,
  };

  /* ================= Tageszeiten ================= */
  const PAL = {
    night: { tint: [0.20, 0.42, 0.74], deep: [0.010, 0.032, 0.085], sun: [0.52, 0.66, 1.00], amb: [0.20, 0.25, 0.36], sky: [0.30, 0.42, 0.72], glint: [0.62, 0.74, 1.0],
      sprite: [0.40, 0.52, 0.74], moonCol: [0.86, 0.92, 1.0], caust: 0.60, fog: 0.88, vig: 0.62, fire: 1, moon: 1, shadow: 0.55, dapple: 0.25, wave: 0.045, gloss: 0.10 },
    dawn: { tint: [0.52, 0.68, 0.84], deep: [0.05, 0.12, 0.23], sun: [1.20, 0.90, 0.86], amb: [0.40, 0.42, 0.50], sky: [1.0, 0.78, 0.80], glint: [1.0, 0.86, 0.84],
      sprite: [0.92, 0.84, 0.88], moonCol: [1, 1, 1], caust: 0.70, fog: 0.72, vig: 0.42, fire: 0.12, moon: 0, shadow: 0.55, dapple: 0.45, wave: 0.05, gloss: 0.22 },
    day: { tint: [0.34, 0.76, 0.80], deep: [0.010, 0.16, 0.23], sun: [1.36, 1.30, 1.12], amb: [0.52, 0.56, 0.56], sky: [0.80, 0.95, 1.0], glint: [1.0, 1.0, 0.94],
      sprite: [1.0, 1.0, 1.0], moonCol: [1, 1, 1], caust: 1.0, fog: 0.78, vig: 0.34, fire: 0, moon: 0, shadow: 0.70, dapple: 0.6, wave: 0.055, gloss: 0.34 },
    gold: { tint: [0.74, 0.68, 0.53], deep: [0.07, 0.095, 0.10], sun: [1.40, 1.05, 0.72], amb: [0.40, 0.38, 0.36], sky: [1.0, 0.62, 0.30], glint: [1.0, 0.80, 0.50],
      sprite: [1.04, 0.90, 0.74], moonCol: [1, 1, 1], caust: 0.80, fog: 0.72, vig: 0.44, fire: 0.10, moon: 0, shadow: 0.70, dapple: 0.6, wave: 0.05, gloss: 0.30 },
  };
  const KEYS = [[0, 'night'], [5, 'night'], [6.6, 'dawn'], [8.6, 'day'], [16.8, 'day'], [18.6, 'gold'], [20.6, 'night'], [24, 'night']];
  const pal = {};
  let hourOverride = qs.has('hour') ? parseFloat(qs.get('hour')) : null;
  function computePalette() {
    let a = PAL.day, b = PAL.day, t = 0;
    const mode = cfg.timemode;
    if (hourOverride === null && mode === 'day') a = b = PAL.day;
    else if (hourOverride === null && mode === 'sunset') a = b = PAL.gold;
    else if (hourOverride === null && mode === 'night') a = b = PAL.night;
    else {
      const d = new Date();
      const h = hourOverride !== null ? hourOverride : d.getHours() + d.getMinutes() / 60 + d.getSeconds() / 3600;
      for (let i = 0; i < KEYS.length - 1; i++) {
        if (h >= KEYS[i][0] && h <= KEYS[i + 1][0]) {
          a = PAL[KEYS[i][1]]; b = PAL[KEYS[i + 1][1]];
          t = U.smooth(0, 1, (h - KEYS[i][0]) / (KEYS[i + 1][0] - KEYS[i][0]));
          break;
        }
      }
    }
    for (const k in a) pal[k] = Array.isArray(a[k]) ? U.mix3(a[k], b[k], t) : U.lerp(a[k], b[k], t);
    // eigene Wasserfarbe: verschiebt den Farbton aller Tageszeiten
    for (let i = 0; i < 3; i++) {
      const ratio = U.clamp(cfg.water[i] / WATER_DEFAULT[i], 0.2, 2.4);
      pal.tint[i] = Math.min(1.15, pal.tint[i] * ratio);
      pal.deep[i] = pal.deep[i] * (0.4 + 0.6 * ratio);
    }
  }

  /* ================= Aufbau ================= */
  const canvas = $('pond');
  let asp = 16 / 9, time = 0, rainAcc = 0, palT = 0, excite = 0;
  const cursor = { x: 0, y: 0, tx: 0, ty: 0, px: 0, py: 0, still: 99, speed: 0, inside: false, acc: 0 };
  const moon = [0, 0, 0.085, 0];

  let warm = true;
  function drop(x, y, r, s) { if (warm) return; P.drop(x, y, r, s); F.push(x, y, Math.abs(s)); }
  const env = { cfg: { size: 1, speed: 1, curious: true, cursorripple: true }, aspect: asp, time: 0, pellets: F.pellets, cursor, drop, excite: 0, fire: 0 };
  function fishCfg() { return { count: cfg.fishcount, varieties: cfg.varieties, seed: cfg.layout }; }

  function applyFish() {
    K.setup(fishCfg(), asp);
    if (K.dirty) { P.uploadFish(K.atlas); K.dirty = false; }
  }
  function applyFlora() {
    F.layout({ pads: cfg.pads, flowers: cfg.flowers, seed: cfg.layout }, asp);
  }
  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.round(window.innerWidth * dpr * cfg.scale), h = Math.round(window.innerHeight * dpr * cfg.scale);
    asp = P.resize(w, h);
    env.aspect = asp;
    moon[0] = asp * 0.70; moon[1] = 0.27;
    applyFlora();
    F.setPetals(cfg.floating, cfg.floatcount, asp);
    F.setFlies(cfg.fireflies ? 18 : 0, asp);
    applyFish();
  }

  /* ================= Einstellungen (Wallpaper Engine) ================= */
  window.wallpaperPropertyListener = {
    applyUserProperties: function (p) {
      const v = (k) => p[k].value;
      let fishChg = false, floraChg = false, petalChg = false;
      if (p.timemode) cfg.timemode = String(v('timemode'));
      if (p.watercolor) { const c = U.parseColor(v('watercolor')); if (c) cfg.water = c; }
      if (p.fishcount) { cfg.fishcount = +v('fishcount') | 0; fishChg = true; }
      if (p.fishsize) cfg.fishsize = (+v('fishsize') || 100) / 100;
      if (p.fishspeed) cfg.fishspeed = (+v('fishspeed') || 100) / 100;
      if (p.varieties) { cfg.varieties = String(v('varieties')); fishChg = true; }
      if (p.feed) cfg.feed = !!v('feed');
      if (p.cursorripple) cfg.cursorripple = !!v('cursorripple');
      if (p.curious) cfg.curious = !!v('curious');
      if (p.pads) { cfg.pads = +v('pads') | 0; floraChg = true; }
      if (p.flowers) { cfg.flowers = !!v('flowers'); floraChg = true; }
      if (p.layout) { cfg.layout = +v('layout') | 0; floraChg = true; fishChg = true; if (P.ready) P.setFloor({ seed: cfg.layout }); }
      if (p.floating) { cfg.floating = String(v('floating')); petalChg = true; }
      if (p.floatcount) { cfg.floatcount = +v('floatcount') | 0; petalChg = true; }
      if (p.rain) cfg.rain = (+v('rain')) / 100;
      if (p.react) cfg.react = (+v('react')) / 100;
      if (p.caustics) cfg.caustics = (+v('caustics')) / 100;
      if (p.floordetail) { cfg.floordetail = (+v('floordetail')) / 100; if (P.ready) P.setFloor({ detail: cfg.floordetail }); }
      if (p.fireflies) { cfg.fireflies = !!v('fireflies'); if (P.ready) F.setFlies(cfg.fireflies ? 18 : 0, asp); }
      if (p.moon) cfg.moon = !!v('moon');
      if (p.clock) cfg.clock = !!v('clock');
      if (p.clockpos) cfg.clockpos = String(v('clockpos'));
      if (p.timeformat) cfg.timeformat = String(v('timeformat'));
      if (p.showdate) cfg.showdate = !!v('showdate');
      if (p.renderscale) { cfg.scale = (+v('renderscale') || 100) / 100; if (P.ready) resize(); }
      if (!P.ready) return;
      if (floraChg) applyFlora();
      if (petalChg) F.setPetals(cfg.floating, cfg.floatcount, asp);
      if (fishChg) applyFish();
      palT = 0;
      updateClock(true);
    },
    applyGeneralProperties: function (p) { if (p.fps) cfg.fpsCap = +p.fps || 0; },
    setPaused: function (x) {
      const was = paused; paused = !!x;
      if (was && !paused && !manual && P.ready) { last = performance.now(); requestAnimationFrame(frame); }
    },
  };

  /* ================= Maus ================= */
  function toPond(e) { return [e.clientX / window.innerWidth * asp, e.clientY / window.innerHeight]; }
  window.addEventListener('mousemove', (e) => { const q = toPond(e); cursor.tx = q[0]; cursor.ty = q[1]; if (!cursor.inside) { cursor.x = cursor.px = q[0]; cursor.y = cursor.py = q[1]; } cursor.inside = true; });
  document.addEventListener('mouseleave', () => { cursor.inside = false; });
  window.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    const q = toPond(e);
    click(q[0], q[1]);
  });
  function click(x, y) {
    drop(x, y, 0.017, 0.42);
    if (cfg.feed) F.feed(x, y, drop);
    K.scare(x, y, cfg.feed ? 0.06 : 0.16);
  }

  /* ================= Uhr ================= */
  const clockEl = $('clock'), timeEl = $('clock-time'), dateEl = $('clock-date');
  let clockKey = '';
  function updateClock(force) {
    clockEl.hidden = !cfg.clock;
    if (!cfg.clock) return;
    const d = new Date();
    const key = d.getHours() + ':' + d.getMinutes() + cfg.timeformat + cfg.clockpos + cfg.showdate;
    if (key === clockKey && !force) return;
    clockKey = key;
    let h = d.getHours(), suffix = '';
    if (cfg.timeformat === '12') { suffix = h < 12 ? ' AM' : ' PM'; h = h % 12 || 12; }
    timeEl.textContent = (cfg.timeformat === '12' ? String(h) : String(h).padStart(2, '0')) + ':' + String(d.getMinutes()).padStart(2, '0');
    timeEl.dataset.suffix = suffix.trim();
    dateEl.hidden = !cfg.showdate;
    try { dateEl.textContent = d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' }); } catch (e) { dateEl.textContent = d.toDateString(); }
    clockEl.className = 'pos-' + cfg.clockpos;
  }

  /* ================= Bildschleife ================= */
  let paused = false, last = 0;
  const manual = qs.has('manual');
  function step(dt) {
    time += dt;
    env.time = time;
    palT -= dt;
    if (palT <= 0) { palT = 5; computePalette(); updateClock(false); }

    // Musik
    A.tick(dt, time);
    const beat = A.takeBeat();
    if (beat > 0 && cfg.react > 0.01) {
      const n = 1 + Math.floor(beat * 2.4 * cfg.react);
      for (let i = 0; i < n; i++) drop(Math.random() * asp, Math.random(), 0.012 + Math.random() * 0.010, (0.16 + 0.34 * beat) * Math.min(1.3, cfg.react * 1.4) * (Math.random() < 0.5 ? 1 : -1));
    }
    excite += ((A.active ? A.level * cfg.react : 0) - excite) * Math.min(1, dt * 1.5);
    env.excite = excite;

    // Regen
    if (cfg.rain > 0.005) {
      rainAcc += cfg.rain * cfg.rain * 34 * asp * dt;
      while (rainAcc > 1) { rainAcc -= 1; drop(Math.random() * asp, Math.random(), 0.008 + Math.random() * 0.006, 0.13 + Math.random() * 0.2); }
    }

    // Maus: Spur aus kleinen Wellen
    const mdx = cursor.tx - cursor.x, mdy = cursor.ty - cursor.y, md = Math.hypot(mdx, mdy);
    cursor.px = cursor.x; cursor.py = cursor.y; cursor.x = cursor.tx; cursor.y = cursor.ty;
    cursor.speed = md / Math.max(dt, 1e-3);
    cursor.still = md > 0.0015 ? 0 : cursor.still + dt;
    if (cfg.cursorripple && cursor.inside && md > 0) {
      cursor.acc += md;
      let n = 0;
      while (cursor.acc > 0.012 && n < 6) {
        cursor.acc -= 0.012; n++;
        const k = 1 - (cursor.acc / Math.max(md, 1e-4)) * 0.5;
        P.drop(cursor.px + mdx * U.clamp(k, 0, 1), cursor.py + mdy * U.clamp(k, 0, 1), 0.012, 0.055 * Math.min(1, 0.4 + cursor.speed * 0.5));
      }
      if (n >= 6) cursor.acc = 0;
    }

    env.cfg.size = cfg.fishsize; env.cfg.speed = cfg.fishspeed; env.cfg.curious = cfg.curious; env.cfg.cursorripple = cfg.cursorripple;
    env.fire = cfg.fireflies ? pal.fire : 0;
    K.update(dt, env);
    F.update(dt, env);
    const fishVerts = K.build();
    const spr = F.build(env);
    moon[3] = cfg.moon ? pal.moon : 0;
    P.render({ time, dt, pal, fishVerts, spr, caustics: cfg.caustics * 1.2, moon });
  }
  function frame(now) {
    if (paused || manual) return;
    requestAnimationFrame(frame);
    if (cfg.fpsCap > 0 && now - last < 1000 / cfg.fpsCap - 1.5) return;
    const dt = Math.min(0.05, Math.max(0.001, (now - last) / 1000));
    last = now;
    step(dt);
  }

  function start() {
    N.art.build();
    let ok = false;
    try { ok = P.init(canvas); } catch (e) { ok = false; if (window.console) console.error(e); }
    if (!ok) { $('nogl').hidden = false; return; }
    P.setFloor({ seed: cfg.layout, detail: cfg.floordetail });
    resize();
    computePalette();
    updateClock(true);
    // ein paar Sekunden vorlaufen lassen, damit die Fische verteilt sind
    for (let i = 0; i < 90; i++) { K.update(1 / 15, env); F.update(1 / 15, env); env.time += 1 / 15; }
    warm = false;
    let rt = 0;
    window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(resize, 150); });
    canvas.addEventListener('webglcontextlost', (e) => { e.preventDefault(); P.ready = false; });
    canvas.addEventListener('webglcontextrestored', () => { try { if (P.init(canvas)) { P.setFloor({}); K.dirty = true; resize(); if (K.atlas) P.uploadFish(K.atlas); } } catch (e) { /* bleibt aus */ } });
    if (qs.get('audio') === 'demo') A.startDemo();
    if (!manual) { last = performance.now(); requestAnimationFrame(frame); }
  }

  /* Zum Testen im Browser: Schritte von Hand, Einstellungen setzen. */
  N.debug = {
    cfg, step: (dt, n) => { for (let i = 0; i < (n || 1); i++) step(dt); },
    set: (o) => { const p = {}; for (const k in o) p[k] = { value: o[k] }; window.wallpaperPropertyListener.applyUserProperties(p); computePalette(); },
    hour: (h) => { hourOverride = h; computePalette(); },
    click, cursor,
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
