/* GLSL-Quelltexte (WebGL 2). Teich-Koordinaten: x von 0 bis Seitenverhältnis, y von 0 (oben) bis 1 (unten). */
(function () {
  'use strict';
  const N = window.Nishiki = window.Nishiki || {};
  const S = N.shaders = {};

  S.MAX_DROPS = 32;

  const head = '#version 300 es\nprecision highp float;\n';

  const noise = `
float hash1(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
vec2 hash2(vec2 p){ return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453123); }
float vnoise(vec2 p){
  vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
  float a = hash1(i), b = hash1(i + vec2(1.0, 0.0)), c = hash1(i + vec2(0.0, 1.0)), d = hash1(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p){
  float s = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.03 + vec2(17.1, 9.7); a *= 0.5; }
  return s;
}
`;

  /* Lichtspiel am Grund: Wellenfeld aus gerichteten Sinuswellen. Die Helligkeit folgt aus der Bündelung des
     gebrochenen Lichts, also dem Kehrwert der Determinante von (I + d * Hesse-Matrix der Wasserhöhe). */
  const caustic = `
float caust(vec2 p, float t){
  p += 0.022 * vec2(sin(p.y * 7.3 + t * 0.23), cos(p.x * 6.1 - t * 0.19));
  float hxx = 0.0, hxy = 0.0, hyy = 0.0;
  for (int i = 0; i < 7; i++) {
    float fi = float(i);
    float a = fi * 2.399963 + 0.7;
    float f = 15.0 + fi * 7.3;
    vec2 k = vec2(cos(a), sin(a));
    float s = sin(dot(k, p) * f + t * (0.55 + 0.14 * fi) + fi * 1.7);
    hxx -= s * k.x * k.x; hxy -= s * k.x * k.y; hyy -= s * k.y * k.y;
  }
  float d = 0.62;
  float det = (1.0 + d * hxx) * (1.0 + d * hyy) - d * d * hxy * hxy;
  float c = 1.0 / (abs(det) + 0.30);
  return min(0.34 + c * 0.36, 2.3);
}
`;

  S.quadVS = head + `
layout(location = 0) in vec2 aPos;
out vec2 vUv;
void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos, 0.0, 1.0); }
`;

  /* ---------- Wellen-Simulation: r = Höhe, g = Höhe im Schritt davor ---------- */
  S.simFS = (enc8) => head + `
in vec2 vUv; out vec4 o;
uniform sampler2D uPrev;
uniform vec2 uTexel;
uniform float uAspect, uDamp;
uniform vec4 uDrops[${S.MAX_DROPS}];
uniform int uDropN;
${enc8 ? '#define DEC(v) ((v) * 4.0 - 2.0)\n#define ENC(v) ((v) * 0.25 + 0.5)' : '#define DEC(v) (v)\n#define ENC(v) (v)'}
void main(){
  vec4 s = texture(uPrev, vUv);
  float h = DEC(s.r), hp = DEC(s.g);
  float l = DEC(texture(uPrev, vUv - vec2(uTexel.x, 0.0)).r);
  float r = DEC(texture(uPrev, vUv + vec2(uTexel.x, 0.0)).r);
  float d = DEC(texture(uPrev, vUv - vec2(0.0, uTexel.y)).r);
  float u = DEC(texture(uPrev, vUv + vec2(0.0, uTexel.y)).r);
  float n = (l + r + u + d) * 0.5 - hp;
  n = mix(n, (l + r + u + d) * 0.25, 0.012);
  n *= uDamp;
  for (int i = 0; i < ${S.MAX_DROPS}; i++) {
    if (i >= uDropN) break;
    vec2 dd = (vUv - uDrops[i].xy) * vec2(uAspect, 1.0);
    float q = dot(dd, dd) / (uDrops[i].z * uDrops[i].z);
    n += uDrops[i].w * (1.0 - 1.3 * q) * exp(-1.3 * q);
  }
  vec2 e = min(vUv, 1.0 - vUv);
  n *= 0.86 + 0.14 * smoothstep(0.0, 0.025, min(e.x, e.y));
  o = vec4(ENC(clamp(n, -2.0, 2.0)), ENC(h), 0.0, 1.0);
}
`;

  /* ---------- Teichgrund, einmal gebacken: rgb = Kiesel und Sand, a = Tiefe ---------- */
  S.floorFS = head + `
in vec2 vUv; out vec4 o;
uniform float uAspect, uSeed, uDetail, uScale;
${noise}
vec3 stoneCol(float h){
  vec3 c = vec3(0.60, 0.57, 0.52);
  c = mix(c, vec3(0.74, 0.69, 0.60), smoothstep(0.16, 0.20, h));
  c = mix(c, vec3(0.42, 0.43, 0.46), smoothstep(0.36, 0.40, h));
  c = mix(c, vec3(0.68, 0.52, 0.38), smoothstep(0.54, 0.58, h));
  c = mix(c, vec3(0.86, 0.84, 0.78), smoothstep(0.72, 0.76, h));
  c = mix(c, vec3(0.50, 0.44, 0.36), smoothstep(0.86, 0.90, h));
  c = mix(c, vec3(0.34, 0.36, 0.40), smoothstep(0.95, 0.97, h));
  return c;
}
/* Dicht liegende Flusskiesel: jede Voronoi-Zelle ist ein Stein. Gibt Farbe, Maske und Wölbung zurück. */
vec3 cobble(vec2 p, float seed, out float m, out float dome){
  vec2 n = floor(p), f = fract(p);
  float d1 = 9.0, d2 = 9.0; vec2 id = vec2(0.0), rc = vec2(0.0);
  for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
    vec2 g = vec2(float(i), float(j));
    vec2 r = g + 0.08 + 0.84 * hash2(n + g + seed) - f; float d = dot(r, r);
    if (d < d1) { d2 = d1; d1 = d; id = n + g; rc = r; } else if (d < d2) { d2 = d; }
  }
  d1 = sqrt(d1); d2 = sqrt(d2);
  float h = hash1(id + seed * 1.7);
  float rad = 0.36 + 0.16 * hash1(id * 1.3 + 5.1 + seed);
  float e = min((d2 - d1) * 0.5, (rad - d1) * 0.8);
  m = smoothstep(0.012, 0.05, e);
  dome = smoothstep(0.0, 0.30, e);
  dome = 1.0 - (1.0 - dome) * (1.0 - dome);
  vec3 nrm = normalize(vec3(-rc / (d1 + 1e-4) * (1.0 - dome) * 1.25, 0.30 + dome));
  float dif = clamp(dot(nrm, normalize(vec3(-0.45, -0.55, 0.70))), 0.0, 1.0);
  vec3 col = stoneCol(h) * (0.38 + 0.80 * dif);
  col *= 0.86 + 0.28 * vnoise(p * 7.0 + h * 40.0);
  col *= 0.92 + 0.16 * hash1(id * 3.1 + seed);
  return col;
}
void main(){
  vec2 P = vec2(vUv.x * uAspect, 1.0 - vUv.y);
  vec2 q = P * uScale + uSeed * 13.0;
  float m, dome;
  vec3 st = cobble(q + 0.18 * vec2(fbm(q * 0.7), fbm(q * 0.7 + 5.0)), uSeed + 1.0, m, dome);
  vec3 gap = vec3(0.30, 0.27, 0.22) * (0.7 + 0.6 * vnoise(q * 9.0));
  float m2, dome2;
  vec3 st2 = cobble(q * 2.6 + 31.0, uSeed + 2.0, m2, dome2);
  gap = mix(gap, st2 * 0.78, m2);
  vec3 col = mix(gap, st, m);
  // Sand: begräbt die Steine stellenweise, nur die Kuppen schauen heraus
  float silt = smoothstep(0.36, 0.74, fbm(P * 2.3 + uSeed * 5.0));
  vec3 sand = vec3(0.66, 0.60, 0.47) * (0.88 + 0.24 * vnoise(q * 11.0)) * (0.92 + 0.16 * fbm(q * 2.0));
  float bury = 1.0 - smoothstep(silt * 1.25 - 0.22, silt * 1.25 + 0.02, dome * m);
  col = mix(col, sand * (0.86 + 0.14 * (1.0 - bury)), bury * step(0.001, silt));
  float alg = smoothstep(0.50, 0.85, fbm(P * 4.1 + 31.0 + uSeed));
  col = mix(col, col * vec3(0.66, 0.88, 0.56), alg * 0.55);
  col *= 0.86 + 0.28 * fbm(P * 1.7 + uSeed * 3.0);
  col = mix(vec3(0.52, 0.49, 0.42), col, uDetail);
  float dep = smoothstep(0.30, 0.74, fbm(P * 0.85 + uSeed * 2.3 + 11.0));
  o = vec4(col, dep);
}
`;

  /* ---------- Unterwasser-Ebene: Grund mit Licht, Schatten, Kaustik ---------- */
  S.underFS = (enc8) => head + `
in vec2 vUv; out vec4 o;
uniform sampler2D uFloor, uShadow, uSim, uNoise;
uniform vec2 uSimTexel, uShTexel;
uniform float uAspect, uTime, uCaustic, uShadowK, uFog, uDapple;
uniform vec3 uTint, uDeep, uSun, uAmb;
${enc8 ? '#define DEC(v) ((v) * 4.0 - 2.0)' : '#define DEC(v) (v)'}
${caustic}
void main(){
  vec2 P = vec2(vUv.x * uAspect, 1.0 - vUv.y);
  vec4 f = texture(uFloor, vUv);
  float sh = texture(uShadow, vUv).r * 0.28;
  sh += texture(uShadow, vUv + vec2( 1.6,  0.9) * uShTexel).r * 0.18;
  sh += texture(uShadow, vUv + vec2(-1.6, -0.9) * uShTexel).r * 0.18;
  sh += texture(uShadow, vUv + vec2( 0.9, -1.6) * uShTexel).r * 0.18;
  sh += texture(uShadow, vUv + vec2(-0.9,  1.6) * uShTexel).r * 0.18;
  float hc = DEC(texture(uSim, vUv).r);
  float lap = DEC(texture(uSim, vUv + vec2(uSimTexel.x * 1.5, 0.0)).r) + DEC(texture(uSim, vUv - vec2(uSimTexel.x * 1.5, 0.0)).r)
            + DEC(texture(uSim, vUv + vec2(0.0, uSimTexel.y * 1.5)).r) + DEC(texture(uSim, vUv - vec2(0.0, uSimTexel.y * 1.5)).r) - 4.0 * hc;
  float c = caust(P, uTime);
  c = mix(1.0, c, uCaustic);
  c *= clamp(1.0 - lap * 9.0, 0.35, 2.6);
  float dap = texture(uNoise, P * 0.31 + uTime * vec2(0.004, 0.002)).b * 0.6 + texture(uNoise, P * 0.83 - uTime * vec2(0.003, 0.005)).a * 0.4;
  dap = mix(1.0, 0.66 + 0.5 * smoothstep(0.34, 0.66, dap), uDapple);
  vec3 light = uAmb + uSun * c * dap * (1.0 - sh * uShadowK);
  light *= 1.0 - sh * uShadowK * 0.35;
  vec3 col = f.rgb * light * uTint;
  col = mix(col, uDeep, clamp(f.a * uFog, 0.0, 1.0));
  o = vec4(col, 1.0);
}
`;

  /* ---------- Fische ---------- */
  S.fishVS = head + `
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in vec2 aTex;
layout(location = 3) in vec2 aMisc;
layout(location = 4) in vec4 aFin;
uniform float uAspect;
uniform vec2 uOffset;
out vec2 vUv; out vec2 vTex; out vec2 vMisc; out vec4 vFin; out vec2 vP;
void main(){
  vec2 p = aPos + uOffset * (1.0 - aMisc.y);
  vUv = aUv; vTex = aTex; vMisc = aMisc; vFin = aFin; vP = aPos;
  gl_Position = vec4(p.x / uAspect * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
}
`;
  S.fishFS = head + `
in vec2 vUv; in vec2 vTex; in vec2 vMisc; in vec4 vFin; in vec2 vP;
out vec4 o;
uniform sampler2D uAtlas;
uniform vec2 uCell;
uniform float uTime, uCaustic, uFog;
uniform vec3 uTint, uDeep, uSun, uAmb;
${caustic}
void main(){
  float part = vMisc.x, depth = vMisc.y;
  float av = abs(vUv.y);
  float fw = fwidth(vUv.y) * 1.5 + 0.02;
  float a = 1.0 - smoothstep(1.0 - fw, 1.0, av);
  vec3 col;
  if (part < 0.5) {
    vec2 t = vTex + vec2(clamp(vUv.x, 0.004, 0.996), clamp(vUv.y * 0.5 + 0.5, 0.02, 0.98)) * uCell;
    col = texture(uAtlas, t).rgb;
    float nz = sqrt(max(0.0, 1.0 - vUv.y * vUv.y));
    col *= 0.46 + 0.56 * nz;
    col += vec3(0.16) * pow(nz, 7.0) * smoothstep(0.02, 0.2, vUv.x);
    float dl = smoothstep(0.075, 0.0, av) * smoothstep(0.30, 0.38, vUv.x) * (1.0 - smoothstep(0.60, 0.72, vUv.x));
    col = mix(col, col * 0.62 + vFin.rgb * 0.10, dl * 0.65);
  } else {
    float u = vUv.x;
    float rays = 0.90 + 0.10 * sin(vUv.y * (part < 1.5 ? 17.0 : 12.0) + vFin.a * 6.0);
    col = vFin.rgb * rays * (0.90 + 0.10 * (1.0 - u));
    float al = mix(0.74, 0.34, u);
    if (part < 1.5) {
      float nw = clamp((u - 0.60) / 0.40, 0.0, 1.0) * 0.55;
      al *= mix(1.0, smoothstep(nw - 0.10, nw + 0.05, av), smoothstep(0.60, 0.68, u));
      al *= 1.0 - smoothstep(0.86, 1.0, u) * 0.6;
    } else {
      al *= 1.0 - smoothstep(0.80, 1.0, u) * 0.5;
    }
    a *= al;
  }
  float c = mix(1.0, caust(vP, uTime), uCaustic * 0.55);
  vec3 light = uAmb * 1.15 + uSun * (0.55 + 0.45 * c);
  col *= light;
  col = mix(col, col * uTint, 0.12 + 0.50 * depth);
  col = mix(col, uDeep, clamp(depth * uFog * 0.50, 0.0, 0.7));
  o = vec4(col * a, a);
}
`;
  S.fishShadowFS = head + `
in vec2 vUv; in vec2 vTex; in vec2 vMisc; in vec4 vFin; in vec2 vP;
out vec4 o;
void main(){
  float a = 1.0 - smoothstep(0.75, 1.0, abs(vUv.y));
  if (vMisc.x > 0.5) a *= 0.45;
  a *= 0.55 + 0.45 * vMisc.y;
  o = vec4(a);
}
`;

  /* ---------- Wasseroberfläche: Brechung, Glanz, Mondspiegelung ---------- */
  S.compFS = (enc8) => head + `
in vec2 vUv; out vec4 o;
uniform sampler2D uScene, uSim, uNoise;
uniform vec2 uSimTexel;
uniform float uAspect, uTime, uRefr, uAmbWave, uVig, uSimH;
uniform vec3 uSky, uGlint, uMoonCol;
uniform vec4 uMoon;
${enc8 ? '#define DEC(v) ((v) * 4.0 - 2.0)' : '#define DEC(v) (v)'}
float hash1(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
void main(){
  vec2 P = vec2(vUv.x * uAspect, 1.0 - vUv.y);
  float hl = DEC(texture(uSim, vUv - vec2(uSimTexel.x, 0.0)).r);
  float hr = DEC(texture(uSim, vUv + vec2(uSimTexel.x, 0.0)).r);
  float hd = DEC(texture(uSim, vUv - vec2(0.0, uSimTexel.y)).r);
  float hu = DEC(texture(uSim, vUv + vec2(0.0, uSimTexel.y)).r);
  vec2 g = vec2(hr - hl, hd - hu) * (uSimH / 320.0) * 3.2;
  vec2 amb = texture(uNoise, P * 0.9 + uTime * vec2(0.013, 0.009)).rg + texture(uNoise, P * 1.9 + uTime * vec2(-0.011, 0.016)).ba - 1.0;
  vec2 n2 = g + amb * uAmbWave;
  vec2 off = n2 * uRefr;
  vec2 duv = vec2(off.x / uAspect, -off.y);
  vec3 col;
  col.r = texture(uScene, vUv + duv * 1.12).r;
  col.g = texture(uScene, vUv + duv).g;
  col.b = texture(uScene, vUv + duv * 0.88).b;
  vec2 L = normalize(vec2(-0.55, -0.80));
  float fac = dot(-n2, L);
  float gl = length(g);
  col += uSky * (min(max(fac, 0.0), 0.45) * 0.80 + min(gl, 0.6) * 0.10);
  col *= 1.0 - clamp(max(-fac, 0.0) * 0.55, 0.0, 0.42);
  col += uGlint * smoothstep(0.34, 0.85, fac) * 0.55;
  vec2 md = P + g * 0.18 + amb * 0.010 - uMoon.xy;
  float ml = length(md);
  float disc = 1.0 - smoothstep(uMoon.z * 0.55, uMoon.z * 1.05, ml);
  float halo = exp(-ml * ml / (uMoon.z * uMoon.z * 14.0));
  float sparkle = smoothstep(0.30, 0.70, fac) * exp(-ml * ml / (uMoon.z * uMoon.z * 30.0));
  col = col * (1.0 - disc * 0.35 * uMoon.w) + uMoonCol * (disc * 0.30 + halo * 0.13 + sparkle * 0.5) * uMoon.w;
  vec2 vc = (vUv - 0.5) * vec2(1.05, 1.2);
  col *= mix(1.0, smoothstep(1.05, 0.25, length(vc)), uVig);
  col += (hash1(gl_FragCoord.xy + uTime) - 0.5) / 255.0;
  o = vec4(col, 1.0);
}
`;

  /* ---------- Alles auf der Oberfläche: Seerosenblätter, Blüten, Blütenblätter, Futter, Glühwürmchen ---------- */
  S.spriteVS = head + `
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in vec2 aLocal;
layout(location = 3) in vec2 aMisc;
uniform float uAspect;
uniform vec2 uOffset;
out vec2 vUv; out vec2 vLocal; out vec2 vMisc; out vec2 vScr;
void main(){
  vec2 p = aPos + uOffset;
  vUv = aUv; vLocal = aLocal; vMisc = aMisc;
  vec2 c = vec2(p.x / uAspect * 2.0 - 1.0, 1.0 - p.y * 2.0);
  vScr = c * 0.5;
  gl_Position = vec4(c, 0.0, 1.0);
}
`;
  S.spriteFS = head + `
in vec2 vUv; in vec2 vLocal; in vec2 vMisc; in vec2 vScr;
out vec4 o;
uniform sampler2D uAtlas;
uniform vec3 uLight;
uniform float uGloss, uVig, uMode;
void main(){
  vec4 t = texture(uAtlas, vUv);
  if (uMode > 1.5) { o = vec4(t.a * vMisc.y); return; }
  if (uMode > 0.5) { o = vec4(t.rgb * uLight * vMisc.y, 0.0); return; }
  vec3 col = t.rgb * uLight;
  if (vMisc.x < 0.5) {
    float gl = smoothstep(0.85, 0.0, length(vLocal - vec2(-0.30, -0.36)));
    col += vec3(1.0, 1.0, 0.9) * gl * gl * uGloss * t.a;
    col *= 0.86 + 0.14 * smoothstep(0.9, -0.6, vLocal.x * 0.55 + vLocal.y * 0.8);
  }
  vec2 vc = vScr * vec2(1.05, 1.2);
  col *= mix(1.0, smoothstep(1.05, 0.25, length(vc)), uVig);
  o = vec4(col, t.a) * vMisc.y;
}
`;
})();
