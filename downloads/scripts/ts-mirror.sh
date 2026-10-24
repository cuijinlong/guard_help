#!/usr/bin/env bash
#
# 把 Cassandra 里的遥测镜像到 Postgres，供验收脚本直查。
#
# ═══════════════ 为什么需要它 ═══════════════
#
# 验收脚本（03/04/06/08）里写了大量直查 SQL，例如：
#
#   SELECT d.name, k.key, t.ts, t.dbl_v
#     FROM ts_kv t
#     JOIN key_dictionary k ON k.key_id = t.key
#     JOIN device d ON d.id = t.entity_id
#
# 这些 SQL 是按「遥测存 Postgres」写的。默认后端换成 Cassandra 之后，
# PG 里**根本没有 ts_kv 表**，于是：
#   · 04 的 devs 列表从遥测派生 → 空 → 所有「单相电表 ≥ 1 台」全部报 0
#   · 08 报「资产上没有 energy_total」「idle_exceed 时序点 0」
# 看起来像产品坏了，其实只是验收工具看错了库。
#
# 本脚本把 Cassandra 的 ts_kv_cf 导出成 CSV，导入 PG 的 ts_kv_mirror，
# 再建一个**同名视图 ts_kv** —— 验收 SQL 一行都不用改。
#
# ⚠ 这是**只读镜像**，不是 TB 的真表：
#      · 只用于验收与排查，写它不会影响 TB（TB 只读写 Cassandra）
#      · 切换回 sql 后端前要先 DROP VIEW ts_kv（否则 install 建真表会撞名）
#
# ═══════════════ 用法 ═══════════════
#
#   bash scripts/ts-mirror.sh          # 需要时导出（默认）
#   bash scripts/ts-mirror.sh --force  # 强制重新导出
#   bash scripts/ts-mirror.sh --clean  # 删掉镜像表与视图（切回 sql 之前跑）
#
# 遥测后端是 sql 时，本脚本什么也不做（PG 本来就有真表）。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f .env ]] || die "缺少 .env（请在部署目录执行）"

FORCE="false"
CLEAN="false"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE="true" ;;
    --clean) CLEAN="true" ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "未知参数：$arg" ;;
  esac
done

env_get() { sed -n "s/^$1=//p" .env | tail -1 | sed 's/^["'\'']//; s/["'\'']$//'; }

TS_TYPE="$(env_get DATABASE_TS_TYPE)"; TS_TYPE="${TS_TYPE:-cassandra}"
DB_NAME="$(env_get DB_NAME)";         DB_NAME="${DB_NAME:-thingsboard}"
DB_USER="$(env_get DB_USER)";         DB_USER="${DB_USER:-postgres}"
KEYSPACE="$(env_get CASSANDRA_KEYSPACE_NAME)"; KEYSPACE="${KEYSPACE:-thingsboard}"

PSQL="docker compose --profile split exec -T postgres psql -U $DB_USER -d $DB_NAME -X -q"

# ---------------------------------------------------------------- clean
if [[ "$CLEAN" == "true" ]]; then
  log "删除镜像视图与镜像表"
  $PSQL <<'SQL' || true
DROP VIEW IF EXISTS ts_kv;
DROP TABLE IF EXISTS ts_kv_mirror;
SQL
  ok "已清理镜像视图、镜像表与索引（切回 sql 后端前必须先跑这一步）"
  exit 0
fi

if [[ "$TS_TYPE" != "cassandra" ]]; then
  log "遥测后端为 ${TS_TYPE}：Postgres 有真表 ts_kv，无需镜像"
  exit 0
fi

# Cassandra 容器必须在线
docker ps --format '{{.Names}}' | grep -qx "energy-cassandra" \
  || die "energy-cassandra 未运行。先 bash scripts/11-cassandra.sh enable"

log "从 Cassandra 导出遥测（${KEYSPACE}.ts_kv_cf）"
docker exec energy-cassandra cqlsh -e \
  "COPY ${KEYSPACE}.ts_kv_cf TO '/tmp/ts_kv_cf.csv' WITH HEADER = TRUE;" 2>&1 \
  | tail -1 | sed 's/^/    /'
docker cp energy-cassandra:/tmp/ts_kv_cf.csv /tmp/energy-ts-mirror.csv >/dev/null

