#!/usr/bin/env bash
#
# 能源管理平台 · 部件样式自检
#
# 用途：客户/运维反馈「部件能看到，但按钮、下拉框样式不对」时，
#       一条命令定位到底哪一层丢了样式。
#
# 用法（在部署目录 ~/energy-app 下）：
#   bash scripts/33-check-widget-style.sh
#   bash scripts/33-check-widget-style.sh --widget query_panel    # 只看一个部件
#   bash scripts/33-check-widget-style.sh --port 8090
#
# 检查四层，逐层给结论：
#   L1  jar 里的前端产物：production / development / 缺失
#   L2  全局 CSS 是否可访问、MIME 是否正确（错成 application/json 会导致整页无样式）
#   L3  数据库里部件的 templateCss 与 HTML 内的 <style> 块
#   L4  部署物料与源码是否一致（新装机最常见）
#
# 退出码：0 = 四层都正常；1 = 有问题（并指出是哪一层）
#
# ⚠ 本脚本只读，不改任何东西。
#
set -uo pipefail

PORT="${HTTP_PORT:-8090}"
ONLY=""
CONTAINER="${APP_CONTAINER:-energy-server}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --widget) ONLY="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="$(cd "$HERE/.." && pwd)"
[ -f "$APP_HOME/.env" ] && { set -a; . "$APP_HOME/.env" 2>/dev/null; set +a; }
: "${APP_HOME:=$APP_HOME}"

