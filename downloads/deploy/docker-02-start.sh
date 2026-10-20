#!/usr/bin/env bash
#
# 能源管理平台 · Docker 部署 第 2 步：启动服务 + 创建系统管理员
#
# 用法（在 energy-deploy 目录内，且已跑完 docker-01-install.sh）：
#   bash docker-02-start.sh --admin-email admin@example.com --admin-pass 'ChangeMe123!'
#
# 若服务已经启动、管理员也已存在，脚本只做校验，不会重复创建。
#
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose"
ADMIN_EMAIL=""
ADMIN_PASS=""

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-pass)  ADMIN_PASS="$2"; shift 2 ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -f .env ]] || die "缺少 .env"
# shellcheck disable=SC1091
set -a; . ./.env; set +a
PORT="${HTTP_PORT:-8090}"
BASE="http://127.0.0.1:${PORT}"
MODE="${DEPLOY_MODE:-split}"
case "$MODE" in
  split)    PROFILE_ARGS="--profile split";    TARGET="energy-server gateway" ;;
  allinone) PROFILE_ARGS="--profile allinone"; TARGET="allinone" ;;
  *) die "DEPLOY_MODE 只能是 split 或 allinone，当前：$MODE" ;;
esac
# 本机代理会把 127.0.0.1 也接管，必须绕过
ncurl() { curl -s --noproxy '*' "$@"; }

# ---------------- 1. 检查 install 是否做过 ----------------
if [[ "$MODE" == "allinone" ]]; then
  # 单容器的表在容器内，先确保容器起来再问表数
  $COMPOSE $PROFILE_ARGS up -d --build allinone
  log "等待容器内 PostgreSQL 与 install 完成（首次约 3-5 分钟）"
else
TABLES=$($COMPOSE $PROFILE_ARGS exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d ' ' || echo 0)
[[ "${TABLES:-0}" -ge 100 ]] || die "库还没初始化（${TABLES:-0} 张表）。先跑 bash docker-01-install.sh"
fi

# ---------------- 2. 启动服务 ----------------
if [[ "$MODE" == "allinone" ]]; then
  log "启动单容器（已在上一步拉起，等待就绪）"
else
log "启动服务"
# 不带服务名：把 postgres / energy-server / ngxai-backend / gateway 一起拉起来。
# 首次运行会构建 ngx-ai 后端镜像（pip 装依赖 + 编译 Stan，约 5-10 分钟）。
log "启动全部服务（首次构建 ngx-ai 镜像较慢，请耐心）"
$COMPOSE $PROFILE_ARGS up -d --build
fi

if [[ "$MODE" == "allinone" ]]; then
  WAIT_MAX=180   # 单容器首次要跑 install，给 15 分钟
  log "等待服务就绪（单容器首次含 install，约 3–5 分钟）"
else
  WAIT_MAX=48
  log "等待服务就绪（首次约 60–120 秒）"
fi

STATE=""
for i in $(seq 1 $WAIT_MAX); do
  sleep 5
  # 只认 JSON 响应。nginx 在上游还没起来时会返回 502 HTML，
  # 那不是"就绪"——旧逻辑只判断"有输出"，会把 502 当成功。
  RESP=$(ncurl -m 4 "$BASE/api/noauth/setup/state" 2>/dev/null || true)
  if echo "$RESP" | grep -q '"status"'; then
    STATE="$RESP"
    ok "服务已就绪（$((i*5))s）：$STATE"
    break
  fi
  if [[ "$i" == "$WAIT_MAX" ]]; then
    $COMPOSE $PROFILE_ARGS logs --tail=60 $TARGET
    die "等待超时（$((WAIT_MAX*5)) 秒），上面是容器日志尾部"
  fi
done

# ---------------- 3. 创建管理员 ----------------
if echo "$STATE" | grep -q "READY"; then
  ok "系统已有管理员，跳过创建"
elif echo "$STATE" | grep -q "ACCOUNT_REQUIRED"; then
  [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" ]] \
    || die "系统还没有管理员，请加参数：--admin-email ... --admin-pass ..."

  log "创建系统管理员 $ADMIN_EMAIL"
  CODE=$(ncurl -m 120 -o /tmp/energy-setup.json -w '%{http_code}' \
    -X POST "$BASE/api/noauth/setup/complete" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"loadDemo\":false}")
  if [[ "$CODE" != "200" ]]; then
    cat /tmp/energy-setup.json
    echo
    die "创建管理员失败（HTTP ${CODE}）"
  fi
  ok "管理员已创建"
else
  die "无法识别的 setup 状态：$STATE"
fi

# ---------------- 4. 登录验证 ----------------
TOKEN=$(ncurl -m 30 -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

if [[ -z "$TOKEN" ]]; then
  warn "登录失败。若管理员已在别处创建，请用当时设置的密码；"
  warn "忘记密码可在容器内重置（见手册「故障排查」）。"
  die "管理员登录验证未通过"
fi

ME=$(ncurl -m 20 -H "X-Authorization: Bearer $TOKEN" "$BASE/api/auth/user")
echo "$ME" | grep -q '"authority":"SYS_ADMIN"' || die "登录成功但不是 SYS_ADMIN，返回：$ME"
ok "系统管理员可登录，权限 SYS_ADMIN"

echo
ok "第 2 步完成"
echo "   访问地址：http://<服务器IP>:${PORT}/"
echo "   管理员：  $ADMIN_EMAIL"
echo "   下一步：  开租户与客户"
echo "             bash ../scripts/02-onboard.sh --base http://127.0.0.1:${PORT} \\"
echo "               --admin $ADMIN_EMAIL --admin-pass '...' \\"
echo "               --tenant \"某某集团\" --tenant-email tenant@example.com --tenant-pass '...' \\"
echo "               --customer \"某某厂区\" --customer-email customer@example.com --customer-pass '...'"
