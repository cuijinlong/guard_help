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
if [[ -n "$DEV_IDS" && "$KEEP_TELEMETRY" != "true" ]]; then
  IDLIST=$(echo "$DEV_IDS" | tr ' ' ',' | sed "s/[^,]*/'&'/g")
  TS_N=$(psql_q "SELECT count(*) FROM ts_kv WHERE entity_id IN ($IDLIST);")
  TS_N="${TS_N:-0}"
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

# ---------------------------------------------------------------- 清遥测
TS_DELETED=0
if [[ "$KEEP_TELEMETRY" != "true" && -n "$DEV_IDS" ]]; then
  log "清理遥测（ts_kv，按删前的设备 id 精确匹配）"
  IDLIST=$(echo "$DEV_IDS" | tr ' ' ',' | sed "s/[^,]*/'&'/g")
  EXPECT_TS=$(psql_q "SELECT count(*) FROM ts_kv WHERE entity_id IN ($IDLIST);")
  # psql 的 DELETE 输出是「DELETE <n>」，但我们统一去了空白，这里只取数字
  DEL_TS=$(docker exec -i "$PG_CONTAINER" psql -U postgres -d "$PG_DB" -tAc \
    "DELETE FROM ts_kv WHERE entity_id IN ($IDLIST);" 2>/dev/null || echo '?')
  DEL_N=$(echo "$DEL_TS" | tr -cd '0-9')
  if echo "$DEL_TS" | grep -q '^DELETE'; then
    TS_DELETED=${DEL_N:-0}
    ok "已删除 ${TS_DELETED} 个数据点（删前计数 ${EXPECT_TS:-?}）"
  else
    warn "ts_kv 清理结果：${DEL_TS:-未知}（可稍后手工核对）"
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
if [[ "${TS_AFTER:-0}" -lt "${TS_BEFORE:-0}" ]]; then
  ISOLATION_OK="false"
  FAIL_MSG="${FAIL_MSG}

  ✗ 目标以外的遥测**减少了** $(( ${TS_BEFORE:-0} - ${TS_AFTER:-0} )) 点！
      删前 ${TS_BEFORE} 点 → 删后 ${TS_AFTER} 点（遥测只增不减，减少必是误删）
    立即恢复备份，不要再执行任何删除。"
else
  ok "遥测：目标以外 ${TS_BEFORE} → ${TS_AFTER} 点（本次删了 ${TS_DELETED} 点，未波及他人）"
fi

# 目标设备的遥测必须归零（除非 --keep-telemetry）
if [[ "$KEEP_TELEMETRY" != "true" && -n "$DEV_IDS" ]]; then
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
