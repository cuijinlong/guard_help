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

# ===== Docker 环境自检：macOS / CentOS 7 / Ubuntu 通用 =====
#
# 为什么不用一句 `docker info || die`（2026-11-03 实测）：
#   1) docker info 可能**挂住**而不是报错 —— macOS 上 Docker Desktop 的宿主侧
#      socket 转发卡死时整整 3 分钟不返回，脚本看起来像卡住了，用户只能 ^C，
#      既看不到原因也看不到解法。
#   2) 新机器上 daemon 多数只是**没启动**。Linux 一条 systemctl start、macOS
#      一次 open -a Docker 就能救，不该直接退出让用户去猜。
#   3) 三个系统的修复命令完全不同。原来那句「守护进程未运行 + usermod」一刀切，
#      macOS 用户会照着敲一条根本不存在的命令（本次故障就是这么误判的）。
#
# 流程：超时探测 → 尝试自动拉起 → 等 120s 复测 → 仍失败按平台分类报错。
# ⚠ docker-02-start.sh 里有同一套逻辑的精简版，改这里请同步那边。

case "$(uname -s)" in
  Darwin) DEPLOY_OS="macos" ;;
  Linux)
    DEPLOY_OS="linux"
    # CentOS 7 / RHEL / Rocky 走 yum 分支（7 没有 dnf），Ubuntu/Debian 走 apt
    if [[ -r /etc/os-release ]] && grep -qiE '^ID="?(centos|rhel|rocky|almalinux)' /etc/os-release; then
      DEPLOY_OS="rhel"
    fi
    ;;
  *) DEPLOY_OS="unknown" ;;
esac

# 带超时执行。macOS 自带的 bash 是 3.2 且没有 timeout/coreutils，
# 所以 GNU timeout 不在时用「后台进程 + 整数秒轮询」兜底。
#
# ⚠ 坑（2026-11-03 实测，必须这么写）：
#   第一版写成 `out="$(_run_tmo 10 docker info)"`，结果 daemon 卡死时
#   脚本仍然挂了 111 秒而不是 10 秒。原因：超时后只 kill 了 docker 进程，
#   但它拉起的子进程（实测 docker CLI 会 fork）还攥着命令替换那根管道
#   的写端，`$(...)` 就一直等到那孩子自己退出 —— 超时形同虚设。
#   解法：超时判定与输出采集分开。用临时文件当结果承载，超时就
#   pkill -P 把整棵子树收掉，外层不靠管道等子进程。
_run_tmo() {
  local secs="$1" tf="$2"; shift 2
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" >"$tf" 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@" >"$tf" 2>&1
  else
    : >"$tf"
    "$@" >"$tf" 2>&1 &
    local pid=$! rc=0 i=0
    while kill -0 "$pid" 2>/dev/null; do
      if (( i >= secs )); then
        # 先收子孙再收本体，避免子进程攥着管道/文件继续跑
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        pkill -KILL -P "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
        # 2>/dev/null：bash 作业控制会把「Terminated: 15」打到终端，
        # 用户看到会以为脚本出错了（超时本就是我们预期的分支）。
        wait "$pid" 2>/dev/null || true
        return 124
      fi
      i=$((i + 1))
      sleep 1
    done
    wait "$pid" 2>/dev/null || rc=$?
    return $rc
  fi
}

# 探测结果 → _DOCKER_STATE：ok / denied / hang / down
#   denied = socket 权限不够（docker info 立刻报错，不是挂住）
#   hang   = 进程还在但不应答（超时；本次 macOS 故障形态）
#   down   = daemon 没启动
_docker_probe() {
  local tf rc out
  # 不用 mktemp -t：GNU coreutils 把它标为 deprecated，会往 stderr 喷警告，
  # 用户看到会以为脚本出错。显式模板两个平台都标准。
  tf="$(mktemp "${TMPDIR:-/tmp}/dockerprobe.XXXXXX")" || { _DOCKER_STATE="down"; return 1; }
  # 外层 2>/dev/null 只用来压 bash 的作业控制通知（“Terminated: 15”）；
  # docker 自己的输出在函数内已重定向进 $tf，不会丢。
  _run_tmo 10 "$tf" docker info 2>/dev/null; rc=$?
  if [[ $rc -eq 0 ]]; then rm -f "$tf"; _DOCKER_STATE="ok"; return 0; fi
  if [[ $rc -eq 124 ]]; then rm -f "$tf"; _DOCKER_STATE="hang"; return 1; fi
  out="$(cat "$tf" 2>/dev/null || true)"; rm -f "$tf"
  case "$out" in
    *"permission denied"*|*"Permission denied"*) _DOCKER_STATE="denied" ;;
    *) _DOCKER_STATE="down" ;;
  esac
  return 1
}

