#!/usr/bin/env bash
# ==============================================================================
# 部署物料 vs 源码 一致性检查（2026-11-02）
#
# 为什么需要它：
#   部件的「源码」有两处 ——
#     源码副本      guard-server/src/main/data/json/system/widget_types/*.json
#     部署物料      <APP_HOME>/data/json/system/widget_types/*.json（install.data_dir）
#   install 只读部署物料，**不读源码副本**。改完源码不拷过去，
#   干净库 install 装进去的还是旧部件 —— 页面表现是「功能莫名其妙没了」，
#   而源码、生产库、浏览器缓存**三处看起来都对**（实测 2026-11-02：
#   综合能耗少了场站下拉、只剩 3 台计量点，查了两小时）。
#
#   同理 data/sql/ 必须是实体目录。源码里它是符号链接
#   （→ ../../../../dao/src/main/resources/sql），dao 模块删除后链接就断，
#   install 直接 NoSuchFileException。
#
# 用法：
#   bash 32-check-deploy-sync.sh                      # 默认比 /Users/cuijinlong/energy-app
#   bash 32-check-deploy-sync.sh --app /path/to/app   # 指定部署目录
#   bash 32-check-deploy-sync.sh --fix                # 有问题就直接同步过去
#
# 退出码：0 一致；1 有差异（或 --fix 失败）
# ==============================================================================
set -uo pipefail

APP="/Users/cuijinlong/energy-app"
SRC=""
FIX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)   APP="$2"; shift 2 ;;
    --src)   SRC="$2"; shift 2 ;;
    --fix)   FIX=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 源码目录：脚本在 <repo>/shiyongshouce/downloads/scripts/
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
[[ -z "$SRC" ]] && SRC="$REPO/guard-server/src/main/data"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1;36m━━ %s\033[0m\n' "$1"; }

step "0. 目录检查"
[[ -d "$SRC" ]] || { bad "源码目录不存在：$SRC"; exit 1; }
[[ -d "$APP/data" ]] || { bad "部署目录不存在：$APP/data"; exit 1; }
ok "源码：$SRC"
ok "部署：$APP/data"

RC=0

step "1. data/sql 必须是实体目录（不能是符号链接、不能缺文件）"
if [[ -L "$APP/data/sql" ]]; then
  bad "部署侧 data/sql 是符号链接 —— 容器里会断链，install 直接失败"
  RC=1
elif [[ ! -d "$APP/data/sql" ]]; then
  bad "部署侧 data/sql 不存在"
  RC=1
else
  n=$(ls "$APP/data/sql"/*.sql 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" -ge 8 ]]; then ok "部署侧 data/sql 有 ${n} 个 sql 文件"; else
    bad "部署侧 data/sql 只有 ${n} 个 sql 文件（应 ≥8）"; RC=1
  fi
fi
if [[ -L "$SRC/sql" ]]; then
  bad "源码侧 data/sql 仍是符号链接 —— dao 模块删除后会断链"
  RC=1
else
  ok "源码侧 data/sql 是实体目录"
fi

step "2. 部件 JSON 与源码逐文件比对"
DIFF_LIST=$(diff -rq "$SRC/json" "$APP/data/json" 2>/dev/null)
NDIFF=$(printf '%s' "$DIFF_LIST" | grep -c . || true)
if [[ "$NDIFF" == "0" ]]; then
  ok "json/ 完全一致"
else
  warn "json/ 有 ${NDIFF} 处差异："
  printf '%s\n' "$DIFF_LIST" | sed 's/^/      /' | head -20
  RC=1
fi

step "3. 结论"
if [[ "$RC" == "0" ]]; then
  ok "部署物料与源码一致，可以 install / 打包"
  exit 0
fi

if [[ "$FIX" == "1" ]]; then
  warn "开始同步（--fix）"
  # ★ 绝不能 rsync --delete 整个 data/：会把部署侧独有的 cassandra/ 删掉，
  #   也会因为源码 sql 是符号链接而删掉部署侧的实体 sql。
  #   只同步 json/，sql 单独按实体复制。
  if [[ -d "$APP/data/json" ]]; then
    cp -R "$APP/data/json" "$APP/data/json.bak.$(date +%m%d-%H%M)"
    ok "已备份 json/ → json.bak.$(date +%m%d-%H%M)"
  fi
  mkdir -p "$APP/data/json"
  rsync -a --delete "$SRC/json/" "$APP/data/json/" && ok "json/ 已同步"
  if [[ -L "$SRC/sql" ]]; then
    warn "源码 sql 是符号链接，跳过 sql 同步（先把它实体化）"
  else
    rm -rf "$APP/data/sql"
    cp -R "$SRC/sql" "$APP/data/sql"
    ok "data/sql 已同步为实体目录（$(ls "$APP/data/sql"/*.sql | wc -l | tr -d ' ') 个文件）"
  fi
  echo
  warn "同步完成。若后端已打包，需要重新 mvn package + 重启容器才会生效"
  exit 0
fi

echo
bad "有差异。加 --fix 自动同步，或按上面清单手工处理。"
echo "    注意：不要用 rsync --delete 整个 data/（会删掉 cassandra/ 与实体 sql）"
exit 1
