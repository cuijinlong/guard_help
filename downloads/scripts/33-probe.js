// 能源管理平台 · 部件样式探针（自判读）
//
// 用法：在出问题的页面按 F12 → Console，整段粘贴回车。
// 它会自己下结论：全绿说明样式正常（那是浏览器缓存）；有红项会列出异常。
//
// 本机基线（干净生产环境实测）：
//   body.class = "tb-default"
//   主题变量   = "56px"
//   部件样式规则数 = 212   （<150 说明部件私有样式没进 DOM）
//   按钮 bg    = rgb(22, 131, 74)
//   表单框 h   = 36px
(() => {
  const q = s => document.querySelector(s);
  const box = el => {
    if (!el) return null;
    const c = getComputedStyle(el), r = el.getBoundingClientRect();
    return { h: Math.round(r.height), bg: c.backgroundColor, radius: c.borderRadius };
  };
  let ngRules = 0, eqpSel = null;
  for (const ss of document.styleSheets) {
    let l; try { l = ss.cssRules } catch (e) { continue; }
    for (const r of l || []) {
      const s = r.selectorText || '';
      if (s.includes('_ngcontent')) ngRules++;
      if (!eqpSel && (s.includes('.eqp-submit') || s.includes('.eqp-ff'))) eqpSel = s;
    }
  }
  const ffvar  = getComputedStyle(document.body).getPropertyValue('--mat-form-field-container-height').trim();
  const btn    = box(q('.eqp-submit'));
  const ff     = box(q('.eqp-ff'));
  const mdcBtn = box(q('.mat-mdc-button-base'));

  const checks = {
    'body 有 tb-default':      document.body.className.includes('tb-default'),
    '主题变量 = 56px':          ffvar === '56px',
    '部件样式规则 ≥ 150':       ngRules >= 150,
    '.eqp 规则带 _ngcontent':   !!(eqpSel && eqpSel.includes('_ngcontent')),
    '按钮有背景色':             !!(btn && btn.bg && btn.bg !== 'rgba(0, 0, 0, 0)'),
    '表单框高 36px':            !!(ff && ff.h === 36),
  };
  const fails = Object.entries(checks).filter(([, v]) => !v).map(([k]) => k);

  console.log('%c===== 部件样式诊断 =====', 'font-weight:bold;font-size:14px');
  console.table({
    'body.class':        document.body.className,
    '主题变量':           ffvar || '(空)',
    '部件样式规则数':      ngRules,
    '.eqp 规则样例':      eqpSel ? eqpSel.slice(0, 80) : '(未找到)',
    '按钮':               btn ? `h=${btn.h} bg=${btn.bg} radius=${btn.radius}` : '(无)',
    '表单框':             ff ? `h=${ff.h}` : '(无)',
    'Material 按钮':      mdcBtn ? `h=${mdcBtn.h} bg=${mdcBtn.bg}` : '(无)',
    'style 标签数':       document.querySelectorAll('style').length,
  });
  if (fails.length === 0) {
    console.log('%c✓ 全部正常 —— 页面样式是好的', 'color:#16834A;font-weight:bold;font-size:14px');
    console.log('如果眼睛看着还不对，是浏览器缓存：Cmd+Shift+R 或开无痕窗口');
  } else {
    console.log('%c✗ 异常项：' + fails.join('、'), 'color:#c00;font-weight:bold;font-size:14px');
  }
  return { ngRules, ffvar, checks, fails };
})()
