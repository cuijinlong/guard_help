#!/usr/bin/env node
/*
 * 部件 controllerScript 的「清理目标可见性」检查。
 *
 * ## 为什么需要它
 *
 * TB 部件的 `self.onDestroy` 负责清理：清定时器、退订、移除监听。
 * 这些清理目标（timer id、订阅对象、监听回调）必须与 onDestroy **同一个
 * 词法作用域** —— 也就是都声明在 `self.onInit` 的顶层。
 *
 * 本项目已经因此出过两次事故（2026-11-13）：
 *
 *   `energy_management_analysis_bar` 里 `var onDocClick` 被误插进
 *   `scope.setTimeMode` 的函数体，而 `self.onDestroy` 在 onInit 顶层
 *   引用它 → 部件销毁时抛 `ReferenceError: onDocClick is not defined`，
 *   且因为异常在第一行，后面所有清理都没执行（定时器与订阅泄漏）。
 *
 * 这类错误只在销毁时暴露，打开页面完全看不出来 —— 所以用脚本卡住。
 *
 * ## 判定方法
 *
 * 只认「清理调用」的目标名，不做通用的标识符分析（后者误报太多）：
 *
 *   clearInterval(X) / clearTimeout(X)
 *   document.removeEventListener(type, X) / window.removeEventListener(...)
 *   X.unsubscribe() / X.disconnect() / X.cancel() / clearTimeout(X)
 *   if (X) { X.stop() } 之类不查（太宽）
 *
 * 对每个 X，检查它是否在 onInit 顶层有声明（var/let/const/function，
 * 或者就是 onInit 的直接子函数）。找不到就报。
 *
 * ## 用法
 *
 *   node tools/check-widget-scope.mjs
 *   node tools/check-widget-scope.mjs --only analysis_bar
 *   node tools/check-widget-scope.mjs --json
 *
 * 退出码：0 全部通过，1 有违规。
 */
import { readFileSync, readdirSync } from 'fs';
import { join, basename } from 'path';

const DIR = 'guard-server/src/main/data/json/system/widget_types';
const argv = process.argv.slice(2);
const only = argv.includes('--only') ? argv[argv.indexOf('--only') + 1] : null;
const asJson = argv.includes('--json');

function sanitize(line) {
  return line
    .replace(/\/\*.*?\*\//g, ' ')
    .replace(/\/\/.*$/, '')
    .replace(/'(?:\\.|[^'\\])*'/g, "''")
    .replace(/"(?:\\.|[^"\\])*"/g, '""');
}

function blockEnd(lines, start) {
  let depth = 0, seen = false;
  for (let i = start; i < lines.length; i++) {
    for (const ch of sanitize(lines[i])) {
      if (ch === '{') { depth++; seen = true; }
      else if (ch === '}') { depth--; if (seen && depth === 0) return i; }
    }
  }
  return lines.length - 1;
}

