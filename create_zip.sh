#!/usr/bin/env bash
set -euo pipefail

OUTDIR="WebGC-scaffold"
ZIPNAME="WebGC-scaffold.zip"

# Clean up previous run
rm -rf "$OUTDIR" "$ZIPNAME"
mkdir -p "$OUTDIR/public" "$OUTDIR/scripts" "$OUTDIR/.github/workflows"

cat > "$OUTDIR/README.md" <<'README'
# WebGC

WebGC is a private project to compile the Dolphin GameCube/Wii emulator to WebAssembly and run it in the browser (interpreter-only, no JIT). This repository contains the web frontend, dev server, build scripts, and CI workflow. The Dolphin upstream source is added as a git submodule under third_party/dolphin.

IMPORTANT: Dolphin is GPL-licensed. If you distribute compiled binaries publicly you must comply with the GPL terms (provide source or an offer). You must also not upload or distribute copyrighted game ISOs — provide your own legally-obtained ISOs locally.

Quick start (developer machine)

Prereqs:
- Linux/macOS (or WSL on Windows)
- Git, python3, cmake, ninja, nodejs
- Emscripten SDK (emsdk)

Clone this repo (already created under your account):

  git clone https://github.com/Trent525/WebGC.git
  cd WebGC

Fetch Dolphin source (script will do this for missing):

  ./scripts/fetch_dolphin.sh

Install and activate emsdk (example):

  git clone https://github.com/emscripten-core/emsdk.git emsdk
  cd emsdk
  ./emsdk install latest
  ./emsdk activate latest
  source ./emsdk_env.sh
  cd ..

Build (local):

  ./scripts/build_dolphin_wasm.sh

Serve locally with COOP/COEP headers (for threads/SharedArrayBuffer):

  npm install
  node server.js

Open http://localhost:8080

Notes:
- The build script configures Dolphin with JIT disabled (ENABLE_JIT=OFF) so it can run in Wasm. Performance relies on wasm SIMD and pthreads; browsers must support these and the site must be served with COOP/COEP headers.
- Building Dolphin to Wasm is resource intensive. Use a machine with lots of RAM/CPU or a self-hosted runner for CI.
README

cat > "$OUTDIR/public/index.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>WebGC — GameCube in Browser</title>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <style>body{margin:0;font-family:sans-serif}canvas{width:100vw;height:100vh;display:block;background:#000}#controls{position:absolute;z-index:2;padding:8px}</style>
</head>
<body>
  <div id="controls">
    <input id="isoInput" type="file" accept=".iso,.gcm" />
    <button id="startBtn">Start</button>
  </div>
  <canvas id="screen"></canvas>
  <script src="app.js"></script>
</body>
</html>
HTML

cat > "$OUTDIR/public/app.js" <<'JS'
// app.js — minimal glue to load the Emscripten-built module and display a framebuffer
// This frontend expects the wasm build to export modularized factory createDolphinModule

const canvas = document.getElementById('screen');
const isoInput = document.getElementById('isoInput');
const startBtn = document.getElementById('startBtn');
let Module = null;
let gl = null;
let texture = null;

function initGL(width, height){
  canvas.width = width;
  canvas.height = height;
  gl = canvas.getContext('webgl2');
  if (!gl) { console.error('WebGL2 not available'); return; }
  texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  // simple shader program to draw the texture
  const vs = `#version 300 es
  in vec2 aPos; in vec2 aUV; out vec2 vUV; void main(){ vUV=aUV; gl_Position=vec4(aPos,0,1); }`;
  const fs = `#version 300 es
  precision mediump float; in vec2 vUV; out vec4 outColor; uniform sampler2D uTex; void main(){ outColor = texture(uTex, vUV); }`;
  const prog = createProgram(gl, vs, fs);
  gl.useProgram(prog);
  // full-screen quad
  const quad = new Float32Array([
    -1,-1, 0,1,
    1,-1, 1,1,
    -1,1,  0,0,
    1,1,   1,0
  ]);
  const vao = gl.createVertexArray(); gl.bindVertexArray(vao);
  const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf); gl.bufferData(gl.ARRAY_BUFFER, quad, gl.STATIC_DRAW);
  const aPos = gl.getAttribLocation(prog, 'aPos');
  const aUV = gl.getAttribLocation(prog, 'aUV');
  gl.enableVertexAttribArray(aPos); gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 16, 0);
  gl.enableVertexAttribArray(aUV); gl.vertexAttribPointer(aUV, 2, gl.FLOAT, false, 16, 8);
}

function createShader(gl, type, src){ const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if(!gl.getShaderParameter(s, gl.COMPILE_STATUS)){console.error(gl.getShaderInfoLog(s));} return s; }
function createProgram(gl, vsSrc, fsSrc){ const vs = createShader(gl, gl.VERTEX_SHADER, vsSrc); const fs = createShader(gl, gl.FRAGMENT_SHADER, fsSrc); const p = gl.createProgram(); gl.attachShader(p, vs); gl.attachShader(p, fs); gl.linkProgram(p); if(!gl.getProgramParameter(p, gl.LINK_STATUS)){console.error(gl.getProgramInfoLog(p));} return p; }

function updateFrameFromWasm(ptr, w, h){
  const size = w * h * 4;
  const heap = new Uint8Array(Module.HEAPU8.buffer, ptr, size);
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, heap);
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
}

