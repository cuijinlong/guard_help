#!/usr/bin/env bash
#
# 能源管理平台 · Cassandra（可选遥测存储）管理
#
# 默认部署**使用** Cassandra 存遥测（DATABASE_TS_TYPE=cassandra）。
# 想省内存的小规模部署可改成 sql（本脚本 disable 子命令）：
# 遥测与实体同存 Postgres，少一个容器、少 2GB 内存。
#
# 用法：
#   bash scripts/11-cassandra.sh status      # 看现状（容器 / keyspace / 表 / 当前后端）
#   bash scripts/11-cassandra.sh init        # 建 keyspace 与表（幂等，可反复跑）
#   bash scripts/11-cassandra.sh enable      # 一键切到 Cassandra（起容器 + init + 改配置 + 重启）
#   bash scripts/11-cassandra.sh disable     # 切回 Postgres（保留 Cassandra 数据，不删）
#   bash scripts/11-cassandra.sh shell       # 进入 cqlsh 交互
#   bash scripts/11-cassandra.sh uninstall   # 删容器 + 删数据卷（**不可恢复**）
#
# ═══════════════ 为什么需要 init 这一步 ═══════════════
# 这是本项目实测踩到的坑（2026-10-22）：
#
#   把 DATABASE_TS_TYPE 改成 cassandra 直接重启 → 启动失败：
#     InvalidKeyspaceException: Invalid keyspace thingsboard
#
#   原因：TB 建 keyspace 与 ts_kv_cf 表的那两个服务
#         （CassandraKeyspaceService / CassandraTsDatabaseSchemaService）
#         都标了 @Profile("install") —— **只在 install 建库阶段跑**。
#         server 启动阶段不建、也不自动补，keyspace 不存在就直接报错退出。
#
#   正确做法是**用 TB 原生的 install 流程**建，不要自己写 CQL：
#     docker compose --profile install run --rm install
#   它会执行 dao/src/main/resources/cassandra/ 下的三份 CQL
#     schema-keyspace.cql / schema-ts.cql / schema-ts-latest.cql
#   —— 和 TB 官方完全一致，升级 TB 版本时这些 CQL 会跟着更新。
#
#   ★ 前置条件：这三个 CQL 必须已经在部署目录的 data/cassandra/ 下。
#     早先 docker-00-prepare.sh 只拷 data/json 与 data/sql，漏了 data/cassandra，
#     导致 install 直接崩：NoSuchFileException: .../data/cassandra/schema-keyspace.cql
#     现已修（2026-10-22）。若你的部署目录没有这个子目录，重跑一次 prepare 即可。
#
#   ★ install 在非空库上会在「重建系统数据」阶段报重复键
#     （tenant_profile_name_unq_key / Admin settings with such name already exists）。
#     那是**正常现象**：Cassandra 部分在它之前就已建完。
#     所以判断成败看「keyspace 与 2 张表是否存在」，不看 install 退出码。
#
# ═══════════════ 切换不会迁移存量数据 ═══════════════
# Postgres 里已有的 ts_kv 数据留在原地，切过去之后历史查不到（新数据才写
# Cassandra）。保留历史有三种做法：
#   1) 不迁移，历史留在 Postgres（推荐：数据不丢，只是查询走不通）
#   2) 切换前自己导出报表/CSV
#   3) 自己写迁移脚本（TB 的 migrator 未在本项目验证过）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."

COMPOSE="docker compose"
CASS_PROFILE="--profile cassandra"
CASS_CONTAINER="${CASS_CONTAINER:-energy-cassandra}"
ENV_FILE=".env"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "缺少 .env。先跑 bash docker-01-install.sh"

# 读 .env（不污染当前环境，只取需要的键）
env_get() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed 's/^["'\'']//; s/["'\'']$//'
}

KEYSPACE="$(env_get CASSANDRA_KEYSPACE_NAME)"
KEYSPACE="${KEYSPACE:-thingsboard}"
TS_TYPE="$(env_get DATABASE_TS_TYPE)"
TS_TYPE="${TS_TYPE:-cassandra}"

# ---------------------------------------------------------------- 容器探测
cass_running() {
  docker ps --format '{{.Names}}' | grep -qx "$CASS_CONTAINER"
}

cass_healthy() {
  local st
  st=$(docker inspect --format '{{.State.Health.Status}}' "$CASS_CONTAINER" 2>/dev/null || echo missing)
  [[ "$st" == "healthy" ]]
}

