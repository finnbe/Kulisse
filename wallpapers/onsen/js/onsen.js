/* Yuzu Onsen – eine heiße Quelle im Schnee, von oben.
 *
 * Grundlage ist eine gemalte Illustration (scene.js, lokal mit Z-Image-Turbo erzeugt, Apache 2.0). Lebendig wird
 * sie durch einen WebGL-Shader und eine kleine Wellen-Simulation:
 *   - Wasser: echte Wellen (Wellengleichung auf einem Gitter), die das Bild darunter brechen, Glanzlichter,
 *     Lichtspiel am Grund. Wellen kommen von Maus, Klicks, Schnee/Regen, Yuzus und dem Takt der Musik.
 *   - Dampf: wabert über dem Becken; die Maus wischt ihn weg, er zieht langsam wieder zu.
 *   - Im Wasser treiben Yuzus, Kirschblütenblätter oder Ahornblätter (oder gemischt): langsam im Kreis, schaukeln
 *     auf den Wellen, Klick schubst sie. Bei "Blüten fallen" segeln Blätter herab und landen auf dem Wasser.
 *   - Laternen flackern (und pulsieren zur Musik), Tageszeit nach Uhr (Tag / Abend / Nacht).
 *   - Schnee oder Regen, Dampf über der Teeschale (2D-Ebene darüber), Uhr.
 * Schnittstelle wie Wallpaper Engine: wallpaperPropertyListener, wallpaperRegisterAudioListener.
 * Das Bild steckt als Data-URI in scene.js, weil WebKit/WebGL Bilder von file:// nicht verwenden darf.
 */
