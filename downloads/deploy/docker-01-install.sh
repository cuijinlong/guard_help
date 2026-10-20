#!/usr/bin/env bash
#
# 能源管理平台 · Docker 部署 第 1 步：环境检查 + 建库 + 初始化
#
# 用法（在 energy-deploy 目录内）：
#   cp env.example .env && vi .env      # 先改密码和 APP_HOME
#   bash docker-01-install.sh
#
# 做完这一步：数据库里有了 112 张表、726 个系统部件、34 个 bundle，
# 但**还没有任何用户**，服务也还没启动。下一步跑 docker-02-start.sh。
#
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------- 1. 前置检查 ----------------
log "检查环境"

command -v docker >/dev/null 2>&1 || die "未安装 docker"
docker info >/dev/null 2>&1 || die "docker 守护进程未运行（或当前用户无权限）。Linux 上试：sudo usermod -aG docker \$USER && newgrp docker"
$COMPOSE version >/dev/null 2>&1 || die "未安装 docker compose v2（需要 'docker compose'，不是旧版 docker-compose）"

# 缺少 .env 时自动生成：远程部署解压后直接跑这一条即可，
# 不需要手工 cp/vi，也不会因为手改路径写错而卡住。
if [[ ! -f .env ]]; then
  gen_pass() {
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 12
    else
      printf '%s%s%s' "$(date +%s)" "$$" "$RANDOM$RANDOM" | shasum | cut -c1-24
    fi
  }
  port_free() {
    if command -v lsof >/dev/null 2>&1; then
      ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
      ! (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1
    fi
  }
  _hp=8090; while ! port_free "$_hp" && [[ "$_hp" -lt 8200 ]]; do _hp=$((_hp+1)); done
  _dp=5432; while ! port_free "$_dp" && [[ "$_dp" -lt 5600 ]]; do _dp=$((_dp+1)); done
  cat > .env <<ENVEOF
# 由 docker-01-install.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 要改端口或密码，改完删掉容器重跑本脚本。
APP_HOME=$(pwd)
HTTP_PORT=$_hp
DB_NAME=thingsboard
DB_USER=postgres
DB_PASSWORD=$(gen_pass)
DB_PORT=$_dp
SERVER_HEAP=2g
SPRING_PROFILE=dev
AI_IMAGE=energy/ngxai-backend:4.4.0
TB_API_USERNAME=tenant@thingsboard.org
TB_API_PASSWORD=tenant
ENVEOF
  log "未找到 .env，已自动生成（APP_HOME=$(pwd)，端口 ${_hp}/${_dp}，密码随机）"
fi

# shellcheck disable=SC1091
set -a; . ./.env; set +a

# 部署模式：split（分容器，默认）| allinone（单容器）
MODE="${DEPLOY_MODE:-split}"
case "$MODE" in
  split)    PROFILE_ARGS="--profile split" ;;
  allinone) PROFILE_ARGS="--profile allinone" ;;
  *) die "DEPLOY_MODE 只能是 split 或 allinone，当前：$MODE" ;;
esac
log "部署模式：$MODE"

