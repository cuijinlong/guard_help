#!/usr/bin/env node
/*
 * 生成「能源卫士」favicon（favicon.ico + favicon.svg）。
 *
 * ## 用法
 *
 *   node 40-make-favicon.mjs                    # 生成到 ui-ngx/src/
 *   node 40-make-favicon.mjs --out /tmp/x       # 生成到别处
 *
 * 依赖：本机 Google Chrome（用它的渲染引擎把 SVG 画成 PNG，无需 ImageMagick）。
 *
 * ## 图形来源
 *
 * 与登录页 brand-logo 完全同源（ui-ngx/src/app/modules/login/pages/login/
 * login.component.html 里那段内联 SVG）：绿色圆角方块 + 白色盾牌描边 +
 * 白色闪电。改品牌图形时**两处要一起改**，否则登录页与标签页图标不一致。
 *
 * ## 为什么要分两套尺寸方案
 *
 * 16/24 px 直接用大图缩小的话，闪电只剩 5×9 px，标签页里糊成一个白点。
 * 专业做法（Google / GitHub / Figma 一致）：小尺寸**重排**而不是缩放 ——
 * 去掉盾牌、把闪电放大到接近铺满，只保留最能识别的那一个元素。
 *
 * ## 为什么 ico 里放 PNG 而不是 BMP
 *
 * Vista 起 ICO 允许条目直接存 PNG，体积小一个数量级且支持 256×256
 * （BMP 版 256 要 256 KB）。现代浏览器与 Windows 都支持。
 */
