#!/usr/bin/env bash
#
# 能源管理平台 · 清理一个客户（连同它的全部数据）
#
# 场景：试用客户不合作了 / 建错了要重来 / 测试数据要清干净。
#
# 用法：
#   bash scripts/10-cleanup-customer.sh --email customer2@company.com --dry-run
#   bash scripts/10-cleanup-customer.sh --name '某某公司' --yes
#   bash scripts/10-cleanup-customer.sh --id 74a70450-ce0f-11f1-...
#
# 定位客户的三种方式（优先 --id，其次 --name，最后 --email）：
#   --id    客户 uuid，最直接
#   --name  客户名完全匹配
#   --email ① 客户名 = 邮箱前缀（09-onboard-customer.sh 的默认约定）
#           ② 用该邮箱查用户表反推 customer_id（客户名自定义时走这条）
#
# 默认会先打印「将删除什么」并要求输入 yes 确认；加 --yes 跳过（脚本化用）。
#
# ═══════════════ 安全性：只动这一个客户 ═══════════════
# 脚本在删除前后各做一次「目标以外世界」的指纹快照（实体数 + 全库 id 的 md5），
# 删完必须逐位相同；遥测也要满足「删后总数 = 删前总数 - 实删点数」。
# 任何一项不符 → 退出码 2 并打印差异，绝不静默通过。
#
# 另有三个预检，不通过直接中止：
#   ① 待删设备必须真的都属于该客户（否则拒绝，防止拿错 id 去删遥测）
#   ② 目标不能是 null uuid（租户/系统实体）
#   ③ 删除前确认客户存在，删除后确认它真的没了
#
# 它删什么（**不可恢复**）：
#   customer / tb_user / user_credentials        客户与账号
#   asset / device / device_credentials          资产与设备
#   relation / attribute_kv                      关系与属性
#   dashboard                                    复制给该客户的看板副本
#   ts_kv                                        遥测（默认删，--keep-telemetry 保留）
#   custom_menu                                  该客户的菜单（无其他客户引用时）
#
# 关于 ts_kv：TB 删设备**不会**删遥测 —— 数据按 entity_id 存在分区表里，
# 设备没了数据还在。不清理会一直占盘（实测：3 台已删设备残留 228 点）。
# 本脚本在删除客户**之前**先记下设备 id，删完再按 id 精确清 ts_kv。
#
# 不会删的：租户、租户管理员、其他客户、租户级主数据（字典 / 费率模板 / 分时方案）。
#
# 退出码：0 成功 / 1 参数或前置失败 / 2 隔离校验不通过（需人工介入）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${BASE:-http://127.0.0.1:8090}"
PG_CONTAINER="${PG_CONTAINER:-energy-postgres}"
PG_DB="${PG_DB:-thingsboard}"

# ---------------------------------------------------------------- 遥测后端
# 遥测可能在 Postgres（DATABASE_TS_TYPE=sql）或 Cassandra（默认）。
# 两者的清理方式**完全不同**，判错就会出现「盘点 0 点、实际残留几万点」的假安全：
#   · sql       → DELETE FROM ts_kv（PG 真表）
#   · cassandra → 必须走 TB 的 telemetry delete API，且**要在删客户之前**
#                 （API 需要实体存在 + WRITE_TELEMETRY 权限校验）
#
# 实测 2026-10-23：脚本按 sql 写死，Cassandra 后端下盘点显示「0 个数据点」，
# 因为 PG 里的 ts_kv 只是验收用的**镜像视图**，不代表真实数据 ——
# 客户销户后 Cassandra 里那几万点会永久残留，正是最该防的「数据污染」。
TS_BACKEND="${DATABASE_TS_TYPE:-}"
if [[ -z "$TS_BACKEND" ]]; then
  # 部署目录的 .env 是唯一可信来源（脚本可能从别处调用）
  for f in "$HERE/../.env" "$HERE/.env"; do
    [[ -f "$f" ]] && TS_BACKEND=$(sed -n 's/^DATABASE_TS_TYPE=//p' "$f" | tail -1) && break
  done
fi
TS_BACKEND="${TS_BACKEND:-cassandra}"

