/* Himmelsinsel – schwebende Inseln über einem Wolkenmeer, über bis zu 3 Bildschirme.
 *
 * Grundlage sind drei gemalte Bilder (scenes.js, lokal mit Z-Image-Turbo erzeugt, Apache 2.0). Lebendig werden sie
 * durch einen WebGL-Shader und eine 2D-Ebene darüber:
 *   - Tiefe: Die Insel liegt vor dem Himmel (Maske R). Hinter ihr steht eine "Himmelsplatte" (das Bild mit
 *     ausgefülltem Vordergrund), so verschiebt die Maus Insel und Himmel unterschiedlich weit (Parallaxe) und die
 *     Insel kann sanft schweben. Kleine Felsen (und das Luftschiff) schaukeln einzeln (Maske B + Rechtecke).
 *   - Wasserfall (Maske G): fließende Schlieren, Gischt und Nebel am Fuß.
 *   - Wolken: der gemalte Himmel "atmet" langsam, darüber ziehen Nebelschwaden mit dem Wind – über alle
 *     Bildschirme hinweg durchgehend (gerechnet in Panorama-Koordinaten).
 *   - Sonnenstrahlen, Tageszeit nach Uhr (Tag / Abendrot / Nacht mit Sternen, Mond, Sternschnuppen, Glühwürmchen).
 *   - Vogelschwärme fliegen über alle Bildschirme (alle Seiten rechnen mit derselben Uhr, darum passen sie
 *     zusammen). Im Wind treiben Blüten, Blätter oder Löwenzahnsamen; die Maus macht Wind, Klick eine Böe.
 * Schnittstelle wie Wallpaper Engine: wallpaperPropertyListener, wallpaperRegisterAudioListener.
 * Die Bilder stecken als Data-URIs in scenes.js, weil WebKit/WebGL Bilder von file:// nicht verwenden darf.
 */
