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
# 本机代理会把 127.0.0.1 也接管，必须绕过
ncurl() { curl -s --noproxy '*' "$@"; }

# ---------------- 1. 检查 install 是否做过 ----------------
TABLES=$($COMPOSE exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d ' ' || echo 0)
[[ "${TABLES:-0}" -ge 100 ]] || die "库还没初始化（${TABLES:-0} 张表）。先跑 bash docker-01-install.sh"

# ---------------- 2. 启动服务 ----------------
log "启动服务"
$COMPOSE up -d server

log "等待服务就绪（首次约 60–120 秒）"
STATE=""
for i in $(seq 1 48); do
  sleep 5
  STATE=$(ncurl -m 4 "$BASE/api/noauth/setup/state" 2>/dev/null || true)
  if [[ -n "$STATE" ]]; then
    ok "服务已就绪（$((i*5))s）：$STATE"
    break
  fi
  if [[ "$i" == "48" ]]; then
    $COMPOSE logs --tail=40 server
    die "240 秒内服务未就绪（上面是容器日志尾部）"
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