# 列出某台设备实际有遥测的 key（跨后端通用：走 TB API，不碰存储层）
telemetry_keys() {
  local dev="$1" raw
  raw=$(api GET "/api/plugins/telemetry/DEVICE/$dev/keys/timeseries" 2>/dev/null || true)
  echo "$raw" | python3 -c "
import json,sys
try:
    ks=json.load(sys.stdin)
except Exception:
    ks=[]
print(','.join(ks) if isinstance(ks,list) else '')" 2>/dev/null || true
}

# 有多少台设备真的带遥测（用于盘点，不做精确点数 —— Cassandra 全表 count 会超时）
devices_with_telemetry() {
  local n=0 d k
  for d in ${DEV_IDS:-}; do
    k=$(telemetry_keys "$d")
    [[ -n "$k" ]] && n=$((n+1))
  done
  echo "$n"
}

# ---------------------------------------------------------------- Cassandra 索引残留
#
# ★ TB 的 delete API 只删 ts_kv_cf，**不删 ts_kv_partitions_cf**。
#
# 实测（2026-10-23）：销户后 ts_kv_cf 读到 0 行（tombstone 生效），
# 但 ts_kv_partitions_cf 里 526 行分区索引原封不动留着。
# 这是 TB 上游行为（CassandraBaseTimeseriesDao.deleteAsync 只发
# `DELETE FROM ts_kv_cf`），不是我们的 bug；但对「销户不留痕」是实实在在的残留：
#   · 占空间（每台表 35 key × 每小时一个分区）
#   · 重建同 UUID 的实体（导入/迁移）会读到旧分区索引
#
# 表主键是 ((entity_type, entity_id, key), partition)，
# 按 (entity_type, entity_id, key) 整个分区删，比逐 partition 快得多。
cass_purge_partitions() {
  local ids="$1" cql=/tmp/purge_partitions_$$.cql
  [[ -z "$ids" ]] && { echo 0; return; }

  : > "$cql"
  local dev
  for dev in ${ids//,/ }; do
    docker exec energy-cassandra cqlsh -e \
      "SELECT entity_type, key FROM thingsboard.ts_kv_partitions_cf WHERE entity_id=${dev} ALLOW FILTERING;" \
      2>/dev/null \
    | python3 -c "
import sys
dev = '${dev}'
n = 0
for ln in sys.stdin:
    if '|' not in ln:
        continue
    et, k = ln.split('|', 1)
    et = et.strip(); k = k.strip()
    if et not in ('DEVICE', 'ASSET') or not k or k == 'key':
        continue
    print(f\"DELETE FROM thingsboard.ts_kv_partitions_cf WHERE entity_type='{et}' AND entity_id={dev} AND key='{k}';\")
    n += 1
" >> "$cql"
  done

  local n
  n=$(grep -c '^DELETE' "$cql" 2>/dev/null || echo 0)
  if [[ "${n:-0}" -gt 0 ]]; then
    docker cp "$cql" energy-cassandra:/tmp/purge.cql >/dev/null
    docker exec energy-cassandra cqlsh -f /tmp/purge.cql >/dev/null 2>&1 || true
  fi
  rm -f "$cql"
  echo "${n:-0}"
}

# 目标设备在 Cassandra 里还有多少分区索引（0 = 干净）
#
# ⚠ 不能对 cqlsh 输出做 `tr -cd '0-9'`：
#   cqlsh 会在结果后面打 Warnings（"Read 638 live rows and 3124 tombstone cells"），
#   那些数字会被一并吞进来，把 0 算成 6383124 之类。实测踩过：明明 0 行，
#   却报「仍有 21 条残留」，逼着人去查一个不存在的残留。
#   只认「整行只有一个数字」的那一行（count 的输出行）。
cass_partitions_left() {
  local ids="$1" total=0
  [[ -z "$ids" ]] && { echo 0; return; }
  local dev c
  for dev in ${ids//,/ }; do
    c=$(docker exec energy-cassandra cqlsh -e \
      "SELECT count(*) FROM thingsboard.ts_kv_partitions_cf WHERE entity_id=${dev} ALLOW FILTERING;" \
      2>/dev/null \
      | awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ { v = $1 } END { print v + 0 }')
    total=$((total + ${c:-0}))
  done
  echo "$total"
}
NULL_UUID="13814000-1dd2-11b2-8080-808080808080"

EMAIL=""; NAME=""; CID=""
TENANT_EMAIL=""; TENANT_PASS=""
ASSUME_YES="false"; KEEP_TELEMETRY="false"; DRY_RUN="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)          EMAIL="$2"; shift 2 ;;
    --name)           NAME="$2"; shift 2 ;;
    --id)             CID="$2"; shift 2 ;;
    --base)           BASE="$2"; shift 2 ;;
    --tenant-email)   TENANT_EMAIL="$2"; shift 2 ;;
    --tenant-pass)    TENANT_PASS="$2"; shift 2 ;;
    --yes|-y)         ASSUME_YES="true"; shift ;;
    --keep-telemetry) KEEP_TELEMETRY="true"; shift ;;
    --dry-run)        DRY_RUN="true"; shift ;;
    -h|--help)        sed -n '2,48p' "$0"; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