_docker_sock_path() {
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    printf '%s' "$DOCKER_HOST"
  elif [[ "$DEPLOY_OS" == "macos" ]]; then
    printf '%s' "$HOME/.docker/run/docker.sock"
  else
    printf '%s' "/var/run/docker.sock"
  fi
}

# 返回 0 = 已发起启动（调用方负责等待）；1 = 没法自动拉起
_docker_try_start() {
  case "$DEPLOY_OS" in
    macos)
      # 进程还在就不重复 open：卡死时 open 只会把窗口调到前台，救不了
      pgrep -f "com\.docker\.backend" >/dev/null 2>&1 && return 1
      command -v open >/dev/null 2>&1 || return 1
      log "Docker Desktop 未运行，正在启动（首次 30-60 秒）…"
      open -a Docker >/dev/null 2>&1 || return 1
      return 0
      ;;
    rhel|linux)
      command -v systemctl >/dev/null 2>&1 || return 1
      log "Docker 守护进程未运行，尝试启动…"
      if [[ "$(id -u)" == "0" ]]; then
        systemctl start docker >/dev/null 2>&1 && return 0
        return 1
      fi
      # 先试免密 sudo（无人值守场景）；_run_tmo 避免 sudo 在没终端时死等密码
      _stf="$(mktemp "${TMPDIR:-/tmp}/sudostart.XXXXXX")" || _stf="/dev/null"
      if _run_tmo 15 "$_stf" sudo -n systemctl start docker 2>/dev/null; then
        rm -f "$_stf"
        return 0
      fi
      rm -f "$_stf"
      # 没免密但有真终端：让用户敲一次密码，总比重跑脚本强
      # （在无人值守/cron 下 [[ -t 0 ]] 为假，直接走报错提示）
      if [[ -t 0 ]]; then
        warn "需要 sudo 权限，请输入密码（或回车跳过）…"
        if sudo systemctl start docker; then return 0; fi
      fi
      return 1
      ;;
  esac
  return 1
}

# 用 SECONDS 计墙钟：_docker_probe 自己最多花 10 秒，
# 按「轮次」计会拖成十几分钟（踩过）
_wait_docker() {
  local limit="$1" start=$SECONDS
  while (( SECONDS - start < limit )); do
    _docker_probe && return 0
    sleep 2
  done
  return 1
}

command -v docker >/dev/null 2>&1 || die "未安装 docker
  macOS  ：装 Docker Desktop —— https://docs.docker.com/desktop/install/mac-install/
  CentOS 7 / RHEL：
    sudo yum install -y yum-utils
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  Ubuntu / Debian：见手册《① 安装环境》第一节"

_DOCKER_STATE="down"
_docker_probe || {
  if [[ "$_DOCKER_STATE" == "down" ]] && _docker_try_start; then
    _wait_docker 120 || true
  fi
}

if [[ "$_DOCKER_STATE" != "ok" ]]; then
  _sock="$(_docker_sock_path)"
  if [[ "$_sock" == unix://* ]]; then _sock="${_sock#unix://}"; fi
  case "$_DOCKER_STATE" in
    hang)
      printf '\n  \033[31m✗ Docker 有进程在，但 daemon 不响应（socket 在、命令超时）\033[0m\n\n' >&2
      if [[ "$DEPLOY_OS" == "macos" ]]; then
        cat >&2 <<'MSG'
    这是 Docker Desktop 的已知故障：宿主侧的 socket 转发卡住，
    VM 里的 dockerd 其实是好的，但界面和 CLI 全都点不动。

    修复：
      osascript -e 'quit app "Docker"'    # 等 30 秒；没退出就执行下一行
      pkill -f com.docker.backend
      open -a Docker

    起来后 docker info 应在 1-2 秒内返回。
    仍不行：菜单栏鲸鱼图标 → Troubleshoot → Restart

MSG
      else
        cat >&2 <<'MSG'
    修复：
      sudo systemctl restart docker
      sudo journalctl -u docker -n 50 --no-pager    # 看它为什么卡

MSG
      fi
      die "Docker 无响应，按上面的命令处理后重跑本脚本"
      ;;
    denied)
      if [[ "$DEPLOY_OS" == "macos" ]]; then
        die "当前用户无权访问 Docker
  确认 Docker Desktop 已启动；若 context 不对：docker context use desktop-linux"
      fi
      die "当前用户无权访问 Docker（daemon 在跑，socket 权限不够）
  sudo usermod -aG docker \$USER && newgrp docker
  newgrp 只对新 shell 生效，重开终端更省事"
      ;;
    *)
      printf '\n  \033[31m✗ Docker 守护进程没有运行\033[0m\n\n' >&2
      if [[ "$DEPLOY_OS" == "macos" ]]; then
        cat >&2 <<'MSG'
    open -a Docker
    等菜单栏鲸鱼图标停止转动（首次 30-60 秒），再重跑本脚本。

