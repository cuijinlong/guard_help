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

[[ -f .env ]] || die "缺少 .env。先执行：cp env.example .env && vi .env"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${APP_HOME:?请在 .env 设置 APP_HOME（部署目录绝对路径）}"
: "${DB_PASSWORD:?请在 .env 设置 DB_PASSWORD}"
[[ "$APP_HOME" = /* ]] || die "APP_HOME 必须是绝对路径，当前：$APP_HOME"
[[ -f "$APP_HOME/guard-server-4.4.0.jar" ]] || die "找不到 $APP_HOME/guard-server-4.4.0.jar"
[[ -f "$APP_HOME/data/sql/schema-entities.sql" ]] || die "找不到 $APP_HOME/data/sql/schema-entities.sql —— data/sql 必须有 8 个 sql 文件"
[[ -d "$APP_HOME/data/json/system/widget_types" ]] || die "找不到 $APP_HOME/data/json/system/widget_types"

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

# ---------------- 2. 启动数据库 ----------------
log "启动 PostgreSQL（首次会拉取镜像，约 1 分钟）"
$COMPOSE up -d postgres

for i in $(seq 1 40); do
  sleep 3
  s=$(docker inspect --format '{{.State.Health.Status}}' energy-postgres 2>/dev/null || echo none)
  if [[ "$s" == "healthy" ]]; then ok "数据库健康（$((i*3))s）"; break; fi
  if [[ "$i" == "40" ]]; then
    $COMPOSE logs postgres | tail -20
    die "数据库 120 秒内未就绪"
  fi
done

# ---------------- 3. 防止重复 install ----------------
TABLES=$($COMPOSE exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d ' ')
if [[ -n "$TABLES" && "$TABLES" != "0" ]]; then
  warn "库 ${DB_NAME:-thingsboard} 已有 ${TABLES} 张表"
  die "拒绝重复初始化。要重新来过请先执行：bash docker-99-uninstall.sh --purge --yes，再从本步开始"
fi

# ---------------- 4. 执行 install ----------------
log "执行 install（建表 + 装载系统资源，约 1-3 分钟）"
set +e
$COMPOSE --profile install run --rm install > /tmp/energy-install.log 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  warn "install 退出码 ${RC}，日志尾部："
  tail -30 /tmp/energy-install.log
  die "install 失败（完整日志：/tmp/energy-install.log）"
fi

TABLES=$($COMPOSE exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" | tr -d ' ')
WIDGETS=$($COMPOSE exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from widget_type" | tr -d ' ')
BUNDLES=$($COMPOSE exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from widgets_bundle" | tr -d ' ')
USERS=$($COMPOSE exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from tb_user" | tr -d ' ')

[[ "$TABLES" -ge 100 ]] || die "建表数异常：${TABLES}（期望 ≥100）"
[[ "$WIDGETS" -ge 700 ]] || die "部件数异常：${WIDGETS}（期望 ≥700）"
[[ "$USERS" == "0" ]] || die "用户数异常：${USERS}（install 不应创建用户）"

ok "install 完成：${TABLES} 张表 / ${WIDGETS} 个部件 / ${BUNDLES} 个 bundle / ${USERS} 个用户"

echo
ok "第 1 步完成"
echo "   下一步：bash docker-02-start.sh --admin-email admin@example.com --admin-pass '你的密码'"