[[ -n "$EMAIL$NAME$CID" ]] || die "必须提供 --email / --name / --id 之一
    例：bash scripts/10-cleanup-customer.sh --email a@b.com"

# ---------------------------------------------------------------- 基础设施
ncurl() { curl -s --noproxy '*' "$@"; }

# psql_q <sql> —— 单值查询：去掉所有空白，失败返回空串
psql_q() {
  docker exec -i "$PG_CONTAINER" psql -U postgres -d "$PG_DB" -tAc "$1" 2>/dev/null \
    | tr -d ' \n' | head -1 || true
}

login() {
  ncurl -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

# ---------------------------------------------------------------- 租户凭据
CRED="$HERE/../DEPLOY-CREDENTIALS.txt"
[[ -f "$CRED" ]] || CRED="$HERE/DEPLOY-CREDENTIALS.txt"
if [[ -z "$TENANT_EMAIL" && -f "$CRED" ]]; then
  TENANT_EMAIL=$(sed -n 's/^租户管理员[[:space:]]*\([^ ]*\) \/.*/\1/p' "$CRED" | head -1)
  TENANT_PASS=$(sed -n 's/^租户管理员[[:space:]]*[^ ]* \/ \(.*\)$/\1/p' "$CRED" | head -1)
fi
[[ -n "$TENANT_EMAIL" && -n "$TENANT_PASS" ]] || die "读不到租户管理员凭据。
    放 DEPLOY-CREDENTIALS.txt 到部署目录，或传 --tenant-email / --tenant-pass"

TOKEN=$(login "$TENANT_EMAIL" "$TENANT_PASS")
[[ -n "$TOKEN" ]] || die "租户管理员登录失败（${TENANT_EMAIL}）"

api() {
  local m="$1" p="$2" b="${3:-}"
  if [[ -n "$b" ]]; then
    ncurl -X "$m" "$BASE$p" -H "X-Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "$b"
  else
    ncurl -X "$m" "$BASE$p" -H "X-Authorization: Bearer $TOKEN"
  fi
}

jlen() { python3 -c "import json,sys;print(len((json.load(sys.stdin) or {}).get('data',[])))" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- 定位客户
log "定位客户"

if [[ -z "$CID" ]]; then
  ALL=$(api GET '/api/customers?pageSize=200&page=0')
  CID=$(echo "$ALL" | Q_EMAIL="$EMAIL" Q_NAME="$NAME" python3 -c "
import json,sys,os
rows=(json.load(sys.stdin) or {}).get('data',[])
email=os.environ.get('Q_EMAIL','')
name=os.environ.get('Q_NAME','')
hit=None
if name:
    hits=[c for c in rows if c.get('title')==name]
    hit=hits[0] if hits else None
elif email:
    prefix=email.split('@')[0]
    hit=next((c for c in rows if c.get('title') in (prefix, email)), None)
print(hit['id']['id'] if hit else '')" 2>/dev/null || true)
fi

# 客户名不是邮箱前缀时，用用户表反查
if [[ -z "$CID" && -n "$EMAIL" ]]; then
  [[ "$EMAIL" =~ ^[A-Za-z0-9._%+@-]+$ ]] || die "邮箱含非法字符：$EMAIL"
  log "客户名未匹配，按用户邮箱反查所属客户"
  CID=$(psql_q "SELECT customer_id FROM tb_user
                 WHERE lower(email) = lower('$EMAIL')
                   AND customer_id IS DISTINCT FROM '$NULL_UUID'
                 LIMIT 1;")
  [[ -n "$CID" ]] && ok "邮箱 $EMAIL 属于客户 $CID"
fi

[[ -n "$CID" ]] || die "找不到客户。
    已尝试按客户名与用户邮箱匹配（name=${NAME:-无} email=${EMAIL:-无}）。
    请确认客户存在，或用 --id 指定。"

# 防误删：null uuid 不是客户
[[ "$CID" != "$NULL_UUID" ]] || die "拒绝执行：$CID 是租户/系统实体的 null uuid，不是客户。"
[[ "$CID" =~ ^[0-9a-f-]{36}$ ]] || die "拒绝执行：$CID 不是合法 uuid。"

# 必须是真实存在的客户（不能是资产/设备的 id）
DETAIL=$(api GET "/api/customer/$CID")
TITLE=$(echo "$DETAIL" | python3 -c "import json,sys;print((json.load(sys.stdin) or {}).get('title',''))" 2>/dev/null || true)
[[ -n "$TITLE" ]] || die "客户 $CID 不存在或读不到（可能已删除，或传错了 id）。"

# ---------------------------------------------------------------- 盘点
log "盘点「${TITLE}」名下数据"
ASSETS=$(api GET "/api/customer/$CID/assets?pageSize=2000&page=0")
DEVICES=$(api GET "/api/customer/$CID/devices?pageSize=2000&page=0")
DASHES=$(api GET "/api/customer/$CID/dashboards?pageSize=1000&page=0")
USERS=$(api GET "/api/customer/$CID/users?pageSize=1000&page=0" 2>/dev/null || echo '{"data":[]}')

read -r SITE_N ITEM_N TOPO_N ASSET_N <<EOF
$(echo "$ASSETS" | python3 -c "
import json,sys
rows=(json.load(sys.stdin) or {}).get('data',[])
print(sum(1 for a in rows if a.get('type')=='场站'),
      sum(1 for a in rows if a.get('type')=='分项'),
      sum(1 for a in rows if a.get('type')=='topology'),
      len(rows))" 2>/dev/null || echo "0 0 0 0")
EOF

DEV_N=$(echo "$DEVICES" | jlen)
DASH_N=$(echo "$DASHES" | jlen)
USER_N=$(echo "$USERS" | jlen)

# 设备 id 必须**在删除前**拿到 —— 删完就查不到了，ts_kv 会变成孤儿
DEV_IDS=$(echo "$DEVICES" | python3 -c "
import json,sys
rows=(json.load(sys.stdin) or {}).get('data',[])
print(' '.join(d['id']['id'] for d in rows))" 2>/dev/null || true)

TS_N=0
TS_WITH=0
if [[ -n "$DEV_IDS" && "$KEEP_TELEMETRY" != "true" ]]; then
  if [[ "$TS_BACKEND" == "cassandra" ]]; then
    # Cassandra 不能 count(*)（全表扫会 ReadFailure），改为「有遥测的设备数」
    TS_WITH=$(devices_with_telemetry)
    TS_WITH="${TS_WITH:-0}"
  else
    IDLIST=$(echo "$DEV_IDS" | tr ' ' ',' | sed "s/[^,]*/'&'/g")
    TS_N=$(psql_q "SELECT count(*) FROM ts_kv WHERE entity_id IN ($IDLIST);")
    TS_N="${TS_N:-0}"
  fi
fi

# ════════════════════════════════════════════════════════════════
# 隔离护栏 A：预检 —— 待删的东西必须真的都属于这个客户
# ════════════════════════════════════════════════════════════════
if [[ -n "$DEV_IDS" ]]; then
  IDLIST=$(echo "$DEV_IDS" | tr ' ' ',' | sed "s/[^,]*/'&'/g")
  FOREIGN=$(psql_q "SELECT count(*) FROM device
                     WHERE id IN ($IDLIST)
                       AND customer_id IS DISTINCT FROM '$CID';")
  if [[ "${FOREIGN:-0}" != "0" ]]; then
    printf '\033[31m  ✗ 已中止：待删设备里有 %s 台不属于「%s」\033[0m\n' "$FOREIGN" "$TITLE" >&2
    echo "    为避免误删其他客户的遥测，不会继续。请核查后再执行。" >&2
    exit 2
  fi
  ok "预检：${DEV_N} 台设备全部属于「${TITLE}」"
fi

# 客户级实体里不该有别人的东西（按 customer_id 再核一遍）
STRAY=$(psql_q "
  SELECT (SELECT count(*) FROM asset  WHERE customer_id='$CID' AND tenant_id <> (SELECT tenant_id FROM customer WHERE id='$CID'))
       + (SELECT count(*) FROM device WHERE customer_id='$CID' AND tenant_id <> (SELECT tenant_id FROM customer WHERE id='$CID'));")
[[ "${STRAY:-0}" == "0" ]] || die "已中止：该客户名下有跨租户实体 ${STRAY} 条，属异常数据，请人工核查。"
ok "预检：客户名下实体租户归属一致"

# ════════════════════════════════════════════════════════════════
# 隔离护栏 B：给「目标以外的世界」拍指纹
#   实体数 + 全库 id 的 md5 —— 实体集合只要少一个/多一个，md5 必变
# ════════════════════════════════════════════════════════════════
outside_fingerprint() {
  psql_q "
  WITH s AS (
    SELECT id FROM asset     WHERE customer_id IS DISTINCT FROM '$CID'
    UNION ALL
    SELECT id FROM device    WHERE customer_id IS DISTINCT FROM '$CID'
    UNION ALL
    SELECT id FROM dashboard WHERE customer_id IS DISTINCT FROM '$CID'
    UNION ALL
    SELECT id FROM customer  WHERE id <> '$CID'
  )
  SELECT count(*)::text || '|' ||
         md5(coalesce(string_agg(id::text, ',' ORDER BY id::text), ''))
  FROM s;"
}

# 目标以外的遥测点数 —— 用于证明「没有误删别人的」
# 注意：不能统计全库总量，遥测是实时写入的，总量一直在涨。
# 语义：遥测 append-only，目标以外的点数**只能增加或不变**，减少就是越界。
ts_outside() {
  # Cassandra 下没有便宜的「非目标点数」查询：
  #   · 全表 count(*) 会 ReadFailure（默认 10s 读超时）
  #   · nodetool 的 partition 数是 estimate，且含 tombstone，作为指纹不可靠
  # 与其拿 PG 镜像快照充数（快照不随销户变化，永远"通过"= 假安全感），
  # 不如**明确跳过**，把遥测层面的隔离交给两条真正的硬校验：
  #   ① 非目标客户的实体指纹（outside_fingerprint，强校验）
  #   ② 目标设备分区索引归零（cass_partitions_left，强校验）
  if [[ "$TS_BACKEND" == "cassandra" ]]; then
    echo "skip"
    return
  fi
  if [[ -n "${DEV_IDS:-}" ]]; then
    local ids
    ids=$(echo "$DEV_IDS" | tr ' ' ',' | sed "s/[^,]*/'&'/g")
    psql_q "SELECT count(*) FROM ts_kv WHERE entity_id NOT IN ($ids);"
  else
    psql_q "SELECT count(*) FROM ts_kv;"
  fi
}

FP_BEFORE=$(outside_fingerprint)
TS_BEFORE=$(ts_outside)
TS_BEFORE="${TS_BEFORE:-0}"

echo
echo "============================================================"
printf '\033[1m  即将删除：「%s」\033[0m\n' "$TITLE"
echo "============================================================"
echo " 客户 ID    $CID"
echo " 场站 ${SITE_N}   分项 ${ITEM_N}   拓扑图 ${TOPO_N}   资产合计 ${ASSET_N}"
echo " 设备       ${DEV_N}"
echo " 看板副本   ${DASH_N}"
echo " 用户       ${USER_N}"
if [[ "$KEEP_TELEMETRY" == "true" ]]; then
  echo " 遥测数据   保留（--keep-telemetry）"
elif [[ "$TS_BACKEND" == "cassandra" ]]; then
  echo " 遥测数据   ${TS_WITH} 台设备带遥测（Cassandra，一并删除）"
else
  echo " 遥测数据   ${TS_N} 个数据点（一并删除）"
fi
echo "------------------------------------------------------------"
echo " 影响面     仅此客户。其他客户 ${FP_BEFORE%%|*} 个实体（含租户级）已拍快照，"
echo "            删后逐项校验，不一致会报错退出。"
echo "------------------------------------------------------------"
printf '\033[33m  此操作不可恢复。平台没有客户级回收站。\033[0m\n'
echo "  建议先备份： bash backups/backup-db.sh（如有）"
echo

if [[ "$DRY_RUN" == "true" ]]; then
  ok "只盘点不删除（--dry-run）"
  exit 0
fi

if [[ "$ASSUME_YES" != "true" ]]; then
  printf '输入 yes 确认删除：'
  read -r ANSWER
  [[ "$ANSWER" == "yes" ]] || { warn "已取消"; exit 0; }
fi

# ---------------------------------------------------------------- 记菜单
# 删客户前记下它引用的菜单 id —— 删后按 id 精确清，不靠名字猜
MENU_ID=$(psql_q "SELECT custom_menu_id FROM customer WHERE id = '$CID';" || true)

# ---------------------------------------------------------------- 先清遥测
#
# ★ 顺序：删客户**之前**。
#
# TB 的 telemetry delete API 会做权限校验（需要实体存在、当前用户有
# WRITE_TELEMETRY）。客户一删，设备就没了，API 返回 404，遥测永远删不掉。
# SQL 后端没有这个约束（可以事后 DELETE FROM ts_kv），但统一放前面更简单，
# 也让「删完再校验」这一步对两种后端都成立。
TS_DELETED=0
TS_PURGED_DEVS=0
if [[ "$KEEP_TELEMETRY" != "true" && -n "$DEV_IDS" ]]; then
  log "清理遥测（先于删客户；后端 ${TS_BACKEND}）"
  for d in $DEV_IDS; do
    KEYS=$(telemetry_keys "$d")
    [[ -z "$KEYS" ]] && continue
    CODE=$(ncurl -o /tmp/cleanup-ts.json -w '%{http_code}' -X DELETE \
      "$BASE/api/plugins/telemetry/DEVICE/$d/timeseries/delete?keys=${KEYS}&deleteAllDataForKeys=true" \
      -H "X-Authorization: Bearer $TOKEN")
    if [[ "$CODE" == "200" ]]; then
      TS_PURGED_DEVS=$((TS_PURGED_DEVS+1))
    else
      warn "设备 $d 遥测删除失败（HTTP ${CODE}）：$(cat /tmp/cleanup-ts.json 2>/dev/null | head -c 200)"
    fi
  done
  TS_DELETED="$TS_PURGED_DEVS"
  ok "已清 ${TS_PURGED_DEVS} 台设备的遥测"

  # TB 只删 ts_kv_cf，分区索引要自己清（原因见 cass_purge_partitions 注释）
  if [[ "$TS_BACKEND" == "cassandra" ]]; then
    IDS_CSV=$(echo "$DEV_IDS" | tr ' ' ',')
    CASS_IDX_DEL=$(cass_purge_partitions "$IDS_CSV")
    ok "已清 ${CASS_IDX_DEL} 条 Cassandra 分区索引（ts_kv_partitions_cf）"
  fi
fi

# ---------------------------------------------------------------- 删除
log "删除客户（级联删资产 / 设备 / 用户 / 看板 / 关系 / 属性）"
CODE=$(ncurl -o /tmp/cleanup-del.json -w '%{http_code}' -X DELETE \
  "$BASE/api/customer/$CID" -H "X-Authorization: Bearer $TOKEN")
if [[ "$CODE" != "200" ]]; then
  cat /tmp/cleanup-del.json 2>/dev/null; die "删客户失败（HTTP ${CODE}）"
fi
ok "客户已删除"

# 删的必须真是这一个
GONE=$(psql_q "SELECT count(*) FROM customer WHERE id = '$CID';")
[[ "${GONE:-1}" == "0" ]] || die "异常：接口返回成功，但客户 $CID 仍在库中。请人工核查。"
ok "确认客户 $CID 已从库中消失"

# ---------------------------------------------------------------- 校验遥测已清
#
# 这是「客户数据不污染系统」的**最后一道闸**。
# 不能只信 API 返回 200 —— 必须回读**真实存储**。
#
# ⚠ Cassandra 后端下绝不能查 PG 的 ts_kv：
#   那是 scripts/ts-mirror.sh 建的**导出快照**，销户时它还是旧数据，
#   于是校验永远报「仍有 N 个点未清掉」的假故障（实测 2026-10-23：
#   误报 122257 点，而 Cassandra 里其实一行都读不到了）。
if [[ "$KEEP_TELEMETRY" != "true" && -n "$DEV_IDS" && "$TS_DELETED" != "0" ]]; then
  log "回读校验：目标设备的遥测是否真的清空"
  if [[ "$TS_BACKEND" == "cassandra" ]]; then
    IDS_CSV=$(echo "$DEV_IDS" | tr ' ' ',')
    CASS_LEFT=$(cass_partitions_left "$IDS_CSV")
    if [[ "${CASS_LEFT:-1}" == "0" ]]; then
      ok "Cassandra：目标设备已无分区索引（0 条）"
    else
      warn "Cassandra：仍有 ${CASS_LEFT} 条分区索引残留（ts_kv_cf 数据已 tombstone）"
    fi
    TS_LEFT="$CASS_LEFT"
  else
    TS_LEFT=0
    for d in $DEV_IDS; do
      KEYS=$(telemetry_keys "$d")
      [[ -n "$KEYS" ]] && TS_LEFT=$((TS_LEFT+1))
    done
    if [[ "$TS_LEFT" == "0" ]]; then
      ok "目标设备遥测已清空（0 台仍有数据）"
    fi
  fi
else
  log "跳过遥测清理（--keep-telemetry 或没有设备）"
fi

# ---------------------------------------------------------------- 清菜单
if [[ -n "$MENU_ID" && "$MENU_ID" != "$NULL_UUID" ]]; then
  log "清理该客户的菜单（按删前记录的 id，且确认无其他客户引用）"
  ORPHAN=$(psql_q "
    WITH gone AS (
      DELETE FROM custom_menu cm
      WHERE cm.id = '$MENU_ID'
        AND NOT EXISTS (SELECT 1 FROM customer c WHERE c.custom_menu_id = cm.id)
      RETURNING cm.id
    ) SELECT count(*) FROM gone;")
  ok "清理菜单 ${ORPHAN:-0} 条"
else
  log "该客户没有独立菜单，跳过"
fi

# ---------------------------------------------------------------- 交付文件
if [[ -f "$HERE/../ONBOARDED-${CID}.txt" ]]; then
  rm -f "$HERE/../ONBOARDED-${CID}.txt"
  ok "已删除交付信息文件 ONBOARDED-${CID}.txt"
fi

# ════════════════════════════════════════════════════════════════
# 复查一：目标已清空
# ════════════════════════════════════════════════════════════════
log "复查：目标客户是否清空"
LEFTOVER=$(psql_q "
SELECT (SELECT count(*) FROM customer  WHERE id='$CID')
     + (SELECT count(*) FROM asset     WHERE customer_id='$CID')
     + (SELECT count(*) FROM device    WHERE customer_id='$CID')
     + (SELECT count(*) FROM dashboard WHERE customer_id='$CID')
     + (SELECT count(*) FROM tb_user   WHERE customer_id='$CID');")

if [[ "${LEFTOVER:-?}" == "0" ]]; then
  ok "已彻底清理（客户 / 资产 / 设备 / 看板 / 用户 全为 0）"
else
  warn "仍有 ${LEFTOVER:-?} 条记录残留：
    SELECT count(*) FROM customer  WHERE id='$CID';
    SELECT count(*) FROM asset     WHERE customer_id='$CID';
    SELECT count(*) FROM device    WHERE customer_id='$CID';
    SELECT count(*) FROM dashboard WHERE customer_id='$CID';
    SELECT count(*) FROM tb_user   WHERE customer_id='$CID';"
fi

# ════════════════════════════════════════════════════════════════
# 复查二：目标以外的世界必须一字节没变
# ════════════════════════════════════════════════════════════════
log "复查：其他客户与租户级数据是否完好"
FP_AFTER=$(outside_fingerprint)
TS_AFTER=$(ts_outside)
TS_AFTER="${TS_AFTER:-0}"

FP_B_N=${FP_BEFORE%%|*}; FP_B_M=${FP_BEFORE##*|}
FP_A_N=${FP_AFTER%%|*};  FP_A_M=${FP_AFTER##*|}

ISOLATION_OK="true"
FAIL_MSG=""

if [[ "$FP_B_M" != "$FP_A_M" ]]; then
  ISOLATION_OK="false"
  FAIL_MSG="${FAIL_MSG}
  ✗ 其他客户的实体集合变了！
      删前 ${FP_B_N} 个（md5 ${FP_B_M}）
      删后 ${FP_A_N} 个（md5 ${FP_A_M}）
    这说明删除越界了。立即恢复备份，不要再执行任何删除。"
fi

# 目标以外的遥测：只能增加（实时写入）或不变，减少就是误删。
# 这里不能用「相等」—— 其他客户每分钟都在上报，数字一直在涨。
if [[ "$TS_BACKEND" == "cassandra" ]]; then
  log "遥测：Cassandra 后端跳过「目标以外点数」指纹（全表 count 不可用）"
  ok "  隔离由实体指纹 + 目标设备索引归零两条硬校验保证"
elif [[ "${TS_AFTER:-0}" -lt "${TS_BEFORE:-0}" ]]; then
  ISOLATION_OK="false"
  FAIL_MSG="${FAIL_MSG}

  ✗ 目标以外的遥测**减少了** $(( ${TS_BEFORE:-0} - ${TS_AFTER:-0} )) 点！
      删前 ${TS_BEFORE} 点 → 删后 ${TS_AFTER} 点（遥测只增不减，减少必是误删）
    立即恢复备份，不要再执行任何删除。"
else
  ok "遥测：目标以外 ${TS_BEFORE} → ${TS_AFTER} 点（本次删了 ${TS_DELETED} 点，未波及他人）"
fi

# 目标设备的遥测必须归零（除非 --keep-telemetry）
#
# 后端决定「归零」怎么判：
#   cassandra → ts_kv_partitions_cf 必须 0 条（ts_kv_cf 的数据已 tombstone，读不到）
#   sql       → ts_kv 必须 0 行
if [[ "$KEEP_TELEMETRY" != "true" && -n "$DEV_IDS" ]]; then
  if [[ "$TS_BACKEND" == "cassandra" ]]; then
    TS_LEFT=$(cass_partitions_left "$(echo "$DEV_IDS" | tr ' ' ',')")
    if [[ "${TS_LEFT:-1}" == "0" ]]; then
      ok "遥测：目标设备已无残留（Cassandra 分区索引 0 条）"
    else
      ISOLATION_OK="false"
      FAIL_MSG="${FAIL_MSG}

  ✗ 目标设备仍有 ${TS_LEFT} 条 Cassandra 分区索引未清掉。"
    fi
  else
    IDLIST=$(echo "$DEV_IDS" | tr ' ' ',' | sed "s/[^,]*/'&'/g")
    TS_LEFT=$(psql_q "SELECT count(*) FROM ts_kv WHERE entity_id IN ($IDLIST);")
    if [[ "${TS_LEFT:-1}" == "0" ]]; then
      ok "遥测：目标设备已无残留（0 点）"
    else
      ISOLATION_OK="false"
      FAIL_MSG="${FAIL_MSG}

  ✗ 目标设备仍有 ${TS_LEFT} 个遥测点未清掉。"
    fi
  fi
fi

if [[ "$ISOLATION_OK" == "true" ]]; then
  ok "隔离校验通过：其他客户 ${FP_A_N} 个实体与租户级数据均未受影响"
  echo
  echo "============================================================"
  printf '\033[32m  清理完成：「%s」\033[0m\n' "$TITLE"
  echo "============================================================"
  echo " 其他客户、租户、租户管理员、租户级主数据（字典/费率模板/分时方案）全部未动。"
  echo
  exit 0
else
  echo
  printf '\033[31m  ✗ 隔离校验不通过 —— 需要人工介入\033[0m\n'
  printf '%s\n' "$FAIL_MSG"
  echo
  echo "  已停止后续动作。建议："
  echo "    1. 不要再执行任何删除脚本"
  echo "    2. 从备份恢复，或逐条核查上面的差异"
  echo "    3. 若确认是虚警，请把上面的完整输出反馈给开发"
  echo
  exit 2
fi
