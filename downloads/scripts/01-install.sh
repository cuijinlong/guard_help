#!/usr/bin/env bash
#
# 能源管理平台 · 一键初始化（空库 → 可登录）
#
# 用法：
#   ./01-install.sh --db-container tb-postgres --db-name thingsboard \
#                   --data-dir /opt/energy/data \
#                   --jar /opt/energy/guard-server-4.4.0.jar \
#                   --admin-email admin@example.com \
#                   --admin-pass 'ChangeMe123!'
#
# 数据库不在 Docker 里、本机有 psql 时，改用：
#   ./01-install.sh --db-host 127.0.0.1 --db-port 5432 \
#                   --db-user postgres --db-pass postgres ...
#
# 必须分两次跑：先 --skip-setup 做 install（此时服务还没启动），
# 启动服务后再用 --skip-install 创建管理员。
#
# 做三件事（严格按顺序，每一步都校验）：
#   1. 建库（不存在才建）
#   2. 跑 install：建 112 张表 + 装载 726 个系统部件 / 34 个 bundle / 默认菜单
#   3. 启动服务并用 /api/noauth/setup/complete 创建系统管理员
#
# 为什么必须分三步：
#   install 只建 schema 与系统级资源，**不创建任何用户**。
#   系统管理员由 setup/complete 接口创建，而该接口只在「库里没有 SYS_ADMIN」时接受请求
#   —— 这是防止匿名调用者接管已开通实例的保护。所以必须先 install、再启动、最后 setup。
#
set -euo pipefail

DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_USER="postgres"
DB_PASS="postgres"
DB_NAME="thingsboard"
DB_CONTAINER=""
DATA_DIR=""
JAR=""
ADMIN_EMAIL=""
ADMIN_PASS=""
HTTP_PORT="8090"
SKIP_INSTALL="false"
SKIP_SETUP="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-host)     DB_HOST="$2"; shift 2 ;;
    --db-port)     DB_PORT="$2"; shift 2 ;;
    --db-user)     DB_USER="$2"; shift 2 ;;
    --db-pass)     DB_PASS="$2"; shift 2 ;;
    --db-name)     DB_NAME="$2"; shift 2 ;;
    # 本机没装 psql 时用：--db-container tb-postgres（容器里执行 psql）
    --db-container) DB_CONTAINER="$2"; shift 2 ;;
    --data-dir)    DATA_DIR="$2"; shift 2 ;;
    --jar)         JAR="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-pass)  ADMIN_PASS="$2"; shift 2 ;;
    --http-port)   HTTP_PORT="$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL="true"; shift ;;
    --skip-setup)   SKIP_SETUP="true"; shift ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$DATA_DIR" ]] || die "必须指定 --data-dir（含 sql/ 与 json/ 的目录）"
[[ -d "$DATA_DIR" ]] || die "data-dir 不存在：$DATA_DIR"
[[ -f "$DATA_DIR/sql/schema-entities.sql" ]] || die "缺少 $DATA_DIR/sql/schema-entities.sql —— 请把 downloads/sql 下的文件放进去"
[[ -d "$DATA_DIR/json/system/widget_types" ]] || die "缺少 $DATA_DIR/json/system/widget_types"

export PGPASSWORD="$DB_PASS"
if [[ -n "$DB_CONTAINER" ]]; then
  command -v docker >/dev/null 2>&1 || die "指定了 --db-container 但找不到 docker 命令"
  PSQL() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }
