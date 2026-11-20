/* Raumstation – eine alte, gemütliche Raumstation über einem Planeten, über bis zu 3 Bildschirme.
 *
 * Grundlage sind drei gemalte Bilder (scenes.js, lokal mit Z-Image-Turbo erzeugt, Apache 2.0). Lebendig werden sie
 * durch einen WebGL-Shader und eine 2D-Ebene darüber:
 *   - Tiefe: Die Station liegt vor dem All (Maske R), dahinter eine "Platte" (Bild mit ausgefülltem Vordergrund).
 *     So verschiebt die Maus Station und All unterschiedlich weit (Parallaxe), die Station schwebt und dreht sich
 *     ganz leicht. Kleinere Teile (Schiffe, Module) schweben einzeln (Maske B + Rechtecke).
 *   - Fenster der Station flackern warm, Positionslichter blinken (links rot, rechts grün, oben weiß).
 *   - Planet (Maske G): die Wolken ziehen langsam, der Rand der Atmosphäre leuchtet.
 *   - Die gemalten Sterne funkeln, ein Nebel zieht ganz langsam – über alle Bildschirme hinweg durchgehend.
 *   - Kleine Raumfähren fliegen über alle Bildschirme (alle Seiten rechnen mit derselben Uhr), Sternschnuppen,
 *     Sternenstaub. Klick: eine Fähre startet von dort. Sonnenlicht und Fenster pulsieren zur Musik.
 * Schnittstelle wie Wallpaper Engine: wallpaperPropertyListener, wallpaperRegisterAudioListener.
 * Die Bilder stecken als Data-URIs in scenes.js, weil WebKit/WebGL Bilder von file:// nicht verwenden darf.
 */
