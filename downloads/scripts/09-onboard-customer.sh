#!/usr/bin/env bash
#
# 能源管理平台 · 一键开通一个客户（带演示数据）
#
# 场景：平台已经部署好，来了一家合作企业，只想给一个账号让他直接用。
#
# 用法：
#   bash scripts/09-onboard-customer.sh \
#     --email customer2@company.com \
#     --password 'Cust@123456'
#
#   # 客户名可选；不传则从邮箱前缀推导（如 customer2@company.com → customer2）
#   bash scripts/09-onboard-customer.sh --email x@y.com --password 'X@1' --name '某某公司'
#
# 租户管理员凭据默认从同目录的 ../DEPLOY-CREDENTIALS.txt 读（重装时生成），
# 也可以用 --tenant-email / --tenant-pass 覆盖。
#
# 它做什么：
#   1. 建客户
#   2. 建客户管理员账号并激活（密码就是 --password）
#   3. 确保演示数据（2 个场站 / 12 个分项 / 21 台设备 / 逐小时遥测）
#   4. 确保客户菜单（13 项，第一项是落地页）+ 复制 20 个看板
#   5. 逐项验证，任何一样缺失就报错
#   6. 打印登录信息 + 数据落表清单 + 查询 SQL
#
# 安全：脚本不写死任何密码；重复执行同一邮箱是幂等的（已存在会复用并重置密码）。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${BASE:-http://127.0.0.1:8090}"
EMAIL=""; PASS=""; NAME=""
TENANT_EMAIL=""; TENANT_PASS=""; TENANT_TITLE=""
NO_DEMO="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)        EMAIL="$2"; shift 2 ;;
    --password)     PASS="$2"; shift 2 ;;
    --name)         NAME="$2"; shift 2 ;;
    --base)         BASE="$2"; shift 2 ;;
    --tenant-email) TENANT_EMAIL="$2"; shift 2 ;;
    --tenant-pass)  TENANT_PASS="$2"; shift 2 ;;
    --tenant-title) TENANT_TITLE="$2"; shift 2 ;;
    --no-demo)      NO_DEMO="true"; shift ;;
    -h|--help)      sed -n '2,26p' "$0"; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

[[ -n "$EMAIL" && -n "$PASS" ]] || die "必须提供 --email 与 --password
    例：bash scripts/09-onboard-customer.sh --email a@b.com --password 'Xxx@123456'"