: "${APP_HOME:?请在 .env 设置 APP_HOME（部署目录绝对路径）}"
: "${DB_PASSWORD:?请在 .env 设置 DB_PASSWORD}"
[[ "$APP_HOME" = /* ]] || die "APP_HOME 必须是绝对路径，当前：$APP_HOME"
[[ -f "$APP_HOME/guard-server-4.4.0.jar" ]] || die "找不到 $APP_HOME/guard-server-4.4.0.jar"
[[ -f "$APP_HOME/data/sql/schema-entities.sql" ]] || die "找不到 $APP_HOME/data/sql/schema-entities.sql —— data/sql 必须有 8 个 sql 文件"
[[ -d "$APP_HOME/data/json/system/widget_types" ]] || die "找不到 $APP_HOME/data/json/system/widget_types"
[[ -f "$APP_HOME/nginx/energy.conf" ]] || die "找不到 $APP_HOME/nginx/energy.conf —— 网关配置缺失"
[[ -d "$APP_HOME/ngxai-dist" ]] || warn "找不到 $APP_HOME/ngxai-dist，分析页将不可用（后端仍可运行）"
[[ -d "$APP_HOME/ngxai-backend" ]] || warn "找不到 $APP_HOME/ngxai-backend，分析服务将不会启动"

# 内存：ES 不需要，但 JVM + PG 建议 4G 起
MEM_MB=$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1/1024/1024}')
if [[ -n "$MEM_MB" && "$MEM_MB" -lt 3500 ]]; then
  warn "Docker 可用内存 ${MEM_MB}MB，建议 4GB 以上（否则可能 OOM）"
fi

# 端口占用：优先 lsof，没有就用 bash 的 /dev/tcp 探测（最小化 Linux 常缺 lsof）
port_busy() {
  local p="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  else
    (exec 3<>/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1 || return 1
    exec 3>&- 2>/dev/null || true
    return 0
  fi
}

# 端口占用
for p in "${HTTP_PORT:-8090}" "${DB_PORT:-5432}"; do
  if port_busy "$p"; then
    die "端口 $p 已被占用，先停掉占用进程或改 .env 里的端口"
  fi
done
ok "docker / compose / 文件 / 端口 检查通过"

# ---------------- 单容器模式：install 在容器内自动完成 ----------------
if [[ "$MODE" == "allinone" ]]; then
  [[ -f "$APP_HOME/allinone/Dockerfile" ]] || die "找不到 $APP_HOME/allinone/Dockerfile"
  [[ -d "$APP_HOME/ngxai-dist" ]] || die "找不到 $APP_HOME/ngxai-dist"
  ok "单容器模式无需单独 install：首次启动时由容器自动建库并初始化"
  echo
  ok "第 1 步完成"
  echo "   下一步：bash docker-02-start.sh --admin-email admin@example.com --admin-pass '你的密码'"
  exit 0
fi

# ---------------- 2. 启动数据库 ----------------
log "启动 PostgreSQL（首次会拉取镜像，约 1 分钟）"
$COMPOSE $PROFILE_ARGS up -d postgres

for i in $(seq 1 40); do
  sleep 3
  s=$(docker inspect --format '{{.State.Health.Status}}' energy-postgres 2>/dev/null || echo none)
  if [[ "$s" == "healthy" ]]; then ok "数据库健康（$((i*3))s）"; break; fi
  if [[ "$i" == "40" ]]; then
    $COMPOSE $PROFILE_ARGS logs postgres | tail -20
    die "数据库 120 秒内未就绪"
  fi
done

# ---------------- 3. 防止重复 install ----------------
TABLES=$($COMPOSE $PROFILE_ARGS exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d ' ')
if [[ -n "$TABLES" && "$TABLES" != "0" ]]; then
  warn "库 ${DB_NAME:-thingsboard} 已有 ${TABLES} 张表"
  die "拒绝重复初始化。要重新来过请先执行：bash docker-99-uninstall.sh --purge --yes，再从本步开始"
fi

# ---------------- 4. 执行 install ----------------
log "执行 install（建表 + 装载系统资源，约 1-3 分钟）"
set +e
$COMPOSE --profile install $PROFILE_ARGS run --rm install > /tmp/energy-install.log 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  warn "install 退出码 ${RC}，日志尾部："
  tail -30 /tmp/energy-install.log
  die "install 失败（完整日志：/tmp/energy-install.log）"
fi

TABLES=$($COMPOSE $PROFILE_ARGS exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" | tr -d ' ')
WIDGETS=$($COMPOSE $PROFILE_ARGS exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from widget_type" | tr -d ' ')
BUNDLES=$($COMPOSE $PROFILE_ARGS exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from widgets_bundle" | tr -d ' ')
USERS=$($COMPOSE $PROFILE_ARGS exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from tb_user" | tr -d ' ')

[[ "$TABLES" -ge 100 ]] || die "建表数异常：${TABLES}（期望 ≥100）"
[[ "$WIDGETS" -ge 700 ]] || die "部件数异常：${WIDGETS}（期望 ≥700）"
[[ "$USERS" == "0" ]] || die "用户数异常：${USERS}（install 不应创建用户）"

ok "install 完成：${TABLES} 张表 / ${WIDGETS} 个部件 / ${BUNDLES} 个 bundle / ${USERS} 个用户"

echo
ok "第 1 步完成"
echo "   下一步：bash docker-02-start.sh --admin-email admin@example.com --admin-pass '你的密码'"