(function () {
  'use strict';

  const cfg = {
    ships: 0.5, dust: 40, nebula: 0.5, twinkle: true, lights: true, glare: 0.6, planet: 0.5, meteors: true,
    react: 0.6, parallax: 0.5, float: 0.5, clock: false, hour24: true, scale: 1, fpsCap: 0,
  };
  const MAX_BOB = 8;

  /* Panorama: die App sagt jeder Seite, welcher Bildschirm sie ist (window.kulisseScreen, von links gezählt).
     3+ Bildschirme: links Planet mit Sonnenaufgang, Mitte Station, rechts Schiff am Andockmodul. 2: links Station,
     rechts Schiff. 1: Station. Zum Testen: index.html?side=left|center|right&i=0&n=3 */
  const qs = new URLSearchParams(location.search);
  const SCR = window.kulisseScreen || { index: +(qs.get('i') || 0), count: +(qs.get('n') || 1) };
  function pickRole() {
    if (qs.get('side')) return qs.get('side');
    if (SCR.count >= 3) return ['left', 'center', 'right'][SCR.index] || 'center';
    if (SCR.count === 2) return SCR.index === 0 ? 'center' : 'right';
    return 'center';
  }
  const ROLE = pickRole();
  const SC = window.STATION_SCENES[ROLE] || window.STATION_SCENES.center;

  const cv = document.getElementById('c'), fx = document.getElementById('fx'), clockEl = document.getElementById('clock');
  const gl = cv.getContext('webgl2', { alpha: false, antialias: false, premultipliedAlpha: false, powerPreference: 'high-performance' });
  if (!gl) { document.getElementById('nogl').hidden = false; return; }
  const g2 = fx.getContext('2d');

  let img = null, plateImg = null, maskImg = null, IA = 16 / 9, W = 0, H = 0, S = 1;
  let prog, uni = {}, texScene, texPlate, texMask, maskData = null, MW = 0, MH = 0;
  const mouse = { x: 0.5, y: 0.5, sx: 0.5, sy: 0.5, inside: false };
  const audio = { bass: 0, high: 0, active: 0 };
  let time = 0, last = 0, acc = 0, paused = false, flowT = 0;
  let dust = [], shooting = [], launches = [];

  /* ================= Shader ================= */
  const VS = `#version 300 es
  in vec2 p; out vec2 vUv;
  void main() { vUv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }`;

  const FS = `#version 300 es
  precision highp float;
  in vec2 vUv; out vec4 o;
  uniform sampler2D uScene, uPlate, uMask;
  uniform vec2 uRes, uImg, uPanF, uPanB, uStation, uSun, uPivot;
  uniform float uT, uZoom, uBass, uHigh, uGX, uTwinkle, uNebula, uGlare, uPlanet, uFlow, uLights, uRot;
  uniform vec3 uHz;                     // Horizont des Planeten: v = a u^2 + b u + c (Bildkoordinaten)
  uniform vec4 uBobRect[${MAX_BOB}];
  uniform vec2 uBobOff[${MAX_BOB}];

  float h21(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
  float noise(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y); }
  float fbm(vec2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { s += a * noise(p); p = p * 2.03 + vec2(13.1, 7.7); a *= 0.5; } return s; }
  float lumf(vec3 c) { return dot(c, vec3(0.3, 0.55, 0.15)); }

  void main() {
    float sa = uRes.x / uRes.y, ia = uImg.x / uImg.y;
    vec2 uv = vUv; uv.y = 1.0 - uv.y;
    vec2 cov = sa > ia ? vec2(1.0, ia / sa) : vec2(sa / ia, 1.0);
    vec2 iuv = (uv - 0.5) * cov / uZoom + 0.5;
    float t = uT;

    // --- All und Planet (Platte), weit weg -> wenig Parallaxe
    vec2 buv = iuv + uPanB;
    float pm = texture(uMask, buv).g;
    if (pm > 0.01 && uPlanet > 0.0) {
      // Wolken auf dem Planeten ziehen: Verschiebung, deren Muster langsam wandert (aufintegriert, kein Springen)
      vec2 q = buv * vec2(ia, 1.0);
      vec2 d = vec2(fbm(q * 5.0 + vec2(-uFlow, 0.0)), fbm(q * 5.0 + vec2(4.3 - uFlow, 1.7))) - 0.5;
      buv += d * 0.007 * pm * uPlanet;
    }
    vec3 col = texture(uPlate, buv).rgb;
    float lum = lumf(col);
    float space = (1.0 - smoothstep(0.12, 0.3, lum)) * (1.0 - pm);          // dunkles All (dort Sterne und Nebel)
    if (pm > 0.01 && uPlanet > 0.0) {
      // Wolkenschatten und Lichtflecken wandern mit
      float cs = fbm(buv * vec2(ia, 1.0) * 3.0 + vec2(-uFlow * 0.7, 0.3));
      col *= 1.0 + (cs - 0.5) * 0.12 * pm * uPlanet;
      // Atmosphärensaum: am Horizont ein weiches Leuchten, atmet zur Musik
      float hv = uHz.x * buv.x * buv.x + uHz.y * buv.x + uHz.z;
      float dh = buv.y - hv;
      col += vec3(0.45, 0.75, 1.0) * exp(-abs(dh) * 90.0) * (0.12 + 0.1 * uBass) * uPlanet * (1.0 - texture(uMask, buv).r);
    }
    // Funkeln der gemalten Sterne: helle Punkte über ihrer weichgezeichneten Umgebung
    if (uTwinkle > 0.0) {
      vec3 blur = textureLod(uPlate, buv, 4.0).rgb;
      float pk = clamp((lum - lumf(blur)) * 4.0, 0.0, 1.0) * (1.0 - pm) * (1.0 - smoothstep(0.1, 0.22, lumf(blur)));   // nur Punkte im dunklen All, nicht Kanten heller Dinge
      vec2 cell = floor(buv * uImg / 3.0);
      float r = h21(cell);
      float tw = 0.5 + 0.5 * sin(t * (1.2 + r * 3.5) + r * 60.0);
      col = mix(col, col * (0.35 + 1.15 * tw) + vec3(0.06, 0.06, 0.08) * tw * uHigh, pk);
      // zusätzliche winzige Sterne im ganz dunklen All, durchgehend über alle Bildschirme
      vec2 sp = vec2(uGX + uv.x * sa, uv.y) * 220.0 + uPanB * 60.0;
      vec2 c2 = floor(sp), f2 = fract(sp) - 0.5;
      float r2 = h21(c2 + 17.0);
      float st = step(0.965, r2) * smoothstep(0.1, 0.0, length(f2 - (vec2(h21(c2 + 3.1), h21(c2 + 7.7)) - 0.5) * 0.6));
      col += vec3(0.9, 0.93, 1.0) * st * (0.4 + 0.6 * sin(t * (0.8 + r2 * 2.0) + r2 * 30.0)) * space * 0.8;
    }
    // Nebel: ganz langsam ziehende Schleier in Petrol und Ocker, nur im dunklen All
    if (uNebula > 0.0) {
      vec2 gp = vec2(uGX + uv.x * sa, uv.y) + uPanB * 2.0;
      float n1 = fbm(gp * vec2(1.3, 1.8) + vec2(t * 0.006, -t * 0.003));
      float n2 = fbm(gp * 2.6 + vec2(-t * 0.004, 5.0) + n1);
      vec3 nc = mix(vec3(0.15, 0.42, 0.48), vec3(0.62, 0.45, 0.22), smoothstep(0.35, 0.7, n2));
      col += nc * smoothstep(0.45, 0.85, n1 * 0.6 + n2 * 0.5) * 0.22 * uNebula * space;
    }

    // --- schwebende Teile (Maske B)
    for (int i = 0; i < ${MAX_BOB}; i++) {
      vec4 r = uBobRect[i];
      if (r.z <= r.x) continue;
      vec2 q = iuv + uPanF * 0.85 - uBobOff[i];
      if (q.x < r.x || q.y < r.y || q.x > r.z || q.y > r.w) continue;
      float m = texture(uMask, q).b;
      if (m > 0.0) col = mix(col, texture(uScene, q).rgb, m);
    }

    // --- die Station (Maske R): schwebt, dreht sich ganz leicht um ihren Schwerpunkt
    vec2 fuv = iuv + uPanF - uStation;
    vec2 pr = (fuv - uPivot) * vec2(ia, 1.0);
    float cr = cos(uRot), sr = sin(uRot);
    fuv = uPivot + vec2(cr * pr.x - sr * pr.y, sr * pr.x + cr * pr.y) / vec2(ia, 1.0);
    float mr = texture(uMask, fuv).r;
    if (mr > 0.0) {
      vec3 sc = texture(uScene, fuv).rgb;
      // warme Fenster: helle gelb-orange Pixel flackern einzeln (Zellen), zur Musik heller
      if (uLights > 0.0) {
        // nur kräftig gelb-orange (Fensterglas), nicht der cremefarbene Rumpf
        float warm = smoothstep(0.6, 0.85, sc.r) * smoothstep(0.3, 0.45, sc.r - sc.b) * smoothstep(0.12, 0.25, sc.g - sc.b);
        if (warm > 0.0) {
          // weiches Flackern (räumlich glatt, damit keine Pixelblöcke entstehen), hin und wieder geht ein Licht aus
          vec2 wp = fuv * uImg / 45.0;
          float fl = noise(wp + vec2(t * 0.35, -t * 0.2)) * 0.6 + noise(wp * 2.3 - vec2(t * 0.9, 0.0)) * 0.4;
          float off = smoothstep(0.78, 0.86, noise(wp * 0.5 + vec2(17.0, t * 0.04)));
          float k = mix(0.8, 1.25, fl) * (1.0 - off * 0.55);
          sc = mix(sc, sc * k * (1.0 + uBass * 0.35) + vec3(0.08, 0.05, 0.0) * uBass, warm * uLights);
        }
      }
      col = mix(col, sc, mr);
    }

    // --- Sonne: weiches Leuchten, Strahlen und ein paar Linsenreflexe
    if (uGlare > 0.0) {
      vec2 sd = (uv - uSun) * vec2(sa, 1.0);
      float ang = atan(sd.y, sd.x), dist = length(sd);
      float rays = noise(vec2(ang * 9.0, t * 0.05)) * 0.6 + noise(vec2(ang * 23.0 + 4.0, -t * 0.04)) * 0.4;
      vec3 sunc = vec3(1.0, 0.92, 0.75);
      col += sunc * exp(-dist * 7.0) * 0.55 * uGlare * (1.0 + uBass * 0.5);
      col += sunc * smoothstep(0.45, 1.0, rays) * exp(-dist * 2.2) * 0.22 * uGlare * (1.0 + uBass * 0.8);
      // Reflexe auf der Linie Sonne -> Bildmitte
      vec2 axis = (vec2(0.5) - uSun);
      for (int k = 1; k <= 3; k++) {
        float fk = float(k);
        vec2 gp = uSun + axis * (0.6 + fk * 0.45);
        float gd = length((uv - gp) * vec2(sa, 1.0));
        float rad = 0.02 + fk * 0.018;
        col += mix(vec3(0.4, 0.8, 0.9), vec3(1.0, 0.75, 0.45), fk / 3.0) * smoothstep(rad, rad * 0.7, gd) * 0.05 * uGlare;
      }
    }

    vec2 v = vUv - 0.5; col *= 1.0 - dot(v, v) * 0.35;
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
    for (const n of ['uScene', 'uPlate', 'uMask', 'uRes', 'uImg', 'uPanF', 'uPanB', 'uStation', 'uSun', 'uPivot', 'uT', 'uZoom', 'uBass',
      'uHigh', 'uGX', 'uTwinkle', 'uNebula', 'uGlare', 'uPlanet', 'uFlow', 'uLights', 'uRot', 'uHz', 'uBobRect', 'uBobOff']) uni[n] = gl.getUniformLocation(prog, n);
    const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    texScene = makeTex(img, true);
    texPlate = makeTex(plateImg, true);
    texMask = makeTex(maskImg, false);
    MW = 480; MH = Math.round(480 / IA);
    const c = document.createElement('canvas'); c.width = MW; c.height = MH;
    const g = c.getContext('2d'); g.drawImage(maskImg, 0, 0, MW, MH);
    maskData = g.getImageData(0, 0, MW, MH).data;
  }
  // Vordergrund (Station/Schiffe) an einer Bildschirmstelle? Ferne Fähren fliegen dahinter vorbei.
  function fgAt(x, y) {
    const c = cover(), z = zoom(), pf = panF();
    const u = ((x / W) - 0.5) * c[0] / z + 0.5 + pf[0], v = ((y / H) - 0.5) * c[1] / z + 0.5 + pf[1];
    if (!maskData || u < 0 || v < 0 || u >= 1 || v >= 1) return 0;
    const i = (((v * MH) | 0) * MW + ((u * MW) | 0)) * 4;
    return Math.max(maskData[i], maskData[i + 2]) / 255;
  }

  /* ================= Ablauf ================= */
  function resize() {
    const dpr = window.devicePixelRatio || 1;
    W = window.innerWidth; H = window.innerHeight; S = dpr * cfg.scale;
    cv.width = Math.round(W * S); cv.height = Math.round(H * S);
    fx.width = Math.round(W * dpr); fx.height = Math.round(H * dpr);
    g2.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  const zoom = () => 1 + 0.035 * cfg.parallax + 0.015 * cfg.float;
  function cover() { const sa = W / H; return sa > IA ? [1, IA / sa] : [sa / IA, 1]; }
  const panF = () => [(mouse.sx - 0.5) * 0.016 * cfg.parallax, (mouse.sy - 0.5) * 0.01 * cfg.parallax];
  const panB = () => { const p = panF(); return [p[0] * 0.25, p[1] * 0.25]; };
  function station() { return SC.stationBob === false ? [0, 0] : [Math.sin(time * 0.13) * 0.002 * cfg.float, Math.sin(time * 0.31) * 0.006 * cfg.float]; }
  const rot = () => (SC.turn === false ? 0 : Math.sin(time * 0.09) * 0.006 * cfg.float);
  function toScreen(u, v) { const c = cover(), z = zoom(); return [((u - 0.5) * z / c[0] + 0.5) * W, ((v - 0.5) * z / c[1] + 0.5) * H]; }
  // Punkt auf der Station (Bildkoordinaten) -> Bildschirm, mit Schweben und Drehung
  function stationPt(u, v) {
    const pv = SC.pivot, r = -rot(), dx = (u - pv[0]) * IA, dy = v - pv[1];
    const ru = pv[0] + (Math.cos(r) * dx - Math.sin(r) * dy) / IA, rv = pv[1] + Math.sin(r) * dx + Math.cos(r) * dy;
    const pf = panF(), st = station();
    return toScreen(ru - pf[0] + st[0], rv - pf[1] + st[1]);
  }

  function frame(now) {
    if (paused) return;
    requestAnimationFrame(frame);
    let dt = Math.min(0.1, (now - last) / 1000 || 0);
    if (cfg.fpsCap > 0) { acc += dt; if (acc < 1 / cfg.fpsCap - 0.002) return; dt = acc; acc = 0; }
    last = now;
    step(dt); draw();
  }

  /* ---------- Sternenstaub ---------- */
  function newDust(x) {
    return { x: x ?? -0.03, y: Math.random(), z: 0.3 + Math.random() * 0.9, ph: Math.random() * 6.28, a: 0 };
  }
  function stepDust(dt) {
    while (dust.length < cfg.dust) { const d = newDust(Math.random()); d.a = Math.random(); dust.push(d); }
    while (dust.length > cfg.dust) dust.pop();
    for (const d of dust) {
      d.a += dt;
      d.x += (0.004 + d.z * 0.008) * dt; d.y += Math.sin(time * 0.2 + d.ph) * 0.002 * dt;
      if (d.x > 1.03) Object.assign(d, newDust());
    }
  }

  /* ---------- Raumfähren über alle Bildschirme ----------
     Jede Seite rechnet aus derselben Uhrzeit, welche Fähre gerade wo ist (Panorama-Koordinate gx: 0 = linker Rand des
     linken Bildschirms, count = rechter Rand des rechten). So fliegt eine Fähre nahtlos von einem Bildschirm zum nächsten. */
  function rng(seed) { let s = (seed * 2654435761) >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }
  const SLOT = 11;
  function ships(nowS) {
    const out = [], n = Math.max(1, SCR.count);
    if (cfg.ships <= 0) return out;
    const first = Math.floor(nowS / SLOT) - 12;
    for (let s = first; s <= first + 12; s++) {
      const r = rng(s * 7 + 3);
      if (r() > 0.15 + cfg.ships * 0.6) continue;
      const dir = r() < 0.55 ? 1 : -1, near = r(), speed = 0.025 + near * 0.05 + r() * 0.02;
      const y0 = 0.08 + r() * 0.62, tilt = (r() - 0.5) * 0.12, dist = n + 0.4, dur = dist / speed;
      const age = nowS - s * SLOT; if (age < 0 || age > dur) continue;
      const gx = dir > 0 ? -0.2 + age * speed : n + 0.2 - age * speed;
      out.push({ gx, y: y0 + tilt * (gx / n) + Math.sin(age * 0.3 + s) * 0.004, dir, size: 0.5 + near * 1.1, kind: (r() * 3) | 0, id: s, ph: r() * 6.28 });
    }
    return out;
  }
  // kleine, rundliche Fähre in Creme und Petrol, Triebwerk glüht, Abgasschweif
  function drawShip(x, y, dir, size, kind, ph, glowK) {
    const s = H * 0.017 * size;
    g2.save(); g2.translate(x, y); g2.scale(dir, 1);
    // Schweif
    const tl = s * (5 + glowK * 4);
    const tg = g2.createLinearGradient(-s * 1.2, 0, -s * 1.2 - tl, 0);
    tg.addColorStop(0, 'rgba(255,200,120,' + (0.55 * glowK) + ')'); tg.addColorStop(1, 'rgba(120,200,230,0)');
    g2.fillStyle = tg; g2.beginPath(); g2.moveTo(-s * 1.1, -s * 0.22); g2.lineTo(-s * 1.2 - tl, 0); g2.lineTo(-s * 1.1, s * 0.22); g2.fill();
    // Triebwerksglühen
    const fl = 0.75 + 0.25 * Math.sin(time * 23 + ph);
    const gr = g2.createRadialGradient(-s * 1.15, 0, 0, -s * 1.15, 0, s * 0.9);
    gr.addColorStop(0, 'rgba(255,235,180,' + (0.95 * fl * glowK) + ')'); gr.addColorStop(1, 'rgba(255,160,80,0)');
    g2.fillStyle = gr; g2.fillRect(-s * 2.1, -s, s * 2, s * 2);
    // Rumpf (von links oben beleuchtet)
    const body = g2.createLinearGradient(0, -s * 0.6, 0, s * 0.6);
    body.addColorStop(0, '#f1e3c4'); body.addColorStop(0.55, '#cdb68c'); body.addColorStop(1, '#7d6a52');
    g2.fillStyle = body;
    g2.beginPath();
    if (kind === 0) { g2.ellipse(0, 0, s * 1.2, s * 0.48, 0, 0, 6.28); }
    else if (kind === 1) { g2.moveTo(-s * 1.1, -s * 0.4); g2.quadraticCurveTo(s * 0.4, -s * 0.7, s * 1.3, 0); g2.quadraticCurveTo(s * 0.4, s * 0.6, -s * 1.1, s * 0.4); g2.closePath(); }
    else { g2.ellipse(0, 0, s * 0.9, s * 0.55, 0, 0, 6.28); }
    g2.fill();
    // Flossen
    g2.fillStyle = '#3f7d80';
    g2.beginPath(); g2.moveTo(-s * 0.6, -s * 0.3); g2.lineTo(-s * 1.1, -s * 0.85); g2.lineTo(-s * 0.2, -s * 0.38); g2.fill();
    g2.beginPath(); g2.moveTo(-s * 0.6, s * 0.3); g2.lineTo(-s * 1.1, s * 0.8); g2.lineTo(-s * 0.2, s * 0.36); g2.fill();
    // Fenster
    g2.fillStyle = '#ffd98a'; g2.beginPath(); g2.arc(s * 0.45, -s * 0.08, s * 0.16, 0, 6.28); g2.fill();
    if (kind !== 2) { g2.beginPath(); g2.arc(s * 0.0, -s * 0.06, s * 0.12, 0, 6.28); g2.fill(); }
    // Blinklicht
    if (Math.sin(time * 3 + ph) > 0.85) { g2.fillStyle = 'rgba(255,90,80,0.95)'; g2.beginPath(); g2.arc(-s * 1.05, -s * 0.8, Math.max(1, s * 0.09), 0, 6.28); g2.fill(); }
    g2.restore();
  }

  function step(dt) {
    time += dt;
    mouse.sx += (mouse.x - mouse.sx) * Math.min(1, dt * 2.5);
    mouse.sy += (mouse.y - mouse.sy) * Math.min(1, dt * 2.5);
    audio.active = Math.max(0, audio.active - dt);
    if (audio.active <= 0) { audio.bass *= 0.9; audio.high *= 0.9; }
    flowT += dt * 0.012 * (0.4 + cfg.planet);
    stepDust(dt);
    if (cfg.meteors && Math.random() < dt * 0.04) shooting.push({ x: 0.1 + Math.random() * 0.8, y: 0.03 + Math.random() * 0.3, a: 0, ang: 0.3 + Math.random() * 0.5, len: 0.08 + Math.random() * 0.1 });
    for (let i = shooting.length - 1; i >= 0; i--) { shooting[i].a += dt; if (shooting[i].a > 1.1) shooting.splice(i, 1); }
    for (let i = launches.length - 1; i >= 0; i--) {
      const l = launches[i]; l.a += dt; l.v += dt * 0.035; l.x += l.dir * l.v * dt * H / W; l.y += l.vy * dt;
      if (l.x < -0.2 || l.x > 1.2 || l.a > 30) launches.splice(i, 1);
    }
  }

  function draw() {
    gl.viewport(0, 0, cv.width, cv.height);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, texScene);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, texPlate);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, texMask);
    gl.uniform1i(uni.uScene, 0); gl.uniform1i(uni.uPlate, 1); gl.uniform1i(uni.uMask, 2);
    gl.uniform2f(uni.uRes, cv.width, cv.height);
    gl.uniform2f(uni.uImg, img.width, img.height);
    const pf = panF(), pb = panB(), st = station();
    gl.uniform2f(uni.uPanF, pf[0], pf[1]); gl.uniform2f(uni.uPanB, pb[0], pb[1]);
    gl.uniform2f(uni.uStation, st[0], st[1]);
    gl.uniform2f(uni.uPivot, SC.pivot[0], SC.pivot[1]);
    gl.uniform1f(uni.uRot, rot());
    gl.uniform2f(uni.uSun, SC.sun ? SC.sun[0] : -0.3, SC.sun ? SC.sun[1] : -0.3);
    gl.uniform1f(uni.uGlare, SC.sun ? cfg.glare : 0);
    const hz = SC.horizon || [0, 0, 2];
    gl.uniform3f(uni.uHz, hz[0], hz[1], hz[2]);
    gl.uniform1f(uni.uZoom, zoom());
    gl.uniform1f(uni.uT, time);
    gl.uniform1f(uni.uFlow, flowT);
    gl.uniform1f(uni.uBass, audio.bass * cfg.react);
    gl.uniform1f(uni.uHigh, audio.high * cfg.react);
    gl.uniform1f(uni.uGX, SCR.index * (W / H));
    gl.uniform1f(uni.uTwinkle, cfg.twinkle ? 1 : 0);
    gl.uniform1f(uni.uNebula, cfg.nebula);
    gl.uniform1f(uni.uPlanet, cfg.planet);
    gl.uniform1f(uni.uLights, cfg.lights ? 1 : 0);
    const rects = new Float32Array(MAX_BOB * 4), offs = new Float32Array(MAX_BOB * 2);
    (SC.bobs || []).slice(0, MAX_BOB).forEach((b, i) => {
      const pad = 0.03;
      rects.set([b[0] - pad, b[1] - pad, b[2] + pad, b[3] + pad], i * 4);
      const amp = (b[4] || 0.008) * cfg.float * 2, ph = i * 1.9 + 0.7;
      offs.set([Math.sin(time * 0.17 + ph) * amp * 0.4, Math.sin(time * (0.35 + i * 0.06) + ph) * amp], i * 2);
    });
    gl.uniform4fv(uni.uBobRect, rects); gl.uniform2fv(uni.uBobOff, offs);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    draw2d();
  }

  function draw2d() {
    g2.clearRect(0, 0, W, H);
    // Sternenstaub
    g2.fillStyle = '#fff';
    for (const d of dust) {
      const tw = 0.5 + 0.5 * Math.sin(time * (1 + d.z) + d.ph);
      g2.globalAlpha = Math.min(1, d.a) * (0.15 + 0.4 * tw) * d.z;
      g2.beginPath(); g2.arc(d.x * W, d.y * H, 0.5 + d.z * 0.9, 0, 6.28); g2.fill();
    }
    g2.globalAlpha = 1;
    // Positionslichter der Station
    if (cfg.lights && SC.nav) {
      for (const [u, v, c] of SC.nav) {
        const p = stationPt(u, v);
        const k = c === 'w' ? Math.max(0, 1 - ((time * 0.8) % 1.6) * 8) : 0.25 + 0.75 * Math.max(0, Math.sin(time * 2.2 + (c === 'g' ? 1.6 : 0)));
        if (k <= 0.01) continue;
        const rgb = c === 'r' ? '255,80,70' : c === 'g' ? '110,255,150' : '255,255,255';
        const r = H * (c === 'w' ? 0.022 : 0.012);
        const gr = g2.createRadialGradient(p[0], p[1], 0, p[0], p[1], r);
        gr.addColorStop(0, 'rgba(' + rgb + ',' + k + ')'); gr.addColorStop(0.25, 'rgba(' + rgb + ',' + (k * 0.4) + ')'); gr.addColorStop(1, 'rgba(' + rgb + ',0)');
        g2.fillStyle = gr; g2.fillRect(p[0] - r, p[1] - r, r * 2, r * 2);
      }
    }
    // Fähren (synchron über alle Bildschirme) und per Klick gestartete
    const nowS = Date.now() / 1000;
    const list = ships(nowS).sort((a, b) => a.size - b.size);
    for (const sh of list) {
      const lx = sh.gx - SCR.index;
      if (lx < -0.1 || lx > 1.1) continue;
      const x = lx * W, y = sh.y * H;
      const hide = sh.size < 1.05 ? fgAt(x, y) : 0;          // ferne Fähren verschwinden hinter der Station
      if (hide > 0.95) continue;
      g2.globalAlpha = 1 - hide;
      drawShip(x, y, sh.dir, sh.size, sh.kind, sh.ph, 0.7 + audio.bass * cfg.react * 0.4);
      g2.globalAlpha = 1;
    }
    for (const l of launches) drawShip(l.x * W, l.y * H, l.dir, l.size, l.kind, l.ph, Math.min(1.6, 0.4 + l.a * 0.8));
    // Sternschnuppen
    const ar = W / H;
    for (const s of shooting) {
      const k = s.a / 1.1, x = (s.x + Math.cos(s.ang) * s.len * k * 2) * W, y = (s.y + Math.sin(s.ang) * s.len * k * 2) * H * ar / 1.6;
      const L = s.len * W * 0.6, al = Math.sin(k * Math.PI) * 0.9;
      const gr = g2.createLinearGradient(x, y, x - Math.cos(s.ang) * L, y - Math.sin(s.ang) * L);
      gr.addColorStop(0, 'rgba(255,250,235,' + al + ')'); gr.addColorStop(1, 'rgba(255,250,235,0)');
      g2.strokeStyle = gr; g2.lineWidth = 1.5; g2.beginPath(); g2.moveTo(x, y); g2.lineTo(x - Math.cos(s.ang) * L, y - Math.sin(s.ang) * L); g2.stroke();
    }
    if (cfg.clock) {
      const d = new Date(); let h = d.getHours(); const mm = String(d.getMinutes()).padStart(2, '0');
      if (!cfg.hour24) h = h % 12 || 12;
      const t = (cfg.hour24 ? String(h).padStart(2, '0') : h) + ':' + mm;
      if (clockEl.textContent !== t) clockEl.textContent = t;
    }
    clockEl.hidden = !cfg.clock || SC !== window.STATION_SCENES.center;     // Uhr nur bei der Station
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
  window.addEventListener('mousemove', (e) => { mouse.x = e.clientX / W; mouse.y = e.clientY / H; mouse.inside = true; });
  document.addEventListener('mouseleave', () => { mouse.inside = false; });
  // Klick: eine kleine Fähre startet von dort und fliegt davon (zur näheren Bildschirmseite hin)
  function launch(x, y) {
    const dir = x < 0.5 ? -1 : 1;
    launches.push({ x, y, dir, v: 0.02, vy: (Math.random() - 0.6) * 0.01, a: 0, size: 0.9 + Math.random() * 0.5, kind: (Math.random() * 3) | 0, ph: Math.random() * 6.28 });
    if (launches.length > 12) launches.shift();
  }
  window.addEventListener('mousedown', (e) => { if (e.button === 0 && img) launch(e.clientX / W, e.clientY / H); });

  /* ================= Wallpaper Engine ================= */
  window.wallpaperPropertyListener = {
    applyUserProperties: function (p) {
      const v = (k) => p[k].value;
      if (p.ships) cfg.ships = (+v('ships')) / 100;
      if (p.dust) cfg.dust = Math.min(200, +v('dust') | 0);
      if (p.nebula) cfg.nebula = (+v('nebula')) / 100;
      if (p.twinkle) cfg.twinkle = !!v('twinkle');
      if (p.lights) cfg.lights = !!v('lights');
      if (p.glare) cfg.glare = (+v('glare')) / 100;
      if (p.planet) cfg.planet = (+v('planet')) / 100;
      if (p.meteors) cfg.meteors = !!v('meteors');
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

  // Bilder laden (Szene, Platte, Maske), dann starten
  let pending = 3;
  const done = () => {
    if (--pending) return;
    IA = img.width / img.height;
    setup(); resize();
    window.addEventListener('resize', resize);
    last = performance.now(); requestAnimationFrame(frame);
  };
  img = new Image(); plateImg = new Image(); maskImg = new Image();
  for (const [im, src] of [[img, SC.image], [plateImg, SC.plate], [maskImg, SC.mask]]) { im.onload = done; im.src = src; }
  // zum Testen
  window.Station = { step: (dt, n) => { for (let i = 0; i < (n || 1); i++) step(dt); draw(); }, cfg, launch, ships: () => ships(Date.now() / 1000) };
})();
