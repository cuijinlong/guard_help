#!/usr/bin/env bash
#
# 能源管理平台 · 第 0 步：准备部署目录
#
# 本脚本在「有仓库和 jar 的机器」上执行。两种用法：
#
#   A. 就在这台机器上部署（最常见）
#        bash docker-00-prepare.sh
#      → 在 $HOME/energy-app 备好全部文件，并生成 .env（路径与密码已自动填好）
#      → 然后直接 bash ~/energy-app/docker-01-install.sh
#
#   --rebuild-web  强制重建前端产物（默认源码没变就复用）
#
#   B. 要部署到另一台服务器
#        bash docker-00-prepare.sh --pack
#      → 生成 energy-deploy-<日期>.tar.gz，传到服务器解压即可
#
# 指定目录：bash docker-00-prepare.sh /data/energy-app
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DATA_SRC="$ROOT/guard-server/src/main/data"
SQL_SRC="$ROOT/dao/src/main/resources/sql"
# Cassandra 的建表 CQL（可选后端）。install 会从 ${install.data_dir}/cassandra/ 读，
# 少了这个目录、又把 DATABASE_TS_TYPE 改成 cassandra 时，install 直接崩：
#   java.nio.file.NoSuchFileException: /opt/energy/data/cassandra/schema-keyspace.cql
# 实测 2026-10-22：打包漏了这个目录，切 Cassandra 一直失败。
CQL_SRC="$ROOT/dao/src/main/resources/cassandra"
JAR="$ROOT/guard-server/target/guard-server-4.4.0.jar"

TARGET=""
PACK="false"
FORCE="false"
REBUILD_WEB="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack)   PACK="true"; shift ;;
    --force)  FORCE="true"; shift ;;
    --rebuild-web) REBUILD_WEB="true"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*)       die "未知参数：$1" ;;
    *)        TARGET="$1"; shift ;;
  esac
done

TARGET="${TARGET:-$HOME/energy-app}"

# ---------------- 1. 检查源文件 ----------------
log "检查源文件"

[[ -d "$ROOT/guard-server" ]] || die "这个脚本要在仓库里执行（找不到 $ROOT/guard-server）"

if [[ ! -f "$JAR" ]]; then
  warn "找不到 jar：$JAR"
  echo "     先构建：cd $ROOT/guard-server && mvn package -DskipTests"
  exit 1
