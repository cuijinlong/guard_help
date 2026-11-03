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
#   第三类最容易漏：<APP_HOME>/scripts/ 里的运维脚本。
#   docker-00-prepare.sh 只在**组装时**拷一次，之后仓库新增/改写的脚本
#   不会自己跑进已部署的目录（实测 2026-11-02：手册让跑
#   `bash scripts/29-rtu-demo-up.sh`，客户照抄得到 No such file or directory,
#   因为部署目录里还是 10-29 那批旧脚本）。
#   症状极难自查：仓库里文件在、手册写得对、容器也在跑，只有命令跑不了。
#
# 用法：
#   bash 32-check-deploy-sync.sh                      # 默认比 /Users/cuijinlong/energy-app
#   bash 32-check-deploy-sync.sh --app /path/to/app   # 指定部署目录
#   bash 32-check-deploy-sync.sh --fix                # 有问题就直接同步过去
#
# ★ 必须在仓库里跑（或 --scripts-src 指定仓库脚本目录）。
#   本脚本自己也会被拷进 <APP>/scripts/，从部署目录跑会自己比自己。
#
# 退出码：0 一致；1 有差异（或 --fix 失败）
# ==============================================================================
set -uo pipefail

APP="/Users/cuijinlong/energy-app"
SRC=""
SCRIPTS_SRC_ARG=""
FIX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)         APP="$2"; shift 2 ;;
    --src)         SRC="$2"; shift 2 ;;
    --scripts-src) SCRIPTS_SRC_ARG="$2"; shift 2 ;;
    --fix)         FIX=1; shift ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 源码目录：脚本在 <repo>/shiyongshouce/downloads/scripts/
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." 2>/dev/null && pwd)"
[[ -z "$SRC" ]] && SRC="$REPO/guard-server/src/main/data"

# ★ 防止「自己比自己」：这个脚本本身也会被拷进 <APP>/scripts/，
#   从部署目录跑时两边是同一个目录，永远报「完全一致」——
#   而真正缺失的脚本一个都查不出来。实测过这个坑：
#   10-29 的部署目录里跑本脚本，28 个脚本「全齐」，
#   可 29-rtu-demo-up.sh 根本不在里面。
# 判据用「父目录有 docker-01-install.sh」而不是比字符串：
#   部署目录可以改名、可以用 --app 指到别处，比字符串会漏。
if [[ -n "$SCRIPTS_SRC_ARG" ]]; then
  SCRIPTS_SRC="$SCRIPTS_SRC_ARG"
elif [[ -f "$HERE/../docker-01-install.sh" ]]; then
  printf '  \033[31m✗\033[0m 本脚本跑在部署目录里（%s）—— 没有源码可比，会假报「一致」\n' "$HERE"
  printf '     请从仓库跑： bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --fix\n'
  printf '     或显式指定 --scripts-src <仓库>/shiyongshouce/downloads/scripts\n'
  exit 1
else
  SCRIPTS_SRC="$HERE"
