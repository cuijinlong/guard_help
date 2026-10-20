#!/usr/bin/env bash
#
# 单容器入口：先让 PostgreSQL 就绪，再把 Java / Python / Nginx 交给 supervisord。
#
# 为什么 PostgreSQL 不交给 supervisord：
#   Java 启动时要立刻连库，连不上会反复重试刷日志。这里先 initdb + 启动 +
#   等 pg_isready 通过，再拉起其余进程，启动过程干净。
#
set -euo pipefail

PGDATA=/var/lib/energy/pgdata
LOGDIR=/var/lib/energy/logs
RUNDIR=/var/lib/energy/run

DB_NAME="${DB_NAME:-thingsboard}"
DB_USER="${DB_USER:-postgres}"
# 未显式设置时用固定值，仅用于单容器内部；对外端口只有 80，数据库不暴露
DB_PASSWORD="${DB_PASSWORD:-energy_local_only}"
SERVER_HEAP_MB="${SERVER_HEAP_MB:-2048}"
SPRING_PROFILE="${SPRING_PROFILE:-dev}"
TB_API_USERNAME="${TB_API_USERNAME:-tenant@thingsboard.org}"
TB_API_PASSWORD="${TB_API_PASSWORD:-tenant}"

export DB_NAME DB_USER DB_PASSWORD SERVER_HEAP_MB SPRING_PROFILE TB_API_USERNAME TB_API_PASSWORD
export PGPASSWORD="$DB_PASSWORD"

# install 步骤直接用 java 调安装入口，不经过 supervisord，
# 所以数据源必须在这里显式导出。漏了会用 thingsboard.yml 的默认值
# （postgres/postgres），表现为 "password authentication failed"。
export SPRING_DATASOURCE_URL="jdbc:postgresql://127.0.0.1:5432/$DB_NAME"
export SPRING_DATASOURCE_USERNAME="$DB_USER"
export SPRING_DATASOURCE_PASSWORD="$DB_PASSWORD"
export DATABASE_TS_TYPE=sql
export DATABASE_ENTITIES_TYPE=sql
export HTTP_ENABLED=false MQTT_ENABLED=false COAP_ENABLED=false LWM2M_ENABLED=false COAP_SERVER_ENABLED=false
export TB_QUEUE_TYPE=in-memory

mkdir -p "$LOGDIR" "$RUNDIR" /app/data
# pg_ctl -l 指定的日志文件由 postgres 身份创建，目录必须可写。
# 命名卷首次挂载时权限来自镜像层，但卷已存在时 entrypoint 的 mkdir 归 root，
# 所以这里每次都显式 chown 一次。
chown -R postgres:postgres "$PGDATA" "$RUNDIR" "$LOGDIR"

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------- 1. initdb
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  log "首次启动：初始化 PostgreSQL 数据目录"
  # Debian 的 pg 集群目录默认在 /var/lib/postgresql，这里改用挂载卷
  su postgres -c "/usr/lib/postgresql/16/bin/initdb -D $PGDATA -E UTF8 --locale=C.UTF-8" \
      >"$LOGDIR/initdb.log" 2>&1
  # 只监听本机；容器内其他进程通过 127.0.0.1 访问
  {
    echo "listen_addresses = '127.0.0.1'"
    echo "port = 5432"
    echo "max_connections = 200"
    echo "shared_buffers = 256MB"
  } >> "$PGDATA/postgresql.conf"
  # 本机密码认证（scram）
  cat > "$PGDATA/pg_hba.conf" <<'EOF'
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
EOF
fi

# ---------------------------------------------------------------- 2. 启动 PG
log "启动 PostgreSQL"
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $PGDATA -l $LOGDIR/postgres.log -w start" \
    || { tail -30 "$LOGDIR/postgres.log"; exit 1; }

# ---------------------------------------------------------------- 3. 建库建角色
# initdb 建的是超级用户 postgres；若 DB_USER 不同则补建
if [[ "$DB_USER" != "postgres" ]]; then
  su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" | grep -q 1 \
    || su postgres -c "psql -c \"CREATE ROLE \\\"$DB_USER\\\" LOGIN PASSWORD '$DB_PASSWORD'\""
fi
# 给 postgres 用户设密码（TCP 连接要用）
su postgres -c "psql -c \"ALTER ROLE postgres PASSWORD '$DB_PASSWORD'\"" >/dev/null

if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"" | grep -q 1; then
  log "创建数据库 $DB_NAME"
  su postgres -c "createdb -O \"$DB_USER\" \"$DB_NAME\""
fi

log "PostgreSQL 就绪（库：${DB_NAME}）"

# ---------------------------------------------------------------- 4. install（首次）
# 库里没有表时先跑 install。用 java 直接调用 install 入口，跑完退出。
TABLES=$(su postgres -c "psql -d $DB_NAME -tAc \"select count(*) from information_schema.tables where table_schema='public'\"" | tr -d ' ')
if [[ "${TABLES:-0}" -eq 0 ]]; then
  log "数据库为空，执行 install（建表 + 装载系统资源，约 1-3 分钟）"
  if ! /opt/java/openjdk/bin/java \
        -Xms128m -Xmx768m \
        -Dloader.main=com.guard.server.ThingsboardInstallApplication \
        -Dinstall.upgrade=false \
        -Dinstall.data_dir=/opt/energy/data \
        -cp /opt/energy/guard-server-4.4.0.jar \
        org.springframework.boot.loader.launch.PropertiesLauncher \
        --spring.config.name=thingsboard --server.port=0 \
        >"$LOGDIR/install.log" 2>&1; then
    echo "✗ install 失败，日志末尾：" >&2
    tail -30 "$LOGDIR/install.log" >&2
    exit 1
  fi
  TABLES=$(su postgres -c "psql -d $DB_NAME -tAc \"select count(*) from information_schema.tables where table_schema='public'\"" | tr -d ' ')
  log "install 完成：${TABLES} 张表"
else
  log "数据库已有 ${TABLES} 张表，跳过 install"
fi

# ---------------------------------------------------------------- 5. 交给 supervisord
log "启动 Java / ngx-ai / Nginx"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