(function () {
  'use strict';

  const cfg = {
    timemode: 'auto', wind: 0.5, mist: 0.5, rays: 0.6, floating: 'seeds', floatcount: 40, birds: 0.5, fireflies: true,
    stars: true, react: 0.6, parallax: 0.5, float: 0.5, clock: false, hour24: true, scale: 1, fpsCap: 0,
  };
  const MAX_BOB = 8;

  /* Panorama: die App sagt jeder Seite, welcher Bildschirm sie ist (window.kulisseScreen, von links gezählt).
     3+ Bildschirme: links Wolkenmeer, Mitte Insel, rechts Luftschiff (weitere: Insel). 2: links Insel, rechts
     Luftschiff. 1: Insel. Zum Testen: index.html?side=left|center|right&i=0&n=3 */
  const qs = new URLSearchParams(location.search);
  const SCR = window.kulisseScreen || { index: +(qs.get('i') || 0), count: +(qs.get('n') || 1) };
  function pickRole() {
    if (qs.get('side')) return qs.get('side');
    if (SCR.count >= 3) return ['left', 'center', 'right'][SCR.index] || 'center';
    if (SCR.count === 2) return SCR.index === 0 ? 'center' : 'right';
    return 'center';
  }
  const ROLE = pickRole();
  const SC = window.SKY_SCENES[ROLE] || window.SKY_SCENES.center;

  const cv = document.getElementById('c'), fx = document.getElementById('fx'), clockEl = document.getElementById('clock');
  const gl = cv.getContext('webgl2', { alpha: false, antialias: false, premultipliedAlpha: false, powerPreference: 'high-performance' });
  if (!gl) { document.getElementById('nogl').hidden = false; return; }
  const g2 = fx.getContext('2d');

  let img = null, plateImg = null, maskImg = null, IA = 16 / 9, W = 0, H = 0, S = 1;
  let prog, uni = {}, texScene, texPlate, texMask, texStill, stillImg = null;
  let maskData = null, MW = 0, MH = 0;               // Maske auf der CPU (Glühwürmchen, Wasserfall-Gischt)
  const mouse = { x: 0.5, y: 0.5, sx: 0.5, sy: 0.5, px: -1, py: -1, vx: 0, vy: 0, inside: false };
  const audio = { bass: 0, high: 0, active: 0 };
  let time = 0, last = 0, acc = 0, paused = false, gust = 0, windT = 0, grassT = 0;
  let motes = [], flies = [], spray = [], shooting = [], scared = new Map(), gusts = [], streaks = [];

  /* ================= Shader ================= */
  const VS = `#version 300 es
  in vec2 p; out vec2 vUv;
  void main() { vUv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }`;

  const FS = `#version 300 es
  precision highp float;
  in vec2 vUv; out vec4 o;
  uniform sampler2D uScene, uPlate, uMask, uStill;
  uniform vec2 uRes, uImg, uPanF, uPanB, uIsland, uSun;
  uniform float uT, uZoom, uTod, uMist, uRays, uBass, uWind, uGX, uStars, uMoon, uGrass, uWindT, uGrassT;  // *T: aufintegrierte Windwege (Böen ohne Sprung)
  uniform vec4 uBobRect[${MAX_BOB}];    // Rechteck im Bild (u0, v0, u1, v1)
  uniform vec2 uBobOff[${MAX_BOB}];     // aktuelle Verschiebung
  uniform vec3 uFall;                   // Fuß des Wasserfalls (u, v) und Breite

  float h21(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
  float noise(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y); }
  float fbm(vec2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { s += a * noise(p); p = p * 2.03 + vec2(13.1, 7.7); a *= 0.5; } return s; }

  void main() {
    float sa = uRes.x / uRes.y, ia = uImg.x / uImg.y;
    vec2 uv = vUv; uv.y = 1.0 - uv.y;
    vec2 cov = sa > ia ? vec2(1.0, ia / sa) : vec2(sa / ia, 1.0);
    vec2 iuv = (uv - 0.5) * cov / uZoom + 0.5;
    float t = uT;
    float day = max(uTod, 0.0), night = max(-uTod, 0.0), dusk = 1.0 - abs(uTod);

    // --- Himmel (Platte): weiter weg -> wenig Parallaxe, die gemalten Wolken quellen langsam
    vec2 buv = iuv + uPanB;
    float still = texture(uStill, buv).r;                                  // Boden, Mühle: wabern nicht
    // Das Wabern läuft mit dem Wind nach rechts (wie Blüten und Nebel) statt dagegen
    vec2 wob = vec2(fbm(buv * 3.0 + vec2(-uWindT * 0.6, 0.0)), fbm(buv * 3.0 + vec2(5.2 - uWindT * 0.6, t * 0.012))) - 0.5;
    buv += wob * 0.006 * (1.0 - still);
    // Gras im Wind (Maske G außerhalb der Insel): Halme wiegen sich, Böen laufen als Wellen durch
    float gm = texture(uMask, buv).g * (1.0 - texture(uMask, buv).r) * uGrass;
    if (gm > 0.01) {
      float gust = noise(vec2(buv.x * 4.0 - uGrassT, buv.y * 2.0));
      buv.x += (sin(t * 1.9 + buv.y * 55.0 - buv.x * 14.0) * 0.4 + gust - 0.4) * 0.004 * gm * (0.35 + min(uWind, 1.6));
    }
    vec3 col = texture(uPlate, buv).rgb;
    float lum = dot(col, vec3(0.3, 0.55, 0.15));
    float blue = clamp((col.b - col.r) * 2.6 - 0.15, 0.0, 1.0) * (1.0 - still);   // freier blauer Himmel (keine Wolke)
    vec3 solid = col;                                                       // Boden/Mühle: wie die Insel beleuchten
    float cloud = 1.0 - blue;

    // Tageszeit am Himmel: Abendrot färbt die Wolken, nachts Sterne im freien Himmel
    vec3 duskSky = mix(vec3(0.98, 0.62, 0.45), vec3(0.45, 0.42, 0.75), smoothstep(0.75, 0.1, iuv.y));
    vec3 duskCloud = mix(vec3(1.0, 0.72, 0.55), vec3(0.95, 0.55, 0.6), smoothstep(0.2, 0.9, iuv.y)) * (0.55 + 0.6 * lum);
    vec3 duskCol = mix(duskSky * (0.7 + 0.4 * lum), duskCloud, cloud);
    duskCol = mix(duskCol, solid * vec3(1.12, 0.84, 0.72) + vec3(0.04, 0.0, 0.0), still);
    col = mix(col, duskCol, dusk * (1.0 - day) * 0.85 + dusk * day * 0.3);
    vec3 nightCol = mix(vec3(0.03, 0.06, 0.15), vec3(0.16, 0.2, 0.33) * (0.5 + lum), cloud);
    nightCol = mix(nightCol, solid * vec3(0.24, 0.29, 0.5), still);
    col = mix(col, nightCol, night * mix(0.92, 1.0, still));
    if (night > 0.0 && uStars > 0.0) {
      vec2 sp = vec2(uGX + uv.x * sa, uv.y) * 140.0;
      vec2 cell = floor(sp), f = fract(sp) - 0.5;
      float r = h21(cell), tw = 0.6 + 0.4 * sin(t * (1.0 + r * 3.0) + r * 40.0);
      float st = step(0.92, r) * smoothstep(0.12, 0.0, length(f - (vec2(h21(cell + 3.1), h21(cell + 7.7)) - 0.5) * 0.6)) * tw;
      col += vec3(0.95, 0.95, 1.0) * st * blue * night * uStars * (1.0 - smoothstep(0.55, 0.85, iuv.y));
    }
    // Mond (nur auf dem Bildschirm mit Mond)
    if (uMoon > 0.0 && night > 0.0) {
      vec2 md = (uv - vec2(0.82, 0.16)) * vec2(sa, 1.0);
      float mr = length(md), vis = clamp(blue * 1.6 + 0.08, 0.0, 1.0);     // hinter Wolken verschwindet er
      col = mix(col, vec3(1.0, 0.97, 0.86), smoothstep(0.052, 0.048, mr) * night * vis * (1.0 - 0.8 * smoothstep(0.03, 0.06, length(md - vec2(0.022, -0.01)))));
      col += vec3(0.5, 0.55, 0.7) * exp(-mr * 9.0) * 0.35 * night;
    }

    // ferne Nebelschwaden über dem Wolkenmeer (hinter den Inseln), über alle Bildschirme durchgehend
    vec2 gp = vec2(uGX + uv.x * sa, uv.y);
    if (uMist > 0.0) {
      float band = smoothstep(0.45, 0.95, uv.y);
      float m = fbm(gp * vec2(1.4, 4.0) + vec2(-uWindT, t * 0.004)) * 0.7 + fbm(gp * vec2(3.0, 7.0) + vec2(-uWindT * 1.6, 0.0)) * 0.4;
      float d = smoothstep(0.45, 0.85, m) * band * uMist;
      vec3 mc = mix(vec3(1.0, 0.99, 0.96), vec3(1.0, 0.75, 0.62), dusk * (1.0 - day)) * mix(1.0, 0.25, night);
      col = mix(col, mc, d * 0.75);
    }

    // --- schaukelnde Felsen / Luftschiff (Maske B)
    for (int i = 0; i < ${MAX_BOB}; i++) {
      vec4 r = uBobRect[i];
      if (r.z <= r.x) continue;
      vec2 q = iuv + uPanF * 0.85 - uBobOff[i];
      if (q.x < r.x || q.y < r.y || q.x > r.z || q.y > r.w) continue;
      float m = texture(uMask, q).b;
      if (m > 0.0) col = mix(col, texture(uScene, q).rgb * mix(vec3(1.0), vec3(0.24, 0.29, 0.5), night) * mix(vec3(1.0), vec3(1.1, 0.85, 0.75), dusk * (1.0 - day) * 0.6), m);
    }

    // --- die Insel (Maske R) mit Wasserfall (Maske G)
    vec2 fuv = iuv + uPanF - uIsland;
    vec3 mk = texture(uMask, fuv).rgb;
    if (mk.r > 0.0) {
      vec3 ic = texture(uScene, fuv).rgb;
      if (mk.g > 0.0) {
        // Wasser fällt: Schlieren laufen nach unten, unten schneller und breiter
        // Die Zeit darf nur mit einer festen Geschwindigkeit eingehen (nicht mit einer höhenabhängigen, sonst
        // zieht sich das Muster mit der Zeit auseinander und läuft scheinbar nach oben). Schneller nach unten wird
        // es über die Streckung: ly wächst unten langsamer -> dieselbe Phase legt dort mehr Weg zurück.
        float ly = log(fuv.y + 0.3);
        float s1 = noise(vec2(fuv.x * 160.0, ly * 10.0 - t * 2.6));
        float s2 = noise(vec2(fuv.x * 70.0 + 3.0, ly * 5.5 - t * 1.6));
        vec2 ruv = fuv + vec2((s2 - 0.5) * 0.003, 0.0);
        vec3 wc = texture(uScene, ruv + vec2(0.0, (s1 - 0.5) * 0.01)).rgb;
        wc = mix(wc, vec3(0.93, 0.97, 1.0), smoothstep(0.55, 0.9, s1 * 0.7 + s2 * 0.5) * 0.55);
        wc *= 0.9 + 0.12 * s2;
        ic = mix(ic, wc, mk.g);
      }
      // Licht der Tageszeit auf der Insel
      ic = mix(ic, ic * vec3(1.12, 0.84, 0.72) + vec3(0.04, 0.0, 0.0), dusk * (1.0 - day) * 0.75);
      ic = mix(ic, ic * vec3(0.24, 0.29, 0.5), night);
      col = mix(col, ic, mk.r);
    }

    // Nebel / Gischt am Fuß des Wasserfalls
    if (uFall.z > 0.0) {
      vec2 fq = (iuv + uPanF - uIsland - uFall.xy) * vec2(ia, 1.0) / uFall.z;
      float fd = exp(-dot(fq * vec2(0.8, 1.6), fq * vec2(0.8, 1.6)));
      float fm = fbm(fq * 1.5 + vec2(0.0, t * 0.5)) ;
      col = mix(col, vec3(0.95, 0.98, 1.0) * mix(1.0, 0.35, night), clamp(fd * smoothstep(0.3, 0.75, fm) * 0.8, 0.0, 0.8));
    }

    // Sonnenstrahlen (Tag und Abend), pulsieren leicht zur Musik
    if (uRays > 0.0 && night < 1.0) {
      vec2 sd = (uv - uSun) * vec2(sa, 1.0);
      float ang = atan(sd.y, sd.x), dist = length(sd);
      float r = noise(vec2(ang * 7.0, t * 0.06)) * 0.65 + noise(vec2(ang * 15.0 + 4.0, -t * 0.045)) * 0.35;
      float ray = smoothstep(0.35, 1.0, r) * exp(-dist * 1.4) * smoothstep(0.0, 0.25, dist) * (1.0 - night);
      vec3 rc = mix(vec3(1.0, 0.95, 0.8), vec3(1.0, 0.7, 0.45), dusk * (1.0 - day));
      col += rc * ray * uRays * 0.32 * (1.0 + uBass * 0.8);
      col += rc * exp(-dist * 5.0) * 0.18 * uRays * (1.0 - night);
    }

    // Wolkenschleier ganz vorne: selten, dünn, über alles hinweg
    if (uMist > 0.0) {
      float m = fbm(gp * vec2(0.9, 2.2) + vec2(-uWindT * 2.4, 3.0));
      float d = smoothstep(0.62, 0.9, m) * uMist * 0.45;
      col = mix(col, mix(vec3(1.0), vec3(0.4, 0.45, 0.6), night), d);
    }

    vec2 v = vUv - 0.5; col *= 1.0 - dot(v, v) * 0.3;
    o = vec4(max(col, 0.0), 1.0);
  }`;

  function compile(type, src) {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  function makeTex(src, mip) {
    const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, src);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mip ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    if (mip) gl.generateMipmap(gl.TEXTURE_2D);
    return t;
  }

  function setup() {
    prog = gl.createProgram();
    gl.attachShader(prog, compile(gl.VERTEX_SHADER, VS));
    gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, FS));
    gl.bindAttribLocation(prog, 0, 'p');
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    for (const n of ['uScene', 'uPlate', 'uMask', 'uStill', 'uGrass', 'uRes', 'uImg', 'uPanF', 'uPanB', 'uIsland', 'uSun', 'uT', 'uZoom', 'uTod',
      'uMist', 'uRays', 'uBass', 'uWind', 'uWindT', 'uGrassT', 'uGX', 'uStars', 'uMoon', 'uBobRect', 'uBobOff', 'uFall']) uni[n] = gl.getUniformLocation(prog, n);
    const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    texScene = makeTex(img, true);
    texPlate = makeTex(plateImg, true);
    texMask = makeTex(maskImg, false);
    texStill = makeTex(stillImg, false);
    MW = 480; MH = Math.round(480 / IA);
    const c = document.createElement('canvas'); c.width = MW; c.height = MH;
    const g = c.getContext('2d'); g.drawImage(maskImg, 0, 0, MW, MH);
    maskData = g.getImageData(0, 0, MW, MH).data;
  }
  const maskAt = (u, v, ch) => {
    if (!maskData || u < 0 || v < 0 || u >= 1 || v >= 1) return 0;
    return maskData[(((v * MH) | 0) * MW + ((u * MW) | 0)) * 4 + ch] / 255;
  };

  /* ================= Ablauf ================= */
  function resize() {
    const dpr = window.devicePixelRatio || 1;
    W = window.innerWidth; H = window.innerHeight; S = dpr * cfg.scale;
    cv.width = Math.round(W * S); cv.height = Math.round(H * S);
    fx.width = Math.round(W * dpr); fx.height = Math.round(H * dpr);
    g2.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  const zoom = () => 1 + 0.035 * cfg.parallax + 0.012 * cfg.float;
  function cover() { const sa = W / H; return sa > IA ? [1, IA / sa] : [sa / IA, 1]; }
  const panF = () => [(mouse.sx - 0.5) * 0.016 * cfg.parallax, (mouse.sy - 0.5) * 0.01 * cfg.parallax];
  const panB = () => { const p = panF(); return [p[0] * 0.3, p[1] * 0.3]; };
  function island() { return SC.islandBob === false ? [0, 0] : [0, Math.sin(time * 0.45) * 0.006 * cfg.float]; }   // Vordergrund am Bildrand (Baumkronen) schwebt nicht
  function toImg(x, y) { const c = cover(), z = zoom(); return [((x / W) - 0.5) * c[0] / z + 0.5, ((y / H) - 0.5) * c[1] / z + 0.5]; }
  function toScreen(u, v) { const c = cover(), z = zoom(); return [((u - 0.5) * z / c[0] + 0.5) * W, ((v - 0.5) * z / c[1] + 0.5) * H]; }

  // Tageszeit: 1 = Tag (so ist das Bild), 0 = Abendrot, -1 = Nacht
  function tod() {
    if (cfg.timemode === 'day') return 1;
    if (cfg.timemode === 'dusk') return 0;
    if (cfg.timemode === 'night') return -1;
    if (cfg.timemode === 'cycle') {
      const m = (Date.now() / 60000) % 40, ease = (x) => x * x * (3 - 2 * x);
      if (m < 10) return 1;
      if (m < 20) return 1 - 2 * ease((m - 10) / 10);
      if (m < 30) return -1;
      return -1 + 2 * ease((m - 30) / 10);
    }
    const d = new Date(), h = d.getHours() + d.getMinutes() / 60;
    const k = [[0, -1], [5, -1], [6.5, 0], [8.5, 1], [16.5, 1], [18.5, 0], [20.5, -1], [24, -1]];
    for (let i = 1; i < k.length; i++) if (h <= k[i][0]) { const a = k[i - 1], b = k[i]; return a[1] + (b[1] - a[1]) * (h - a[0]) / (b[0] - a[0]); }
    return -1;
  }

  function frame(now) {
    if (paused) return;
    requestAnimationFrame(frame);
    let dt = Math.min(0.1, (now - last) / 1000 || 0);
    if (cfg.fpsCap > 0) { acc += dt; if (acc < 1 / cfg.fpsCap - 0.002) return; dt = acc; acc = 0; }
    last = now;
    step(dt); draw();
  }

  /* ---------- Dinge im Wind: Löwenzahnsamen, Blüten, Blätter ---------- */
  function newMote(x, y, burst) {
    const kind = cfg.floating === 'mix' ? ['seeds', 'sakura', 'maple'][(Math.random() * 3) | 0] : cfg.floating;
    return { x: x ?? -0.05 - Math.random() * 0.1, y: y ?? 0.1 + Math.random() * 0.8, vx: burst ? (Math.random() - 0.3) * 0.25 : 0,
      vy: burst ? (Math.random() - 0.6) * 0.2 : 0, kind, ph: Math.random() * 6.28, rot: Math.random() * 6.28,
      sz: 0.7 + Math.random() * 0.6, z: 0.6 + Math.random() * 0.8, life: burst ? 6 + Math.random() * 4 : 1e9, a: 0 };
  }
  function stepMotes(dt) {
    const want = cfg.floating === 'none' ? 0 : cfg.floatcount;
    let base = motes.filter((m) => m.life > 1e8).length;
    while (base < want) { const m = newMote(Math.random() * 1.1 - 0.05); m.a = 2; motes.push(m); base++; }
    const windX = (0.02 + cfg.wind * 0.07 + gust * 0.25) * (1 + audio.bass * cfg.react * 0.5);
    for (let i = motes.length - 1; i >= 0; i--) {
      const m = motes[i];
      m.a += dt;
      const light = m.kind === 'seeds' ? 1 : m.kind === 'sakura' ? 0.8 : 0.6;
      // Wind + Wirbel, Samen steigen leicht, Blätter sinken
      const tx = windX * m.z * light + Math.sin(time * 0.7 + m.ph) * 0.01;
      const ty = (m.kind === 'seeds' ? -0.004 : 0.012) + Math.cos(time * 0.9 + m.ph * 1.3) * 0.012;
      m.vx += (tx - m.vx) * Math.min(1, dt * 0.8); m.vy += (ty - m.vy) * Math.min(1, dt * 0.8);
      // Maus macht Wind
      if (mouse.inside) {
        const dx = (m.x - mouse.x) * W / H, dy = m.y - mouse.y, d = Math.hypot(dx, dy);
        if (d < 0.12) { const k = (1 - d / 0.12) * dt * 4; m.vx += mouse.vx * k * 0.5; m.vy += mouse.vy * k * 0.5; }
      }
      // Böen vom Klick: die Druckwelle schiebt alles nach außen und mit dem Wind nach rechts
      for (const g of gusts) {
        const dx = (m.x - g.x) * W / H, dy = m.y - g.y, d = Math.hypot(dx, dy) + 1e-4, R = g.a * 0.9;
        const band = Math.max(0, 1 - Math.abs(d - R) / 0.14) * g.k * (1 - g.a / GUST_LIFE);
        if (band > 0) { const f = band * dt * 9 * light; m.vx += (dx / d * 0.7 + 0.5) * f * H / W; m.vy += dy / d * 0.7 * f; m.spin = (m.spin || 0) + band * dt * 18; }
      }
      if (m.spin) { m.rot += m.spin * dt; m.spin *= Math.pow(0.3, dt); }
      m.x += m.vx * dt; m.y += m.vy * dt; m.rot += dt * (m.kind === 'seeds' ? 0.4 : 1.6) * (0.5 + m.z);
      const gone = m.x > 1.08 || m.y < -0.1 || m.y > 1.1 || m.x < -0.25;
      if (m.a > m.life || gone) {
        if (m.life > 1e8 && motes.filter((q) => q.life > 1e8).length <= want) { Object.assign(m, newMote()); }
        else motes.splice(i, 1);
      }
    }
  }

  /* ---------- Windstoß per Klick ----------
     Eine Druckwelle läuft vom Klickpunkt nach außen (schiebt Blüten/Samen), dazu wehen ein paar weiße Windlinien
     nach rechts davon, manche mit einer kleinen Schleife, wie gemalter Wind. */
  const GUST_LIFE = 1.8;
  function blow(x, y) {
    gust = Math.min(2, gust + 0.9);
    gusts.push({ x, y, a: 0, k: 1 });
    if (gusts.length > 6) gusts.shift();
    for (let k = 0; k < 7; k++) {
      streaks.push({ x0: x - 0.04 + Math.random() * 0.05, y0: y + (Math.random() - 0.5) * 0.16, a: -k * 0.05 * Math.random(),
        sp: 0.55 + Math.random() * 0.45, len: 0.12 + Math.random() * 0.14, amp: 0.006 + Math.random() * 0.014, f: 9 + Math.random() * 10,
        ph: Math.random() * 6.28, curl: Math.random() < 0.45 ? 0.12 + Math.random() * 0.25 : -1, r: 0.02 + Math.random() * 0.018,
        w: 1.2 + Math.random() * 1.6, life: 1.5 + Math.random() * 0.7 });
    }
    if (streaks.length > 60) streaks.splice(0, streaks.length - 60);
    // Vögel in der Nähe erschrecken
    const nowS = Date.now() / 1000, ar = W / H;
    for (const fl of flocks(nowS)) for (const b of fl.birds) {
      const lx = b.gx - SCR.index;
      if (Math.hypot((lx - x) * ar, b.y - y) < 0.3) scared.set(b.id, 1);
    }
    // aufwirbelnde Blüten/Samen
    if (cfg.floating !== 'none') for (let k = 0; k < 22; k++) {
      const m = newMote(x + (Math.random() - 0.5) * 0.03, y + (Math.random() - 0.5) * 0.03, true);
      const an = Math.random() * 6.28, v = 0.1 + Math.random() * 0.25;
      m.vx = Math.cos(an) * v * H / W + 0.12; m.vy = Math.sin(an) * v - 0.05; m.spin = (Math.random() - 0.5) * 14;
      motes.push(m);
    }
    if (motes.length > 280) motes.splice(0, motes.length - 280);
  }
  function stepGusts(dt) {
    for (let i = gusts.length - 1; i >= 0; i--) { gusts[i].a += dt; if (gusts[i].a > GUST_LIFE) gusts.splice(i, 1); }
    for (let i = streaks.length - 1; i >= 0; i--) { streaks[i].a += dt; if (streaks[i].a > streaks[i].life) streaks.splice(i, 1); }
  }
  // Punkt auf einer Windlinie bei Bogenlänge s (in Bildschirmhöhen)
  function streakPt(st, s) {
    let x = s, y = Math.sin(s * st.f + st.ph) * st.amp * Math.min(1, s * 8);
    if (st.curl > 0) {
      const L = st.r * 5, th = Math.min(Math.max((s - st.curl) / L, 0), 1) * 6.283;
      x -= st.r * Math.sin(th) * 1.35; y += st.r * (Math.cos(th) - 1);
    }
    return [st.x0 * W + x * H, (st.y0 + y) * H];
  }
  function drawStreaks(night, dusk, day) {
    if (!streaks.length) return;
    const c = night > 0.5 ? [190, 205, 235] : dusk > 0.5 && day < 0.5 ? [255, 236, 220] : [255, 255, 252];
    const peak = 0.6 * (1 - night * 0.55);
    for (const st of streaks) {
      if (st.a <= 0) continue;
      const head = st.a * st.sp, tail = Math.max(0, head - st.len), fade = Math.min(1, st.a / 0.15) * Math.min(1, (st.life - st.a) / 0.5);
      // als ein gefülltes, sich verjüngendes Band zeichnen (keine Einzelstriche, sonst wirkt es gestrichelt)
      const N = 30, pts = [];
      for (let k = 0; k <= N; k++) pts.push(streakPt(st, tail + (head - tail) * k / N));
      const left = [], right = [], wmax = st.w * (H / 1080) * 1.4 + 0.5;
      for (let k = 0; k <= N; k++) {
        const a = pts[Math.max(0, k - 1)], b = pts[Math.min(N, k + 1)];
        let nx = -(b[1] - a[1]), ny = b[0] - a[0]; const l = Math.hypot(nx, ny) || 1; nx /= l; ny /= l;
        const u = k / N, hw = wmax * Math.pow(Math.sin(u * Math.PI), 0.7) * (0.35 + 0.65 * u);
        left.push([pts[k][0] + nx * hw, pts[k][1] + ny * hw]); right.push([pts[k][0] - nx * hw, pts[k][1] - ny * hw]);
      }
      const gr = g2.createLinearGradient(pts[0][0], pts[0][1], pts[N][0], pts[N][1]), col = 'rgba(' + c.join(',') + ',';
      gr.addColorStop(0, col + '0)'); gr.addColorStop(0.55, col + (peak * fade) + ')'); gr.addColorStop(1, col + (peak * fade * 0.8) + ')');
      g2.fillStyle = gr; g2.beginPath(); g2.moveTo(left[0][0], left[0][1]);
      for (const q of left) g2.lineTo(q[0], q[1]);
      for (let k = N; k >= 0; k--) g2.lineTo(right[k][0], right[k][1]);
      g2.closePath(); g2.fill();
    }
  }

  /* ---------- Vogelschwärme über alle Bildschirme ----------
     Jede Seite rechnet aus derselben Uhrzeit, welcher Schwarm gerade wo ist (Panorama-Koordinate gx: 0 = linker Rand des
     linken Bildschirms, count = rechter Rand des rechten). So fliegt ein Schwarm nahtlos von einem Bildschirm zum nächsten. */
  function rng(seed) { let s = (seed * 2654435761) >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }
  const SLOT = 14;                                           // alle 14 s kann ein Schwarm starten
  function flocks(nowS) {
    const out = [], n = Math.max(1, SCR.count);
    if (cfg.birds <= 0) return out;
    const first = Math.floor(nowS / SLOT) - 6;
    for (let s = first; s <= first + 6; s++) {
      const r = rng(s);
      if (r() > 0.25 + cfg.birds * 0.6) continue;
      const dir = r() < 0.65 ? 1 : -1, speed = 0.06 + r() * 0.05, count = 3 + ((r() * (4 + cfg.birds * 10)) | 0);
      const y0 = 0.12 + r() * 0.38, dist = n + 0.6, dur = dist / speed;
      const age = nowS - s * SLOT; if (age < 0 || age > dur) continue;
      const lead = dir > 0 ? -0.3 + age * speed : n + 0.3 - age * speed;
      const birds = [];
      for (let b = 0; b < count; b++) {
        const row = Math.ceil(b / 2), side = b % 2 ? 1 : -1;      // V-Formation, leicht unordentlich
        birds.push({ gx: lead - dir * row * 0.022 + (r() - 0.5) * 0.01, y: y0 + side * row * 0.018 + Math.sin(age * 0.5 + b) * 0.006 + (r() - 0.5) * 0.012,
          ph: r() * 6.28, sz: 0.8 + r() * 0.4, id: s * 100 + b });
      }
      out.push({ dir, birds, scale: 0.75 + r() * 0.5 });
    }
    return out;
  }

  function step(dt) {
    time += dt;
    const ox = mouse.sx, oy = mouse.sy;
    mouse.sx += (mouse.x - mouse.sx) * Math.min(1, dt * 2.5);
    mouse.sy += (mouse.y - mouse.sy) * Math.min(1, dt * 2.5);
    if (mouse.px >= 0) { mouse.vx += ((mouse.x - mouse.px) / Math.max(dt, 1e-3) - mouse.vx) * 0.3; mouse.vy += ((mouse.y - mouse.py) / Math.max(dt, 1e-3) - mouse.vy) * 0.3; }
    mouse.px = mouse.x; mouse.py = mouse.y;
    mouse.vx *= Math.pow(0.1, dt); mouse.vy *= Math.pow(0.1, dt);
    audio.active = Math.max(0, audio.active - dt);
    if (audio.active <= 0) { audio.bass *= 0.9; audio.high *= 0.9; }
    gust *= Math.pow(0.35, dt);
    // Wind nicht als Zeit x Geschwindigkeit, sondern aufsummiert: sonst springen Nebel und Gras bei jeder Böe
    windT += dt * (0.012 + (cfg.wind + gust) * 0.05);
    grassT += dt * (0.4 + cfg.wind + gust * 1.5);
    stepGusts(dt);
    stepMotes(dt);
    // Gischt am Wasserfall
    if (SC.fall && Math.random() < dt * 14) {
      const f = SC.fall; spray.push({ u: f[0] + (Math.random() - 0.5) * f[2] * 0.6, v: f[1] - Math.random() * 0.02, vu: (Math.random() - 0.5) * 0.02, vv: -0.01 - Math.random() * 0.02, a: 0, life: 1 + Math.random() * 1.2 });
    }
    for (let i = spray.length - 1; i >= 0; i--) { const p = spray[i]; p.a += dt; p.u += p.vu * dt; p.v += p.vv * dt; p.vv += 0.015 * dt; if (p.a > p.life) spray.splice(i, 1); }
    // Glühwürmchen nachts im Gras der Insel
    const night = Math.max(0, -tod());
    const wantFlies = cfg.fireflies && SC.fireflies !== false ? Math.round(26 * night) : 0;
    while (flies.length < wantFlies) {
      for (let k = 0; k < 30; k++) {
        const u = Math.random(), v = Math.random();
        if (maskAt(u, v, 0) > 0.5 && maskAt(u, v - 0.05, 0) < 0.5) { flies.push({ u, v: v - Math.random() * 0.05, ph: Math.random() * 6.28, a: 0 }); break; }
        if (k === 29) flies.push({ u: Math.random(), v: 0.3 + Math.random() * 0.4, ph: Math.random() * 6.28, a: 0 });
      }
    }
    while (flies.length > wantFlies) flies.pop();
    for (const f of flies) { f.a += dt; f.u += Math.sin(time * 0.4 + f.ph) * 0.004 * dt; f.v += Math.cos(time * 0.33 + f.ph * 1.7) * 0.004 * dt; }
    // Sternschnuppen
    if (cfg.stars && night > 0.6 && Math.random() < dt * 0.05) shooting.push({ x: 0.1 + Math.random() * 0.8, y: 0.05 + Math.random() * 0.25, a: 0, ang: 0.35 + Math.random() * 0.4, len: 0.1 + Math.random() * 0.1 });
    for (let i = shooting.length - 1; i >= 0; i--) { shooting[i].a += dt; if (shooting[i].a > 1.1) shooting.splice(i, 1); }
  }

  function draw() {
    gl.viewport(0, 0, cv.width, cv.height);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, texScene);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, texPlate);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, texMask);
    gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, texStill);
    gl.uniform1i(uni.uScene, 0); gl.uniform1i(uni.uPlate, 1); gl.uniform1i(uni.uMask, 2); gl.uniform1i(uni.uStill, 3);
    gl.uniform1f(uni.uGrass, SC.grass ? 1 : 0);
    gl.uniform2f(uni.uRes, cv.width, cv.height);
    gl.uniform2f(uni.uImg, img.width, img.height);
    const pf = panF(), pb = panB(), is = island();
    gl.uniform2f(uni.uPanF, pf[0], pf[1]); gl.uniform2f(uni.uPanB, pb[0], pb[1]);
    gl.uniform2f(uni.uIsland, is[0], is[1]);
    gl.uniform2f(uni.uSun, SC.sun ? SC.sun[0] : -0.2, SC.sun ? SC.sun[1] : -0.2);
    gl.uniform1f(uni.uZoom, zoom());
    gl.uniform1f(uni.uT, time);
    gl.uniform1f(uni.uTod, tod());
    gl.uniform1f(uni.uMist, cfg.mist);
    gl.uniform1f(uni.uRays, SC.sun ? cfg.rays : 0);
    gl.uniform1f(uni.uBass, audio.bass * cfg.react);
    gl.uniform1f(uni.uWind, cfg.wind + gust);
    gl.uniform1f(uni.uWindT, windT); gl.uniform1f(uni.uGrassT, grassT);
    gl.uniform1f(uni.uGX, SCR.index * (W / H));          // Panorama: Nebel und Sterne laufen über die Bildschirme durch
    gl.uniform1f(uni.uStars, cfg.stars ? 1 : 0);
    gl.uniform1f(uni.uMoon, SC.moon ? 1 : 0);
    const rects = new Float32Array(MAX_BOB * 4), offs = new Float32Array(MAX_BOB * 2);
    (SC.bobs || []).slice(0, MAX_BOB).forEach((b, i) => {
      const pad = 0.03;
      rects.set([b[0] - pad, b[1] - pad, b[2] + pad, b[3] + pad], i * 4);
      const amp = (b[4] || 0.008) * cfg.float * 2, ph = i * 1.9 + 0.7;
      offs.set([Math.sin(time * 0.21 + ph) * amp * 0.25, Math.sin(time * (0.5 + i * 0.07) + ph) * amp], i * 2);
    });
    gl.uniform4fv(uni.uBobRect, rects); gl.uniform2fv(uni.uBobOff, offs);
    gl.uniform3f(uni.uFall, SC.fall ? SC.fall[0] : 0, SC.fall ? SC.fall[1] : 0, SC.fall ? SC.fall[2] : 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    draw2d();
  }

  function draw2d() {
    g2.clearRect(0, 0, W, H);
    const td = tod(), night = Math.max(0, -td), dusk = 1 - Math.abs(td);
    const px = H * zoom() / cover()[1];
    const pf = panF(), is = island();
    // Gischt
    g2.fillStyle = 'rgba(240,248,255,0.5)';
    for (const p of spray) {
      const s = toScreen(p.u - pf[0] + is[0], p.v - pf[1] + is[1]), k = p.a / p.life;
      g2.globalAlpha = (1 - k) * (1 - night * 0.6) * 0.7;
      g2.beginPath(); g2.arc(s[0], s[1], 1.2 + k * 1.5, 0, 6.28); g2.fill();
    }
    g2.globalAlpha = 1;
    // Vögel
    const nowS = Date.now() / 1000, ar = W / H;
    if (night < 0.85) {
      const col = dusk > 0.5 && td < 0.6 ? 'rgba(40,25,30,' : 'rgba(35,40,55,';
      for (const fl of flocks(nowS)) {
        for (const b of fl.birds) {
          const lx = b.gx - SCR.index;
          if (lx < -0.05 || lx > 1.05) continue;
          let x = lx * W, y = b.y * H;
          // Maus in der Nähe: Vogel weicht nach oben aus
          const sc = scared.get(b.id) || 0;
          const dm = Math.hypot((lx - mouse.x) * ar, b.y - mouse.y);
          const ns = mouse.inside && dm < 0.08 ? Math.min(1, sc + 0.08) : sc * 0.985;
          if (ns > 0.01) scared.set(b.id, ns); else scared.delete(b.id);
          y -= ns * 0.06 * H;
          const s = H * 0.008 * b.sz * fl.scale, fl2 = Math.sin(nowS * 9 * (1 + ns) + b.ph);
          g2.strokeStyle = col + (0.75 * (1 - night)) + ')'; g2.lineWidth = Math.max(1, s * 0.28); g2.lineCap = 'round';
          g2.beginPath();
          g2.moveTo(x - s, y - fl2 * s * 0.7); g2.quadraticCurveTo(x - s * 0.45, y - s * 0.35 - fl2 * s * 0.2, x, y);
          g2.quadraticCurveTo(x + s * 0.45, y - s * 0.35 - fl2 * s * 0.2, x + s, y - fl2 * s * 0.7);
          g2.stroke();
        }
      }
      if (scared.size > 400) scared.clear();
    }
    // Dinge im Wind
    drawStreaks(night, dusk, Math.max(0, td));
    for (const m of motes) {
      const x = m.x * W, y = m.y * H, r = m.sz * m.z * H * 0.006;
      const al = Math.min(1, m.a * 1.2) * (m.life < 1e8 ? Math.min(1, (m.life - m.a) / 1.5) : 1);
      const shade = 1 - night * 0.7;
      g2.save(); g2.translate(x, y); g2.rotate(m.rot); g2.globalAlpha = al * (0.55 + m.z * 0.35);
      if (m.kind === 'seeds') {
        // Löwenzahnschirmchen: feine Strahlen mit Stiel
        g2.strokeStyle = 'rgba(' + (255 * shade | 0) + ',' + (252 * shade | 0) + ',' + (245 * shade | 0) + ',0.9)'; g2.lineWidth = Math.max(0.6, r * 0.12);
        g2.beginPath();
        for (let k = 0; k < 9; k++) { const a = -Math.PI * 0.95 + k * Math.PI * 0.95 / 4; g2.moveTo(0, 0); g2.lineTo(Math.cos(a) * r, Math.sin(a) * r * 0.75); }
        g2.moveTo(0, 0); g2.lineTo(0, r * 1.3); g2.stroke();
      } else if (m.kind === 'sakura') {
        g2.scale(1, 0.55 + 0.45 * Math.abs(Math.cos(m.rot * 1.3)));
        g2.fillStyle = 'rgb(' + (250 * shade | 0) + ',' + (200 * shade | 0) + ',' + (215 * shade | 0) + ')';
        g2.beginPath(); g2.ellipse(0, 0, r * 0.6, r, 0, 0, 6.28); g2.fill();
      } else {
        g2.scale(1, 0.5 + 0.5 * Math.abs(Math.cos(m.rot * 1.1)));
        g2.fillStyle = 'rgb(' + (110 * shade | 0) + ',' + (160 * shade | 0) + ',' + (70 * shade | 0) + ')';
        g2.beginPath(); g2.ellipse(0, 0, r * 0.55, r * 1.15, 0, 0, 6.28); g2.fill();
        g2.strokeStyle = 'rgba(60,90,40,0.6)'; g2.lineWidth = 0.7; g2.beginPath(); g2.moveTo(0, -r); g2.lineTo(0, r * 1.3); g2.stroke();
      }
      g2.restore();
    }
    g2.globalAlpha = 1;
    // Glühwürmchen
    if (flies.length) {
      g2.globalCompositeOperation = 'lighter';
      for (const f of flies) {
        const s = toScreen(f.u - pf[0] + is[0], f.v - pf[1] + is[1]);
        const b = Math.max(0, Math.sin(time * 1.6 + f.ph)) * Math.min(1, f.a) * night, r = px * 0.012;
        const rg = g2.createRadialGradient(s[0], s[1], 0, s[0], s[1], r);
        rg.addColorStop(0, 'rgba(230,255,150,' + (0.9 * b) + ')'); rg.addColorStop(0.2, 'rgba(200,255,110,' + (0.35 * b) + ')'); rg.addColorStop(1, 'rgba(180,255,90,0)');
        g2.fillStyle = rg; g2.fillRect(s[0] - r, s[1] - r, r * 2, r * 2);
      }
      g2.globalCompositeOperation = 'source-over';
    }
    // Sternschnuppen
    for (const s of shooting) {
      const k = s.a / 1.1, x = (s.x + Math.cos(s.ang) * s.len * k * 2) * W, y = (s.y + Math.sin(s.ang) * s.len * k * 2) * H * ar / 1.6;
      const L = s.len * W * 0.6, al = Math.sin(k * Math.PI) * night;
      const gr = g2.createLinearGradient(x, y, x - Math.cos(s.ang) * L, y - Math.sin(s.ang) * L);
      gr.addColorStop(0, 'rgba(255,255,240,' + al + ')'); gr.addColorStop(1, 'rgba(255,255,240,0)');
      g2.strokeStyle = gr; g2.lineWidth = 1.5; g2.beginPath(); g2.moveTo(x, y); g2.lineTo(x - Math.cos(s.ang) * L, y - Math.sin(s.ang) * L); g2.stroke();
    }
    if (cfg.clock) {
      const d = new Date(); let h = d.getHours(); const mm = String(d.getMinutes()).padStart(2, '0');
      if (!cfg.hour24) h = h % 12 || 12;
      const t = (cfg.hour24 ? String(h).padStart(2, '0') : h) + ':' + mm;
      if (clockEl.textContent !== t) clockEl.textContent = t;
    }
    clockEl.hidden = !cfg.clock || SC !== window.SKY_SCENES.center;     // Uhr nur bei der Insel
  }

  /* ================= Musik / Maus ================= */
  if (typeof window.wallpaperRegisterAudioListener === 'function') {
    window.wallpaperRegisterAudioListener(function (a) {
      if (!a || a.length < 128) return;
      let b = 0, h = 0;
      for (let i = 0; i < 6; i++) b += a[i] + a[64 + i];
      for (let i = 34; i < 60; i++) h += a[i] + a[64 + i];
      audio.bass += (Math.min(1.2, b / 12) - audio.bass) * 0.5; audio.high += (Math.min(1.2, h / 52) - audio.high) * 0.3;
      audio.active = 3;
    });
  }
  window.addEventListener('mousemove', (e) => { mouse.x = e.clientX / W; mouse.y = e.clientY / H; if (!mouse.inside) { mouse.px = mouse.x; mouse.py = mouse.y; } mouse.inside = true; });
  document.addEventListener('mouseleave', () => { mouse.inside = false; mouse.px = -1; });
  window.addEventListener('mousedown', (e) => {
    if (e.button !== 0 || !img) return;
    // Klick: ein Windstoß weht von dort los
    blow(e.clientX / W, e.clientY / H);
  });

  /* ================= Wallpaper Engine ================= */
  window.wallpaperPropertyListener = {
    applyUserProperties: function (p) {
      const v = (k) => p[k].value;
      if (p.timemode) cfg.timemode = String(v('timemode'));
      if (p.wind) cfg.wind = (+v('wind')) / 100;
      if (p.mist) cfg.mist = (+v('mist')) / 100;
      if (p.rays) cfg.rays = (+v('rays')) / 100;
      if (p.floating) { const was = cfg.floating; cfg.floating = String(v('floating')); if (was !== cfg.floating) motes = []; }
      if (p.floatcount) cfg.floatcount = Math.min(150, +v('floatcount') | 0);
      if (p.birds) cfg.birds = (+v('birds')) / 100;
      if (p.fireflies) cfg.fireflies = !!v('fireflies');
      if (p.stars) cfg.stars = !!v('stars');
      if (p.react) cfg.react = (+v('react')) / 100;
      if (p.parallax) cfg.parallax = (+v('parallax')) / 100;
      if (p.float) cfg.float = (+v('float')) / 100;
      if (p.clock) cfg.clock = !!v('clock');
      if (p.hour24) cfg.hour24 = !!v('hour24');
      if (p.renderscale) { cfg.scale = (+v('renderscale') || 100) / 100; if (img) resize(); }
    },
    applyGeneralProperties: function (p) { if (p.fps) cfg.fpsCap = +p.fps || 0; },
    setPaused: function (x) { const was = paused; paused = !!x; if (was && !paused && img) { last = performance.now(); requestAnimationFrame(frame); } },
  };

  // Bilder laden (Szene, Himmelsplatte, Maske, feste Teile), dann starten
  let pending = 4;
  const done = () => {
    if (--pending) return;
    IA = img.width / img.height;
    setup(); resize();
    window.addEventListener('resize', resize);
    last = performance.now(); requestAnimationFrame(frame);
  };
  img = new Image(); plateImg = new Image(); maskImg = new Image(); stillImg = new Image();
  for (const [im, src] of [[img, SC.image], [plateImg, SC.plate], [maskImg, SC.mask], [stillImg, SC.still]]) { im.onload = done; im.src = src; }
  // zum Testen: vorspulen
  window.Sky = { step: (dt, n) => { for (let i = 0; i < (n || 1); i++) step(dt); draw(); }, cfg, motes: () => motes, blow };
})();
