#!/usr/bin/env bash
#
# 能源管理平台 · 改完后端后的产物一致性自检
#
# 解决什么问题：源码 / 部署 jar / 运行容器 三份状态不同步时，
# 测的是旧代码，白排查半天（2026-10-22 真实踩过）。
#
# 用法（任意目录）：
#   bash shiyongshouce/downloads/deploy/docker-97-preflight.sh
#   bash .../docker-97-preflight.sh --app-home ~/energy-app
#
# 退出码：0 = 全部一致；1 = 有不一致项（不要继续验收，先修）
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
APP_HOME="${HOME}/energy-app"
BASE="${BASE:-http://127.0.0.1:8090}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-home) APP_HOME="$2"; shift 2 ;;
    --base)     BASE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
C()   { printf '\n\033[36m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. 部署目录
C "1. 部署目录完整性"
[[ -d "$APP_HOME" ]] || { bad "部署目录不存在：${APP_HOME}（还没装？）"; exit 1; }

# docker-00 / docker-98 本来就只在仓库里，不由部署目录持有 —— 不列入检查
for f in docker-compose.yml docker-01-install.sh docker-02-start.sh docker-99-uninstall.sh; do
  [[ -f "$APP_HOME/$f" ]] && ok "$f" || bad "缺 $f"
done

# ---------------------------------------------------------------- 2. jar 一致性
C "2. 后端产物一致性"
SRC_JAR="$ROOT/guard-server/target/guard-server-4.4.0.jar"
DST_JAR="$APP_HOME/guard-server-4.4.0.jar"
if [[ ! -f "$SRC_JAR" ]]; then
  warn "仓库里没有打好 jar（先 mvn package）"
elif [[ ! -f "$DST_JAR" ]]; then
  bad "部署目录没有 jar"
else
  # macOS 用 md5 -q，Linux 用 md5sum
  if command -v md5 >/dev/null 2>&1; then
    A=$(md5 -q "$SRC_JAR"); B=$(md5 -q "$DST_JAR")
  else
    A=$(md5sum "$SRC_JAR" | cut -d' ' -f1); B=$(md5sum "$DST_JAR" | cut -d' ' -f1)
  fi
  if [[ "$A" == "$B" ]]; then
    ok "jar 一致（$(stat -f%z "$DST_JAR" 2>/dev/null || stat -c%s "$DST_JAR") 字节）"
  else
    bad "jar 不一致 —— 忘了 cp target/guard-server-4.4.0.jar 到 $APP_HOME"
  fi
fi

# ---------------------------------------------------------------- 3. 脚本一致性
C "3. 脚本一致性（仓库是唯一真相，部署目录是副本）"
SRC_DIR="$ROOT/shiyongshouce/downloads/scripts"
DST_DIR="$APP_HOME/scripts"

# ★ 只比对 02 起的脚本 —— 这是 docker-00-prepare.sh 的拷贝规则，两处必须一致。
#
#   01-install.sh 是「不起 Docker、直连数据库」的裸机路径，**有意不进**
#   Docker 部署目录（放进去只会让人误以为要跑它）。
#   本脚本第一版用 `*` 全比，误报「部署目录缺 01-install.sh」——
#   教训：写检查判据前先确认「正确状态长什么样」，别拿「仓库有什么」
#   当「部署目录该有什么」。规则变了要同时改这里和 docker-00-prepare.sh。
# 两个通配符：0[2-9]-* 覆盖 02..09，[1-9][0-9]-* 覆盖 10..99。
# 只写前者会漏掉 10-cleanup-customer.sh（踩过：手册让用户跑，但没进部署目录）。
SCRIPT_GLOBS=( '0[2-9]-*' '[1-9][0-9]-*' )

is_ops_script() {
  local n="$1" g
  for g in "${SCRIPT_GLOBS[@]}"; do
    [[ "$n" == $g ]] && return 0
  done
  return 1
}

if [[ -d "$SRC_DIR" && -d "$DST_DIR" ]]; then
  N=0; TOTAL=0
  for f in "$SRC_DIR"/0[2-9]-* "$SRC_DIR"/[1-9][0-9]-*; do
    [[ -e "$f" ]] || continue
    TOTAL=$((TOTAL+1))
    b=$(basename "$f")
    if [[ ! -f "$DST_DIR/$b" ]]; then
      bad "部署目录缺脚本：$b"
      N=$((N+1))
    elif ! diff -q "$f" "$DST_DIR/$b" >/dev/null 2>&1; then
      bad "脚本过期：${b}（cp 过去）"
      N=$((N+1))
    fi
  done

  # 反向检查：部署目录里有、仓库里没有的 → 是旧版残留，容易被误跑
  for f in "$DST_DIR"/*; do
    [[ -e "$f" ]] || continue
    b=$(basename "$f")
    is_ops_script "$b" || continue
    [[ -f "$SRC_DIR/$b" ]] || { bad "部署目录有仓库已删的脚本：${b}（删掉它，避免误跑）"; N=$((N+1)); }
  done

  [[ "$N" == "0" ]] && ok "全部一致（${TOTAL} 个，不含裸机路径 01-install.sh）"

  # 3b. bash 3.2 兼容性：$VAR 紧跟中文会被当成变量名的一部分
  #     macOS 自带 bash 3.2，这个坑已经踩过三次（报错信息里变量名带乱码）
  CHK="$HERE/../../../tools/check-bash-cn-var.py"
  if [[ -f "$CHK" ]]; then
    # 两处都要扫：deploy/ 是本目录的脚本，scripts/ 是运维脚本。
    # 只扫一处会漏（踩过：新增的 docker-02-start.sh 与 preflight 自身都有这个问题）。
    if python3 "$CHK" -q "$HERE" 2>/dev/null && python3 "$CHK" -q "$SRC_DIR" 2>/dev/null; then
      ok "脚本无 \$VAR 紧跟中文（bash 3.2 兼容）"
    else
      bad "脚本里有 \$VAR 紧跟中文，macOS bash 3.2 会报 unbound variable"
      python3 "$CHK" "$HERE" 2>/dev/null | sed 's/^/      /' | head -8
      python3 "$CHK" "$SRC_DIR" 2>/dev/null | sed 's/^/      /' | head -8
      N=$((N+1))
    fi
  fi
else
  warn "缺少脚本目录，跳过"
fi

# ---------------------------------------------------------------- 4. 服务健康
C "4. 服务健康"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' \
  "$BASE/api/noauth/whiteLabel/loginWhiteLabelParams" 2>/dev/null || echo 000)
[[ "$CODE" == "200" ]] && ok "HTTP $CODE" || bad "HTTP ${CODE}（服务没起或端口不对）"

# 进程内 class 版本无法直接查；用「健康 + jar 一致」间接保证
if command -v docker >/dev/null 2>&1 && [[ -f "$APP_HOME/docker-compose.yml" ]]; then
  ST=$(cd "$APP_HOME" && docker compose --profile split ps energy-server --format '{{.Status}}' 2>/dev/null | head -1)
  [[ "$ST" == *healthy* ]] && ok "energy-server $ST" || warn "energy-server 状态：${ST:-未知}"
fi

# ---------------------------------------------------------------- 5. 手册一致性
C "5. 手册一致性"
if [[ -x "$ROOT/shiyongshouce/check-docs.py" ]]; then
  if (cd "$ROOT/shiyongshouce" && ./check-docs.py >/tmp/preflight-docs.log 2>&1); then
    ok "check-docs 全过"
  else
    bad "check-docs 有差异（见 /tmp/preflight-docs.log）"
  fi
  if (cd "$ROOT/shiyongshouce" && ./sync.sh --check >/dev/null 2>&1); then
    ok "guard_help 已同步"
  else
    bad "guard_help 未同步（跑 ./sync.sh）"
  fi
else
  warn "找不到 check-docs.py，跳过"
fi

# ---------------------------------------------------------------- 结论
echo
if [[ "$FAIL" == "0" ]]; then
  printf '\033[32m产物一致，可以开始验收。\033[0m\n'
  echo "  下一步：bash scripts/08-verify-release.sh ... && bash scripts/06-verify-e2e.sh ..."
  exit 0
else
  printf '\033[31m有不一致项，先修再验收。\033[0m\n'
  echo "  最常见：改了源码没 cp jar / 改了脚本没同步到部署目录。"
  exit 1
fi