function collectFns(lines) {
  const fns = [];
  lines.forEach((l, i) => {
    const s = sanitize(l);
    const m = s.match(/^\s*(scope\.\w+|self\.\w+)\s*=\s*function/)
           || s.match(/^\s*(?:var|let|const)\s+(\w+)\s*=\s*function/)
           || s.match(/^\s*function\s+(\w+)\s*\(/);
    if (m) fns.push({ line: i, name: m[1], end: blockEnd(lines, i) });
  });
  return fns;
}

function ownerOf(fns, idx) {
  const hits = fns.filter(f => f.line < idx && idx <= f.end);
  if (!hits.length) return null;
  return hits.reduce((a, b) => (b.line > a.line ? b : a));
}

/* 在 [from, to] 范围内，某名字是否「直接」声明（不在更深的函数里） */
function declaredAtLevel(lines, fns, from, to, name, levelOwner) {
  for (let i = from; i <= to && i < lines.length; i++) {
    const s = sanitize(lines[i]);
    const re = new RegExp(`\\b(?:var|let|const)\\s+${name}\\b`);
    const reFn = new RegExp(`^\\s*function\\s+${name}\\s*\\(`);
    if (re.test(s) || reFn.test(s)) {
      const o = ownerOf(fns, i);
      // 与目标同级：所属函数相同，或者都在顶层
      if (o === levelOwner || (!o && !levelOwner)) return true;
    }
  }
  return false;
}

/* 从 onDestroy 体里提取清理目标名 */
function cleanupTargets(lines, from, to) {
  const out = [];
  for (let i = from; i <= to && i < lines.length; i++) {
    const s = sanitize(lines[i]);
    const push = (name) => { if (name && !/^(this|window|document|self)$/.test(name)) out.push({ name, line: i + 1 }); };
    // clearInterval(x) / clearTimeout(x) / cancelAnimationFrame(x)
    for (const m of s.matchAll(/\b(?:clearInterval|clearTimeout|cancelAnimationFrame|removeEventListener)\s*\(\s*([A-Za-z_$][\w$]*)\s*\)/g)) push(m[1]);
    // removeEventListener(type, x) —— 取第二个实参
    for (const m of s.matchAll(/\bremoveEventListener\s*\(\s*[^,]+,\s*([A-Za-z_$][\w$]*)/g)) push(m[1]);
    /*
     * x.unsubscribe() 等 —— 只取**根标识符**。
     *
     * ★ 不能取属性名（2026-11-13 实测）：`handle.sub.unsubscribe()` 里
     *   真正要检查可见性的是 `handle`，而 `sub` 只是它的属性。
     *   正则要求 x 前面不是 `.`/标识符字符，才能保证取到表达式开头那个名字。
     */
    for (const m of s.matchAll(/(?:^|[^.\w$])([A-Za-z_$][\w$]*)\.(?:unsubscribe|disconnect|cancel|stop|clear|destroy)\s*\(/g)) push(m[1]);
  }
  // 去重（同名多处只报一次，取第一次）
  const seen = new Map();
  for (const t of out) if (!seen.has(t.name)) seen.set(t.name, t);
  return [...seen.values()];
}

function checkScript(js) {
  const lines = js.split('\n');
  const fns = collectFns(lines);
  const init = fns.find(f => f.name === 'self.onInit');
  const destroy = fns.find(f => f.name === 'self.onDestroy');
  if (!init || !destroy) return [];      // 没有 onDestroy 就没什么可清理
  const problems = [];
  for (const t of cleanupTargets(lines, destroy.line, destroy.end)) {
    // 顶层声明 = onInit 的直接语句（所属函数是 onInit 本身或没有）
    const ok = declaredAtLevel(lines, fns, init.line, init.end, t.name, init);
    if (ok) continue;

    /*
     * 只报「确实用 var/let/const 声明在某个**子函数**里」的情况 ——
     * 这正是 onDocClick 那次事故的形态，判据确定、零误报。
     *
     * 「哪里都找不到声明」的不报：可能是属性（this.xxx）、解构、
     * 或运行时注入，那些不属于本检查的范围。
     */
    let where = null, at = -1;
    for (let i = 0; i < lines.length; i++) {
      if (new RegExp(`\\b(?:var|let|const)\\s+${t.name}\\b`).test(sanitize(lines[i]))) {
        const o = ownerOf(fns, i);
        if (o && o.name !== 'self.onInit') { where = o.name; at = i + 1; break; }
      }
    }
    if (!where) continue;
    problems.push({ name: t.name, usedAt: t.line, declaredIn: where, declaredAt: at });
  }
  return problems;
}

/*
 * 只查**自研**部件（energy_management_*）。
 *
 * TB 原生部件的写法不一样（清理目标常是属性或解构出来的，
 * `this.valueChanges.unsubscribe()` 这种），用同一套判据会满屏误报。
 * 这个检查的目标是「我们自己在 onInit 里用 var 声明的清理目标」。
 */
const files = readdirSync(DIR)
  .filter(f => f.endsWith('.json') && f.startsWith('energy_management_'))
  .filter(f => !only || f.includes(only));
const results = [];
for (const f of files) {
  let d;
  try { d = JSON.parse(readFileSync(join(DIR, f), 'utf8')); } catch { continue; }
  const js = d?.descriptor?.controllerScript;
  if (!js || js.length < 200) continue;
  const p = checkScript(js);
  if (p.length) results.push({ file: f, name: d.name || basename(f, '.json'), problems: p });
}

if (asJson) console.log(JSON.stringify(results, null, 2));
else if (!results.length) console.log(`✓ 检查 ${files.length} 个部件，onDestroy 的清理目标全部在 onInit 顶层可见`);
else {
  console.log(`✗ ${results.length} 个部件的 onDestroy 引用了不可见的清理目标：\n`);
  for (const r of results) {
    console.log(`  ${r.file}（${r.name}）`);
    for (const p of r.problems) {
      const loc = p.declaredIn ? `声明在 ${p.declaredIn} 内部（第 ${p.declaredAt} 行）` : '找不到任何局部声明';
      console.log(`      onDestroy 第 ${p.usedAt} 行用到 ${p.name} —— ${loc}`);
      console.log(`      → 部件销毁时抛 ReferenceError，后面的清理不会执行`);
    }
    console.log();
  }
}
process.exit(results.length ? 1 : 0);
