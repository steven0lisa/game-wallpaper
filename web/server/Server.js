'use strict';
// Web 服务器：/            → 查看器页面
//          /api/maps      → 可用地图列表
//          /api/scene     → 场景 JSON（?map=xxx&level=0）
//          /atlas-N.png   → 图集页
const http = require('http');
const fs = require('fs');
const path = require('path');
const { LodFile } = require('./engines/heroes3/LodFile');
const { H3mFile } = require('./engines/heroes3/H3mFile');
const { AssetLibrary, buildScene, encodePng } = require('./engines/heroes3/Scene');

const PORT = process.env.PORT ? parseInt(process.env.PORT) : 8765;
const VCMI_DIR = process.env.H3_DATA_DIR ||
  path.join(process.env.HOME, 'Library/Application Support/vcmi');

const MAPS_DIR = path.join(VCMI_DIR, 'Maps');
const LOD_PATH = path.join(VCMI_DIR, 'Data/H3sprite.lod');

// 场景缓存（key: mapName|level）
const sceneCache = new Map();

let library = null;
try {
  library = new AssetLibrary(new LodFile(LOD_PATH));
  console.log(`[server] loaded ${LOD_PATH} (${library.lod.count} entries)`);
} catch (e) {
  console.error(`[server] cannot open ${LOD_PATH}: ${e.message}`);
}

function listMaps() {
  try {
    return fs.readdirSync(MAPS_DIR)
      .filter((f) => f.toLowerCase().endsWith('.h3m'))
      .sort();
  } catch {
    return [];
  }
}

const keySafe = encodeURIComponent;

// 生成代码指纹：服务端所有参与场景构建的源文件
function computeServerCodeHash() {
  const crypto = require('crypto');
  const files = ['Scene.js', 'DefFile.js', 'H3mFile.js', 'LodFile.js', 'Reader.js', 'Server.js'];
  const h = crypto.createHash('md5');
  for (const f of files) {
    const st = fs.statSync(path.join(__dirname, f));
    h.update(f + st.mtimeMs.toFixed(0) + st.size);
  }
  return h.digest('hex').slice(0, 8);
}
const SERVER_CODE_HASH = computeServerCodeHash();

function getScene(mapName, level) {
  const key = `${mapName}|${level}`;
  if (sceneCache.has(key)) return sceneCache.get(key);
  const mapPath = path.join(MAPS_DIR, mapName);
  if (!fs.existsSync(mapPath)) return null;
  const h3m = new H3mFile(mapPath);
  const { scene, atlasPages } = buildScene(h3m, library, level);
  // 内容指纹 = 地图 mtime + 帧数 + 对象数 + 【生成代码指纹】。
  // 代码指纹（server 端解析/打包源文件的 mtime+size）保证 Scene/DefFile 逻辑
  // 变更后 URL 必变，绕开浏览器 immutable 缓存（曾因缺它导致旧图集"中毒"）。
  const mtime = fs.statSync(mapPath).mtimeMs.toFixed(0);
  const codeHash = SERVER_CODE_HASH;
  scene.atlasVersion = `${mtime}-${Object.keys(scene.frames).length}-${scene.objects.length}-${codeHash}`;
  const result = { scene, atlasPages };
  sceneCache.set(key, result);
  return result;
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.json': 'application/json',
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  try {
    if (url.pathname === '/api/ping') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('pong');
      return;
    }
    if (url.pathname === '/api/maps') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ maps: listMaps() }));
      return;
    }
    if (url.pathname === '/api/scene') {
      const map = url.searchParams.get('map') || listMaps()[0];
      const level = parseInt(url.searchParams.get('level') || '0');
      if (!library) { res.writeHead(500); res.end('asset lod unavailable'); return; }
      const built = getScene(map, level);
      if (!built) { res.writeHead(404); res.end('map not found'); return; }
      // 目录名带内容指纹（atlasVersion）：图集内容变化 → 新 URL → 浏览器/CDN 缓存自动失效
      const dir = path.join(__dirname, 'cache', map, `level${level}-${built.scene.atlasVersion}`);
      if (!fs.existsSync(path.join(dir, 'atlas-0.png'))) {
        built.atlasPages.forEach((pageBuf, i) => {
          fs.mkdirSync(dir, { recursive: true });
          fs.writeFileSync(path.join(dir, `atlas-${i}.png`), encodePng(2048, 2048, pageBuf));
        });
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(built.scene));
      return;
    }
    if (url.pathname.startsWith('/atlas/')) {
      // /atlas/<map>/<levelVersion>/atlas-N.png（levelVersion 含内容指纹）
      const parts = url.pathname.split('/').filter(Boolean); // [atlas, map, levelVer, file]
      if (parts.length === 4) {
        const file = path.join(__dirname, 'cache', decodeURIComponent(parts[1]), parts[2], path.basename(parts[3]));
        if (fs.existsSync(file)) {
          res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=31536000, immutable' });
          fs.createReadStream(file).pipe(res);
          return;
        }
      }
      res.writeHead(404); res.end(); return;
    }
    // 静态页面
    let file = url.pathname === '/' ? '/index.html' : url.pathname;
    const full = path.join(__dirname, '..', 'public', file);
    if (!fs.existsSync(full) || !fs.statSync(full).isFile()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'application/octet-stream' });
    fs.createReadStream(full).pipe(res);
  } catch (e) {
    console.error('[server]', e);
    res.writeHead(500);
    res.end(String(e.message || e));
  }
});

fs.mkdirSync(path.join(__dirname, 'cache'), { recursive: true });
server.listen(PORT, () => {
  console.log(`[server] http://localhost:${PORT}/  (maps from ${MAPS_DIR})`);
});