# ---------------------------------------------------------------- CQL 执行
# 用 cqlsh 跑一段 CQL。注意 macOS 下的引号嵌套：统一走 stdin。
cql() {
  docker exec -i "$CASS_CONTAINER" cqlsh 2>/dev/null
}

# ---------------------------------------------------------------- 等待就绪
wait_healthy() {
  local max="${1:-60}" i
  log "等待 Cassandra 就绪（首次启动 2~5 分钟属正常）"
  for ((i = 1; i <= max; i++)); do
    if cass_healthy; then
      ok "Cassandra 已就绪（$((i * 10))s）"
      return 0
    fi
    if ((i % 6 == 0)); then
      printf '  仍在启动… %ss\n' "$((i * 10))"
    fi
    sleep 10
  done
  warn "等待超时。看日志：docker compose logs --tail=50 cassandra"
  return 1
}

# ================================================================ status
cmd_status() {
  log "Cassandra 状态"

  echo "  当前遥测后端   DATABASE_TS_TYPE=${TS_TYPE}"
  echo "  最新值后端     DATABASE_TS_LATEST_TYPE=$(env_get DATABASE_TS_LATEST_TYPE || echo sql)"
  echo "  keyspace       ${KEYSPACE}"
  echo

  if ! cass_running; then
    if [[ "$TS_TYPE" == "cassandra" ]]; then
      warn "容器 ${CASS_CONTAINER} 未运行，但 DATABASE_TS_TYPE=cassandra —— 服务连不上会启动失败"
      echo "  启动：bash scripts/11-cassandra.sh enable"
    else
      warn "容器 ${CASS_CONTAINER} 未运行（当前遥测后端为 sql，属正常）"
      echo "  启用：bash scripts/11-cassandra.sh enable"
    fi
    return 0
  fi

  docker ps --filter "name=${CASS_CONTAINER}" --format '  容器    {{.Names}}  {{.Status}}' || true

  if ! cass_healthy; then
    warn "容器在跑但未 healthy，跳过 keyspace 检查"
    return 1
  fi

  echo
  echo "  keyspace 是否存在："
  local ks
  ks=$(docker exec -i "$CASS_CONTAINER" cqlsh -e "DESCRIBE KEYSPACES;" 2>/dev/null \
        | tr -d '"' | tr -s ' ' '\n' | grep -x "$KEYSPACE" || true)
  if [[ -n "$ks" ]]; then
    ok "  ${KEYSPACE} 存在"
    echo
    echo "  表："
    docker exec -i "$CASS_CONTAINER" cqlsh -e "DESCRIBE TABLES;" 2>/dev/null \
      | sed 's/^/    /' | head -10
  else
    warn "  ${KEYSPACE} 不存在 —— 切到 cassandra 前必须先跑 init"
    echo "    bash scripts/11-cassandra.sh init"
  fi

  echo
  echo "  集群："
  docker exec -i "$CASS_CONTAINER" nodetool status 2>/dev/null | sed 's/^/    /' | head -8
}

# ================================================================ init
# 用 TB 原生 install 流程建 keyspace 与表 —— 不自创 CQL
cass_schema_ready() {
  local tabs
  tabs=$(docker exec -i "$CASS_CONTAINER" cqlsh -e "DESCRIBE KEYSPACES;" 2>/dev/null \
          | tr -d '"' | tr -s ' ' '\n')
  echo "$tabs" | grep -qx "$KEYSPACE" || return 1

  tabs=$(docker exec -i "$CASS_CONTAINER" cqlsh -e \
    "SELECT table_name FROM system_schema.tables WHERE keyspace_name='${KEYSPACE}';" 2>/dev/null \
    | tr -d '"' | tr -s ' ' '\n')
  echo "$tabs" | grep -qx "ts_kv_cf" || return 1
  echo "$tabs" | grep -qx "ts_kv_partitions_cf" || return 1
  return 0
}