(function () {
  'use strict';

  const cfg = {
    timemode: 'auto', weather: 'snow', amount: 0.5, steam: 0.6, floating: 'yuzu', floatcount: 7, ripples: true, flicker: 0.6,
    teasteam: true, react: 0.6, parallax: 0.5, clock: false, hour24: true, scale: 1, fpsCap: 0,
  };
  const MAX_FLOAT = 40;                                // so viele Dinge treiben höchstens im Wasser
  const KIND = { yuzu: 0, petal: 1, maple: 2 };
  const SIZE = { 0: [0.022, 0.006], 1: [0.015, 0.005], 2: [0.017, 0.005] };   // Radius (Anteil Bildhöhe) + Zufall
  const SC = window.ONSEN_SCENE;

  const cv = document.getElementById('c'), fx = document.getElementById('fx'), clockEl = document.getElementById('clock');
  const gl = cv.getContext('webgl2', { alpha: false, antialias: false, premultipliedAlpha: false, powerPreference: 'high-performance' });
  if (!gl) { document.getElementById('nogl').hidden = false; return; }
  const g2 = fx.getContext('2d');

  let img = null, IA = 16 / 9, W = 0, H = 0, S = 1;
  let prog, uni = {}, texScene, texMask, texFog, texEmit, texWave, fogCv, fogCtx;
  let maskData = null, MW = 0, MH = 0;                 // Wassermaske auf der CPU (für Yuzus, Schnee)
  const mouse = { x: 0.5, y: 0.5, sx: 0.5, sy: 0.5, px: -1, py: -1, inside: false };
  const audio = { bass: 0, high: 0, active: 0, lastBeat: 0, prevBass: 0 };
  let time = 0, last = 0, acc = 0, paused = false, refog = 0;
  let yuzus = [], flakes = [], tea = [];

  /* ================= Perspektive ================= */
  // Das Bild ist schräg von oben gemalt: hinten (oben im Bild) ist das Wasser weiter weg. s(v) = wie groß Dinge an
  // der Bildhöhe v erscheinen (hinten klein, vorne groß), CV = wie stark die Wasserfläche in der Höhe gestaucht ist.
  // Wellen, Lichtspiel und Treibgut leben auf der "Fläche" (X, Y) und werden von dort ins Bild gerechnet.
  const P0 = 0.24, P1 = 0.84, S0 = 0.72, S1 = 1.12, CV = 0.62, KB = (S1 - S0) / (P1 - P0);
  const sAt = (v) => Math.max(0.3, S0 + KB * (v - P0));
  function toPlane(u, v) { const s = sAt(v); return [(u - 0.5) * IA / s, Math.log(s / S0) / (KB * CV)]; }
  function fromPlane(X, Y) { const s = S0 * Math.exp(Y * KB * CV); return [0.5 + X * s / IA, P0 + (s - S0) / KB]; }

  /* ================= Wellen-Simulation (auf der Wasserfläche) ================= */
  let GW = 512, GH = 256, PX0 = 0, PY0 = 0, CELL = 0.01;   // Gitter, Ursprung und Zellgröße in Flächen-Einheiten
  let BX0 = 1, BX1 = GW - 1, BY0 = 1, BY1 = GH - 1;          // nur im Bereich des Beckens rechnen
  let h0, h1, wmask, waveBytes;
  function waveStep() {
    for (let y = BY0; y < BY1; y++) {
      for (let x = BX0; x < BX1; x++) {
        const i = y * GW + x;
        if (!wmask[i]) { h1[i] = 0; continue; }
        const v = (h0[i - 1] + h0[i + 1] + h0[i - GW] + h0[i + GW]) * 0.5 - h1[i];
        h1[i] = Math.max(-1, Math.min(1, v * 0.985));
      }
    }
    const t = h0; h0 = h1; h1 = t;
  }
  // r = Radius als Anteil der Bildbreite (vorne gemessen); auf der Fläche überall gleich groß -> hinten kleiner im Bild
  function splash(u, v, r, str) {
    const q = toPlane(u, v);
    const cx = (q[0] - PX0) / CELL, cy = (q[1] - PY0) / CELL, rr = Math.max(1, r * IA / CELL);
    for (let y = Math.max(1, (cy - rr) | 0); y < Math.min(GH - 1, cy + rr + 1); y++) {
      for (let x = Math.max(1, (cx - rr) | 0); x < Math.min(GW - 1, cx + rr + 1); x++) {
        const d = Math.hypot(x - cx, y - cy) / rr;
        if (d < 1) { const i = y * GW + x; if (wmask[i]) h0[i] += str * (Math.cos(d * Math.PI) * 0.5 + 0.5); }
      }
    }
  }
  function heightAt(u, v) {
    const q = toPlane(u, v);
    const x = Math.min(GW - 1, Math.max(0, ((q[0] - PX0) / CELL) | 0)), y = Math.min(GH - 1, Math.max(0, ((q[1] - PY0) / CELL) | 0));
    return h0[y * GW + x];
  }
  function inWater(u, v) {
    if (!maskData) return false;
    const x = Math.min(MW - 1, Math.max(0, (u * MW) | 0)), y = Math.min(MH - 1, Math.max(0, (v * MH) | 0));
    return maskData[(y * MW + x) * 4] > 140;
  }

  /* ================= Shader ================= */
  const VS = `#version 300 es
  in vec2 p; out vec2 vUv;
  void main() { vUv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }`;

  const FS = `#version 300 es
  precision highp float;
  in vec2 vUv; out vec4 o;
  uniform sampler2D uScene, uMask, uFog, uEmit, uWave;
  uniform vec2 uRes, uImg, uPan, uWaveRes;
  uniform vec4 uPlane;                 // Ursprung X, Y und Größe der Wasserfläche (Flächen-Einheiten)
  uniform float uT, uZoom, uSteam, uFlicker, uBass, uHigh, uTod, uRainy;
  uniform vec4 uFloat[${MAX_FLOAT}];   // u, v, Radius, Drehung
  uniform float uKind[${MAX_FLOAT}];   // 0 Yuzu, 1 Kirschblütenblatt, 2 Ahornblatt
  uniform vec3 uLight;                 // Schatten auf dem Grund: Versatz (in Radien) und Stärke – folgt der Tageszeit

  float h21(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
  float noise(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y); }
  float fbm(vec2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { s += a * noise(p); p = p * 2.03 + vec2(13.1, 7.7); a *= 0.5; } return s; }

  float wave(vec2 uv) { return texture(uWave, uv).r * 2.0 - 1.0; }

  // Perspektive (wie im JS-Teil): hinten klein und gestaucht, vorne groß
  const float P0 = ${P0}, S0 = ${S0}, CV = ${CV}, KB = ${KB};
  float sAt(float v) { return max(0.3, S0 + KB * (v - P0)); }
  vec2 toPlane(vec2 iuv, float ia) { float s = sAt(iuv.y); return vec2((iuv.x - 0.5) * ia / s, log(s / S0) / (KB * CV)); }

  // Lichtspiel am Beckengrund (zwei verschobene Muster, gemischt)
  float caustic(vec2 p, float t) {
    vec2 q = p * 9.0;
    float c = 0.0;
    for (int i = 0; i < 3; i++) {
      float fi = float(i);
      q += vec2(sin(q.y * 1.3 + t * 0.6 + fi), cos(q.x * 1.1 - t * 0.5 + fi * 1.7)) * 0.55;
      c += 1.0 / (1.0 + 18.0 * abs(sin(q.x + sin(q.y + t * 0.3))));
    }
    return c / 3.0;
  }

  void main() {
    float sa = uRes.x / uRes.y, ia = uImg.x / uImg.y;
    vec2 uv = vUv; uv.y = 1.0 - uv.y;
    vec2 cov = sa > ia ? vec2(1.0, ia / sa) : vec2(sa / ia, 1.0);
    vec2 iuv = (uv - 0.5) * cov / uZoom + 0.5 + uPan;

    vec3 mk = texture(uMask, iuv).rgb;       // r = Wasser (scharf), g = Wasser (weich, für Dampf)
    float water = mk.r;
    vec3 col = texture(uScene, iuv).rgb;

    if (water > 0.003) {
      // Ort auf der Wasserfläche -> Wellen-Gitter
      float sv = sAt(iuv.y);
      vec2 pl = toPlane(iuv, ia);
      vec2 wuv = (pl - uPlane.xy) / uPlane.zw;
      vec2 e = 1.0 / uWaveRes;
      float hc = wave(wuv);
      vec2 gr = vec2(wave(wuv + vec2(e.x, 0.0)) - wave(wuv - vec2(e.x, 0.0)), wave(wuv + vec2(0.0, e.y)) - wave(wuv - vec2(0.0, e.y)));
      float t = uT;
      // feines Kräuseln, ebenfalls auf der Fläche (hinten dichter)
      vec2 ripple = vec2(noise(pl * 60.0 + vec2(t * 0.35, t * 0.2)), noise(pl * 60.0 - vec2(t * 0.25, -t * 0.3) + 9.0)) - 0.5;
      vec2 n = gr * 1.6 + ripple * 0.008;
      // Verschiebung im Bild: vorne stärker, in der Höhe gestaucht
      vec2 ruv = iuv + n * 0.035 * water * vec2(1.0, CV) * sv;
      vec3 under = texture(uScene, ruv).rgb;
      // Lichtspiel am Grund (auf der Fläche -> hinten feiner)
      float ca = caustic(pl * 0.9 + n * 0.02, t);
      float depthK = clamp((iuv.y - P0) / 0.6, 0.0, 1.0);       // 0 = hinten, 1 = vorne
      under += vec3(0.55, 0.85, 0.9) * pow(ca, 3.0) * (0.22 + 0.18 * max(uTod, 0.0)) * (1.0 - uRainy * 0.5) * mix(0.6, 1.1, depthK);
      // Spiegelung (Fresnel): hinten schaut man flach aufs Wasser -> mehr Himmel/Schnee, vorne klarer Blick auf den Grund
      float fres = mix(0.42, 0.04, smoothstep(0.0, 0.85, depthK));
      vec3 sky = mix(vec3(0.62, 0.7, 0.82), vec3(0.85, 0.9, 0.97), max(uTod, 0.0)) * (0.65 + 0.35 * max(uTod, -0.4));
      sky += vec3(0.05) * noise(pl * 8.0 + n * 3.0 + t * 0.05);            // leicht unruhige Spiegelung
      under = mix(under, sky, fres * (0.75 + clamp(abs(hc) * 3.0, 0.0, 0.25)));
      // Glanzlicht (Licht von hinten oben – hinten heller) und Wellenkämme
      float spec = pow(max(0.0, dot(normalize(vec3(-n * 26.0, 1.0)), normalize(vec3(-0.35, -0.8, 0.7)))), 60.0);
      under += vec3(1.0, 0.95, 0.85) * spec * mix(0.8, 0.35, depthK);
      under += vec3(0.75, 0.9, 1.0) * clamp(abs(hc) * 0.9, 0.0, 0.1);

      // Treibgut auf der Oberfläche: Yuzus, Kirschblütenblätter, Ahornblätter
      for (int i = 0; i < ${MAX_FLOAT}; i++) {
        vec4 y = uFloat[i];
        if (y.z <= 0.0) continue;
        float kind = uKind[i];
        vec2 d = (iuv - y.xy) * vec2(ia, 1.0) / (y.z * sAt(y.y));
        if (kind > 0.5) d.y /= CV;          // Blätter liegen flach auf dem Wasser -> perspektivisch gestaucht
        if (dot(d, d) > 4.0) continue;
        float ca2 = cos(y.w), sa2 = sin(y.w);
        vec2 rd = vec2(ca2 * d.x - sa2 * d.y, sa2 * d.x + ca2 * d.y);
        float dayK = 0.85 + 0.15 * float(uTod > 0.0);
        if (kind < 0.5) {
          // Yuzu: Kugel mit Poren, Glanzpunkt, Stiel und Blättchen
          // Schatten auf dem Grund: an der gebrochenen Stelle (wabert mit den Wellen), Richtung nach Tageszeit
          vec2 ds = (ruv - y.xy) * vec2(ia, 1.0) / (y.z * sAt(y.y));
          float sh = smoothstep(1.35, 0.45, length((ds - uLight.xy) * vec2(1.0, 1.0 / CV)));
          under *= 1.0 - sh * uLight.z;
          float r = length(d);
          if (r < 1.0) {
            vec3 nn = vec3(d, sqrt(1.0 - r * r));
            float dimple = noise(rd * 7.0) * 0.12 + noise(rd * 15.0) * 0.06;
            vec3 base = mix(vec3(0.98, 0.70, 0.08), vec3(1.0, 0.86, 0.25), nn.z) - dimple;
            float lit = 0.45 + 0.55 * max(0.0, dot(nn, normalize(vec3(-0.5, -0.6, 0.8))));
            vec3 yc = base * lit;
            yc += vec3(1.0) * pow(max(0.0, dot(nn, normalize(vec3(-0.45, -0.55, 0.75)))), 30.0) * 0.5;
            yc = mix(yc, vec3(0.35, 0.3, 0.12), smoothstep(0.13, 0.08, length(rd - vec2(0.0, -0.55))));
            vec2 lf = (rd - vec2(0.28, -0.72)) * mat2(0.8, -0.6, 0.6, 0.8);
            yc = mix(yc, vec3(0.2, 0.45, 0.15), smoothstep(1.0, 0.85, length(lf * vec2(3.0, 7.0))));
            under = mix(under, yc * dayK, smoothstep(1.0, 0.92, r));
          }
        } else if (kind < 1.5) {
          // Kirschblütenblatt: Oval mit Kerbe an der Spitze, zur Mitte hin heller
          vec2 q = rd;                                  // dünn und durchscheinend: kein Schatten auf dem tiefen Grund
          float body = length(q * vec2(1.55, 1.0));
          float notch = length((q - vec2(0.0, 1.0)) * vec2(1.0, 1.4));
          float m = smoothstep(1.0, 0.9, body) * smoothstep(0.22, 0.32, notch);
          if (m > 0.0) {
            vec3 pc = mix(vec3(1.0, 0.93, 0.95), vec3(0.96, 0.62, 0.74), smoothstep(0.1, 1.0, body));
            pc = mix(pc, vec3(0.88, 0.45, 0.58), smoothstep(-0.6, -1.0, q.y) * 0.6);      // Ansatz dunkler
            pc *= 0.9 + 0.1 * (q.x * 0.5 + 0.5);
            under = mix(under, pc * dayK, m * 0.95);
          }
        } else {
          // Ahornblatt: fünf Spitzen, rot-orange, mit Adern und Stiel
          vec2 q = rd;
          float ang = atan(q.x, -q.y);
          float lobe = 0.55 + 0.45 * pow(abs(cos(ang * 2.5)), 0.6);
          lobe *= smoothstep(3.14, 2.4, abs(ang)) * 0.6 + 0.4;
          float rr2 = length(q);
          vec2 ds = (ruv - y.xy) * vec2(ia, 1.0) / (y.z * sAt(y.y)) - uLight.xy;
          ds.y /= CV;
          float sh = smoothstep(1.0, 0.35, length(ds));
          under *= 1.0 - sh * uLight.z * 0.55;
          float m = smoothstep(lobe, lobe - 0.08, rr2);
          float stem = smoothstep(0.06, 0.03, abs(q.x)) * step(0.0, q.y) * step(q.y, 0.75);
          if (m > 0.0 || stem > 0.0) {
            vec3 lc = mix(vec3(0.95, 0.35, 0.08), vec3(0.75, 0.12, 0.08), smoothstep(0.2, 1.0, rr2));
            float vein = smoothstep(0.04, 0.0, abs(fract(ang / 1.2566 + 0.5) - 0.5) * rr2 * 3.0);
            lc = mix(lc, vec3(1.0, 0.6, 0.25), vein * 0.4 * m);
            under = mix(under, lc * dayK, max(m, stem * 0.9));
          }
        }
      }
      col = mix(col, under, water);
    }

    // Dampf: weiche Wolken über dem Wasser, von der Maus weggewischt
    float steamArea = mk.g;
    if (uSteam > 0.0 && steamArea > 0.01) {
      vec2 sp = toPlane(iuv, ia) * 2.0;
      float f = fbm(sp + vec2(uT * 0.05, -uT * 0.08) + fbm(sp * 0.6 - uT * 0.03) * 1.6);
      float f2 = fbm(sp * 2.1 - vec2(uT * 0.09, uT * 0.04));
      float dens = smoothstep(0.34, 0.82, f * 0.75 + f2 * 0.35) * steamArea * uSteam;
      dens *= texture(uFog, iuv).r;
      vec3 sc = mix(vec3(0.85, 0.9, 0.97), vec3(1.0, 0.85, 0.65), texture(uEmit, iuv).b * 0.8);
      sc *= 0.75 + 0.35 * max(uTod, -0.3);
      col = mix(col, sc, clamp(dens * 0.9, 0.0, 0.85));
    }

    // Tageszeit: Bild ist Abend (uTod = 0). Tag heller und wärmer, Nacht dunkler und blauer.
    if (uTod > 0.0) col = mix(col, col * vec3(1.14, 1.1, 1.02) + 0.035, uTod);
    else col = mix(col, col * vec3(0.48, 0.55, 0.82), -uTod);
    // Laternen: flackern, Lichthof wird nachts stärker, pulsiert zur Musik
    vec3 em = texture(uEmit, iuv).rgb;
    float fl = noise(vec2(uT * 7.0, 3.1)) * 0.6 + noise(vec2(uT * 17.0, 8.2)) * 0.4;
    float flick = 1.0 + (fl - 0.5) * 0.35 * uFlicker + uBass * 0.4;
    float nightGlow = 0.35 + max(-uTod, 0.0) * 0.9;
    col += em.g * col * (flick - 1.0) * 1.5;
    col += vec3(1.0, 0.62, 0.28) * em.b * nightGlow * flick * 0.55;
    // Rand leicht abdunkeln
    vec2 v = vUv - 0.5; col *= 1.0 - dot(v, v) * 0.35;
    o = vec4(max(col, 0.0), 1.0);
  }`;

  function compile(type, src) {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  function makeTex(src, mip, w, h) {
    const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
    if (src) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, src);
    else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mip ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    if (mip) gl.generateMipmap(gl.TEXTURE_2D);
    return t;
  }
  function poly(c, pts, w, h) { c.beginPath(); pts.forEach((q, i) => (i ? c.lineTo(q[0] * w, q[1] * h) : c.moveTo(q[0] * w, q[1] * h))); c.closePath(); c.fill(); }

  function setup() {
    prog = gl.createProgram();
    gl.attachShader(prog, compile(gl.VERTEX_SHADER, VS));
    gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, FS));
    gl.bindAttribLocation(prog, 0, 'p');
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    for (const n of ['uScene', 'uMask', 'uFog', 'uEmit', 'uWave', 'uRes', 'uImg', 'uPan', 'uWaveRes', 'uT', 'uZoom', 'uSteam',
      'uFlicker', 'uBass', 'uHigh', 'uTod', 'uRainy', 'uFloat', 'uKind', 'uPlane', 'uLight']) uni[n] = gl.getUniformLocation(prog, n);
    const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

    texScene = makeTex(img, true);
    // Wassermaske: R scharf (Wasser), G weich und etwas größer (Dampf reicht über den Rand)
    MW = 960; MH = Math.round(960 / IA);
    const sharp = document.createElement('canvas'); sharp.width = MW; sharp.height = MH;
    const s = sharp.getContext('2d');
    s.fillStyle = '#000'; s.fillRect(0, 0, MW, MH);
    if (maskImg) {
      s.drawImage(maskImg, 0, 0, MW, MH);           // genaue Graustufen-Maske (weiß = Wasser)
    } else {
      s.fillStyle = '#fff'; for (const p of SC.water) poly(s, p, MW, MH);
      s.fillStyle = '#000'; for (const p of SC.cut || []) poly(s, p, MW, MH);
    }
    const soft = document.createElement('canvas'); soft.width = MW; soft.height = MH;
    const so = soft.getContext('2d'); so.filter = 'blur(28px)'; so.drawImage(sharp, 0, 0); so.drawImage(sharp, 0, 0); so.filter = 'none';
    const sb = document.createElement('canvas'); sb.width = MW; sb.height = MH;
    const sbc = sb.getContext('2d'); sbc.filter = 'blur(1.5px)'; sbc.drawImage(sharp, 0, 0); sbc.filter = 'none';
    maskData = s.getImageData(0, 0, MW, MH).data;
    const a = sbc.getImageData(0, 0, MW, MH), b = so.getImageData(0, 0, MW, MH);
    for (let i = 0; i < a.data.length; i += 4) { a.data[i + 1] = Math.min(255, b.data[i] * 1.3); a.data[i + 2] = 0; a.data[i + 3] = 255; }
    sbc.putImageData(a, 0, 0);
    texMask = makeTex(sb, false);
    // Wellen-Gitter auf der Wasserfläche: Ausdehnung aus dem Becken-Umriss, 512 Zellen in der Breite
    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    for (let py = 0; py < MH; py += 2) for (let px = 0; px < MW; px += 2) {
      if (maskData[(py * MW + px) * 4] <= 140) continue;
      const q = toPlane((px + 0.5) / MW, (py + 0.5) / MH);
      x0 = Math.min(x0, q[0]); x1 = Math.max(x1, q[0]); y0 = Math.min(y0, q[1]); y1 = Math.max(y1, q[1]);
    }
    const pad = 0.02; x0 -= pad; y0 -= pad; x1 += pad; y1 += pad;
    GW = 512; CELL = (x1 - x0) / GW; GH = Math.ceil((y1 - y0) / CELL); PX0 = x0; PY0 = y0;
    h0 = new Float32Array(GW * GH); h1 = new Float32Array(GW * GH); wmask = new Uint8Array(GW * GH); waveBytes = new Uint8Array(GW * GH * 4);
    BX0 = GW; BX1 = 0; BY0 = GH; BY1 = 0;
    for (let y = 0; y < GH; y++) for (let x = 0; x < GW; x++) {
      const im = fromPlane(PX0 + (x + 0.5) * CELL, PY0 + (y + 0.5) * CELL);
      const w = inWater(im[0], im[1]) ? 1 : 0;
      wmask[y * GW + x] = w;
      if (w) { BX0 = Math.min(BX0, x); BX1 = Math.max(BX1, x + 1); BY0 = Math.min(BY0, y); BY1 = Math.max(BY1, y + 1); }
    }
    BX0 = Math.max(1, BX0); BY0 = Math.max(1, BY0); BX1 = Math.min(GW - 1, BX1); BY1 = Math.min(GH - 1, BY1);
    texWave = makeTex(null, false, GW, GH);
    texEmit = makeTex(emissiveMap(), false);
    fogCv = document.createElement('canvas'); fogCv.width = 320; fogCv.height = Math.round(320 / IA);
    fogCtx = fogCv.getContext('2d'); fogCtx.fillStyle = '#fff'; fogCtx.fillRect(0, 0, fogCv.width, fogCv.height);
    texFog = makeTex(fogCv, false);
    yuzus = [];
  }

  // Leuchtende warme Stellen (Laternen): G = Laterne selbst, B = großer Lichthof
  function emissiveMap() {
    const w = 480, h = Math.round(480 / IA);
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const g = c.getContext('2d'); g.drawImage(img, 0, 0, w, h);
    const d = g.getImageData(0, 0, w, h), p = d.data;
    for (let i = 0; i < p.length; i += 4) {
      const r = p[i] / 255, gg = p[i + 1] / 255, b = p[i + 2] / 255;
      const warm = r > 0.7 && gg > 0.55 && b < 0.55 && r > b * 1.6;
      const e = warm ? Math.min(1, (r - 0.6) * 2.5) : 0;
      p[i] = 0; p[i + 1] = e * 255; p[i + 2] = e * 255; p[i + 3] = 255;
    }
    g.putImageData(d, 0, 0);
    // G leicht, B stark weichzeichnen (Lichthof)
    const halo = document.createElement('canvas'); halo.width = w; halo.height = h;
    const hc = halo.getContext('2d'); hc.filter = 'blur(26px)'; hc.drawImage(c, 0, 0); hc.drawImage(c, 0, 0); hc.drawImage(c, 0, 0); hc.filter = 'none';
    const core = document.createElement('canvas'); core.width = w; core.height = h;
    const cc = core.getContext('2d'); cc.filter = 'blur(2px)'; cc.drawImage(c, 0, 0); cc.filter = 'none';
    const A = cc.getImageData(0, 0, w, h), B = hc.getImageData(0, 0, w, h);
    for (let i = 0; i < A.data.length; i += 4) { A.data[i + 2] = Math.min(255, B.data[i + 2] * 1.8); }
    cc.putImageData(A, 0, 0);
    return core;
  }

  // welche Art als Nächstes ins Wasser kommt
  function nextKind() {
    if (cfg.floating === 'sakura') return KIND.petal;
    if (cfg.floating === 'maple') return KIND.maple;
    if (cfg.floating === 'mix') return Math.random() < 0.3 ? KIND.yuzu : KIND.petal;
    return KIND.yuzu;
  }
  function newFloater(u, v, kind) {
    const sz = SIZE[kind];
    return { u, v, vu: 0, vv: 0, kind, r: sz[0] + Math.random() * sz[1], rot: Math.random() * 6.28, rot0: Math.random() * 6.28,
             spin: (Math.random() - 0.5) * (kind === KIND.yuzu ? 0.3 : 0.9), bob: Math.random() * 6.28 };
  }

  /* ================= Ablauf ================= */
  function resize() {
    const dpr = window.devicePixelRatio || 1;
    W = window.innerWidth; H = window.innerHeight; S = dpr * cfg.scale;
    cv.width = Math.round(W * S); cv.height = Math.round(H * S);
    fx.width = Math.round(W * dpr); fx.height = Math.round(H * dpr);
    g2.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  const zoom = () => 1 + 0.03 * cfg.parallax;
  const pan = () => [(mouse.sx - 0.5) * 0.012 * cfg.parallax, (mouse.sy - 0.5) * 0.008 * cfg.parallax];
  function cover() { const sa = W / H; return sa > IA ? [1, IA / sa] : [sa / IA, 1]; }
  function toImg(x, y) { const c = cover(), z = zoom(), p = pan(); return [((x / W) - 0.5) * c[0] / z + 0.5 + p[0], ((y / H) - 0.5) * c[1] / z + 0.5 + p[1]]; }
  function toScreen(u, v) { const c = cover(), z = zoom(), p = pan(); return [((u - 0.5 - p[0]) * z / c[0] + 0.5) * W, ((v - 0.5 - p[1]) * z / c[1] + 0.5) * H]; }
  const pxPerImg = () => H * zoom() / cover()[1];     // Bildschirm-px je Bildhöhe

  // Tageszeit: 1 = Tag, 0 = Abend (so ist das Bild), -1 = Nacht
  function tod() {
    if (cfg.timemode === 'day') return 1;
    if (cfg.timemode === 'dusk') return 0;
    if (cfg.timemode === 'night') return -1;
    if (cfg.timemode === 'cycle') {
      // 40-Minuten-Kreislauf nach der Uhr: 10 Min. Tag, 10 Min. Übergang zur Nacht (über den Abend),
      // 10 Min. Nacht, 10 Min. Übergang zurück zum Tag
      const m = (Date.now() / 60000) % 40;
      const ease = (x) => x * x * (3 - 2 * x);
      if (m < 10) return 1;
      if (m < 20) return 1 - 2 * ease((m - 10) / 10);
      if (m < 30) return -1;
      return -1 + 2 * ease((m - 30) / 10);
    }
    const d = new Date(), h = d.getHours() + d.getMinutes() / 60;
    const k = [[0, -1], [5, -1], [7, 0], [9, 1], [15.5, 1], [17.5, 0], [19.5, -1], [24, -1]];
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

  let waveAcc = 0;
  function step(dt) {
    time += dt;
    mouse.sx += (mouse.x - mouse.sx) * Math.min(1, dt * 2.5);
    mouse.sy += (mouse.y - mouse.sy) * Math.min(1, dt * 2.5);
    audio.active = Math.max(0, audio.active - dt);
    if (audio.active <= 0) { audio.bass *= 0.9; audio.high *= 0.9; }
    // Musik: auf Bass-Schläge Tropfen ins Wasser
    if (audio.active > 0 && cfg.react > 0 && audio.bass > 0.35 && audio.bass > audio.prevBass * 1.25 && time - audio.lastBeat > 0.18) {
      audio.lastBeat = time;
      for (let k = 0; k < 1 + (cfg.react * 2 | 0); k++) { const q = randomWater(); if (q) splash(q[0], q[1], 0.006, -0.4 * cfg.react * audio.bass); }
    }
    audio.prevBass = audio.bass;
    // Wellen mit fester Schrittweite (30/s – ruhiges Tempo passend zur Beckengröße), bei jeder Bildrate gleich
    waveAcc += dt;
    let n = 0;
    while (waveAcc > 1 / 30 && n < 3) { waveStep(); waveAcc -= 1 / 30; n++; }
    if (n === 3) waveAcc = 0;
    // ganz leises Kräuseln, damit das Wasser nie stillsteht
    if (Math.random() < dt * 1.5) { const q = randomWater(); if (q) splash(q[0], q[1], 0.004, -0.05); }
    // Maus: Spur im Wasser, Dampf wegwischen
    if (mouse.inside && mouse.px >= 0) {
      const a = toImg(mouse.px * W, mouse.py * H), b = toImg(mouse.x * W, mouse.y * H);
      const dist = Math.hypot((b[0] - a[0]) * W, (b[1] - a[1]) * H);
      if (dist > 0.5) {
        const m = Math.min(14, Math.ceil(dist / 10));
        for (let i = 1; i <= m; i++) {
          const u = a[0] + (b[0] - a[0]) * i / m, v = a[1] + (b[1] - a[1]) * i / m;
          wipe(u, v, 0.05, 0.35);
          if (cfg.ripples) splash(u, v, 0.005, -0.06 * Math.min(1, dist / 30));
        }
      }
    }
    mouse.px = mouse.x; mouse.py = mouse.y;
    refog += dt;
    if (refog > 0.2) { fogCtx.fillStyle = 'rgba(255,255,255,' + (0.035 * refog) + ')'; fogCtx.fillRect(0, 0, fogCv.width, fogCv.height); refog = 0; }
    stepYuzus(dt);
    stepWeather(dt);
    if (cfg.teasteam && SC.teaSteam && Math.random() < dt * 7) {
      const s = SC.teaSteam; tea.push({ u: s[0] + (Math.random() - 0.5) * s[2] * 0.5, v: s[1], a: 0, life: 3 + Math.random() * 2, ph: Math.random() * 6.28, w: s[2] });
    }
    for (let i = tea.length - 1; i >= 0; i--) { tea[i].a += dt; if (tea[i].a > tea[i].life) tea.splice(i, 1); }
  }

  function randomWater() {
    for (let k = 0; k < 20; k++) { const u = 0.18 + Math.random() * 0.62, v = 0.24 + Math.random() * 0.6; if (inWater(u, v)) return [u, v]; }
    return null;
  }

  function stepYuzus(dt) {
    // Anzahl: fehlende tauchen auf (außer bei fallenden Blüten – die kommen von oben), zu viele verschwinden (älteste zuerst)
    const want = Math.min(MAX_FLOAT, cfg.floatcount);
    if (cfg.weather !== 'blossoms') while (yuzus.length < want) { const q = randomWater(); if (!q) break; yuzus.push(newFloater(q[0], q[1], nextKind())); }
    while (yuzus.length > want) yuzus.shift();
    const cx = 0.49, cy = 0.54;
    for (const y of yuzus) {
      // langsame Kreisströmung + Wellen schieben (bergab) + Reibung
      const dx = (y.u - cx) * IA, dy = y.v - cy, d = Math.hypot(dx, dy) + 1e-4;
      const light = y.kind === KIND.yuzu ? 1 : 2.2;      // Blätter treiben leichter
      y.vu += (-dy / d) * 0.0025 * light * dt / IA; y.vv += (dx / d) * 0.0025 * light * dt;
      // sanft zur Mitte – aber erst im äußeren Bereich; innen treibt alles frei
      const pull = 0.0016 * light * Math.max(0, Math.min(1, (d - 0.2) / 0.12));
      y.vu -= (dx / d) * pull * dt / IA; y.vv -= (dy / d) * pull * dt;
      // Rand: Wasser schiebt weich zurück, bevor es an die Steine stößt (8 Fühler rundum)
      const probe = 0.035 + y.r;
      for (let k = 0; k < 8; k++) {
        const a = k * Math.PI / 4, px = Math.cos(a), py = Math.sin(a);
        if (!inWater(y.u + px * probe / IA, y.v + py * probe)) { y.vu -= px * 0.007 * light * dt / IA; y.vv -= py * 0.007 * light * dt; }
      }
      // leichtes Umherirren, jedes Objekt anders
      y.vu += Math.sin(time * 0.31 + y.rot0) * 0.0018 * light * dt / IA;
      y.vv += Math.cos(time * 0.23 + y.rot0 * 1.7) * 0.0018 * light * dt;
      const e = 0.006;
      y.vu -= (heightAt(y.u + e, y.v) - heightAt(y.u - e, y.v)) * 0.03 * light * dt;
      y.vv -= (heightAt(y.u, y.v + e) - heightAt(y.u, y.v - e)) * 0.03 * light * dt;
      y.vu *= Math.pow(0.6, dt); y.vv *= Math.pow(0.6, dt);
      // gegenseitig abstoßen
      for (const o of yuzus) if (o !== y) {
        const both = y.kind === KIND.yuzu && o.kind === KIND.yuzu;
        const ox = (y.u - o.u) * IA, oy = y.v - o.v, od = Math.hypot(ox, oy);
        const min = (y.r + o.r) * (both ? 1.1 : 1.6) * sAt(y.v);
        if (od < min && od > 1e-5) {
          if (both) { const k = (min - od) / od * 0.5; y.u += ox * k / IA * 0.5; y.v += oy * k * 0.5; }
          else { const k = (min - od) / min * 0.004 * light; y.vu += ox / od * k * dt * 60 / IA * 0.1; y.vv += oy / od * k * dt * 60 * 0.1; }
        }
      }
      const ps = sAt(y.v);                                  // hinten treibt alles langsamer übers Bild
      let nu = y.u + y.vu * dt * ps, nv = y.v + y.vv * dt * ps * CV;
      // am Beckenrand abprallen (Rand der Frucht muss im Wasser bleiben)
      const rr = y.r * 0.9 * ps;
      const ok = (u, v) => inWater(u + rr / IA, v) && inWater(u - rr / IA, v) && inWater(u, v + rr) && inWater(u, v - rr);
      if (!ok(nu, y.v)) { y.vu *= -0.5; nu = y.u; }
      if (!ok(y.u, nv)) { y.vv *= -0.5; nv = y.v; }
      if (ok(nu, nv)) { y.u = nu; y.v = nv; }
      y.rot += (y.spin + Math.hypot(y.vu, y.vv) * 40) * dt;
      y.bob += dt;
      if (y.kind === KIND.yuzu && Math.random() < dt * 0.4) splash(y.u, y.v, 0.004, -0.025);   // kleine Wellen durchs Schaukeln
    }
  }

  // Schnee fällt auf den Betrachter zu und landet; Regen = kurze Striche + Ringe im Wasser
  function stepWeather(dt) {
    const W8 = cfg.weather;
    const target = W8 === 'none' ? 0 : Math.round((W8 === 'rain' ? 140 : W8 === 'blossoms' ? 30 : 110) * cfg.amount);
    const rate = target * (W8 === 'rain' ? 3 : W8 === 'blossoms' ? 0.25 : 0.35);
    let spawn = rate * dt;
    while (spawn > 0 && flakes.length < target * 2 + 5) {
      if (Math.random() < spawn) {
        const u = Math.random() * 1.1 - 0.05, v = Math.random() * 1.1 - 0.05;
        flakes.push(W8 === 'rain'
          ? { rain: true, u, v, a: 0, life: 0.18 + Math.random() * 0.12 }
          : W8 === 'blossoms'
          ? { petal: true, u, v, a: 0, life: 5 + Math.random() * 4, sz: 0.7 + Math.random() * 0.6, drift: 0.01 + Math.random() * 0.012, ph: Math.random() * 6.28, rot: Math.random() * 6.28 }
          : { rain: false, u, v, a: 0, life: 4 + Math.random() * 4, sz: 0.5 + Math.random(), drift: (Math.random() - 0.5) * 0.01, ph: Math.random() * 6.28 });
      }
      spawn -= 1;
    }
    for (let i = flakes.length - 1; i >= 0; i--) {
      const f = flakes[i];
      f.a += dt;
      if (f.petal) { f.u += (f.drift + Math.sin(f.ph + f.a * 1.1) * 0.012) * dt; f.v += (0.008 + Math.cos(f.ph + f.a * 0.9) * 0.006) * dt; f.rot += dt * 1.5; }
      else if (!f.rain) { f.u += (f.drift + Math.sin(f.ph + f.a * 0.8) * 0.004) * dt; f.v += 0.006 * dt; }
      if (f.a >= f.life) {
        if (inWater(f.u, f.v)) {
          splash(f.u, f.v, f.rain ? 0.0035 : 0.003, f.rain ? -0.28 : f.petal ? -0.04 : -0.09);
          if (f.petal) { yuzus.push(newFloater(f.u, f.v, cfg.floating === 'maple' ? KIND.maple : KIND.petal)); }
        }
        flakes.splice(i, 1);
      }
    }
  }

  function wipe(u, v, r, a) {
    const w = fogCv.width, h = fogCv.height, x = u * w, y = v * h, rr = r * w;
    const rg = fogCtx.createRadialGradient(x, y, 0, x, y, rr);
    rg.addColorStop(0, 'rgba(0,0,0,' + a + ')'); rg.addColorStop(1, 'rgba(0,0,0,0)');
    fogCtx.fillStyle = rg; fogCtx.fillRect(x - rr, y - rr, rr * 2, rr * 2);
  }

  function draw() {
    gl.viewport(0, 0, cv.width, cv.height);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, texScene);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, texMask);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, texFog);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, fogCv);
    gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, texEmit);
    gl.activeTexture(gl.TEXTURE4); gl.bindTexture(gl.TEXTURE_2D, texWave);
    for (let i = 0, j = 0; i < GW * GH; i++, j += 4) { const v = Math.max(0, Math.min(255, (h0[i] * 0.5 + 0.5) * 255)); waveBytes[j] = v; }
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, GW, GH, gl.RGBA, gl.UNSIGNED_BYTE, waveBytes);
    gl.uniform1i(uni.uScene, 0); gl.uniform1i(uni.uMask, 1); gl.uniform1i(uni.uFog, 2); gl.uniform1i(uni.uEmit, 3); gl.uniform1i(uni.uWave, 4);
    gl.uniform2f(uni.uRes, cv.width, cv.height);
    gl.uniform2f(uni.uImg, img.width, img.height);
    gl.uniform2f(uni.uWaveRes, GW, GH);
    const P = pan(); gl.uniform2f(uni.uPan, P[0], P[1]);
    gl.uniform1f(uni.uZoom, zoom());
    gl.uniform1f(uni.uT, time);
    gl.uniform1f(uni.uSteam, cfg.steam);
    gl.uniform1f(uni.uFlicker, cfg.flicker);
    gl.uniform1f(uni.uBass, audio.bass * cfg.react);
    gl.uniform1f(uni.uHigh, audio.high * cfg.react);
    const td = tod();
    gl.uniform1f(uni.uTod, td);
    // Licht für die Schatten: Tag = Sonne hoch von links oben (kurz, deutlich), Abend = flach von links (lang, weich),
    // Nacht = kaum Schatten (nur Laternen); bei Regen diffus -> schwächer
    {
      const day = Math.max(0, td), dusk = 1 - Math.abs(td), night = Math.max(0, -td);
      const ox = -0.35 * day - 1.1 * dusk - 0.2 * night, oy = -0.5 * day - 0.35 * dusk - 0.2 * night;
      const str = (0.38 * day + 0.26 * dusk + 0.06 * night) * (cfg.weather === 'rain' ? 1 - 0.6 * cfg.amount : 1);
      gl.uniform3f(uni.uLight, ox, oy, str);
    }
    gl.uniform1f(uni.uRainy, cfg.weather === 'rain' ? cfg.amount : 0);
    gl.uniform4f(uni.uPlane, PX0, PY0, GW * CELL, GH * CELL);
    const yp = new Float32Array(MAX_FLOAT * 4), yk = new Float32Array(MAX_FLOAT);
    yuzus.slice(0, MAX_FLOAT).forEach((y, i) => { yp.set([y.u, y.v + Math.sin(y.bob * 1.3) * 0.0008, y.r, y.rot], i * 4); yk[i] = y.kind; });
    gl.uniform4fv(uni.uFloat, yp);
    gl.uniform1fv(uni.uKind, yk);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    draw2d();
  }

  function draw2d() {
    g2.clearRect(0, 0, W, H);
    const px = pxPerImg();
    // Dampf über der Teeschale
    if (cfg.teasteam && tea.length) {
      g2.globalCompositeOperation = 'screen';
      for (const p of tea) {
        const k = p.a / p.life;
        const s = toScreen(p.u + Math.sin(p.ph + p.a * 1.5) * 0.004 * k, p.v - p.a * 0.012);
        const r = (p.w * 0.25 + k * p.w * 0.7) * px;
        const al = Math.sin(Math.min(1, k * 1.4) * Math.PI) * 0.12;
        const rg = g2.createRadialGradient(s[0], s[1], 0, s[0], s[1], r);
        rg.addColorStop(0, 'rgba(240,240,248,' + al + ')'); rg.addColorStop(1, 'rgba(240,240,248,0)');
        g2.fillStyle = rg; g2.fillRect(s[0] - r, s[1] - r, r * 2, r * 2);
      }
      g2.globalCompositeOperation = 'source-over';
    }
    // Schnee / Regen
    for (const f of flakes) {
      const s = toScreen(f.u, f.v), k = f.a / f.life;
      if (f.petal) {
        const r = f.sz * (1 + (1 - k) * 1.2) * px * 0.006 * sAt(f.v);
        const al = Math.min(1, f.a * 1.5) * (k > 0.9 ? (1 - k) / 0.1 : 1);
        g2.save(); g2.translate(s[0], s[1]); g2.rotate(f.rot); g2.scale(1, 0.55 + 0.45 * Math.abs(Math.cos(f.rot * 1.3)));
        g2.fillStyle = cfg.floating === 'maple' ? 'rgba(225,80,30,' + al + ')' : 'rgba(250,200,215,' + al + ')';
        g2.beginPath(); g2.ellipse(0, 0, r * 0.65, r, 0, 0, Math.PI * 2); g2.fill(); g2.restore();
      } else if (f.rain) {
        const L = (1 - k) * 0.05 * px;
        g2.strokeStyle = 'rgba(210,225,245,' + (0.35 * (1 - k)) + ')'; g2.lineWidth = 1.2;
        g2.beginPath(); g2.moveTo(s[0] - L * 0.15, s[1] - L); g2.lineTo(s[0], s[1]); g2.stroke();
      } else {
        const r = f.sz * (1 + (1 - k) * 1.4) * px * 0.0016 * sAt(f.v);     // kommt näher -> wird kleiner, bis er landet
        const al = Math.min(1, f.a * 2) * (k > 0.85 ? (1 - k) / 0.15 : 1) * 0.8;
        g2.fillStyle = 'rgba(255,255,255,' + al + ')';
        g2.beginPath(); g2.arc(s[0], s[1], r, 0, Math.PI * 2); g2.fill();
      }
    }
    if (cfg.clock) {
      const d = new Date(); let h = d.getHours(); const mm = String(d.getMinutes()).padStart(2, '0');
      if (!cfg.hour24) h = h % 12 || 12;
      const t = (cfg.hour24 ? String(h).padStart(2, '0') : h) + ':' + mm;
      if (clockEl.textContent !== t) clockEl.textContent = t;
    }
    clockEl.hidden = !cfg.clock;
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
    const q = toImg(e.clientX, e.clientY);
    wipe(q[0], q[1], 0.06, 0.6);
    if (!inWater(q[0], q[1])) return;
    splash(q[0], q[1], 0.009, -0.45);
    for (const y of yuzus) {    // Yuzus in der Nähe wegschubsen
      const dx = (y.u - q[0]) * IA, dy = y.v - q[1], d = Math.hypot(dx, dy);
      if (d < 0.12 && d > 1e-4) { const k = (0.12 - d) / 0.12 * 0.08; y.vu += dx / d * k / IA; y.vv += dy / d * k; y.spin += (Math.random() - 0.5) * 2; }
    }
  });

  /* ================= Wallpaper Engine ================= */
  window.wallpaperPropertyListener = {
    applyUserProperties: function (p) {
      const v = (k) => p[k].value;
      if (p.timemode) cfg.timemode = String(v('timemode'));
      if (p.weather) { cfg.weather = String(v('weather')); flakes = []; }
      if (p.amount) cfg.amount = (+v('amount')) / 100;
      if (p.steam) cfg.steam = (+v('steam')) / 100;
      if (p.floating) { const was = cfg.floating; cfg.floating = String(v('floating')); if (was !== cfg.floating) yuzus = []; }
      if (p.floatcount) cfg.floatcount = Math.min(MAX_FLOAT, +v('floatcount') | 0);
      if (p.yuzu) cfg.floatcount = Math.min(MAX_FLOAT, +v('yuzu') | 0);   // alter Name
      if (p.ripples) cfg.ripples = !!v('ripples');
      if (p.flicker) cfg.flicker = (+v('flicker')) / 100;
      if (p.teasteam) cfg.teasteam = !!v('teasteam');
      if (p.react) cfg.react = (+v('react')) / 100;
      if (p.parallax) cfg.parallax = (+v('parallax')) / 100;
      if (p.clock) cfg.clock = !!v('clock');
      if (p.hour24) cfg.hour24 = !!v('hour24');
      if (p.renderscale) { cfg.scale = (+v('renderscale') || 100) / 100; if (img) resize(); }
    },
    applyGeneralProperties: function (p) { if (p.fps) cfg.fpsCap = +p.fps || 0; },
    setPaused: function (x) { const was = paused; paused = !!x; if (was && !paused && img) { last = performance.now(); requestAnimationFrame(frame); } },
  };

  let maskImg = null;
  img = new Image();
  img.onload = () => {
    IA = img.width / img.height;
    if (SC.waterMask && !maskImg) {                  // erst die Maske laden, dann aufbauen
      maskImg = new Image();
      maskImg.onload = img.onload;
      maskImg.onerror = () => { maskImg = null; img.onload(); };
      maskImg.src = SC.waterMask;
      return;
    }
    setup(); resize();
    window.addEventListener('resize', resize);
    last = performance.now(); requestAnimationFrame(frame);
  };
  img.src = SC.image;
  // zum Testen: vorspulen, klicken
  window.Onsen = { step: (dt, n) => { for (let i = 0; i < (n || 1); i++) step(dt); draw(); }, cfg, splash, wipe, yuzus: () => yuzus };
})();