# 密码强度：客户要能自己登录，太短的密码容易被撞库；TB 默认要求 8 位以上
[[ ${#PASS} -ge 8 ]] || die "密码至少 8 位（当前 ${#PASS} 位）"

# 客户名默认从邮箱前缀推导：customer2@company.com → customer2
[[ -n "$NAME" ]] || NAME="${EMAIL%%@*}"

# ---------------------------------------------------------------- 读默认凭据
CRED="$HERE/../DEPLOY-CREDENTIALS.txt"
[[ -f "$CRED" ]] || CRED="$HERE/DEPLOY-CREDENTIALS.txt"
if [[ -z "$TENANT_EMAIL" && -f "$CRED" ]]; then
  TENANT_EMAIL=$(sed -n 's/^租户管理员[[:space:]]*\([^ ]*\) \/.*/\1/p' "$CRED" | head -1)
  TENANT_PASS=$(sed -n 's/^租户管理员[[:space:]]*[^ ]* \/ \(.*\)$/\1/p' "$CRED" | head -1)
  [[ -n "$TENANT_TITLE" ]] || TENANT_TITLE=$(sed -n 's/^租户名称[[:space:]]*\(.*\)$/\1/p' "$CRED" | head -1)
fi

[[ -n "$TENANT_EMAIL" && -n "$TENANT_PASS" ]] || die "读不到租户管理员凭据。
    要么在部署目录放 DEPLOY-CREDENTIALS.txt（重装时自动生成），
    要么显式传：--tenant-email xxx@yyy.com --tenant-pass '密码'"

ncurl() { curl -s --noproxy '*' "$@"; }

login() {
  ncurl -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

CATALOG="$HERE/02-onboard.sh"
[[ -f "$CATALOG" ]] || die "找不到 ${CATALOG}（脚本必须和 02-onboard.sh 放在同一目录）"

echo
printf '\033[1m开通客户：%s（%s）\033[0m\n' "$NAME" "$EMAIL"
echo " 平台：$BASE"
echo " 租户：${TENANT_TITLE:-（自动）}"
echo

# ---------------------------------------------------------------- 1. 建客户 + 账号
# 复用 02-onboard.sh，不重写一遍 API 调用 ——
# 两份实现迟早分叉，而它已经带了 11 项验证。
log "步骤 1/3　建客户与账号（复用 02-onboard.sh）"
bash "$CATALOG" \
  --base "$BASE" \
  --admin "$TENANT_EMAIL" --admin-pass "$TENANT_PASS" \
  --customer "$NAME" --customer-email "$EMAIL" --customer-pass "$PASS" \
  > /tmp/onboard-customer.log 2>&1 \
  || { tail -40 /tmp/onboard-customer.log; die "开通失败，完整日志：/tmp/onboard-customer.log"; }
sed -n 's/^  ✓ /    ✓ /p' /tmp/onboard-customer.log | head -20

TOKEN=$(login "$TENANT_EMAIL" "$TENANT_PASS")
[[ -n "$TOKEN" ]] || die "租户管理员登录失败"

api() {
  local m="$1" p="$2" b="${3:-}"
  if [[ -n "$b" ]]; then
    ncurl -X "$m" "$BASE$p" -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$b"
  else
    ncurl -X "$m" "$BASE$p" -H "X-Authorization: Bearer $TOKEN"
  fi
}

CID=$(api GET "/api/customers?pageSize=100&page=0&textSearch=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$NAME")" \
  | python3 -c "
import json,sys
rows=(json.load(sys.stdin) or {}).get('data',[])
hit=next((c for c in rows if c.get('title')=='$NAME'), None)
print(hit['id']['id'] if hit else '')" 2>/dev/null)
[[ -n "$CID" ]] || die "建完了但查不到客户「${NAME}」"

# ---------------------------------------------------------------- 2. 确保演示数据
if [[ "$NO_DEMO" == "true" ]]; then
  log "步骤 2/3　跳过演示数据（--no-demo）"
else
  log "步骤 2/3　确保演示数据（幂等：已有则跳过）"
  # 显式调一次，不依赖「建客户时异步触发」——
  # 异步那一步失败时脚本只说成功，用户登录后才发现页面空着。
  api POST /api/energy/demo-data "{\"customerId\":\"$CID\",\"customerName\":\"$NAME\"}" \
    > /tmp/onboard-demo.json 2>&1 || warn "演示数据接口调用失败，看 /tmp/onboard-demo.json"

  # 资产汇总遥测（energy_total / water_total / …）。
  #
  # 看板在「选场站 / 选分项」时读的是**资产**上的汇总遥测，
  # 不是设备的 energy。建客户流程里已经写了一次，这里**再显式补一次**：
  #   · 演示数据是幂等跳过时，说明之前建过 —— 但期间库里可能被动过；
  #   · 客户自己加过设备后再跑本脚本，也需要刷新汇总。
  # 不补的话，运营看到「开通成功」，客户登录选场站却是空的。
  api POST /api/energy/asset-totals/rebuild "{\"customerId\":\"$CID\",\"days\":60}" \
    > /tmp/onboard-totals.json 2>&1 || warn "资产汇总重算失败，看 /tmp/onboard-totals.json"
  ASSET_N=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/onboard-totals.json')).get('assetsWritten', 0))
except Exception:
    print(0)" 2>/dev/null)
  [[ "${ASSET_N:-0}" -gt 0 ]] && ok "资产汇总已写入（${ASSET_N} 个资产，看板场站维度可用）" \
      || warn "资产汇总写入 0 个（看板选场站可能为空）"
fi

# ---------------------------------------------------------------- 3. 验证
log "步骤 3/3　逐项验证"

ncurl -X POST "$BASE/api/energy/repair-init" -H "X-Authorization: Bearer $TOKEN" \
  -o /dev/null 2>&1 || true   # 补拓扑 / 升级菜单结构 / 修显示名（幂等）

ASSETS=$(api GET "/api/customer/$CID/assets?pageSize=500&page=0")
DEVICES=$(api GET "/api/customer/$CID/devices?pageSize=500&page=0")
CLIENT_LOGIN=$(login "$EMAIL" "$PASS")
[[ -n "$CLIENT_LOGIN" ]] || die "客户账号登录失败 —— 账号建了但密码不对"

SITE_N=$(echo "$ASSETS" | python3 -c "import json,sys;print(sum(1 for a in json.load(sys.stdin).get('data',[]) if a.get('type')=='场站'))" 2>/dev/null || echo 0)
ITEM_N=$(echo "$ASSETS" | python3 -c "import json,sys;print(sum(1 for a in json.load(sys.stdin).get('data',[]) if a.get('type')=='分项'))" 2>/dev/null || echo 0)
DEV_N=$(echo "$DEVICES" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)
TOPO_N=$(echo "$ASSETS" | python3 -c "import json,sys;print(sum(1 for a in json.load(sys.stdin).get('data',[]) if a.get('type')=='topology'))" 2>/dev/null || echo 0)
DASH_N=$(api GET "/api/customer/$CID/dashboards?pageSize=200&page=0" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)

# 用**客户自己的 token** 验菜单：租户查自己的菜单看不到客户的
MENU_N=$(ncurl -H "X-Authorization: Bearer $CLIENT_LOGIN" "$BASE/api/customMenu" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len((d.get('config') or {}).get('items') or d.get('items') or []))" 2>/dev/null || echo 0)
HOME_N=$(ncurl -H "X-Authorization: Bearer $CLIENT_LOGIN" "$BASE/api/customMenu" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=(d.get('config') or {}).get('items') or d.get('items') or []
print(1 if items and items[0].get('id')=='home' else 0)" 2>/dev/null || echo 0)

FAIL=0
chk() {  # 名称 实际 下限 缺失提示
  if [[ "${2:-0}" -ge "$3" ]]; then ok "$1：$2"; else printf '\033[31m  ✗ %s：%s（期望 ≥%s）— %s\033[0m\n' "$1" "${2:-0}" "$3" "$4"; FAIL=1; fi
}
chk "场站"            "$SITE_N"  2  "演示数据没生成"
chk "分项（分类）"     "$ITEM_N"  6  "维度树不完整"
chk "设备"            "$DEV_N"  10  "演示设备缺失"
chk "拓扑图"          "$TOPO_N"  2  "每个场站应有一张"
chk "客户看板"        "$DASH_N" 10  "看板没复制给客户"
chk "客户菜单项"      "$MENU_N" 10  "侧边栏会是空的"
[[ "$HOME_N" == "1" ]] && ok "落地页（菜单第一项是 home）" \
  || { printf '\033[31m  ✗ 落地页未设置 —— 客户登录会落在空门户页\033[0m\n'; FAIL=1; }

echo
if [[ "$FAIL" != "0" ]]; then
  die "有验证失败项，客户账号可以登录但功能可能不完整，请按上面提示排查"
fi

# ---------------------------------------------------------------- 交付信息
echo "============================================================"
printf '\033[32m  客户已开通\033[0m\n'
echo "============================================================"
echo
echo " 登录地址   $BASE"
echo " 账号       $EMAIL"
echo " 密码       $PASS"
echo " 客户名     $NAME"
echo " 客户 ID    $CID"
echo
echo " 客户登录后直接看到「能耗概览」，左侧 13 项菜单全部可用。"
echo " 演示数据可以随时清空：客户「平台自检」或租户调"
echo "   DELETE /api/energy/demo-data?customerId=$CID"
echo
echo "------------------------------------------------------------"
echo " 数据落在哪些表（均可直接用客户 ID 查）"
echo "------------------------------------------------------------"
cat <<'TABLES'

  customer            客户主体（title = 客户名）
  tb_user             客户管理员账号（authority = CUSTOMER_USER）
  user_credentials    密码哈希（bcrypt）

  asset               资产：场站 2 / 分项 12 / 维度根 4 / 拓扑图 2 / 分类树节点
  device              设备 21 台（19 普通 + 2 虚拟）
  device_credentials  每台设备一个接入令牌（默认 ACCESS_TOKEN）
  relation            实体关系，type = 'Contains'（拓扑连线写的就是这张表）
  attribute_kv        属性（SERVER_SCOPE）：分项归属 / 层级 / 站点 id
  ts_kv               遥测（按月分区）：energy / energy_reading / power …

  dashboard           20 个看板副本（customer_id = 该客户，不是 assigned_customers）
  custom_menu         客户菜单 13 项（归属走 customer.custom_menu_id → custom_menu.id）
  entity_group        可选：按场站授权时才有（场站级用户）
  group_permission    可选：同上

TABLES
echo "------------------------------------------------------------"
echo " 常用查询 SQL（把 <CID> 换成上面的客户 ID）"
echo "------------------------------------------------------------"
cat <<SQL

-- 客户总览：一行看全
SELECT c.title AS 客户,
       (SELECT count(*) FROM asset  WHERE customer_id = c.id AND type='场站')    AS 场站,
       (SELECT count(*) FROM asset  WHERE customer_id = c.id AND type='分项')    AS 分项,
       (SELECT count(*) FROM device WHERE customer_id = c.id)                    AS 设备,
       (SELECT count(*) FROM asset  WHERE customer_id = c.id AND type='topology') AS 拓扑,
       (SELECT count(*) FROM dashboard WHERE customer_id = c.id)                 AS 看板,
       (SELECT count(*) FROM tb_user WHERE customer_id = c.id)                   AS 用户
FROM customer c WHERE c.id = '<CID>';

-- 场站清单
SELECT id, name, label FROM asset
WHERE customer_id = '<CID>' AND type = '场站' ORDER BY name;

-- 设备清单（含是否虚拟、所属分项）
SELECT d.name, d.type,
       (d.additional_info::jsonb->>'deviceVirtual') AS 虚拟,
       (d.additional_info::jsonb->>'siteId')        AS 场站ID
FROM device d WHERE d.customer_id = '<CID>' ORDER BY d.name;

-- 某台设备的接入令牌（发给现场装 RTU 用）
SELECT d.name, dc.credentials_id, dc.credentials_type
FROM device d JOIN device_credentials dc ON dc.device_id = d.id
WHERE d.customer_id = '<CID>' ORDER BY d.name;

-- 遥测数据量（ts_kv 按月分区，必须查分区）
SELECT count(*) AS 数据点, min(ts) AS 最早, max(ts) AS 最新
FROM ts_kv WHERE entity_id IN (SELECT id FROM device WHERE customer_id = '<CID>');

-- 最近 24 小时的遥测（抽查上报是否正常）
SELECT to_timestamp(ts/1000) AS 时间, key, dbl_v AS 值
FROM ts_kv
WHERE entity_id IN (SELECT id FROM device WHERE customer_id = '<CID>')
  AND key = 'energy' AND ts > (extract(epoch from now()) - 86400) * 1000
ORDER BY ts DESC LIMIT 20;

-- 拓扑图与它挂的场站
SELECT id, name, label, additional_info::jsonb->>'siteId' AS 场站ID
FROM asset WHERE customer_id = '<CID>' AND type = 'topology';

-- 客户菜单项（13 项）
SELECT cm.id, cm.name, jsonb_array_length(cm.config::jsonb->'items') AS 菜单项数
FROM customer c JOIN custom_menu cm ON cm.id = c.custom_menu_id
WHERE c.id = '<CID>';

-- 复制给客户的看板
SELECT title FROM dashboard WHERE customer_id = '<CID>' ORDER BY title;

-- 清理这个客户的全部演示数据（保留客户与账号）
-- 只删 additionalInfo.demo=true 的实体，客户自建的不受影响
DELETE FROM relation WHERE from_id IN (
    SELECT id FROM asset  WHERE customer_id='<CID>' AND additional_info::jsonb->>'demo'='true'
    UNION ALL
    SELECT id FROM device WHERE customer_id='<CID>' AND additional_info::jsonb->>'demo'='true'
);
-- 更稳妥的做法是走接口：DELETE /api/energy/demo-data?customerId=<CID>

SQL
echo

# 交付信息写一份到部署目录，方便反复入驻时回看
REPORT="$HERE/../ONBOARDED-$CID.txt"
{
  echo "# 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
  echo "客户    $NAME"
  echo "账号    $EMAIL"
  echo "密码    $PASS"
  echo "客户ID  $CID"
  echo "端口    $BASE"
} > "$REPORT" 2>/dev/null && chmod 600 "$REPORT" 2>/dev/null || true
# ★ $REPORT 后面紧跟中文括号，必须写 ${REPORT} —— macOS bash 3.2 会把
#   中文字节当成变量名的一部分，报 "${REPORT（权限: unbound variable"。
#   本项目已踩过多次（知识库 06-环境速查「macOS bash 3.2」）。
[[ -f "$REPORT" ]] && echo " 交付信息已写入：${REPORT}（权限 600）"
echo