cmd_init() {
  cass_running || die "Cassandra 未运行。先起容器：
    docker compose --profile cassandra up -d cassandra"
  cass_healthy || wait_healthy || die "Cassandra 未就绪，稍后重试"

  if cass_schema_ready; then
    ok "Cassandra schema 已就绪（keyspace ${KEYSPACE} + 2 张表），无需重建"
    return 0
  fi

  # CQL 文件必须在 data/cassandra 下，否则 install 会崩
  if [[ ! -f "data/cassandra/schema-keyspace.cql" ]]; then
    die "缺少 data/cassandra/schema-keyspace.cql
    install 需要它来建 keyspace。修复：
      cd <仓库根> && bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --force
    或手工补：cp dao/src/main/resources/cassandra/*.cql ./data/cassandra/"
  fi

  log "用 TB 原生 install 流程建 Cassandra schema（执行 data/cassandra/*.cql）"

  # 临时把 TS 后端指到 cassandra，让 install 走 Cassandra 分支；
  # 用环境变量覆盖，不改 .env（避免中途失败留下半套配置）。
  local out rc=0
  out=$(DATABASE_TS_TYPE=cassandra \
        $COMPOSE $CASS_PROFILE --profile split --profile install run --rm \
          -e DATABASE_TS_TYPE=cassandra install 2>&1) || rc=$?

  # 非空库上 install 会在「重建系统数据」阶段报重复键 —— 那是正常的，
  # Cassandra 部分在它之前已经建完。所以只按 schema 判断成败。
  if echo "$out" | grep -q "Installing Cassandra DataBase schema part: schema-keyspace.cql"; then
    ok "已执行 schema-keyspace.cql"
  fi
  if echo "$out" | grep -q "Installing Cassandra DataBase schema part: schema-ts.cql"; then
    ok "已执行 schema-ts.cql"
  fi

  if cass_schema_ready; then
    ok "keyspace ${KEYSPACE} 与 2 张表已就绪（TB 原生 CQL）"
    if [[ "$rc" != "0" ]]; then
      echo
      warn "install 整体退出码 ${rc}（非空库上会报 tenant_profile/admin_settings 重复键）"
      echo "    Cassandra schema 已建成，这个报错可以忽略。"
      echo "    它发生在 Cassandra 建表**之后**，只影响系统默认数据重建。"
    fi
    return 0
  fi

  echo
  warn "Cassandra schema 仍未就绪。install 输出末尾："
  echo "$out" | grep -iE "ERROR|Exception|Caused by|NoSuchFile" | tail -8 | sed 's/^/    /'
  return 1
}

# ================================================================ enable
cmd_enable() {
  log "切换到 Cassandra（遥测存 Cassandra，实体仍在 Postgres）"

  # 提醒存量数据
  local pg_pts=""
  if docker compose --profile split ps --format '{{.Name}}' 2>/dev/null | grep -qx energy-postgres; then
    pg_pts=$(docker exec -i energy-postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" \
      -tAc "SELECT count(*) FROM ts_kv;" 2>/dev/null | tr -d ' ' || true)
  fi
  if [[ -n "$pg_pts" && "$pg_pts" != "0" ]]; then
    warn "Postgres 里已有 ${pg_pts} 个遥测点 —— **不会迁移到 Cassandra**"
    echo "    切换后这些历史数据在界面里查不到（数据本身没删，仍可用 SQL 查）。"
    echo "    如需保留历史，先导出再切换；或接受「历史留在 Postgres」这个现状。"
    echo
  fi

  # 1. 起容器
  if cass_running; then
    ok "Cassandra 容器已在运行"
  else
    log "启动 Cassandra 容器"
    $COMPOSE $CASS_PROFILE up -d cassandra 2>&1 | tail -2
  fi
  wait_healthy || die "Cassandra 没起来，先解决容器问题再试"

  # 2. 建 keyspace 与表
  cmd_init

  # 3. 改配置
  log "写入 .env"
  if grep -q '^DATABASE_TS_TYPE=' "$ENV_FILE"; then
    sed -i.bak "s|^DATABASE_TS_TYPE=.*|DATABASE_TS_TYPE=cassandra|" "$ENV_FILE"
  else
    printf '\n# 遥测存储后端：cassandra（默认）| sql\nDATABASE_TS_TYPE=cassandra\n' >> "$ENV_FILE"
  fi
  if grep -q '^DATABASE_TS_LATEST_TYPE=' "$ENV_FILE"; then
    sed -i.bak "s|^DATABASE_TS_LATEST_TYPE=.*|DATABASE_TS_LATEST_TYPE=${DATABASE_TS_LATEST_TYPE:-sql}|" "$ENV_FILE"
  else
    printf 'DATABASE_TS_LATEST_TYPE=%s\n' "${DATABASE_TS_LATEST_TYPE:-sql}" >> "$ENV_FILE"
  fi
  rm -f "${ENV_FILE}.bak"
  ok "DATABASE_TS_TYPE=cassandra"

  # 4. 重启 server（改环境变量必须 force-recreate，restart 不生效）
  log "重建 energy-server（改环境变量必须重建容器）"
  $COMPOSE $CASS_PROFILE --profile split up -d --force-recreate energy-server 2>&1 | tail -2

  # 5. 等健康
  log "等待服务健康（约 2~3 分钟）"
  local i st
  for ((i = 1; i <= 40; i++)); do
    st=$(docker inspect --format '{{.State.Health.Status}}' energy-server 2>/dev/null || echo unknown)
    [[ "$st" == "healthy" ]] && break
    [[ "$st" == "unhealthy" ]] && break
    sleep 5
  done

  if [[ "$st" == "healthy" ]]; then
    ok "服务已切到 Cassandra 并健康"
    echo
    echo "  验证：docker compose exec cassandra cqlsh -e \"SELECT count(*) FROM ${KEYSPACE}.ts_kv_cf;\""
    echo "  回退：bash scripts/11-cassandra.sh disable"
  else
    warn "服务未就绪（当前 ${st}）。看日志找原因："
    echo "    docker compose logs --tail=80 energy-server | grep -iE 'cassandra|keyspace|ERROR'"
    echo
    echo "  回退到 Postgres：bash scripts/11-cassandra.sh disable"
    return 1
  fi
}

# ================================================================ disable
cmd_disable() {
  log "切回 Postgres（Cassandra 数据保留，不删）"

  # 先把验收用的 ts_kv 镜像视图删掉。
  #
  # 不删的后果：切回 sql 后 TB 要建真表 ts_kv，而 PG 里已经有一个同名**视图**
  # （由 scripts/ts-mirror.sh 建的），install 会报 relation already exists。
  if [[ -f scripts/ts-mirror.sh ]]; then
    bash scripts/ts-mirror.sh --clean >/dev/null 2>&1 || true
    ok "已清理验收镜像（ts_kv 视图 / ts_kv_mirror 表）"
  fi

  if grep -q '^DATABASE_TS_TYPE=' "$ENV_FILE"; then
    sed -i.bak "s|^DATABASE_TS_TYPE=.*|DATABASE_TS_TYPE=sql|" "$ENV_FILE"
  else
    printf '\nDATABASE_TS_TYPE=sql\n' >> "$ENV_FILE"
  fi
  rm -f "${ENV_FILE}.bak"
  ok "DATABASE_TS_TYPE=sql"

  log "重建 energy-server"
  $COMPOSE --profile split up -d --force-recreate energy-server 2>&1 | tail -2

  local i st
  for ((i = 1; i <= 40; i++)); do
    st=$(docker inspect --format '{{.State.Health.Status}}' energy-server 2>/dev/null || echo unknown)
    [[ "$st" == "healthy" ]] && break
    sleep 5
  done
  [[ "$st" == "healthy" ]] && ok "已切回 Postgres 并健康" || warn "服务未就绪（${st}），看日志"

  echo
  echo "  Cassandra 容器与数据仍在（不影响运行）。"
  echo "  彻底删除：bash scripts/11-cassandra.sh uninstall"
}

# ================================================================ shell
cmd_shell() {
  cass_running || die "Cassandra 未运行"
  exec docker exec -it "$CASS_CONTAINER" cqlsh
}

# ================================================================ uninstall
cmd_uninstall() {
  [[ "$TS_TYPE" == "cassandra" ]] && die "当前正在用 Cassandra（DATABASE_TS_TYPE=cassandra）。
    先切回 Postgres：bash scripts/11-cassandra.sh disable"

  echo "============================================================"
  printf '\033[33m  即将删除 Cassandra 容器与数据卷\033[0m\n'
  echo "============================================================"
  echo "  容器      ${CASS_CONTAINER}"
  echo "  数据卷    energy-cassandra-data"
  echo "  当前后端  ${TS_TYPE}（不是 cassandra，可以安全删）"
  echo
  printf '\033[33m  数据卷删除后不可恢复。\033[0m\n'
  echo

  if [[ "${1:-}" != "--yes" ]]; then
    printf '输入 yes 确认：'
    read -r a
    [[ "$a" == "yes" ]] || { warn "已取消"; return 0; }
  fi

  $COMPOSE $CASS_PROFILE rm -sf cassandra 2>&1 | tail -2 || true
  docker volume rm energy-cassandra-data 2>/dev/null && ok "数据卷已删除" || warn "数据卷不存在或仍被占用"

  # 从 .env 摘掉 cassandra 相关键（保留其余）
  ok "Cassandra 已卸载（.env 中的 CASSANDRA_* 变量保留，无害）"
}

# ================================================================ main
case "${1:-status}" in
  status)    cmd_status ;;
  init)      cmd_init ;;
  enable)    cmd_enable ;;
  disable)   cmd_disable ;;
  shell)     cmd_shell ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  -h|--help) sed -n '2,40p' "$0" ;;
  *)         die "未知参数：$1（用 --help 看用法）" ;;
esac