ROWS=$(($(wc -l < /tmp/energy-ts-mirror.csv) - 1))
if [[ "$ROWS" -le 0 ]]; then
  warn "Cassandra 里没有遥测行（演示数据可能还没生成）"
fi

log "导入 Postgres 镜像表（${ROWS} 行）"
docker cp /tmp/energy-ts-mirror.csv energy-postgres:/tmp/energy-ts-mirror.csv >/dev/null

# json_v 用 text 而不是 jsonb：Cassandra 的 COPY TO 用 \" 转义双引号，
# 而 PostgreSQL 的 COPY FROM CSV 只认 "" —— 两套转义不同，含引号的 JSON
# （如规则链调试输出 {"ruleNodeId":"..."}）会被读成字面 \"，jsonb 直接拒收。
# COPY 是原子的：一行失败整批 0 行，镜像静默变成空表，后面所有数据类验收都失效
# （实测 2026-10-24，14 万行里有 1 行这种数据）。
#
# 本表只用于「按 TB 原生 ts_kv 结构写验收 SQL」，json_v 不需要 jsonb 操作符，
# 存 text 足够；真后端（Cassandra）里它本来就是 text 语义。
#
# 每次重建而不是 TRUNCATE：列类型改过，旧表的 jsonb 约束会挡住新数据。
$PSQL <<'SQL'
DROP VIEW IF EXISTS ts_kv;
DROP TABLE IF EXISTS ts_kv_mirror;
CREATE TABLE ts_kv_mirror (
  entity_type varchar(32),
  entity_id   uuid,
  key         varchar(255),
  partition   bigint,
  ts          bigint,
  bool_v      boolean,
  dbl_v       double precision,
  json_v      text,
  long_v      bigint,
  str_v       varchar(1000000)
);
SQL

docker compose --profile split exec -T postgres \
  psql -U "$DB_USER" -d "$DB_NAME" -X -q -v ON_ERROR_STOP=1 \
  -c "\copy ts_kv_mirror (entity_type,entity_id,key,partition,ts,bool_v,dbl_v,json_v,long_v,str_v) FROM '/tmp/energy-ts-mirror.csv' CSV HEADER NULL ''" \
  2>&1 | grep -vE '^$' | sed 's/^/    /' || true

# 把 key 名映射回 key_id：真表 ts_kv.key 是整数，验收 SQL 都按整数 JOIN
$PSQL <<'SQL'
ALTER TABLE ts_kv_mirror ADD COLUMN IF NOT EXISTS key_id integer;
UPDATE ts_kv_mirror m
   SET key_id = k.key_id
  FROM key_dictionary k
 WHERE k.key = m.key
   AND m.key_id IS NULL;
DROP VIEW IF EXISTS ts_kv;
CREATE VIEW ts_kv AS
SELECT entity_type, entity_id, key_id AS key, partition, ts,
       bool_v, dbl_v, json_v, long_v, str_v
  FROM ts_kv_mirror;

-- 索引不是可选项。
--
-- 真表 ts_kv 上有 (entity_id, key, ts) 索引，手册和验收里的相关子查询
-- 才能走索引。镜像表若裸着，下面这种写法会退化成 O(n²)：
--
--   WHERE kv.ts = (SELECT max(ts) FROM ts_kv k2
--                   WHERE k2.entity_id = kv.entity_id AND k2.key = kv.key)
--
-- 实测 2026-10-23：14 万行的镜像上这条超过 90 秒（真表上瞬间返回），
-- 导致 check-docs.py 的 SQL 校验整体超时。
CREATE INDEX IF NOT EXISTS idx_ts_kv_mirror_ek_t
    ON ts_kv_mirror (entity_id, key_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_ts_kv_mirror_ts
    ON ts_kv_mirror (ts);
SQL

GOT=$($PSQL -tAc "SELECT count(*) FROM ts_kv;" | tr -d ' ')
MISS=$($PSQL -tAc "SELECT count(*) FROM ts_kv WHERE key IS NULL;" | tr -d ' ')
ok "镜像就绪：ts_kv 视图 ${GOT} 行（key 未匹配 ${MISS} 行）"
if [[ "${MISS:-0}" -gt 0 ]]; then
  warn "有 ${MISS} 行的 key 名在 key_dictionary 里找不到 —— 可能是新指标还没进字典"
fi
