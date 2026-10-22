#!/usr/bin/env bash
#
# 能源管理平台 · Docker 部署 第 1 步：环境检查 + 建库 + 初始化
#
# 用法（在 energy-deploy 目录内）：
#   bash docker-01-install.sh
#
# .env 已经由 docker-00-prepare.sh 生成，无需手工创建。
# 若 .env 里的 APP_HOME 为空或指向不存在的目录，本脚本会自动改成当前目录。
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
# dev = 只有控制台日志；pro = 生产，日志按天落盘到 ${APP_HOME}/logs/
SPRING_PROFILE=dev
AI_IMAGE=energy/ngxai-backend:4.4.0
TB_API_USERNAME=tenant@thingsboard.org
TB_API_PASSWORD=tenant
ENVEOF
  log "未找到 .env，已自动生成（APP_HOME=$(pwd)，端口 ${_hp}/${_dp}，密码随机）"
fi

# .env 存在但 APP_HOME 不可用时自动修正为当前目录。
# 典型场景：发布包里的 .env 是打包机生成的，APP_HOME 故意留空，
# 解压到任意路径后直接跑本脚本，不该因为路径没改就报“找不到 jar”。
if [[ -f .env ]]; then
  _env_home=$(grep -E '^APP_HOME=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)
  if [[ -z "${_env_home:-}" || ! -f "${_env_home}/guard-server-4.4.0.jar" ]]; then
    if [[ -f "$(pwd)/guard-server-4.4.0.jar" ]]; then
      _abs_home="$(pwd)"
      # 路径里若含 & 或 #，直接传给 sed 会被当成特殊字符，先转义
      _safe_home=$(printf '%s' "$_abs_home" | sed 's/[&#]/\\&/g')
      if grep -qE '^APP_HOME=' .env; then
        # sed -i.bak 同时兼容 macOS 与 GNU sed；.bak 立即删掉
        sed -i.bak "s#^APP_HOME=.*#APP_HOME=${_safe_home}#" .env && rm -f .env.bak
      else
        printf '\nAPP_HOME=%s\n' "$_abs_home" >> .env
      fi
      log "已把 .env 的 APP_HOME 修正为当前目录：${_abs_home}"
    else
      die "当前目录没有 guard-server-4.4.0.jar，无法作为部署目录：$(pwd)"
    fi
  fi

  # 老版本的 .env 没有 MQTT_PORT（那时设备通道是关的）。
  # 现在 RTU 要通过它上报，缺了就补默认值，否则 compose 会拿空值当端口。
  if ! grep -qE '^MQTT_PORT=' .env; then
    printf 'MQTT_PORT=1883\n' >> .env
    log "旧 .env 缺 MQTT_PORT，已补 1883"
  fi

  # 密码为空时补一个随机值，避免 compose 因空密码拒绝启动
  if ! grep -qE '^DB_PASSWORD=.+$' .env; then
    _p=$(openssl rand -hex 12 2>/dev/null || printf '%s%s' "$(date +%s)" "$RANDOM")
    if grep -qE '^DB_PASSWORD=' .env; then
      sed -i.bak "s#^DB_PASSWORD=.*#DB_PASSWORD=${_p}#" .env && rm -f .env.bak
    else
      printf 'DB_PASSWORD=%s\n' "$_p" >> .env
    fi
    log "DB_PASSWORD 为空，已补一个随机密码"
  fi
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

# 端口占用：只检查 HTTP_PORT。
#
# 数据库不需要检查：两种模式下 PostgreSQL 都只在容器网络内可达
# （compose 里没有 ports 映射，只有 expose），宿主机的 5432 被别的
# PostgreSQL 占用完全不影响本平台。早期版本误查 DB_PORT，导致开发用的
# tb-postgres 一开机就报“端口被占用”，实际根本不会冲突。
if port_busy "${HTTP_PORT:-8090}"; then
  die "端口 ${HTTP_PORT:-8090} 已被占用。改 .env 里的 HTTP_PORT 换个端口，或停掉占用它的进程"
fi

# MQTT 端口必须检查：它会映射到宿主机，被 mosquitto 之类占用时容器起不来。
# 老版本 .env 里没有这一项，缺省用 1883。
MQTT_P="${MQTT_PORT:-1883}"
if port_busy "$MQTT_P"; then
  cat <<MSG >&2
  ✗ 端口 $MQTT_P 已被占用 —— 这是 RTU / 网关上报用的 MQTT 端口。

  两个选择：
    1. 换端口：编辑 .env，把 MQTT_PORT 改成别的（如 18830），
       然后所有设备的连接地址也要跟着改。
    2. 停掉占用它的进程：lsof -nP -iTCP:$MQTT_P -sTCP:LISTEN

MSG
  die "MQTT 端口冲突"
fi
ok "docker / compose / 文件 / 端口 检查通过"

# ---------------- 单容器模式：install 在容器内自动完成 ----------------
if [[ "$MODE" == "allinone" ]]; then
  [[ -f "$APP_HOME/allinone/Dockerfile" ]] || die "找不到 $APP_HOME/allinone/Dockerfile"
  [[ -d "$APP_HOME/ngxai-dist" ]] || die "找不到 $APP_HOME/ngxai-dist"
  ok "单容器模式无需单独 install：首次启动时由容器自动建库并初始化"
  cat <<DONE

============================================================
 第 2 步完成：配置检查通过
============================================================

  单容器模式下，建库与初始化由容器在首次启动时自动完成。
  服务尚未启动，现在还不能用浏览器访问。

------------------------------------------------------------
 下一步：复制下面这一整行执行
------------------------------------------------------------

  cd ${APP_HOME} && bash docker-02-start.sh --admin-email admin@example.com --admin-pass 'ChangeMe123!'

  首次启动会构建镜像并跑 install，约 10-20 分钟。

DONE
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
  cat <<DONE

============================================================
 第 2 步已经做过了
============================================================

  数据库 ${DB_NAME:-thingsboard} 已有 ${TABLES} 张表，不用再初始化。

  直接跳到下一步：

    cd ${APP_HOME} && bash docker-02-start.sh --admin-email admin@example.com --admin-pass 'ChangeMe123!'

------------------------------------------------------------
 真的要清空数据重来
------------------------------------------------------------

    cd ${APP_HOME} && bash docker-99-uninstall.sh --purge --yes
  然后从第 1 步重新开始。

DONE
  exit 1
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

cat <<DONE

============================================================
 第 2 步完成：数据库已初始化
============================================================

  表 ${TABLES} 张 / 部件 ${WIDGETS} 个 / bundle ${BUNDLES} 个 / 用户 ${USERS} 个
  用户数为 0 是正常的：install 只建表，不建账号。

  服务尚未启动，现在还不能用浏览器访问。

------------------------------------------------------------
 下一步：复制下面这一整行执行（在哪个目录都行）
------------------------------------------------------------

  cd ${APP_HOME} && bash docker-02-start.sh --admin-email admin@example.com --admin-pass 'ChangeMe123!'

  把邮箱和密码换成你自己要用的（密码至少 8 位）。
  首次会构建 ngx-ai 镜像，约 5-10 分钟；就绪提示约 2 分钟。

DONE
