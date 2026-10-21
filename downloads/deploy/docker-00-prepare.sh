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
mkdir -p "$STAGE/data/sql" "$STAGE/logs" "$STAGE/scripts"

cp "$JAR" "$STAGE/guard-server-4.4.0.jar"
cp -R "$DATA_SRC/json" "$STAGE/data/"
# 仓库里 data/sql 是符号链接，必须从 dao 的真实目录拷贝
cp "$SQL_SRC"/*.sql "$STAGE/data/sql/"
cp "$HERE/docker-compose.yml"        "$STAGE/"
# 不再拷 env.example 到部署目录：第 3 节会直接生成 .env，
# 目录里只留一个配置文件，避免“到底该改哪个”的困惑。
# env.example 仍保留在下载区，供查阅全部配置项含义。
cp "$HERE/docker-01-install.sh"      "$STAGE/"
cp "$HERE/docker-02-start.sh"        "$STAGE/"
cp "$HERE/docker-99-uninstall.sh"    "$STAGE/"
cp "$HERE/../scripts/02-onboard.sh"      "$STAGE/scripts/"
cp "$HERE/../scripts/03-verify.sh"       "$STAGE/scripts/"
cp "$HERE/../scripts/04-verify-data.sh"  "$STAGE/scripts/"
cp "$HERE/../scripts/06-verify-e2e.sh"    "$STAGE/scripts/"
cp "$HERE/../scripts/05-import-customer-data.py" "$STAGE/scripts/"
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
  ENV_APP_HOME="$STAGE"
  ENV_HTTP_PORT=$HTTP_PORT
  ENV_DB_PORT=$DB_PORT
  ENV_MQTT_PORT=$MQTT_PORT
fi

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
SERVER_HEAP=2g
SERVER_HEAP_MB=2048
SPRING_PROFILE=dev
AI_IMAGE=energy/ngxai-backend:4.4.0
ALLINONE_IMAGE=energy/allinone:4.4.0
TB_API_USERNAME=tenant@thingsboard.org
TB_API_PASSWORD=tenant
ENVEOF

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
