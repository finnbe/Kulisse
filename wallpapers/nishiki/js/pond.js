/* Renderer (WebGL 2). Ablauf pro Bild:
   1. Wellen-Simulation, 2. Schatten von Fischen und Blättern, 3. Unterwasser-Ebene (Grund + Fische),
   4. Wasseroberfläche mit Brechung, darauf Blätter, Blüten, Futter und Glühwürmchen. */
(function () {
  'use strict';
  const N = window.Nishiki, S = N.shaders;
  const P = N.pond = {};

  const SIM_H = 320;
  let gl = null, cv = null;
  let W = 1, H = 1, asp = 1, enc8 = false;
  const pr = {};
  let quadVAO, fishVAO, fishVBO, sprVAO, sprVBO;
  let sim = [null, null], simIdx = 0, simAcc = 0;
  let scene = null, shadow = null, floor = null;
  let texNoise = null, texFish = null, texSprite = null;
  let dropQ = [];
  const dropArr = new Float32Array(S.MAX_DROPS * 4);
  let floorDirty = true;
  const floorCfg = { seed: 1, detail: 0.7, scale: 21 };
  P.ready = false;

  function shader(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error('Shader: ' + gl.getShaderInfoLog(s));
    return s;
  }
  function program(vs, fs) {
    const p = gl.createProgram();
    gl.attachShader(p, shader(gl.VERTEX_SHADER, vs)); gl.attachShader(p, shader(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error('Programm: ' + gl.getProgramInfoLog(p));
    const u = {}, n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
    for (let i = 0; i < n; i++) { const inf = gl.getActiveUniform(p, i); u[inf.name.replace(/\[0\]$/, '')] = gl.getUniformLocation(p, inf.name); }
    return { p, u };
  }
  function target(w, h, float, filter) {
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    if (float) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, null);
    else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const fbo = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    return { tex, fbo, w, h };
  }
  function freeTarget(t) { if (t) { gl.deleteTexture(t.tex); gl.deleteFramebuffer(t.fbo); } }
  function canvasTexture(canvas, premult) {
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, premult ? 1 : 0);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, canvas);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, 0);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return tex;
  }
  /* Kachelbares, weiches Rauschen in vier Kanälen: für kleine Wellen und Lichtflecken. */
  function noiseTexture() {
    const n = 256, data = new Uint8Array(n * n * 4), U = N.util;
    for (let c = 0; c < 4; c++) {
      const r = U.rng(100 + c * 17);
      const grids = [16, 32].map((g) => { const a = new Float32Array(g * g); for (let i = 0; i < a.length; i++) a[i] = r(); return { g, a }; });
      for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
        let v = 0, w = 0.65;
        for (const G of grids) {
          const fx = x / n * G.g, fy = y / n * G.g, xi = Math.floor(fx), yi = Math.floor(fy);
          let tx = fx - xi, ty = fy - yi; tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
          const at = (i, j) => G.a[((j + G.g) % G.g) * G.g + ((i + G.g) % G.g)];
          v += w * ((at(xi, yi) * (1 - tx) + at(xi + 1, yi) * tx) * (1 - ty) + (at(xi, yi + 1) * (1 - tx) + at(xi + 1, yi + 1) * tx) * ty);
          w = 0.35;
        }
        data[(y * n + x) * 4 + c] = Math.max(0, Math.min(255, v * 255));
      }
    }
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, n, n, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    return tex;
  }
  function vao(buffer, stride, attrs) {
    const v = gl.createVertexArray();
    gl.bindVertexArray(v); gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    let off = 0;
    attrs.forEach((size, i) => { gl.enableVertexAttribArray(i); gl.vertexAttribPointer(i, size, gl.FLOAT, false, stride * 4, off * 4); off += size; });
    gl.bindVertexArray(null);
    return v;
  }

  P.init = function (canvas) {
    cv = canvas;
    gl = cv.getContext('webgl2', { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: 'high-performance' });
    if (!gl) return false;
    enc8 = !(gl.getExtension('EXT_color_buffer_float') || gl.getExtension('EXT_color_buffer_half_float'));
    pr.sim = program(S.quadVS, S.simFS(enc8));
    pr.floor = program(S.quadVS, S.floorFS);
    pr.under = program(S.quadVS, S.underFS(enc8));
    pr.fish = program(S.fishVS, S.fishFS);
    pr.fishSh = program(S.fishVS, S.fishShadowFS);
    pr.comp = program(S.quadVS, S.compFS(enc8));
    pr.spr = program(S.spriteVS, S.spriteFS);

    const qb = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, qb);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    quadVAO = vao(qb, 2, [2]);
    fishVBO = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, fishVBO); gl.bufferData(gl.ARRAY_BUFFER, N.koi.buffer.byteLength, gl.DYNAMIC_DRAW);
    fishVAO = vao(fishVBO, N.koi.STRIDE, [2, 2, 2, 2, 4]);
    sprVBO = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, sprVBO); gl.bufferData(gl.ARRAY_BUFFER, N.flora.buffer.byteLength, gl.DYNAMIC_DRAW);
    sprVAO = vao(sprVBO, N.flora.STRIDE, [2, 2, 2, 2]);

    texNoise = noiseTexture();
    texSprite = canvasTexture(N.art.canvas || N.art.build(), true);
    texFish = null;
    gl.disable(gl.DEPTH_TEST); gl.disable(gl.CULL_FACE);
    P.ready = true;
    return true;
  };

  P.uploadFish = function (canvas) {
    if (texFish) gl.deleteTexture(texFish);
    texFish = canvasTexture(canvas, false);
  };

  P.resize = function (w, h) {
    W = Math.max(2, w | 0); H = Math.max(2, h | 0); asp = W / H;
    cv.width = W; cv.height = H;
    freeTarget(scene); freeTarget(shadow); freeTarget(floor); freeTarget(sim[0]); freeTarget(sim[1]);
    scene = target(W, H, false, gl.LINEAR);
    floor = target(W, H, false, gl.LINEAR);
    shadow = target(Math.max(2, Math.round(W / 3)), Math.max(2, Math.round(H / 3)), false, gl.LINEAR);
    const sw = Math.max(2, Math.round(SIM_H * asp));
    for (let i = 0; i < 2; i++) {
      sim[i] = target(sw, SIM_H, !enc8, gl.LINEAR);
      gl.clearColor(enc8 ? 0.5 : 0, enc8 ? 0.5 : 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
    }
    simIdx = 0; dropQ = [];
    floorDirty = true;
    return asp;
  };
  P.aspect = () => asp;

  P.setFloor = function (c) {
    if (c.seed !== undefined) floorCfg.seed = c.seed;
    if (c.detail !== undefined) floorCfg.detail = c.detail;
    floorDirty = true;
  };

  /* Tropfen in Teich-Koordinaten. */
  P.drop = function (x, y, r, s) {
    if (dropQ.length >= S.MAX_DROPS * 3 * 4) dropQ.splice(0, 4);
    dropQ.push(x / asp, 1 - y, r, s);
  };

  function drawQuad() { gl.bindVertexArray(quadVAO); gl.drawArrays(gl.TRIANGLES, 0, 3); }
  function bindTex(unit, tex, loc) { gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, tex); gl.uniform1i(loc, unit); }

  function bakeFloor() {
    floorDirty = false;
    gl.bindFramebuffer(gl.FRAMEBUFFER, floor.fbo); gl.viewport(0, 0, W, H); gl.disable(gl.BLEND);
    const p = pr.floor; gl.useProgram(p.p);
    gl.uniform1f(p.u.uAspect, asp); gl.uniform1f(p.u.uSeed, floorCfg.seed); gl.uniform1f(p.u.uDetail, floorCfg.detail); gl.uniform1f(p.u.uScale, floorCfg.scale);
    drawQuad();
  }

  function simSteps(dt) {
    simAcc += dt;
    let n = Math.floor(simAcc * 60 + 1e-6);
    simAcc -= n / 60;
    if (n > 3) { n = 3; simAcc = 0; }
    const p = pr.sim; gl.useProgram(p.p); gl.disable(gl.BLEND);
    for (let i = 0; i < n; i++) {
      const src = sim[simIdx], dst = sim[1 - simIdx];
      gl.bindFramebuffer(gl.FRAMEBUFFER, dst.fbo); gl.viewport(0, 0, dst.w, dst.h);
      bindTex(0, src.tex, p.u.uPrev);
      gl.uniform2f(p.u.uTexel, 1 / src.w, 1 / src.h); gl.uniform1f(p.u.uAspect, asp); gl.uniform1f(p.u.uDamp, 0.9915);
      const cnt = Math.min(S.MAX_DROPS, dropQ.length / 4);
      for (let k = 0; k < cnt * 4; k++) dropArr[k] = dropQ[k];
      dropQ.splice(0, cnt * 4);
      gl.uniform4fv(p.u.uDrops, dropArr); gl.uniform1i(p.u.uDropN, cnt);
      drawQuad();
      simIdx = 1 - simIdx;
    }
  }

  /* st: { time, dt, pal, fishVerts, spr: {nShadow, nSurface, nTotal}, caustics, moon } */
  P.render = function (st) {
    if (!P.ready) return;
    const pal = st.pal, t = st.time;
    if (floorDirty) bakeFloor();
    simSteps(st.dt);
    const simTex = sim[simIdx];

    gl.bindBuffer(gl.ARRAY_BUFFER, fishVBO);
    if (st.fishVerts) gl.bufferSubData(gl.ARRAY_BUFFER, 0, N.koi.buffer, 0, st.fishVerts * N.koi.STRIDE);
    gl.bindBuffer(gl.ARRAY_BUFFER, sprVBO);
    if (st.spr.nTotal) gl.bufferSubData(gl.ARRAY_BUFFER, 0, N.flora.buffer, 0, st.spr.nTotal * N.flora.STRIDE);

    // --- Schatten ---
    gl.bindFramebuffer(gl.FRAMEBUFFER, shadow.fbo); gl.viewport(0, 0, shadow.w, shadow.h);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    let p = pr.fishSh; gl.useProgram(p.p);
    gl.uniform1f(p.u.uAspect, asp); gl.uniform2f(p.u.uOffset, 0.046, 0.068);
    if (st.fishVerts) { gl.bindVertexArray(fishVAO); gl.drawArrays(gl.TRIANGLES, 0, st.fishVerts); }
    p = pr.spr; gl.useProgram(p.p);
    gl.uniform1f(p.u.uAspect, asp); gl.uniform2f(p.u.uOffset, 0.034, 0.050); gl.uniform1f(p.u.uMode, 2);
    bindTex(0, texSprite, p.u.uAtlas);
    if (st.spr.nShadow) { gl.bindVertexArray(sprVAO); gl.drawArrays(gl.TRIANGLES, 0, st.spr.nShadow); }

    // --- Unterwasser ---
    gl.bindFramebuffer(gl.FRAMEBUFFER, scene.fbo); gl.viewport(0, 0, W, H);
    gl.disable(gl.BLEND);
    p = pr.under; gl.useProgram(p.p);
    bindTex(0, floor.tex, p.u.uFloor); bindTex(1, shadow.tex, p.u.uShadow); bindTex(2, simTex.tex, p.u.uSim); bindTex(3, texNoise, p.u.uNoise);
    gl.uniform2f(p.u.uSimTexel, 1 / simTex.w, 1 / simTex.h); gl.uniform2f(p.u.uShTexel, 1 / shadow.w, 1 / shadow.h);
    gl.uniform1f(p.u.uAspect, asp); gl.uniform1f(p.u.uTime, t);
    gl.uniform1f(p.u.uCaustic, pal.caust * st.caustics); gl.uniform1f(p.u.uShadowK, pal.shadow); gl.uniform1f(p.u.uFog, pal.fog); gl.uniform1f(p.u.uDapple, pal.dapple);
    gl.uniform3fv(p.u.uTint, pal.tint); gl.uniform3fv(p.u.uDeep, pal.deep); gl.uniform3fv(p.u.uSun, pal.sun); gl.uniform3fv(p.u.uAmb, pal.amb);
    drawQuad();
    if (st.fishVerts && texFish) {
      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      p = pr.fish; gl.useProgram(p.p);
      bindTex(0, texFish, p.u.uAtlas);
      gl.uniform2f(p.u.uCell, N.koi.cell[0], N.koi.cell[1]);
      gl.uniform1f(p.u.uAspect, asp); gl.uniform2f(p.u.uOffset, 0, 0); gl.uniform1f(p.u.uTime, t);
      gl.uniform1f(p.u.uCaustic, pal.caust * st.caustics); gl.uniform1f(p.u.uFog, pal.fog);
      gl.uniform3fv(p.u.uTint, pal.tint); gl.uniform3fv(p.u.uDeep, pal.deep); gl.uniform3fv(p.u.uSun, pal.sun); gl.uniform3fv(p.u.uAmb, pal.amb);
      gl.bindVertexArray(fishVAO); gl.drawArrays(gl.TRIANGLES, 0, st.fishVerts);
    }

    // --- Oberfläche ---
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0, 0, W, H);
    gl.disable(gl.BLEND);
    p = pr.comp; gl.useProgram(p.p);
    bindTex(0, scene.tex, p.u.uScene); bindTex(1, simTex.tex, p.u.uSim); bindTex(2, texNoise, p.u.uNoise);
    gl.uniform2f(p.u.uSimTexel, 1 / simTex.w, 1 / simTex.h); gl.uniform1f(p.u.uSimH, SIM_H);
    gl.uniform1f(p.u.uAspect, asp); gl.uniform1f(p.u.uTime, t);
    gl.uniform1f(p.u.uRefr, 0.020); gl.uniform1f(p.u.uAmbWave, pal.wave); gl.uniform1f(p.u.uVig, pal.vig);
    gl.uniform3fv(p.u.uSky, pal.sky); gl.uniform3fv(p.u.uGlint, pal.glint); gl.uniform3fv(p.u.uMoonCol, pal.moonCol);
    gl.uniform4f(p.u.uMoon, st.moon[0], st.moon[1], st.moon[2], st.moon[3]);
    drawQuad();

    if (st.spr.nTotal) {
      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      p = pr.spr; gl.useProgram(p.p);
      bindTex(0, texSprite, p.u.uAtlas);
      gl.uniform1f(p.u.uAspect, asp); gl.uniform2f(p.u.uOffset, 0, 0); gl.uniform1f(p.u.uMode, 0);
      gl.uniform3fv(p.u.uLight, pal.sprite); gl.uniform1f(p.u.uGloss, pal.gloss); gl.uniform1f(p.u.uVig, pal.vig);
      gl.bindVertexArray(sprVAO);
      if (st.spr.nSurface) gl.drawArrays(gl.TRIANGLES, 0, st.spr.nSurface);
      if (st.spr.nTotal > st.spr.nSurface) {
        gl.blendFunc(gl.ONE, gl.ONE);
        gl.uniform1f(p.u.uMode, 1); gl.uniform3f(p.u.uLight, 0.80, 1.0, 0.42);
        gl.drawArrays(gl.TRIANGLES, st.spr.nSurface, st.spr.nTotal - st.spr.nSurface);
      }
    }
    gl.bindVertexArray(null);
  };
})();