MSG
      elif [[ "$DEPLOY_OS" == "rhel" || "$DEPLOY_OS" == "linux" ]]; then
        cat >&2 <<'MSG'
    sudo systemctl start docker
    sudo systemctl enable docker     # 开机自启，避免下次重启又遇到

MSG
        # 不在 docker 组时，daemon 起来了照样报权限错
        if [[ "$(id -u)" != "0" ]] && ! id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
          cat >&2 <<'MSG'
    另外：当前用户不在 docker 组，daemon 起来后仍会报权限错误
    sudo usermod -aG docker $USER && newgrp docker

MSG
        fi
      fi
      die "Docker 不可用，按上面的命令处理后重跑本脚本"
      ;;
  esac
fi

$COMPOSE version >/dev/null 2>&1 || die "未安装 docker compose v2（要 'docker compose' 插件，不是旧的 docker-compose 命令）
  macOS  ：Docker Desktop 自带；缺了说明装的是旧版 Desktop
  CentOS 7 / RHEL：sudo yum install -y docker-compose-plugin
  Ubuntu / Debian：sudo apt-get install -y docker-compose-plugin"

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

# ---------------- 2b. 遥测后端（Cassandra 默认） ----------------
#
# Cassandra 放在独立的 "cassandra" profile 下（不在 split 里），
# 所以必须在这里显式带 profile 拉起，不能指望 up postgres 顺带。
#
# 顺序要求：**必须等 Cassandra healthy 才跑 install**。
# TB 建 keyspace 的服务（CassandraKeyspaceService）带 @Profile("install")，
# 只在 install 阶段跑；连不上或 keyspace 不存在就直接：
#     InvalidKeyspaceException: Invalid keyspace thingsboard
# 实测 2026-10-22。首次启动 2~5 分钟，慢是正常的。
TS_TYPE="${DATABASE_TS_TYPE:-sql}"
if [[ "$MODE" == "split" && "$TS_TYPE" == "cassandra" ]]; then
  log "遥测后端：Cassandra（启动容器，首次 2~5 分钟）"
  $COMPOSE $PROFILE_ARGS --profile cassandra up -d cassandra

  CASS_OK="false"
  for i in $(seq 1 60); do
    sleep 5
    s=$(docker inspect --format '{{.State.Health.Status}}' energy-cassandra 2>/dev/null || echo none)
    if [[ "$s" == "healthy" ]]; then CASS_OK="true"; ok "Cassandra 健康（$((i*5))s）"; break; fi
    if (( i % 6 == 0 )); then echo "    仍在启动… $((i*5))s（首次建系统表，耐心）"; fi
  done
  if [[ "$CASS_OK" != "true" ]]; then
    $COMPOSE --profile cassandra logs --tail=40 cassandra
    die "Cassandra 300 秒内未就绪。看上面日志，或调大 CASSANDRA_HEAP"
  fi
else
  log "遥测后端：${TS_TYPE}（不需要 Cassandra 容器）"
fi

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
log "执行 install（建表 + 装载系统资源，约 1-3 分钟；含 Cassandra schema）"
set +e
# cassandra 情形下必须带 --profile cassandra，否则 install 容器的 depends_on
# 看不到 cassandra 服务（虽然本脚本已提前把它起来，但 compose 仍需 profile 解析）
COMPOSE_INSTALL_ARGS="$PROFILE_ARGS"
if [[ "$MODE" == "split" && "${DATABASE_TS_TYPE:-sql}" == "cassandra" ]]; then
  COMPOSE_INSTALL_ARGS="$PROFILE_ARGS --profile cassandra"
fi
$COMPOSE --profile install $COMPOSE_INSTALL_ARGS run --rm install > /tmp/energy-install.log 2>&1
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