RC=0
head1() { printf '\n\033[1;36m━━ %s\033[0m\n' "$1"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$1"; RC=1; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
info()  { printf '    %s\n' "$1"; }

psql_q() {
  docker exec "${PSQL_CONTAINER:-energy-postgres}" psql -U postgres -d thingsboard -t -A -c "$1" 2>/dev/null
}

echo "============================================================"
echo " 部件样式自检"
echo " 部署目录 $APP_HOME"
echo " 服务端口 $PORT"
echo "============================================================"

# ════════════════════════════════════════════════════════════════
head1 "L1　jar 里的前端产物"
# ════════════════════════════════════════════════════════════════
JAR="$APP_HOME/guard-server-4.4.0.jar"
if [[ ! -f "$JAR" ]]; then
  bad "找不到 $JAR"
else
  # 取 index.html，看引用的文件名有没有 hash
  IDX=$(unzip -p "$JAR" BOOT-INF/classes/public/index.html 2>/dev/null)
  if [[ -z "$IDX" ]]; then
    bad "jar 里没有前端产物（BOOT-INF/classes/public/index.html 不存在）"
    info "这就是整页无样式/白屏的原因。用 bash guard-server/pack.sh 重新打包（别加 --skip-ui）"
  else
    N_UI=$(unzip -l "$JAR" 2>/dev/null | grep -cF "BOOT-INF/classes/public/")
    if grep -qE 'main-[A-Z0-9]{8}\.js' <<<"$IDX"; then
      ok "前端产物：production（带 hash），public/ 下 ${N_UI} 个文件"
    elif grep -qE 'main\.js' <<<"$IDX"; then
      warn "前端产物：development（无 hash）—— 能用，但不是发布版"
      info "要发布请用 bash guard-server/pack.sh（不加 --skip-ui）"
    else
      warn "无法判断构建类型（index.html 里没有 main-*.js）"
    fi
    # 全局 CSS 清单
    CSS_LIST=$(grep -oE 'href="[^"]+\.css"' <<<"$IDX" | sed 's/href="//;s/"//')
    echo "$CSS_LIST" | sed 's/^/      /'
    if [[ -z "$CSS_LIST" ]]; then
      bad "index.html 没有引用任何 .css"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════
head1 "L2　全局 CSS 可访问性与 MIME"
# ════════════════════════════════════════════════════════════════
BASE="http://127.0.0.1:${PORT}"
CURL_OPTS=(-s --noproxy '*' --max-time 10)
if ! curl "${CURL_OPTS[@]}" -o /dev/null "$BASE/" 2>/dev/null; then
  bad "服务没在 $BASE 响应 —— 先确认容器在跑：docker ps | grep energy-server"
else
  ok "服务可访问：$BASE"
  if [[ -n "${IDX:-}" ]]; then
    while IFS= read -r cssurl; do
      [[ -z "$cssurl" ]] && continue
      CODE=$(curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' "$BASE/$cssurl")
      CT=$(curl "${CURL_OPTS[@]}" -I "$BASE/$cssurl" 2>/dev/null | grep -i '^content-type' | tr -d '\r' | cut -d' ' -f2-)
      SIZE=$(curl "${CURL_OPTS[@]}" "$BASE/$cssurl" | wc -c | tr -d ' ')
      if [[ "$CODE" != "200" ]]; then
        bad "$cssurl → HTTP $CODE（加载失败，整页会缺这块样式）"
      elif [[ "$CT" != text/css* ]]; then
        bad "$cssurl → Content-Type 是「$CT」，不是 text/css"
        info "浏览器会拒收（X-Content-Type-Options: nosniff），表现为整页无样式"
      else
        ok "$cssurl  HTTP 200  text/css  ${SIZE} 字节"
      fi
    done <<<"$CSS_LIST"
  fi
fi

# ════════════════════════════════════════════════════════════════
head1 "L3　数据库里的部件样式字段"
# ════════════════════════════════════════════════════════════════
if ! docker ps --format '{{.Names}}' | grep -qx "${PSQL_CONTAINER:-energy-postgres}"; then
  warn "跳过：找不到容器 ${PSQL_CONTAINER:-energy-postgres}"
else
  W="%"
  [[ -n "$ONLY" ]] && W="%${ONLY}%"
  ROWS=$(psql_q "
    SELECT fqn,
           length(descriptor::jsonb->>'templateCss'),
           length(descriptor::jsonb->>'templateHtml'),
           (length(descriptor::jsonb->>'templateHtml')
            - length(replace(descriptor::jsonb->>'templateHtml','<style','')))/6
    FROM widget_type
    WHERE fqn LIKE 'energy_%' AND fqn LIKE '$W'
    ORDER BY fqn;")
  if [[ -z "$ROWS" ]]; then
    bad "库里查不到能源部件（widget_type 为空？）—— install 没跑完，或连错了库"
  else
    N_ALL=0; N_NOCSS=0
    printf '    %-44s %8s %8s %6s\n' "fqn" "css" "html" "style块"
    while IFS='|' read -r fqn css html st; do
      [[ -z "$fqn" ]] && continue
      N_ALL=$((N_ALL+1))
      flag=""
      if [[ "${css:-0}" == "0" && "${st:-0}" == "0" ]]; then
        flag="  \033[31m← 完全无样式\033[0m"; N_NOCSS=$((N_NOCSS+1))
      elif [[ "${st:-0}" == "0" ]]; then
        flag="  (仅 templateCss)"
      fi
      printf "    %-44s %8s %8s %6s" "$fqn" "${css:-0}" "${html:-0}" "${st:-0}"
      [[ -n "$flag" ]] && printf "$flag"
      printf '\n'
    done <<<"$ROWS"
    echo
    if [[ "$N_NOCSS" -gt 0 ]]; then
      bad "有 ${N_NOCSS} 个部件既没有 templateCss 也没有 HTML <style> 块 —— 它们装出来必然无样式"
    else
      ok "全部 ${N_ALL} 个部件都有样式定义"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════
head1 "L4　部署物料与源码（新装机最常见）"
# ════════════════════════════════════════════════════════════════
WT="$APP_HOME/data/json/system/widget_types"
if [[ ! -d "$WT" ]]; then
  bad "找不到 $WT —— 部署目录不完整，重跑 docker-00-prepare.sh"
else
  N=$(ls "$WT"/energy_*.json 2>/dev/null | wc -l | tr -d ' ')
  ok "部署物料里有 ${N} 个能源部件 JSON"
  # 抽查：至少一个部件 JSON 能解析且带 descriptor
  BADJSON=0
  for f in "$WT"/energy_*.json; do
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
if not (d.get('descriptor') or d.get('templateHtml') or d.get('templateCss')):
    sys.exit(1)
" "$f" 2>/dev/null || BADJSON=$((BADJSON+1))
  done
  if [[ "$BADJSON" -gt 0 ]]; then
    bad "${BADJSON} 个部件 JSON 无法解析或缺少 descriptor"
  else
    ok "全部部件 JSON 结构正常"
  fi
fi

# ════════════════════════════════════════════════════════════════
head1 "结论"
# ════════════════════════════════════════════════════════════════
if [[ "$RC" == "0" ]]; then
  printf '  \033[32m四层都正常\033[0m —— 后端与物料没问题。\n\n'
  echo "  问题在浏览器层。请在**出问题的那个页面**按 F12 → Console，粘贴下面这段回车："
  echo
  cat <<'JS'
(() => {
  const r = {};
  r.bodyClass = document.body.className;
  r.hasTbDefault = !!document.querySelector('.tb-default');
  r.formFieldVar = getComputedStyle(document.body)
      .getPropertyValue('--mat-form-field-container-height').trim();
  // 统计部件私有样式规则
  const w = document.querySelector('[class*="widget-type-"]');
  r.widgetClass = w ? [...w.classList].find(c=>c.startsWith('widget-type-')) : null;
  let n = 0;
  for (const ss of document.styleSheets) {
    let l; try { l = ss.cssRules } catch(e){ continue }
    for (const rule of l||[]) {
      if ((rule.selectorText||'').includes('_ngcontent')) n++;
    }
  }
  r.ngcontentRules = n;
  r.styleTags = document.querySelectorAll('style').length;
  console.table(r);
  return r;
})()
JS
  echo
  echo "  判读："
  echo "    formFieldVar 是 56px / tb-default=true  → TB 公共主题正常"
  echo "    ngcontentRules 很小（<100）              → 部件私有样式没进 DOM"
  echo "    bodyClass 里没有 tb-default              → 白标配置把它去掉了"
else
  printf '  \033[31m上面标 ✗ 的层就是问题所在\033[0m\n'
  echo
  echo "  常见对应关系："
  echo "    L1 ✗  → jar 里没前端，重新 bash guard-server/pack.sh"
  echo "    L2 ✗  → MIME 或 404，检查 nginx/gateway 配置"
  echo "    L3 ✗  → 部件数据缺样式，重跑 install 或推部件"
  echo "    L4 ✗  → 物料不全，bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --fix"
fi

echo
exit "$RC"
