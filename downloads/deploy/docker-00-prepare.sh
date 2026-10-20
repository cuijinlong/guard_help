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
SKIP_AI="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack)   PACK="true"; shift ;;
    --force)  FORCE="true"; shift ;;
    --skip-ai) SKIP_AI="true"; shift ;;
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
  warn "目录 $STAGE 已存在且已初始化过（有 .env）"
  echo "     要重新准备（会覆盖脚本与 .env，换掉数据库密码）请加 --force"
  echo "     只想升级 jar/脚本、保留数据库，请用：bash docker-99-uninstall.sh 后重来，或手工替换 jar"
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
cp "$HERE/env.example"               "$STAGE/"
cp "$HERE/docker-01-install.sh"      "$STAGE/"
cp "$HERE/docker-02-start.sh"        "$STAGE/"
cp "$HERE/docker-99-uninstall.sh"    "$STAGE/"
cp "$HERE/../scripts/02-onboard.sh"  "$STAGE/scripts/"
cp "$HERE/../scripts/03-verify.sh"   "$STAGE/scripts/"

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
env.example
.dockerignore
IGNEOF

# ---------------- 2b. ngx-ai（前端产物 + 后端源码） ----------------
if [[ "$SKIP_AI" != "true" ]]; then
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
    rm -rf "$STAGE/ngxai-dist"
    cp -R "$AI_ROOT/frontend/dist" "$STAGE/ngxai-dist"
    grep -q '/ngxai/assets/' "$STAGE/ngxai-dist/index.html" \
      || die "前端产物路径不对：index.html 里没有 /ngxai/assets/"
    ok "前端产物：$(du -sh "$STAGE/ngxai-dist" | cut -f1)（base=/ngxai/）"
  else
    [[ "$SKIP_AI" == "true" ]] && die "已指定 --skip-ai，但 compose 仍引用 ngxai-backend；请使用默认的完整打包"
    die "找不到 ngx-ai 源码（$AI_ROOT/backend 或 frontend），无法打包完整部署包"
  fi
fi

# ---------------- 3. 生成 .env ----------------
# APP_HOME 自动填成实际目录，避免手改路径出错；DB_PASSWORD 自动生成随机密码。
if [[ "$PACK" != "true" ]]; then
  gen_pass() {
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 12
    else
      # 没有 openssl 时的纯 shell 兜底，拼到 24 位十六进制样式
      printf '%s%s%s' "$(date +%s)" "$$" "$RANDOM$RANDOM" | shasum | cut -c1-24
    fi
  }
  DB_PASS=$(gen_pass)
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

  cat > "$STAGE/.env" <<ENVEOF
# 由 docker-00-prepare.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 想改端口或密码，直接改这个文件。
DEPLOY_MODE=${DEPLOY_MODE:-split}
APP_HOME=$STAGE
HTTP_PORT=$HTTP_PORT
DB_NAME=thingsboard
DB_USER=postgres
DB_PASSWORD=$DB_PASS
DB_PORT=$DB_PORT
SERVER_HEAP=2g
SERVER_HEAP_MB=2048
SPRING_PROFILE=dev
AI_IMAGE=energy/ngxai-backend:4.4.0
ALLINONE_IMAGE=energy/allinone:4.4.0
TB_API_USERNAME=tenant@thingsboard.org
TB_API_PASSWORD=tenant
ENVEOF
  ok "已生成 .env（APP_HOME 已填好，端口检测后取 ${HTTP_PORT}/${DB_PORT}，密码随机生成）"
fi

# ---------------- 4. 输出 ----------------
echo
if [[ "$PACK" == "true" ]]; then
  OUT="$ROOT/dist"
  mkdir -p "$OUT"
  TAR="$OUT/energy-deploy-$(date +%Y%m%d).tar.gz"
  tar -czf "$TAR" -C "$(dirname "$STAGE")" energy-deploy
  ok "发布包：${TAR}（$(du -h "$TAR" | cut -f1)）"
  echo
  echo "下一步：把包传到服务器。下面的 root@1.2.3.4 换成 你的用户名@你的服务器IP。"
  echo
  echo "  ── 在你自己的电脑上执行 ──"
  echo "    scp $TAR root@1.2.3.4:/opt/"
  echo
  echo "  ── 登录服务器后执行 ──"
  echo "    ssh root@1.2.3.4"
  echo "    cd /opt && tar -xzf $(basename "$TAR") && cd energy-deploy"
  echo "    bash docker-01-install.sh    # 会自动生成 .env，无需手工配置"
  echo
  echo "  没有服务器、只是本机试用：不用 --pack，直接"
  echo "    bash $HERE/docker-00-prepare.sh"
else
  ok "部署目录已就绪：$STAGE"
  echo "   内容："
  ls -1 "$STAGE" | sed 's/^/      /'
  echo
  echo "   数据库密码（已写入 .env）：${DB_PASS}"
  echo "   ⚠ 请把这行密码记到你的密码管理器，卸载重装时需要。"
  echo
  echo "   下一步（复制这一条就行）："
  echo "      cd $STAGE && bash docker-01-install.sh"
fi
