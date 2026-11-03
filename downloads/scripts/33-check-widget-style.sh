#!/usr/bin/env bash
#
# 能源管理平台 · 部件样式自检（v2：四层 + 浏览器实测基线）
#
# v1 只查后端四层。如果四层全绿但页面依然没样式，本脚本会额外：
#   ① 找出 jar 里混入的旧构建残留（多套 app-theme/styles/*.map）
#   ② 打印 jar 内 index.html 引用的 JS/CSS，供与出问题机器对比
#   ③ 给出可直接粘贴到 Console 的精确探针（区分两条样式通道）
#
# 用法（在部署目录 ~/energy-app 下）：
#   bash scripts/33-check-widget-style.sh
#   bash scripts/33-check-widget-style.sh --widget query_panel
#
# ⚠ 只读，不改任何东西。
#
set -uo pipefail

PORT="${HTTP_PORT:-8090}"
ONLY=""
CONTAINER="${APP_CONTAINER:-energy-server}"
PSQL_CONTAINER="${PSQL_CONTAINER:-energy-postgres}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --widget) ONLY="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="$(cd "$HERE/.." && pwd)"
[ -f "$APP_HOME/.env" ] && { set -a; . "$APP_HOME/.env" 2>/dev/null; set +a; }

RC=0
step() { printf '\n\033[1;36m━━ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; RC=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

psql_q() {
  docker exec "$PSQL_CONTAINER" psql -U postgres -d thingsboard -t -A -c "$1" 2>/dev/null
}

echo "============================================================"
echo " 部件样式自检"
echo " 部署目录 $APP_HOME"
echo " 服务端口 $PORT"
echo "============================================================"

JAR="$APP_HOME/guard-server-4.4.0.jar"
IDX=""
CSS_LIST=""

# ════════════════════════════════════════════════════════════════
step "L1　jar 里的前端产物"
# ════════════════════════════════════════════════════════════════
if [[ ! -f "$JAR" ]]; then
  bad "找不到 $JAR"
else
  IDX=$(unzip -p "$JAR" BOOT-INF/classes/public/index.html 2>/dev/null)
  if [[ -z "$IDX" ]]; then
    bad "jar 里没有前端产物（BOOT-INF/classes/public/index.html 不存在）"
    info "这就是整页无样式/白屏的原因。用 bash guard-server/pack.sh（别加 --skip-ui）重打"
  else
    JAR_LIST_RAW=$(unzip -l "$JAR" 2>/dev/null)
    N_UI=$(grep -cF "BOOT-INF/classes/public/" <<<"$JAR_LIST_RAW" || true)
    if grep -qE 'main-[A-Z0-9]{8}\.js' <<<"$IDX"; then
      ok "前端产物：production（带 hash），public/ 下 ${N_UI} 个文件"
    elif grep -qE 'main\.js' <<<"$IDX"; then
      warn "前端产物：development（无 hash）—— 能用，但不是发布版"
    else
      warn "无法判断构建类型"
    fi

    #
    # ★ 多套前端构建叠加检测（2026-11-04 客户新机器实测根因）
    #
    # pom.xml 用 <resource> 把 ui-ngx 产物拷进 target/classes/public，
    # 而 maven-resources-plugin 只增/覆盖，**从不删除上轮遗留**。
    # 每跑一次 pack.sh 就多积一层。实测跑过多次的 jar：
    #     10268 个 public 文件，跨 8 个日期（8842 个 11-02 / 1298 个 11-03 / ...）
    #   干净构建（mvn clean）：9066 个，全部同一天。
    #
    # 危害：index.html 只引最新那套（带 hash 文件名），但 assets/ 下**同名**文件
    # （字体、i18n、locale、图片）会被旧构建覆盖 → CSS/JS 版本不匹配：
    #   · 「无效的部件 HTML 模板」(NG0 编译错误)
    #   · 部分样式丢失（按钮、下拉框裸奔）
    #   · 部分页面全白，另一些正常
    # 开发机因浏览器缓存看不出来，新机器上必现。
    #
    # 硬判据：public/ 下文件的**日期种类数**。干净 = 1，脏 = 2 以上。
    #
    N_DATES=$(grep -F "BOOT-INF/classes/public/" <<<"$JAR_LIST_RAW" \
              | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
    N_CHUNK=$(grep -cE "public/chunk-[A-Z0-9]+[.]js$" <<<"$JAR_LIST_RAW" || true)
    if [[ "${N_DATES:-0}" -gt 1 ]]; then
      bad "jar 内前端混了 ${N_DATES} 个不同日期 —— 多套构建叠加！"
      grep -F "BOOT-INF/classes/public/" <<<"$JAR_LIST_RAW" \
        | awk '{print $2}' | sort | uniq -c | sort -rn | head -6 | sed 's/^/      /'
      info "这就是「样式丢失 / 无效的部件 HTML 模板 / 部分页面空白」的根因"
      info "修：cd <仓库> && bash guard-server/pack.sh --clean，然后换 jar 重启"
    else
      ok "前端产物日期一致（单一构建，无叠加）"
    fi
    if [[ "${N_CHUNK:-0}" -gt 200 ]]; then
      bad "jar 内有 ${N_CHUNK} 个 chunk（干净构建约 88）—— 存在旧构建残留"
      info "同上：bash guard-server/pack.sh --clean"
    elif [[ "${N_CHUNK:-0}" -gt 0 ]]; then
      ok "chunk 数正常（${N_CHUNK} 个）"
    fi

    CSS_LIST=$(grep -oE 'href="[^"]+\.css"' <<<"$IDX" | sed 's/href="//;s/"//')
    JS_LIST=$(grep -oE 'src="[^"]+\.js"' <<<"$IDX" | sed 's/src="//;s/"//')

    echo
    echo "    index.html 实际引用（出问题的机器应与这里**完全一致**）："
    echo "$CSS_LIST" | sed 's/^/      CSS  /'
    echo "$JS_LIST"  | sed 's/^/      JS   /'

    # index.html 引用的文件必须都在 jar 里
    #
    # ★ 只解一次清单存进变量，不能写成 `unzip -l | grep -q`（2026-11-04 实测）：
    #   grep -q 命中后提前退出 → unzip 收到 SIGPIPE → 在 `set -o pipefail` 下
    #   整条管道被判为失败，于是「jar 里明明有却报找不到」，全部文件误报缺失。
    #   guard-server/pack.sh 里也记着同一个坑。
    JAR_LIST=$(unzip -l "$JAR" 2>/dev/null)
    MISS=0
    for u in $CSS_LIST $JS_LIST; do
      if ! grep -qF "BOOT-INF/classes/public/$u" <<<"$JAR_LIST"; then
        bad "jar 里缺少被引用的 $u"; MISS=1
      fi
    done
    [[ "$MISS" == "0" ]] && ok "index.html 引用的文件全部在 jar 内"
  fi
fi

# ════════════════════════════════════════════════════════════════
step "L2　全局 CSS 可访问性与 MIME"
# ════════════════════════════════════════════════════════════════
BASE="http://127.0.0.1:${PORT}"
CURL=(curl -s --noproxy '*' --max-time 10)
if ! "${CURL[@]}" -o /dev/null "$BASE/" 2>/dev/null; then
  bad "服务没在 $BASE 响应 —— docker ps | grep energy-server"
else
  ok "服务可访问：$BASE"
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/$u")
    CT=$("${CURL[@]}" -I "$BASE/$u" 2>/dev/null | grep -i '^content-type' | tr -d '\r' | cut -d' ' -f2-)
    SIZE=$("${CURL[@]}" "$BASE/$u" | wc -c | tr -d ' ')
    if [[ "$CODE" != "200" ]]; then
      bad "$u → HTTP $CODE"
    elif [[ "$CT" != text/css* ]]; then
      bad "$u → Content-Type 是「$CT」，浏览器会拒收（nosniff）"
    else
      ok "$u  HTTP 200  text/css  ${SIZE} 字节"
    fi
  done <<<"$CSS_LIST"
fi

# ════════════════════════════════════════════════════════════════
step "L3　数据库里的部件样式字段"
# ════════════════════════════════════════════════════════════════
if ! docker ps --format '{{.Names}}' | grep -qx "$PSQL_CONTAINER"; then
  warn "跳过：找不到容器 $PSQL_CONTAINER"
else
  W="%"; [[ -n "$ONLY" ]] && W="%${ONLY}%"
  ROWS=$(psql_q "
    SELECT fqn,
           length(descriptor::jsonb->>'templateCss'),
           length(descriptor::jsonb->>'templateHtml'),
           (length(descriptor::jsonb->>'templateHtml')
            - length(replace(descriptor::jsonb->>'templateHtml','<style','')))/6
    FROM widget_type WHERE fqn LIKE 'energy_%' AND fqn LIKE '$W' ORDER BY fqn;")
  if [[ -z "$ROWS" ]]; then
    bad "库里查不到能源部件 —— install 没跑完，或连错了库"
  else
    N_ALL=0; N_NOCSS=0
    printf '    %-44s %8s %8s %6s\n' "fqn" "css" "html" "style块"
    while IFS='|' read -r fqn css html st; do
      [[ -z "$fqn" ]] && continue
      N_ALL=$((N_ALL+1))
      printf "    %-44s %8s %8s %6s" "$fqn" "${css:-0}" "${html:-0}" "${st:-0}"
      if [[ "${css:-0}" == "0" && "${st:-0}" == "0" ]]; then
        printf "  \033[31m← 完全无样式\033[0m"; N_NOCSS=$((N_NOCSS+1))
      fi
      printf '\n'
    done <<<"$ROWS"
    echo
    if [[ "$N_NOCSS" -gt 0 ]]; then
      bad "${N_NOCSS} 个部件既无 templateCss 也无 HTML <style> 块"
    else
      ok "全部 ${N_ALL} 个部件都有样式定义"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════
step "L4　部署物料与源码"
# ════════════════════════════════════════════════════════════════
WT="$APP_HOME/data/json/system/widget_types"
if [[ ! -d "$WT" ]]; then
  bad "找不到 $WT —— 部署目录不完整"
else
  N=$(ls "$WT"/energy_*.json 2>/dev/null | wc -l | tr -d ' ')
  ok "部署物料里有 ${N} 个能源部件 JSON"
  BADJSON=0
  for f in "$WT"/energy_*.json; do
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if (d.get('descriptor') or d.get('templateHtml') or d.get('templateCss')) else 1)
" "$f" 2>/dev/null || BADJSON=$((BADJSON+1))
  done
  [[ "$BADJSON" -gt 0 ]] && bad "${BADJSON} 个部件 JSON 结构异常" || ok "全部部件 JSON 结构正常"
fi

# ════════════════════════════════════════════════════════════════
step "结论与下一步"
# ════════════════════════════════════════════════════════════════
if [[ "$RC" == "0" ]]; then
  printf '  \033[32m后端与物料都正常\033[0m —— 问题在浏览器层。\n\n'
  cat <<'TXT'
  部件有【两条】样式通道，必须分别验证，不要混为一谈：

    通道 A  descriptor.templateCss
            → cssParser 注入，规则带 .widget-type-xxx 前缀
            → 管「排布」：间距、flex、内外边距
            → 失效表现：位置乱了，但按钮仍有颜色

    通道 B  templateHtml 里的 <style> 块
            → Angular 模板编译，规则带 [_ngcontent-xxx] 属性
            → 管「控件外观」：按钮颜色/圆角、下拉框高度、输入框边框
            → 失效表现：**布局正常，但按钮、下拉框、输入框全裸**

  你描述的「布局正常 + 按钮和下拉框完全没样式」= 通道 B 失效。

  请把下面这段贴到【出问题的那个页面】的 Console（F12）回车：
TXT
  echo
  cat <<'JS'
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
JS
  echo
  echo "  判读（对照本机正常值）："
  echo "    ngcontentRules  ≥ 200      → 通道 A/B 都在"
  echo "    ngcontentRules  < 50       → 通道 B 没进 DOM，前端产物或缓存问题"
  echo "    eqpRuleSample 里没有 _ngcontent → 同上"
  echo "    button.bg  应为 rgb(22, 131, 74)    → 绿色"
  echo "    formField.h 应为 36               → px"
  echo "    tbDefault 应含 tb-default"
  echo
  echo "  三项都正常但客户仍看着不对 → 浏览器缓存：Cmd+Shift+R / Ctrl+F5，或换无痕窗口"
else
  printf '  \033[31m上面标 ✗ 的层就是问题所在\033[0m\n'
  echo
  echo "    L1 ✗ → jar 里没前端或前端不完整：bash guard-server/pack.sh --clean"
  echo "    L2 ✗ → MIME/404：检查 nginx/gateway；nonsniff 下 MIME 错会让整页无样式"
  echo "    L3 ✗ → 部件数据缺样式：重跑 install，或 31-deploy-widget.sh --all 推部件"
  echo "    L4 ✗ → 物料不全：32-check-deploy-sync.sh --fix"
fi

echo
exit "$RC"
