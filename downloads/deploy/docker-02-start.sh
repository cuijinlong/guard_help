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

[[ -f .env ]] || die "缺少 .env。先跑 bash docker-01-install.sh（它会生成并校验配置）"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

# APP_HOME 是 compose 里挂载 jar 与 data 的基准路径，空值会让 compose 直接报错。
# 正常流程是 01 → 02，这里只是防止跳过 01 直接跑 02。
if [[ -z "${APP_HOME:-}" || ! -f "${APP_HOME}/guard-server-4.4.0.jar" ]]; then
  die "APP_HOME 未设置或无效（当前：${APP_HOME:-空}）。先跑 bash docker-01-install.sh，它会自动修正"
fi
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

# 设备接入通道。
#
# 不能用「/api/v1/xxx/telemetry 返回什么」来判断 —— 端点没装配是 404，
# 端点装了但 token 不对也是 404，两者分不出来。直接看装配条件：
#   DeviceApiController 要求 service.type=monolith 且 transport.http.enabled=true
SVC_TYPE=$($COMPOSE $PROFILE_ARGS exec -T energy-server \
  sh -c 'printf "%s" "${SERVICE_TYPE:-}"' 2>/dev/null | tr -d '\r\n')
HTTP_ON=$($COMPOSE $PROFILE_ARGS exec -T energy-server \
  sh -c 'printf "%s" "${HTTP_ENABLED:-}"' 2>/dev/null | tr -d '\r\n')

if [[ "$SVC_TYPE" == "monolith" && "$HTTP_ON" == "true" ]]; then
  ok "设备接入通道已开放（HTTP + MQTT）"
else
  cat <<MSG >&2
  ✗ 设备接入通道未开放：SERVICE_TYPE=${SVC_TYPE:-空} HTTP_ENABLED=${HTTP_ON:-空}

    平台自己的接口全正常，但 RTU / 网关会全部上报失败，界面上看不出来。
    需要 .env 与 docker-compose.yml 同时满足：
      SERVICE_TYPE=monolith
      HTTP_ENABLED=true
      MQTT_ENABLED=true

    排查：docker compose logs energy-server | grep -i transport

MSG
  warn "继续往下走，但在修好之前设备上报不通"
fi

# MQTT 端口：容器在跑不代表端口映射成功
MQTT_P="${MQTT_PORT:-1883}"
if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$MQTT_P" -sTCP:LISTEN >/dev/null 2>&1; then
    ok "MQTT 端口 ${MQTT_P} 正在监听"
  else
    warn "MQTT 端口 ${MQTT_P} 未监听 —— RTU 会连不上。看 docker compose ps 的端口映射"
  fi
fi

cat <<DONE

============================================================
 第 3 步完成：服务已启动，管理员已就绪
============================================================

  访问地址
    http://localhost:${PORT}/
    （服务器部署则用 http://服务器IP:${PORT}/）

  系统管理员
    ${ADMIN_EMAIL}

  现在可以用浏览器登录了。

------------------------------------------------------------
 下一步：开一个租户和一个客户（可选，不建也能登录）
------------------------------------------------------------

  cd ${APP_HOME} && bash scripts/02-onboard.sh \\
    --base http://127.0.0.1:${PORT} \\
    --admin ${ADMIN_EMAIL} --admin-pass '你刚设的密码' \\
    --tenant "环宇能源集团" \\
    --tenant-email tenant@example.com --tenant-pass 'Tenant@12345' \\
    --customer "星河工业园" \\
    --customer-email customer@example.com --customer-pass 'Customer@123'

  开完后跑验收：
  cd ${APP_HOME} && bash scripts/03-verify.sh \\
    --base http://127.0.0.1:${PORT} \\
    --tenant tenant@example.com --tenant-pass 'Tenant@12345' \\
    --customer customer@example.com --customer-pass 'Customer@123' \\
    --ai http://127.0.0.1:${PORT}

  预期最后一行：通过 22 / 失败 0

------------------------------------------------------------
 设备接入（RTU / 网关上报）
------------------------------------------------------------

  MQTT    ${MQTT_P}
          主题：v1/devices/me/telemetry
          用户名：设备的 Access Token（不是账号密码）
          密码：留空

  HTTP    http://本机IP:${PORT}/api/v1/{AccessToken}/telemetry
          Content-Type: application/json
          {"energy":2.88,"power_total":2.88,"voltage_a":220.5}

  每台设备的 Access Token 在平台里查：
    设备 → 点开某台 → 复制访问令牌

DONE