fi
[[ -d "$DATA_SRC/json/system/widget_types" ]] || die "找不到 $DATA_SRC/json/system/widget_types"
[[ -f "$SQL_SRC/schema-entities.sql" ]] || die "找不到 $SQL_SRC/schema-entities.sql"
SQL_N=$(ls "$SQL_SRC"/*.sql 2>/dev/null | wc -l | tr -d ' ')
[[ "$SQL_N" -ge 8 ]] || die "SQL 文件只有 ${SQL_N} 个，期望 8 个"

ok "jar：$(du -h "$JAR" | cut -f1)"
ok "json：$(du -sh "$DATA_SRC/json" | cut -f1)"
ok "sql：${SQL_N} 个文件"

# 手册与代码一致性：这次组装会把模板/字典拷进部署目录，
# 手册若还写着旧数字，装完验收时会拿错标准。不一致只提醒，不中断。
if [[ -x "$ROOT/shiyongshouce/check-docs.py" ]]; then
  if DOC_OUT="$("$ROOT/shiyongshouce/check-docs.py" 2>&1)"; then
    ok "$(echo "$DOC_OUT" | grep '全部一致' | sed 's/^✓ //')"
  else
    warn "手册与代码不一致（不影响安装，但别照手册的数字验收）："
    echo "$DOC_OUT" | sed -n '/✗/,$p' | sed 's/^/     /'
  fi
fi

# ---------------- 2. 组装目录 ----------------
STAGE="$TARGET"
if [[ "$PACK" == "true" ]]; then
  STAGE="$(mktemp -d)/energy-deploy"
fi

# 已有部署时默认不动它：覆盖 .env 会换掉数据库密码，旧库立刻连不上
if [[ "$PACK" != "true" && -f "$STAGE/.env" && "$FORCE" != "true" ]]; then
  cat <<DONE

============================================================
 第 1 步已经做过了
============================================================

  部署目录已存在，里面已有配置：
    ${STAGE}
    ${STAGE}/.env

  不用再准备一遍。直接跳到下一步：

    cd ${STAGE} && bash docker-01-install.sh

  如果你已经跑过第 2 步（install），那条会提示"库已有 N 张表"并拒绝，
  这也是正常的 —— 直接跳到第 3 步：

    cd ${STAGE} && bash docker-02-start.sh --admin-email admin@example.com --admin-pass 'ChangeMe123!'

------------------------------------------------------------
 真的要推翻重来
------------------------------------------------------------

  先卸载（会删掉数据库数据）：
    cd ${STAGE} && bash docker-99-uninstall.sh --purge --yes
  然后重新跑本脚本。

  只覆盖脚本与 .env、不要旧数据，也可以加 --force：
    bash $0 --force

DONE
  exit 1
fi

log "组装部署目录：$STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/data/sql" "$STAGE/data/cassandra" "$STAGE/logs" "$STAGE/scripts"

cp "$JAR" "$STAGE/guard-server-4.4.0.jar"
cp -R "$DATA_SRC/json" "$STAGE/data/"
# 仓库里 data/sql 是符号链接，必须从 dao 的真实目录拷贝
cp "$SQL_SRC"/*.sql "$STAGE/data/sql/"
# Cassandra 建表脚本（schema-keyspace / schema-ts / schema-ts-latest）。
# 不用 Cassandra 时这几个文件是死重量（<2KB），但漏了就无法启用，宁可带上。
cp "$CQL_SRC"/*.cql "$STAGE/data/cassandra/" 2>/dev/null || true
cp "$HERE/docker-compose.yml"        "$STAGE/"
# 不再拷 env.example 到部署目录：第 3 节会直接生成 .env，
# 目录里只留一个配置文件，避免“到底该改哪个”的困惑。
# env.example 仍保留在下载区，供查阅全部配置项含义。
cp "$HERE/docker-01-install.sh"      "$STAGE/"
cp "$HERE/docker-02-start.sh"        "$STAGE/"
cp "$HERE/docker-99-uninstall.sh"    "$STAGE/"
# 运维脚本全量拷贝 —— 不写死文件名。
# 教训：早先这里是逐个 cp 的清单，新增 08-verify-release.sh 时忘了加，
# 结果「重装一次脚本就没了」，而手册已经让用户去跑它。
# 通配符保证以后新增脚本自动进部署目录，不会再漏。
# 只拷 02 起的运维脚本：01-install.sh 是「不起 Docker、直连数据库」的裸机路径，
# 放进 Docker 部署目录只会让人误以为要跑它。
# 用 0[2-9]-* 加 [1-9][0-9]-* 而不是逐个写文件名，新增脚本自动带上。
# ★ 只写 0[2-9]-* 会漏掉 10 及以后 —— 10-cleanup-customer.sh 就踩过：
#   手册让它跑，但打包根本没拷进部署目录。
#
# ★ 这条规则在 docker-97-preflight.sh 第 3 节有一份镜像（它按同样的通配符比对
#   部署目录）。改这里必须同步改那边，否则自检会误报「缺脚本」——
#   本脚本第一版就踩过：preflight 用 `*` 全比，重装后报「缺 01-install.sh」。
cp "$HERE/../scripts/"0[2-9]-* "$HERE/../scripts/"[1-9][0-9]-* "$STAGE/scripts/" 2>/dev/null \
  || die "scripts/ 下没有 02-* 起的脚本"

# 不带数字前缀的辅助脚本也要拷 —— 上面的通配符只匹配 02-~99- 开头的文件。
# ts-mirror.sh 是验收脚本（04/06/08）的依赖：它把 Cassandra 遥测镜像到 PG。
# 漏拷的后果不是报错，而是验收静默跳过镜像、然后一堆断言误报为 0
# （实测 2026-10-23：重装后 08 报「资产上没有 energy_total」等 3 项）。
for helper in ts-mirror.sh; do
  [[ -f "$HERE/../scripts/$helper" ]] && cp "$HERE/../scripts/$helper" "$STAGE/scripts/"
done

# 自检：脚本数与仓库一致，防止某次改动只加了文件没被拷进来
REPO_SCRIPTS=$(ls "$HERE/../scripts/"0[2-9]-* "$HERE/../scripts/"[1-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
STAGE_SCRIPTS=$(ls "$STAGE/scripts/"0[2-9]-* "$STAGE/scripts/"[1-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
[[ "$REPO_SCRIPTS" -eq "$STAGE_SCRIPTS" ]] \
  || die "脚本拷贝不全：仓库 ${REPO_SCRIPTS} 个，部署目录 ${STAGE_SCRIPTS} 个"
# 客户基础数据的空白模板：客户拿这三张表填，再交给导入脚本
mkdir -p "$STAGE/templates"
cp "$HERE/../templates/"*.csv "$STAGE/templates/" 2>/dev/null || true

# 网关配置（生产专用，仓库里的开发配置一律不动）
mkdir -p "$STAGE/nginx"
cp "$HERE/nginx/energy.conf" "$STAGE/nginx/"

# 单容器模式所需的构建文件
mkdir -p "$STAGE/allinone"
cp "$HERE/allinone/Dockerfile"        "$STAGE/allinone/"
cp "$HERE/allinone/supervisord.conf"  "$STAGE/allinone/"
cp "$HERE/allinone/entrypoint.sh"     "$STAGE/allinone/"
chmod +x "$STAGE/allinone/entrypoint.sh"

chmod +x "$STAGE"/docker-*.sh "$STAGE"/scripts/*.sh

# 单容器构建上下文 = 部署目录。必须排除 .env（含密码）与运行时产物，
# 否则密码会被烤进镜像层，卸载重装也删不掉。
cat > "$STAGE/.dockerignore" <<'IGNEOF'
# 运行时与敏感文件，绝不能进镜像
.env
logs/
scripts/
docker-*.sh
.dockerignore
IGNEOF

# ---------------- 2b. ngx-ai（前端产物 + 后端源码） ----------------
# 不能跳过：compose 的 gateway 依赖 ngxai-backend，缺目录会让 up 直接失败。
# 反复重装时真正省时间的是复用前端产物 —— vite build 要 1 分钟，
# 源码没动就没必要重跑。--rebuild-web 可强制重建。
AI_ROOT="$ROOT/ngx-ai"
if [[ -d "$AI_ROOT/backend" && -d "$AI_ROOT/frontend" ]]; then
  log "打包 ngx-ai"

  # 后端源码：排除宿主虚拟环境与数据，Linux 容器里不能用 macOS 的 .venv
  mkdir -p "$STAGE/ngxai-backend"
  ( cd "$AI_ROOT/backend" && tar -cf - \
      --exclude='.venv' --exclude='__pycache__' --exclude='*.pyc' \
      --exclude='.pytest_cache' --exclude='data' --exclude='.env' \
      --exclude='.DS_Store' . ) | ( cd "$STAGE/ngxai-backend" && tar -xf - )
  cp "$HERE/ngxai/Dockerfile.backend" "$STAGE/ngxai-backend/Dockerfile.prod"
  ok "后端源码：$(du -sh "$STAGE/ngxai-backend" | cut -f1)"

  # 前端构建产物：base 用 /ngxai/，由 nginx 直接托管，不跑 node 容器
  NEED_BUILD="true"
  if [[ "$REBUILD_WEB" != "true" && -f "$AI_ROOT/frontend/dist/index.html" ]]; then
    # 产物必须是 /ngxai/ 前缀，且不比源码旧，才可复用
    if grep -q '/ngxai/assets/' "$AI_ROOT/frontend/dist/index.html" \
       && [[ -z "$(find "$AI_ROOT/frontend/src" "$AI_ROOT/frontend/index.html" \
                    "$AI_ROOT/frontend/vite.config.ts" \
                    -newer "$AI_ROOT/frontend/dist/index.html" 2>/dev/null | head -1)" ]]; then
      NEED_BUILD="false"
    fi
  fi

  if [[ "$NEED_BUILD" == "true" ]]; then
    log "构建前端（base=/ngxai/，约 1 分钟）"
    if [[ -d "$AI_ROOT/frontend/node_modules" ]]; then
      ( cd "$AI_ROOT/frontend" && VITE_BASE=/ngxai/ npx vite build >/tmp/ngxai-build.log 2>&1 ) \
        || { tail -20 /tmp/ngxai-build.log; die "前端构建失败"; }
    else
      docker run --rm -v "$AI_ROOT/frontend:/app" -w /app -e VITE_BASE=/ngxai/ \
        node:22-slim sh -c 'corepack enable >/dev/null 2>&1; pnpm install --frozen-lockfile && pnpm exec vite build' \
        >/tmp/ngxai-build.log 2>&1 \
        || { tail -20 /tmp/ngxai-build.log; die "前端构建失败（容器方式）"; }
    fi
  else
    ok "前端产物未过期，复用（--rebuild-web 可强制重建）"
  fi

  rm -rf "$STAGE/ngxai-dist"
  cp -R "$AI_ROOT/frontend/dist" "$STAGE/ngxai-dist"
  grep -q '/ngxai/assets/' "$STAGE/ngxai-dist/index.html" \
    || die "前端产物路径不对：index.html 里没有 /ngxai/assets/"
  ok "前端产物：$(du -sh "$STAGE/ngxai-dist" | cut -f1)（base=/ngxai/）"
else
  die "找不到 ngx-ai 源码（$AI_ROOT/backend 或 frontend），无法打包完整部署包"
fi

# ---------------- 3. 生成 .env ----------------
# 两种模式都生成 .env，用户不需要再 cp env.example：
#   本机模式：APP_HOME 直接写实际目录，端口探测可用值
#   打包模式：目标机路径未知，APP_HOME 留空，由 docker-01-install.sh
#              在解压后的目录里自动填入（脚本里有自愈逻辑）
gen_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
  else
    # 没有 openssl 时的纯 shell 兜底，拼到 24 位十六进制样式
    printf '%s%s%s' "$(date +%s)" "$$" "$RANDOM$RANDOM" | shasum | cut -c1-24
  fi
}
DB_PASS=$(gen_pass)

if [[ "$PACK" == "true" ]]; then
  # 目标机器路径与端口都未知，用默认值；APP_HOME 留空待解压后自愈
  ENV_APP_HOME=""
  ENV_HTTP_PORT=8090
  ENV_DB_PORT=5432
  ENV_MQTT_PORT=1883
  ENV_MQTT_RTU_PORT=11883
else
  # 端口占用时自动顺延，省得用户手工排查
  port_free() {
    if command -v lsof >/dev/null 2>&1; then
      ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
      ! (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1
    fi
  }
  HTTP_PORT=8090
  while ! port_free "$HTTP_PORT" && [[ "$HTTP_PORT" -lt 8200 ]]; do HTTP_PORT=$((HTTP_PORT+1)); done
  DB_PORT=5432
  while ! port_free "$DB_PORT" && [[ "$DB_PORT" -lt 5600 ]]; do DB_PORT=$((DB_PORT+1)); done
  # MQTT 是 RTU / 网关的接入口，被 mosquitto 之类占用时顺延，别让部署失败
  MQTT_PORT=1883
  while ! port_free "$MQTT_PORT" && [[ "$MQTT_PORT" -lt 1983 ]]; do MQTT_PORT=$((MQTT_PORT+1)); done
  # RTU 别名端口：现场固件把 11883 写死在代码里（HaaS506-ED1）。
  # 平台多映射一个端口，换机器 / 重装 / 换客户都不用重烧固件。
  # 与主端口相同时跳过（否则 compose 会报端口重复）。
  MQTT_RTU_PORT=11883
  while ! port_free "$MQTT_RTU_PORT" && [[ "$MQTT_RTU_PORT" -lt 12000 ]]; do
    MQTT_RTU_PORT=$((MQTT_RTU_PORT+1))
  done
  [[ "$MQTT_RTU_PORT" == "$MQTT_PORT" ]] && MQTT_RTU_PORT=""
  ENV_APP_HOME="$STAGE"
  ENV_HTTP_PORT=$HTTP_PORT
  ENV_DB_PORT=$DB_PORT
  ENV_MQTT_PORT=$MQTT_PORT
  ENV_MQTT_RTU_PORT=$MQTT_RTU_PORT
fi

# 遥测后端：按宿主机物理内存自动选（详见下面 .env 注释）。
# ★ 必须在 heredoc **之前**求值：heredoc 里写 `VAR=$(...)` 只是往文件里写字面量，
#   而 `$DATABASE_TS_TYPE` 会被立即展开 —— set -u 下未定义就直接退出（实测）。
HOST_MEM_GB=$( (sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/{printf "%.0f\n", $2*1024}' /proc/meminfo 2>/dev/null || echo 0) | awk '{printf "%.0f", $1/1073741824}' )
if [[ -n "${DATABASE_TS_TYPE:-}" ]]; then
  DATABASE_TS_TYPE="$DATABASE_TS_TYPE"
elif [[ "${HOST_MEM_GB:-0}" -ge 10 ]]; then
  DATABASE_TS_TYPE="cassandra"
else
  DATABASE_TS_TYPE="sql"
fi
DATABASE_TS_LATEST_TYPE="${DATABASE_TS_LATEST_TYPE:-sql}"

cat > "$STAGE/.env" <<ENVEOF
# 由 docker-00-prepare.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 改端口或密码就改这个文件；改完删掉容器重跑 docker-01-install.sh。
#
# APP_HOME 留空时，docker-01-install.sh 会自动填成脚本所在目录：
# 同一个包解压到任何路径都能直接跑，不必手工改路径。
DEPLOY_MODE=${DEPLOY_MODE:-split}
APP_HOME=$ENV_APP_HOME
HTTP_PORT=$ENV_HTTP_PORT
DB_NAME=thingsboard
DB_USER=postgres
DB_PASSWORD=$DB_PASS
DB_PORT=$ENV_DB_PORT
# 设备侧 MQTT 端口：RTU / 物联网网关连这个端口上报数据
MQTT_PORT=$ENV_MQTT_PORT
# RTU 现场固件写死的端口（11883），平台额外监听；留空表示不映射
MQTT_RTU_PORT=$ENV_MQTT_RTU_PORT
SERVER_HEAP=2g
SERVER_HEAP_MB=2048
# dev = 只有控制台日志；pro = 生产，日志按天落盘到 \${APP_HOME}/logs/
SPRING_PROFILE=dev
AI_IMAGE=energy/ngxai-backend:4.4.0
ALLINONE_IMAGE=energy/allinone:4.4.0
TB_API_USERNAME=tenant@thingsboard.org
TB_API_PASSWORD=tenant
# 遥测存储后端：sql（遥测与实体同存 Postgres）| cassandra（独立时序库，需 ~2GB 常驻）
# 改这个值不迁移存量数据；空库部署随便切。详见手册「Cassandra」一节。
#
# ★ 默认值按**宿主机物理内存**自动选（2026-10-25 实测教训）：
#   8GB 机器上 Cassandra 堆 2G + 页缓存 + 其它三个容器会把 Docker VM 挤爆，
#   Cassandra 被反复杀 → commitlog 写到一半 → 下次启动报
#   "Could not read commit log descriptor" 并无限重启，平台整体 502。
#   而这种损坏**不会自己好**，只能清 commitlog 才恢复
#   （scripts/12-cassandra-recover.sh）。
#
#   数据量在千万行 / 20GB 以内时，Postgres 存遥测完全够用，所以：
#     物理内存 < 10GB  → 默认 sql（少一个容器、少 2GB 常驻、少一整类故障）
#     物理内存 ≥ 10GB  → 默认 cassandra（高写入吞吐更好）
#   要强制指定就显式导出 DATABASE_TS_TYPE=cassandra|sql 再跑本脚本。
DATABASE_TS_TYPE=$DATABASE_TS_TYPE
# 最新值后端：建议留 sql（查询快、与实体同库）
DATABASE_TS_LATEST_TYPE=$DATABASE_TS_LATEST_TYPE
ENVEOF

ok "遥测后端：${DATABASE_TS_TYPE}（宿主机内存 ${HOST_MEM_GB:-?}GB；可用 DATABASE_TS_TYPE 环境变量覆盖）"

if [[ "$PACK" == "true" ]]; then
  ok "已生成 .env（随包分发；APP_HOME 解压后自动填入，密码随机）"
else
  ok "已生成 .env（APP_HOME 已填好，端口检测后取 ${ENV_HTTP_PORT}/${ENV_DB_PORT}/${ENV_MQTT_PORT}，密码随机生成）"
fi

# ---------------- 4. 输出 ----------------
# 输出规则：只说三件事 —— 东西在哪、密码是什么、下一条命令是什么。
# 不要再罗列目录、不要再给多个选项，用户只需要照着敲。
if [[ "$PACK" != "true" ]]; then
  cat <<DONE

============================================================
 第 1 步完成：部署文件已准备好
============================================================

  部署目录
    ${STAGE}
    （脚本默认装到 ~/energy-app，不是当前目录）

  配置文件
    ${STAGE}/.env
    （隐藏文件，ls 看不到；要看内容用：cat ${STAGE}/.env）

  数据库密码
    ${DB_PASS}
    ⚠ 现在就记到密码管理器，重装时还要用

------------------------------------------------------------
 下一步：复制下面这一整行执行
------------------------------------------------------------

  cd ${STAGE} && bash docker-01-install.sh

  预期输出最后一行：✓ 第 1 步完成
  （注意：这里的"第 1 步"是安装脚本自己的计数，
    与你正在走的"准备→安装→启动"编号无关）

DONE
  exit 0
fi

if [[ "$PACK" == "true" ]]; then
  OUT="$ROOT/dist"
  mkdir -p "$OUT"
  TAR="$OUT/energy-deploy-$(date +%Y%m%d).tar.gz"
  tar -czf "$TAR" -C "$(dirname "$STAGE")" energy-deploy
  cat <<DONE

============================================================
 打包完成
============================================================

  发布包
    ${TAR}
    （$(du -h "$TAR" | cut -f1)）

  数据库密码（已写进包内 .env）
    ${DB_PASS}
    ⚠ 现在就记到密码管理器

------------------------------------------------------------
 下一步 A：在你自己的电脑上执行
------------------------------------------------------------

  scp ${TAR} root@1.2.3.4:/opt/

  把 root@1.2.3.4 换成 你的用户名@你的服务器IP

------------------------------------------------------------
 下一步 B：登录服务器后执行
------------------------------------------------------------

  ssh root@1.2.3.4
  cd /opt && tar -xzf $(basename "$TAR") && cd energy-deploy
  bash docker-01-install.sh

  .env 已在包里，APP_HOME 会自动填成解压目录，不用手改。

------------------------------------------------------------
 没有服务器、只是本机试用？
------------------------------------------------------------

  不要加 --pack，直接重跑：
    bash $HERE/docker-00-prepare.sh

DONE
  exit 0
fi