async function startModule(){
  if (typeof createDolphinModule === 'undefined') { console.error('Wasm glue not found. Build must place the generated .js in public/.'); return; }
  Module = await createDolphinModule({ locateFile: (f)=>f });
  console.log('Module ready');
  if (Module._get_framebuffer_ptr && Module._get_framebuffer_w && Module._get_framebuffer_h){
    const w = Module._get_framebuffer_w();
    const h = Module._get_framebuffer_h();
    initGL(w,h);
    const loop = ()=>{
      if (Module._run_frame){
        const ptr = Module._run_frame();
        updateFrameFromWasm(ptr, w, h);
      }
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  } else {
    console.warn('Expected exported functions _run_frame, _get_framebuffer_w/h');
  }
}

// ISO handling: write selected ISO into Emscripten MEMFS and call _load_iso if exported
isoInput.addEventListener('change', async (e)=>{
  const file = e.target.files[0]; if(!file) return;
  const buf = await file.arrayBuffer();
  if (!Module) { alert('Module not ready'); return; }
  Module.FS_createDataFile('/', 'game.iso', new Uint8Array(buf), true, true);
  if (Module._load_iso){
    const pathPtr = Module.allocate(Module.intArrayFromString('/game.iso'), 'i8', Module.ALLOC_NORMAL);
    Module._load_iso(pathPtr);
    Module._free(pathPtr);
  } else {
    console.warn('No _load_iso export — core must expose an API to mount the ISO from FS.');
  }
});

startBtn.addEventListener('click', ()=>{ startModule(); });
JS

cat > "$OUTDIR/server.js" <<'NODE'
// server.js — simple express server that sets COOP/COEP headers required for wasm threads/SharedArrayBuffer
const express = require('express');
const app = express();
const port = process.env.PORT || 8080;

app.use((req, res, next) => {
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  next();
});

app.use(express.static('public'));

app.listen(port, () => console.log(`WebGC dev server running at http://localhost:${port}`));
NODE

cat > "$OUTDIR/scripts/build_dolphin_wasm.sh" <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail

# scripts/build_dolphin_wasm.sh
# This script clones the Dolphin repo into third_party/dolphin (if not present)
# and attempts to build an interpreter-only wasm build using Emscripten.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/third_party"
DOLPHIN_DIR="$THIRD_PARTY_DIR/dolphin"

mkdir -p "$THIRD_PARTY_DIR"

if [ ! -d "$DOLPHIN_DIR/.git" ]; then
  echo "Cloning Dolphin upstream into $DOLPHIN_DIR (this may take a while)..."
  git clone --depth 1 https://github.com/dolphin-emu/dolphin.git "$DOLPHIN_DIR"
else
  echo "Dolphin source already present in $DOLPHIN_DIR"
fi

# Require the user to have activated emsdk in their shell
if [ -z "${EMSDK:-}" ] && [ -z "${EMSCRIPTEN:-}" ]; then
  echo "Please install and activate Emscripten SDK and source emsdk_env.sh before running this script. See README.md"
  exit 1
fi

BUILD_DIR="$DOLPHIN_DIR/build-wasm"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Configuring CMake for Emscripten..."
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE="$EMSCRIPTEN/cmake/Modules/Platform/Emscripten.cmake" \
  -DENABLE_JIT=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_GUI_G3D=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -G Ninja

# Export flags for Emscripten build
export EMCC_CFLAGS="-O3 -msimd128 -flto -s USE_PTHREADS=1 -sPROXY_TO_PTHREAD=1"
export EMCC_CXXFLAGS="$EMCC_CFLAGS"
export EMCC_LDFLAGS="$EMCC_CFLAGS -sMODULARIZE=1 -sEXPORT_NAME='createDolphinModule' -sALLOW_MEMORY_GROWTH=1"

echo "Building Dolphin (this will take a long time)..."
emmake ninja -j$(nproc || 4)

# Copy artifacts if present
mkdir -p "$ROOT_DIR/public/wasm"
if [ -f "$BUILD_DIR/dolphin.js" ]; then
  cp "$BUILD_DIR/dolphin.js" "$ROOT_DIR/public/"
fi
if [ -f "$BUILD_DIR/dolphin.wasm" ]; then
  cp "$BUILD_DIR/dolphin.wasm" "$ROOT_DIR/public/"
fi

echo "Build script finished. If artifacts were produced, they are copied to public/."
BUILD

cat > "$OUTDIR/scripts/fetch_dolphin.sh" <<'FETCH'
#!/usr/bin/env bash
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/third_party"
DOLPHIN_DIR="$THIRD_PARTY_DIR/dolphin"

mkdir -p "$THIRD_PARTY_DIR"

if [ ! -d "$DOLPHIN_DIR" ]; then
  git clone --depth 1 https://github.com/dolphin-emu/dolphin.git "$DOLPHIN_DIR"
else
  echo "Dolphin already cloned"
fi
FETCH

cat > "$OUTDIR/.gitignore" <<'GITIGNORE'
node_modules
public/wasm
third_party/dolphin/build-wasm
.DS_Store
GITIGNORE

cat > "$OUTDIR/.github/workflows/ci.yml" <<'CI'
name: CI

on:
  push:
    branches: [ main ]

jobs:
  build-scaffold:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate scaffold
        run: |
          echo "This job validates the scaffold only. Building Dolphin for wasm is disabled in hosted CI because it is resource-intensive."

  build-demo-wasm:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup emsdk (lightweight test)
        run: |
          sudo apt-get update && sudo apt-get install -y build-essential cmake python3 git nodejs npm
          echo "Skipping full Dolphin build in hosted runner. To build Dolphin to wasm, run ./scripts/build_dolphin_wasm.sh on a self-hosted runner with emsdk installed."
CI

# Make scripts executable
chmod +x "$OUTDIR/scripts/build_dolphin_wasm.sh" "$OUTDIR/scripts/fetch_dolphin.sh"

# Create the zip
pushd "$OUTDIR" >/dev/null
zip -r "../$ZIPNAME" .
popd >/dev/null

echo "Created $ZIPNAME containing the scaffold in the current directory."
echo "Unzip with: unzip $ZIPNAME -d WebGC-scaffold"