else
  command -v psql >/dev/null 2>&1 || die "本机没有 psql。用 --db-container <容器名>（如 tb-postgres）改在容器里执行"
  PSQL() { psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$@"; }
fi

# ---------------- 1. 建库 ----------------
log "检查数据库 $DB_NAME"
if PSQL -lqt | cut -d'|' -f1 | grep -qw "$DB_NAME"; then
  TABLES=$(PSQL -d "$DB_NAME" -tAc "select count(*) from information_schema.tables where table_schema='public'")
  if [[ "$TABLES" != "0" ]]; then
    warn "库 $DB_NAME 已有 $TABLES 张表，跳过建库"
    if [[ "$SKIP_INSTALL" != "true" ]]; then
      die "库非空。要重新初始化请先 DROP DATABASE ${DB_NAME}；确需在已有库上补跑 install 请加 --skip-install=false 并自行确认"
    fi
  fi
else
  PSQL -c "CREATE DATABASE \"$DB_NAME\"" >/dev/null
  ok "已创建数据库 $DB_NAME"
fi

# ---------------- 2. install ----------------
if [[ "$SKIP_INSTALL" != "true" ]]; then
  [[ -f "$JAR" ]] || die "找不到 jar：$JAR"
  log "执行 install（建表 + 装载系统资源，约 2-3 分钟）"
  set +e
  SPRING_DATASOURCE_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME" \
  SPRING_DATASOURCE_USERNAME="$DB_USER" \
  SPRING_DATASOURCE_PASSWORD="$DB_PASS" \
  java -Xms128m -Xmx768m \
    -Dloader.main=com.guard.server.ThingsboardInstallApplication \
    -Dinstall.upgrade=false \
    -Dinstall.data_dir="$DATA_DIR" \
    -cp "$JAR" \
    org.springframework.boot.loader.launch.PropertiesLauncher \
    --spring.config.name=thingsboard --server.port=0 \
    >/tmp/tb-install.log 2>&1
  RC=$?
  set -e

  if [[ $RC -ne 0 ]]; then
    warn "install 退出码 ${RC}，检查日志 /tmp/tb-install.log"
    grep -E "ERROR|Caused by" /tmp/tb-install.log | tail -8
    die "install 失败"
  fi

  TABLES=$(PSQL -d "$DB_NAME" -tAc "select count(*) from information_schema.tables where table_schema='public'")
  WIDGETS=$(PSQL -d "$DB_NAME" -tAc "select count(*) from widget_type")
  BUNDLES=$(PSQL -d "$DB_NAME" -tAc "select count(*) from widgets_bundle")
  [[ "$TABLES" -ge 100 ]] || die "建表数异常：${TABLES}（期望 ≥100）"
  [[ "$WIDGETS" -ge 700 ]] || die "部件数异常：${WIDGETS}（期望 ≥700）"
  ok "install 完成：$TABLES 张表 / $WIDGETS 个部件 / $BUNDLES 个 bundle"
else
  ok "按要求跳过 install"
fi

# ---------------- 3. 启动 + 创建管理员 ----------------
if [[ "$SKIP_SETUP" != "true" ]]; then
  [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" ]] || die "创建管理员需要 --admin-email 与 --admin-pass"

  STATE=$(curl -s --noproxy '*' -m 5 "http://127.0.0.1:$HTTP_PORT/api/noauth/setup/state" 2>/dev/null || true)
  if [[ -z "$STATE" ]]; then
    log "服务未在 $HTTP_PORT 监听，请先在另一个终端启动："
    echo "    bash run.sh"
    echo "  然后重跑本脚本并加 --skip-install --skip-setup=false"
    echo "  当前状态：库已就绪，等待启动服务后创建管理员 $ADMIN_EMAIL"
    exit 0
  fi

  echo "$STATE" | grep -q "ACCOUNT_REQUIRED" || {
    ok "系统已有管理员，跳过创建（state=${STATE}）"
    exit 0
  }

  log "创建系统管理员 $ADMIN_EMAIL"
  RESP=$(curl -s --noproxy '*' -m 60 -o /tmp/tb-setup.json -w '%{http_code}' \
    -X POST "http://127.0.0.1:$HTTP_PORT/api/noauth/setup/complete" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"loadDemo\":false}")
  [[ "$RESP" == "200" ]] || { cat /tmp/tb-setup.json; die "创建管理员失败（HTTP ${RESP}）"; }

  TOKEN=$(curl -s --noproxy '*' -m 20 -X POST "http://127.0.0.1:$HTTP_PORT/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [[ -n "$TOKEN" ]] || die "管理员创建成功但登录失败"
  ok "系统管理员可登录"
fi

echo
ok "初始化完成"
echo "   登录地址：http://127.0.0.1:$HTTP_PORT/"
echo "   管理员：  $ADMIN_EMAIL"
echo "   下一步：  建租户与客户，见手册「开租户与开客户」"