import { writeFileSync, readFileSync, statSync, mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

const argv = process.argv.slice(2);
const OUT = argv.includes('--out') ? argv[argv.indexOf('--out') + 1] : 'ui-ngx/src';
const CHROME = process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const BRAND_TOP = '#1BA25B';       // 品牌绿（渐变上端）
const BRAND_BOTTOM = '#116B3C';    // 品牌绿（渐变下端，= BRAND_GREEN_DARK）
const RADIUS = 0.30;               // 圆角占方块边长比（登录页 14/46）

/* 32×32 坐标系下的图元（与登录页内联 SVG 一致） */
const SHIELD = 'M16 2.5 28 7v8.5c0 7.2-4.8 12-12 14-7.2-2-12-6.8-12-14V7l12-4.5Z';
const BOLT = 'm18 7-9 12h7l-2 7 9-13h-7l2-6Z';

/**
 * 从 SVG 路径串算出包围盒（只支持本文件用到的 m/l/h/v/Z 相对指令）。
 *
 * ★ 为什么要有这个函数（2026-11-14）：
 *   上一版把闪电包围盒中心写死成 (13.5, 16.5)，而实际是 (16, 16.5) ——
 *   X 差 2.5，放大后闪电明显往右偏，客户直接看出来了。
 *   写死的数字会错，而且错了没人会发现（图标很小）。所以改成**算出来的**，
 *   并在下面 assert 校验，改路径时立刻报错。
 */
function pathBBox(d) {
  const toks = d.match(/[a-zA-Z]|-?\d+\.?\d*/g) || [];
  let x = 0, y = 0, cmd = null, nums = [];
  const pts = [];
  const flush = () => {
    if (!cmd || !nums.length) return;
    if (cmd === 'm' || cmd === 'l') {
      for (let k = 0; k + 1 < nums.length; k += 2) {
        x += nums[k]; y += nums[k + 1]; pts.push([x, y]);
      }
    } else if (cmd === 'h') {
      for (const v of nums) { x += v; pts.push([x, y]); }
    } else if (cmd === 'v') {
      for (const v of nums) { y += v; pts.push([x, y]); }
    }
    nums = [];
  };
  for (const t of toks) {
    if (/[a-zA-Z]/.test(t)) { flush(); cmd = t.toLowerCase(); }
    else nums.push(parseFloat(t));
  }
  flush();
  const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  const minY = Math.min(...ys), maxY = Math.max(...ys);
  return { minX, maxX, minY, maxY, cx: (minX + maxX) / 2, cy: (minY + maxY) / 2,
           w: maxX - minX, h: maxY - minY };
}

const BOLT_BOX = pathBBox(BOLT);
/*
 * 自检：闪电中心必须落在画布中心 (16, 16) 附近。
 * 容差 0.6 —— Y 天生偏 0.5（包围盒 7..26，中心 16.5；画布中心 16），
 * 这是图形本身的性质，不是错误；X 必须几乎精确等于 16。
 */
if (Math.abs(BOLT_BOX.cx - 16) > 0.01) {
  throw new Error(`闪电 X 中心应为 16，实际 ${BOLT_BOX.cx}（包围盒 ${BOLT_BOX.minX}..${BOLT_BOX.maxX}）`);
}
if (Math.abs(BOLT_BOX.cy - 16) > 0.6) {
  throw new Error(`闪电 Y 中心偏离过大：${BOLT_BOX.cy}（包围盒 ${BOLT_BOX.minY}..${BOLT_BOX.maxY}）`);
}

/** 闪电缩放锚点 = 实测包围盒中心，不写死。 */
const BOLT_CX = BOLT_BOX.cx;
const BOLT_CY = BOLT_BOX.cy;

function svg({ size, pad, boltScale, shieldPx, withShield, comment }) {
  const inner = size * (1 - 2 * pad);
  const off = size * pad;
  const k = inner / 32;
  const rx = inner * RADIUS;
  /*
   * 闪电包围盒中心由 pathBBox() 实测得出（现为 (16, 16.5)），
   * 绕它缩放后平移到画布中心 (16, 16)。
   *
   * ★★★ 2026-11-14 修：这里原本写 (-13.5, -16.5)，X 差了 2.5 个单位，
   *     导致闪电整体**往右偏**（客户原话「中间的闪电没有居中，往右侧偏」）。
   *
   *     13.5 从哪来的：大概是「宽度 27 的一半」—— 但实测包围盒宽度是
   *     14（X 从 9 到 23），不是 27。把 23-9 算成 27 会漏掉路径左右两端
   *     的不对称，于是平移量少 2.5，放大后偏差 = 2.5 × boltScale：
   *       16px 版 (scale 1.62) 偏右 4.05 个单位，肉眼非常明显。
   *
   *     验证办法（脚本已带自检）：包围盒中心 = (min+max)/2，
   *     X = (9+23)/2 = 16，Y = (7+26)/2 = 16.5。直接算，不要猜。
   *
   * ★ 即使 boltScale === 1 也要应用这个 transform（2026-11-13 实测）：
   *   跳过它（"scale(1) 等于没做"）会让光栅化走另一条路径，
   *   256px 下闪电与盾牌的边缘产生亚像素偏移 —— 肉眼看不出，但
   *   两次生成的 PNG 不再逐字节相同，破坏了「脚本可复现」这个前提。
   *   恒等变换的代价是零，保留它换来确定性。
   */
  const boltTf = ` transform="translate(16,16) scale(${boltScale}) translate(${-BOLT_CX},${-BOLT_CY})"`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
  ${comment ? `<!-- ${comment} -->` : ''}
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="${BRAND_TOP}"/><stop offset="1" stop-color="${BRAND_BOTTOM}"/>
  </linearGradient></defs>
  <rect x="${off}" y="${off}" width="${inner}" height="${inner}" rx="${rx}" ry="${rx}" fill="url(#g)"/>
  <g transform="translate(${off},${off}) scale(${k})">
    ${withShield ? `<path d="${SHIELD}" fill="none" stroke="#fff" stroke-width="${shieldPx / k}"
      stroke-linejoin="round" stroke-linecap="round"/>` : ''}
    <path d="${BOLT}" fill="#fff"${boltTf}/>
  </g>
</svg>`;
}

/* 尺寸方案：小尺寸去掉盾牌、放大闪电；大尺寸用完整图形 */
const VERSIONS = [
  { size: 16,  withShield: false, boltScale: 1.62, pad: 0.015, shieldPx: 1.00 },
  { size: 24,  withShield: false, boltScale: 1.50, pad: 0.020, shieldPx: 1.00 },
  { size: 32,  withShield: true,  boltScale: 1.22, pad: 0.045, shieldPx: 1.35 },
  { size: 48,  withShield: true,  boltScale: 1.10, pad: 0.055, shieldPx: 1.55 },
  { size: 64,  withShield: true,  boltScale: 1.04, pad: 0.060, shieldPx: 1.70 },
  { size: 128, withShield: true,  boltScale: 1.00, pad: 0.065, shieldPx: 2.30 },
  { size: 256, withShield: true,  boltScale: 1.00, pad: 0.070, shieldPx: 3.60 },
];

/* 用 Chrome 把每张 SVG 渲染成等尺寸 PNG（透明底） */
async function renderPngs(dir) {
  /*
   * puppeteer-core 是可选依赖（本仓库不把它写进 package.json —— 生成图标
   * 是一次性的活，不值得为它给所有人加安装负担）。缺失时给明确指引，
   * 而不是抛一个 ERR_MODULE_NOT_FOUND。
   */
  /*
   * ★ 必须按**当前工作目录**解析，不能裸 import。
   *   ESM 的裸 import 是相对脚本文件的位置解析的 —— 本脚本在
   *   shiyongshouce/downloads/scripts/ 下，就算从 /tmp 运行也找不到
   *   /tmp/node_modules。createRequire 用 CWD 建立解析起点才符合直觉。
   */
  let puppeteer;
  try {
    const { createRequire } = await import('module');
    const req = createRequire(join(process.cwd(), 'noop.js'));
    puppeteer = req('puppeteer-core');
  } catch {
    console.error(`✗ 找不到 puppeteer-core。\n
  装一下（不会污染项目依赖）：\n
    npm install --no-save --prefix /tmp puppeteer-core\n
  然后在这个目录下运行本脚本（Node 会从 /tmp/node_modules 找包）：\n
    cd /tmp && node <本脚本路径> --out ui-ngx/src\n`);
    process.exit(2);
  }
  const b = await puppeteer.launch({
    executablePath: CHROME, headless: 'new',
    args: ['--no-sandbox', '--force-device-scale-factor=1'],
  });
  const p = await b.newPage();
  for (const v of VERSIONS) {
    await p.setViewport({ width: v.size, height: v.size, deviceScaleFactor: 1 });
    await p.setContent(`<html><body style="margin:0;background:transparent">${svg(v)}</body></html>`);
    await new Promise(r => setTimeout(r, 130));
    const buf = await p.screenshot({
      omitBackground: true,
      clip: { x: 0, y: 0, width: v.size, height: v.size },
    });
    writeFileSync(join(dir, `icon-${v.size}.png`), buf);
  }
  await b.close();
}

/* 组装 ICO：ICONDIR + ICONDIRENTRY×N + PNG 数据 */
function buildIco(pngPaths, out) {
  const items = pngPaths.map((p) => {
    const d = readFileSync(p);
    if (d.subarray(0, 8).toString('binary') !== '\x89PNG\r\n\x1a\n') {
      throw new Error(`${p} 不是 PNG`);
    }
    const w = d.readUInt32BE(16), h = d.readUInt32BE(20);
    if (w !== h) throw new Error(`${p} 不是正方形`);
    return { w, d };
  });
  const head = Buffer.alloc(6);
  head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(items.length, 4);
  let offset = 6 + items.length * 16;
  const entries = [];
  for (const it of items) {
    const e = Buffer.alloc(16);
    e.writeUInt8(it.w >= 256 ? 0 : it.w, 0);   // 256 记作 0（规范）
    e.writeUInt8(it.w >= 256 ? 0 : it.w, 1);
    e.writeUInt8(0, 2); e.writeUInt8(0, 3);
    e.writeUInt16LE(1, 4); e.writeUInt16LE(32, 6);
    e.writeUInt32LE(it.d.length, 8);
    e.writeUInt32LE(offset, 12);
    offset += it.d.length;
    entries.push(e);
  }
  writeFileSync(out, Buffer.concat([head, ...entries, ...items.map(i => i.d)]));
  return items.length;
}

const tmp = mkdtempSync(join(tmpdir(), 'favicon-'));
try {
  await renderPngs(tmp);
  const pngs = VERSIONS.map(v => join(tmp, `icon-${v.size}.png`));
  const n = buildIco(pngs, join(OUT, 'favicon.ico'));
  writeFileSync(join(OUT, 'favicon.svg'), svg({
    size: 32, pad: 0.0, boltScale: 1, shieldPx: 1.8, withShield: true,
    comment: '能源卫士 · 与登录页 brand-logo 同源（绿色圆角方块 + 白色盾牌 + 白色闪电）',
  }));

  console.log(`✓ ${join(OUT, 'favicon.ico')}  ${statSync(join(OUT, 'favicon.ico')).size} B  ${n} 个尺寸`);
  console.log(`✓ ${join(OUT, 'favicon.svg')}  ${statSync(join(OUT, 'favicon.svg')).size} B`);
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