fi

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1;36m━━ %s\033[0m\n' "$1"; }

step "0. 目录检查"
[[ -d "$SRC" ]] || { bad "源码目录不存在：$SRC"; exit 1; }
[[ -d "$APP/data" ]] || { bad "部署目录不存在：$APP/data"; exit 1; }
[[ -d "$SCRIPTS_SRC" ]] || { bad "脚本源码目录不存在：$SCRIPTS_SRC"; exit 1; }
ok "源码：$SRC"
ok "脚本：$SCRIPTS_SRC"
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

step "2. 运维脚本与源码逐文件比对（缺脚本 = 手册命令直接报 No such file）"
# ★ 收集规则在 _deploy-manifest.sh 里 —— 与 docker-00-prepare.sh（拷贝）、
#   docker-97-preflight.sh（自检）共用同一份，不再各自内联维护。
#   三处各写一份的代价实测过：preflight 用 `*` 全比误报缺 01-install.sh；
#   prepare 漏 dev-fast-build.sh，手册里的命令从来跑不了。
SCRIPTS_APP="$APP/scripts"
if [[ -f "$SCRIPTS_SRC/_deploy-manifest.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPTS_SRC/_deploy-manifest.sh"
else
  bad "源码里缺 _deploy-manifest.sh（部署脚本清单的唯一真相）"
  exit 1
fi
list_scripts() { deploy_list_scripts "$1"; }

if [[ ! -d "$SCRIPTS_APP" ]]; then
  bad "部署目录没有 scripts/ —— 手册里所有 bash scripts/xxx.sh 都会失败"
  RC=1
else
  SRC_SET=$(list_scripts "$SCRIPTS_SRC")
  APP_SET=$(list_scripts "$SCRIPTS_APP")
  MISSING=$(comm -23 <(printf '%s\n' "$SRC_SET") <(printf '%s\n' "$APP_SET") | grep . || true)
  EXTRA=$(comm -13 <(printf '%s\n' "$SRC_SET") <(printf '%s\n' "$APP_SET") | grep . || true)

  # 内容比对只看两边都有的
  DIFFED=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$SCRIPTS_APP/$f" ]] || continue
    if ! cmp -s "$SCRIPTS_SRC/$f" "$SCRIPTS_APP/$f"; then DIFFED+="$f"$'\n'; fi
  done <<< "$SRC_SET"
  DIFFED=$(printf '%s' "$DIFFED" | grep . || true)

  NSRC=$(printf '%s\n' "$SRC_SET" | grep -c . || true)
  NAPP=$(printf '%s\n' "$APP_SET" | grep -c . || true)

  if [[ -z "$MISSING" && -z "$DIFFED" ]]; then
    ok "scripts/ 齐全且与源码一致（${NAPP} 个）"
  else
    [[ -n "$MISSING" ]] && { bad "部署目录缺 $(printf '%s\n' "$MISSING" | grep -c .) 个脚本："; printf '%s\n' "$MISSING" | sed 's/^/      /'; RC=1; }
    [[ -n "$DIFFED"  ]] && { bad "内容与源码不同 $(printf '%s\n' "$DIFFED" | grep -c .) 个："; printf '%s\n' "$DIFFED" | sed 's/^/      /'; RC=1; }
  fi

  # 部署侧多出来的：不自动删（可能是客户自己放的），但必须报 ——
  # 仓库已废弃的脚本留在现场，会让人在两个同名用途的脚本之间选错。
  if [[ -n "$EXTRA" ]]; then
    warn "部署目录多出 $(printf '%s\n' "$EXTRA" | grep -c .) 个仓库已无的脚本（不自动删除，请人工确认）："
    printf '%s\n' "$EXTRA" | sed 's/^/      /'
  fi
fi

step "3. 部署根目录的 docker-*.sh（97-preflight / 98-rebuild 容易漏）"
# 这些也是部署物料，但不在 data/ 也不在 scripts/ —— 之前没人查，
# 于是 97-preflight 从来没进过部署目录（手册提到就报 No such file）。
DOCKER_SRC="$HERE/../deploy"
# ★ 目录不存在时不能静默通过：deploy_list_docker 对不存在的目录返回空，
#   循环一次不跑，于是永远报「齐全」—— 实测过，路径写错成 ../../deploy
#   时得到的就是这个假绿。
[[ -d "$DOCKER_SRC" ]] || { bad "找不到部署脚本源目录：$DOCKER_SRC"; exit 1; }
DOCKER_MISSING=""
DOCKER_DIFFED=""
for b in $(deploy_list_docker "$DOCKER_SRC"); do
  [[ -z "$b" ]] && continue
  if [[ ! -f "$APP/$b" ]]; then
    DOCKER_MISSING+="$b"$'\n'
  elif ! cmp -s "$DOCKER_SRC/$b" "$APP/$b"; then
    DOCKER_DIFFED+="$b"$'\n'
  fi
done
DOCKER_MISSING=$(printf '%s' "$DOCKER_MISSING" | grep . || true)
DOCKER_DIFFED=$(printf '%s' "$DOCKER_DIFFED" | grep . || true)
if [[ -z "$DOCKER_MISSING" && -z "$DOCKER_DIFFED" ]]; then
  ok "docker-*.sh 齐全且一致（$(deploy_list_docker "$APP" | grep -c .) 个）"
else
  [[ -n "$DOCKER_MISSING" ]] && { bad "部署目录缺 $(printf '%s\n' "$DOCKER_MISSING" | grep -c .) 个部署脚本："; printf '%s\n' "$DOCKER_MISSING" | sed 's/^/      /'; RC=1; }
  [[ -n "$DOCKER_DIFFED"  ]] && { bad "部署脚本过期 $(printf '%s\n' "$DOCKER_DIFFED" | grep -c .) 个："; printf '%s\n' "$DOCKER_DIFFED" | sed 's/^/      /'; RC=1; }
fi

step "4. 部件 JSON 与源码逐文件比对"
DIFF_LIST=$(diff -rq "$SRC/json" "$APP/data/json" 2>/dev/null)
NDIFF=$(printf '%s' "$DIFF_LIST" | grep -c . || true)
if [[ "$NDIFF" == "0" ]]; then
  ok "json/ 完全一致"
else
  warn "json/ 有 ${NDIFF} 处差异："
  printf '%s\n' "$DIFF_LIST" | sed 's/^/      /' | head -20
  RC=1
fi

step "5. 结论"
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

  # 运维脚本：只补缺失与更新内容，**不删**部署侧多出的（客户可能自己放了东西）
  if [[ ! -d "$SCRIPTS_APP" ]]; then
    mkdir -p "$SCRIPTS_APP"
  else
    cp -R "$SCRIPTS_APP" "$SCRIPTS_APP.bak.$(date +%m%d-%H%M)" 2>/dev/null \
      && ok "已备份 scripts/ → scripts.bak.$(date +%m%d-%H%M)"
  fi
  COPY_N=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ ! -f "$SCRIPTS_APP/$f" ]] || ! cmp -s "$SCRIPTS_SRC/$f" "$SCRIPTS_APP/$f"; then
      cp "$SCRIPTS_SRC/$f" "$SCRIPTS_APP/$f" && COPY_N=$((COPY_N+1))
    fi
  done <<< "$(deploy_list_scripts "$SCRIPTS_SRC")"
  chmod +x "$SCRIPTS_APP"/*.sh 2>/dev/null || true
  ok "scripts/ 已同步（更新 ${COPY_N} 个，现共 $(deploy_list_scripts "$SCRIPTS_APP" | grep -c .) 个）"

  # 部署根目录的 docker-*.sh：同样是物料，同样会漂移
  DCOPY_N=0
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    if [[ ! -f "$APP/$b" ]] || ! cmp -s "$DOCKER_SRC/$b" "$APP/$b"; then
      cp "$DOCKER_SRC/$b" "$APP/$b" && DCOPY_N=$((DCOPY_N+1))
    fi
  done <<< "$(deploy_list_docker "$DOCKER_SRC")"
  chmod +x "$APP"/docker-*.sh 2>/dev/null || true
  ok "docker-*.sh 已同步（更新 ${DCOPY_N} 个）"
  echo
  warn "同步完成。若后端已打包，需要重新 mvn package + 重启容器才会生效"
  exit 0
fi

echo
bad "有差异。加 --fix 自动同步，或按上面清单手工处理。"
echo "    注意：不要用 rsync --delete 整个 data/（会删掉 cassandra/ 与实体 sql）"
echo "    scripts/ 多出的文件不会被自动删除，需人工确认后处理"
exit 1
