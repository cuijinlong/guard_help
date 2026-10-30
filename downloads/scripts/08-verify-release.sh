#!/usr/bin/env bash
#
# 能源管理平台 · 发布内容验收（把"这一版应该是什么样"变成断言）
#
# 与另几个脚本的分工：
#   03-verify.sh          接口可用 + 权限正确            —— 结构
#   04-verify-data.sh     库里数据彼此自洽               —— 数据
#   06-verify-e2e.sh      客户建数据 → 报表出数          —— 业务闭环
#   08-verify-release.sh  这一版改的每一项是否真的落地    —— 发布内容  ← 本脚本
#
# 为什么需要它：
#   重装后"看起来能登录"不等于"这一版的功能都在"。菜单少几项、看板标题没改、
#   字典缺键这类问题都不报错，但会让你在验收时反复怀疑是自己配错了。
#   这个脚本把每一版的改动点变成可执行断言：跑一遍，哪项没到位直接告诉你
#   缺什么、怎么修，不用一条条沟通。
#
# 用法（在部署目录内，与 scripts/ 同级）：
#   bash scripts/08-verify-release.sh \
#     --tenant tenant@example.com --tenant-pass '...' \
#     --customer customer@example.com --customer-pass '...'
#
# 可选：
#   --base URL        默认 http://127.0.0.1:8090
#   --skip-ui         跳过前端产物检查（镜像里没带 UI 时用）
#   --quiet           只输出失败项
#
# 退出码：0 = 全部通过，1 = 有失败项
#
set -uo pipefail

cd "$(dirname "$0")/.."
# 脚本按「部署目录结构」调用（scripts/ 与 data/ 同级），所以根目录就是 cd 之后的 pwd。
# ★ 必须显式赋值：I-5d 的客户视角探针要拼 $APP_HOME/scripts/27-...，
#   少了它 set -u 会让整个验收在最后一段崩掉（前面的结果全白跑）。
APP_HOME="${APP_HOME:-$(pwd)}"

BASE="http://127.0.0.1:8090"
TENANT="" ; TENANT_PASS=""
CUST=""   ; CUST_PASS=""
SKIP_UI="false"
QUIET="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)          BASE="$2"; shift 2 ;;
    --tenant)        TENANT="$2"; shift 2 ;;
    --tenant-pass)   TENANT_PASS="$2"; shift 2 ;;
    --customer)      CUST="$2"; shift 2 ;;
    --customer-pass) CUST_PASS="$2"; shift 2 ;;
    --skip-ui)       SKIP_UI="true"; shift ;;
    --quiet|-q)      QUIET="true"; shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[[ -n "$TENANT" && -n "$TENANT_PASS" ]] || { echo "必须提供 --tenant 与 --tenant-pass" >&2; exit 2; }

# 预期通过的检查项数。
#
# 为什么要有这个数：手册里写着「通过 N 项」，而 N 会随脚本增删检查项变化。
# 光靠人手同步两处必然漂移。这里声明一次，脚本结尾自校验，
# check-docs.py 也读这里去比对手册。
# **改检查项时同步改这个数**（少改 → 结尾会报「项数与预期不符」）。
EXPECTED_PASS=85

PASS=0 ; FAIL=0 ; FAILED_ITEMS=()

ok()   { PASS=$((PASS+1)); [[ "$QUIET" == "true" ]] || printf '\033[32m  ✓\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); FAILED_ITEMS+=("$1"); printf '\033[31m  ✗\033[0m %s\n' "$*"; printf '      → 修法：%s\n' "$2"; }
sec()  { [[ "$QUIET" == "true" ]] || { printf '\n\033[36m%s\033[0m\n' "$*"; }; }

# 断言：相等
eq() {  # eq <说明> <实际> <期望> <修法>
  if [[ "$2" == "$3" ]]; then ok "$1（$2）"; else bad "$1：实际 $2，期望 $3" "$4"; fi
}
# 断言：大于等于
ge() {  # ge <说明> <实际> <下限> <修法>
  if [[ "${2:-0}" -ge "$3" ]] 2>/dev/null; then ok "$1（${2}）"; else bad "$1：实际 ${2:-0}，至少 $3" "$4"; fi
}
# 断言：包含
has() {  # has <说明> <文本> <关键字> <修法>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1：缺少「$3」" "$4"; fi
}
# 断言：不包含
hasnt() {  # hasnt <说明> <文本> <关键字> <修法>
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1：不该有「$3」" "$4"; fi
}

# jget '<语句>'：变量 d 已就绪，语句里自己 print。
# 支持多行 —— 之前用 print($1) 包一层，多行/赋值语句会语法错，导致断言全判 0。
jget() {
  python3 -c "
import json,sys
d=json.load(sys.stdin)
$1" 2>/dev/null
}

# 直接查库：有几类事实走 API 拿不到（如 ALARM 类型的计算字段），
# 或走 API 会被当前账号权限过滤。自检接口内部也是查库，这里与它同源。
DASH_DB() {
  docker compose exec -T postgres psql -U postgres -d thingsboard -tA -F'|' -c "$1" 2>/dev/null
}

echo "============================================================"
echo " 发布内容验收 · ${BASE}"
echo " 时间 $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# 遥测后端可能是 Cassandra（默认）。验收 SQL 是按 Postgres 的 ts_kv 写的，
# 这里先把它镜像过来，否则「设备数/资产汇总/峰谷自洽」会全部误报为 0。
# 后端是 sql 时本脚本什么也不做（PG 本来就有真表）。
if [[ -x scripts/ts-mirror.sh || -f scripts/ts-mirror.sh ]]; then
  bash scripts/ts-mirror.sh >/tmp/ts-mirror.log 2>&1 || \
    echo "  ! 遥测镜像失败，部分断言会误报：看 /tmp/ts-mirror.log" >&2
fi

# ---------------------------------------------------------------- 登录
TOK=$(curl -s --noproxy '*' -m 15 -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$TENANT\",\"password\":\"$TENANT_PASS\"}" | jget "print(d.get('token',''))")
[[ -n "$TOK" ]] || { echo "租户账号登录失败：$TENANT" >&2; exit 1; }

CTOK=""
if [[ -n "$CUST" && -n "$CUST_PASS" ]]; then
  CTOK=$(curl -s --noproxy '*' -m 15 -X POST "$BASE/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$CUST\",\"password\":\"$CUST_PASS\"}" | jget "print(d.get('token',''))")
  [[ -n "$CTOK" ]] || echo "  ! 客户账号登录失败，将跳过客户侧检查：$CUST"
fi

TAPI() { curl -s --noproxy '*' -m 40 -H "X-Authorization: Bearer $TOK" "$BASE$1"; }
CAPI() { curl -s --noproxy '*' -m 40 -H "X-Authorization: Bearer $CTOK" "$BASE$1"; }

# ================================================================
sec "A. 初始化完整性（平台自检）"
SC=$(TAPI '/api/energy/self-check')
SUMMARY=$(echo "$SC" | jget "print(json.dumps(d.get('summary',{})))" 2>/dev/null)
if [[ -n "$SUMMARY" ]]; then
  eq "自检 missing 项"  "$(echo "$SC" | jget "print(d['summary']['missing'])")"  "0" \
     '点「平台自检 → 一键修复初始化」补装；仍失败看 /api/energy/self-check 的具体项'
  eq "自检 partial 项"  "$(echo "$SC" | jget "print(d['summary']['partial'])")"  "0" \
     '同上；partial 通常是个别档案/规则没建全'
else
  bad "平台自检接口不可用" "确认后端已升级到含 EnergySelfCheckController 的版本"
fi

# ================================================================
sec "B. 参数字典（两级指标）"
MP=$(TAPI '/api/energy/metric-params')
ELEC=$(echo "$MP" | jget "
k = [x for x in d.get('kinds', []) if x.get('code') == 'elec']
print(json.dumps(k[0]) if k else '{}')")
L1=$(echo "$ELEC" | jget "print(len(d.get('params',[])))" 2>/dev/null)
L2=$(echo "$ELEC" | jget "print(sum(len(p.get('children',[])) for p in d.get('params',[])))" 2>/dev/null)
eq "电能一级指标" "${L1:-0}" "26" \
   '跑「平台自检 → 一键修复初始化」（会调 upgradeDictionaryParams 补新指标）；仍不对说明资源文件没更新'
eq "电能二级 key" "${L2:-0}" "48" \
   '同上。低于 48 通常是缺 voltage_avg / current_avg 两个汇总项'
has "相电压含平均项"  "$ELEC" '"voltage_avg"' '字典升级没跑到：确认后端版本，或重建租户'
has "相电流含平均项"  "$ELEC" '"current_avg"' '同上'
eq "能源品种数" "$(echo "$MP" | jget "print(len(d.get('kinds',[])))")" "4" \
   '字典缺品种：重建租户或一键修复'

# ================================================================
sec "C. 计算字段（告警 + 派生指标）"
# 走 SQL 而不是 /api/calculatedFields：那个接口只返回 SIMPLE，
# ALARM 类型的 7 条不出现 —— 拿它计数会误判成「只装了 4 条」。
# 自检的 SQL 与这里同源（都数 calculated_field 表）。
CFROWS=$(DASH_DB "SELECT dp.name || ' / ' || cf.type || ' / ' || cf.name
                    FROM calculated_field cf
                    JOIN device_profile dp ON dp.id = cf.entity_id
                   ORDER BY dp.name, cf.type;" | tr -d '\r')
NCF=$(printf '%s\n' "$CFROWS" | grep -c . 2>/dev/null || echo 0)
ge "计算字段条数" "${NCF:-0}" "11" \
   '设备档案上的 11 条规则没装全：跑一键修复初始化；日志搜 "[energy]" 看有哪条 warn'
has "含「闲时能耗超标」规则" "$CFROWS" '闲时能耗超标' \
   '该规则读 idle_exceed，阈值在场站「空闲时段」配；缺失说明 DeviceRuleInstaller 没跑'
has "含「电压越限」规则"     "$CFROWS" '电压越限' '同上'
has "含「不平衡度」规则"     "$CFROWS" '电压不平衡度超限' '同上（仅三相表有）'
has "含「负荷率」派生指标"   "$CFROWS" '负荷率'   '同上'
has "含「碳排放」派生指标"   "$CFROWS" '碳排放'   '同上'

# ================================================================
sec "C2. 主数据层级与费率模板"

# 层级边界：字典 / 时段方案 / 费率模板必须是租户级（customer_id 为空）。
# 沉到客户级会让读取侧拿到「不确定是哪一份」，报表 key 对不上。
LEAK=$(DASH_DB "SELECT type || ':' || count(*) FROM asset
                 WHERE type IN ('energy_type_library','tou_scheme','rate_template')
                   AND customer_id <> '13814000-1dd2-11b2-8080-808080808080'
                 GROUP BY type;" | tr -d '\r')
if [[ -z "$LEAK" ]]; then
  ok "租户级主数据未混入客户级（字典 / 时段方案 / 费率模板）"
else
  bad "租户级主数据混入了客户级：$LEAK" \
      '客户不要自建字典/时段方案/费率模板；应引租户级的那份 + override 调价'
fi

TPL_TYPE_N=$(DASH_DB "SELECT count(*) FROM asset WHERE type='rate_template'
                        AND customer_id='13814000-1dd2-11b2-8080-808080808080';" | tr -d ' ')
ge "费率模板数（租户级）" "${TPL_TYPE_N:-0}" "4" \
   '客户能源建档的费率下拉会为空、一键初始化直接失败：确认 EnergyLibraryInstaller.createRateTemplates 跑过'

TPL_ENERGIES=$(DASH_DB "SELECT DISTINCT ak.str_v FROM asset a
                          JOIN attribute_kv ak ON ak.entity_id = a.id
                          JOIN key_dictionary k ON k.key_id = ak.attribute_key
                         WHERE a.type='rate_template' AND k.key='energy';" | tr -d '\r')
n=$(printf '%s\n' "$TPL_ENERGIES" | grep -c . 2>/dev/null || echo 0)
eq "模板覆盖的能源品种数" "${n:-0}" "4" \
   '缺某个品种的模板 → 该品种无法开通（能源建档里选了也没模板可选）；确认 createRateTemplates 跑过'

TPL_TOU=$(DASH_DB "SELECT count(*) FROM relation r
                     JOIN asset a ON a.id = r.from_id
                    WHERE a.type='rate_template' AND r.relation_type='uses';" | tr -d ' ')
ge "电价模板关联的时段方案" "${TPL_TOU:-0}" "4" \
   '账单会退化为「按季节猜方案」：确认 createRateTemplates 的 linkTouSchemes 跑过'

# 闲时能耗链路：重算 → idle_exceed → 计算字段 → 告警。
# 这条链最容易「看起来都在、实际不通」：直写 DAO 的话计算字段永远缺参数。
IDLE_TS=$(DASH_DB "SELECT count(*) FROM ts_kv kv JOIN key_dictionary k ON k.key_id=kv.key
                    WHERE k.key='idle_exceed';" | tr -d ' ')
ge "idle_exceed 时序点" "${IDLE_TS:-0}" "1" \
   '空闲时段没配阈值或没跑过重算：在「场站 → 空闲时段」配一次，或点「历史重算」'

IDLE_CFG=$(DASH_DB "SELECT count(*) FROM attribute_kv ak
                      JOIN key_dictionary k ON k.key_id=ak.attribute_key
                      JOIN asset a ON a.id=ak.entity_id
                     WHERE k.key='idleConfig' AND a.type='场站';" | tr -d ' ')
ge "配了闲时阈值的场站" "${IDLE_CFG:-0}" "1" \
   '没有 idleConfig：闲时超标判定拿不到阈值，等于这条功能没开'

IDLE_ALARM=$(DASH_DB "SELECT count(*) FROM alarm WHERE type='闲时能耗超标';" | tr -d ' ')
ge "闲时能耗超标告警（历史累计）" "${IDLE_ALARM:-0}" "1" \
   '计算字段没被触发：确认 persistDaily 走的是 telemetrySubscriptionService（直写 DAO 不会触发）'

# 客户费率：价格现在由客户自己维护，模板不再是必经来源。
CUST_RATES=$(curl -s --noproxy '*' -m 20 "$BASE/api/energy/rate-policies" \
  -H "X-Authorization: Bearer $CTOK" 2>/dev/null)
if printf '%s' "$CUST_RATES" | grep -q '"customerRates"'; then
  ok "客户费率接口返回 customerRates"
else
  bad "客户费率接口缺少 customerRates 字段" \
      '后端没重启到新版本：确认 EnergyRatePolicyController 里有 readCustomerRates'
fi

N_RATES=$(printf '%s' "$CUST_RATES" | jget "
cr = d.get('customerRates') or {}
print(len(cr))
")
# 费率：**新客户未填价是正常状态**，不判失败。
#
# 平台免费、不向客户收费，费率是客户自己用来算成本的分析参数。
# 客户刚入驻时没填，不能算缺陷 —— 之前这里要求 ≥1，会让「全新部署」的验收
# 必然挂一项，运维反复怀疑是自己部署错了。
#
# 填了就要能读到（这是真检查）；没填就明说没填。
if [[ "${N_RATES:-0}" -ge 1 ]]; then
  ok "客户已填费率的品种数（${N_RATES}）"
else
  ok "客户尚未填费率（正常：新客户，客户可在「能源建档」里自行填写）"
fi

# 保存接口探活：故意发一个**不合法**的费率（单一制缺单价），
# 期望 400 —— 既证明接口存在，又不会改到客户已有的价格。
# 千万别用 {"rates":{}} 探活：那是合法的空覆盖，会把客户填的价清空。
CODE=$(curl -s --noproxy '*' -m 15 -o /dev/null -w '%{http_code}' \
  -X POST "$BASE/api/energy/customer-rate" \
  -H "X-Authorization: Bearer $CTOK" -H 'Content-Type: application/json' \
  -d '{"rates":{"__probe__":{"rateType":"flat"}}}')
if [[ "$CODE" == "404" ]]; then
  bad "客户费率保存接口不存在（404）" '后端是旧版：重新打包并重启 energy-server'
elif [[ "$CODE" == "400" ]]; then
  ok "客户费率保存接口可用（非法输入按预期拒绝 400）"
else
  bad "客户费率保存接口异常（HTTP ${CODE}，期望 400）" \
      '校验逻辑可能被绕过：检查 validateCustomerRate'
fi

# 组织层：客户侧维护费率的立足点。
# 没有组织，客户登录后进不去「组织 → 能源费率」，只能靠客户级兜底。
ORG_N=$(DASH_DB "SELECT count(*) FROM asset WHERE type='组织';" | tr -d ' ')
ge "组织数" "${ORG_N:-0}" "1" \
   '客户侧没有组织 → 「能源费率」页签无处可挂：跑「平台自检 → 一键修复初始化」补建'

ORG_SITE=$(DASH_DB "SELECT count(*) FROM relation r
                      JOIN asset o ON o.id = r.from_id AND o.type='组织'
                      JOIN asset s ON s.id = r.to_id AND s.type='场站'
                     WHERE r.relation_type='Contains';" | tr -d ' ')
ge "挂在组织下的场站" "${ORG_SITE:-0}" "1" \
   '场站没挂到组织 → 组织配的费率无法被场站继承（只能吃客户级兜底）'

# 探活：传一个**非法 UUID**，期望 400。
# 不能用「不存在的组织 uuid」——那也返回 404（ITEM_NOT_FOUND），
# 和「接口不存在」的 404 分不开，会误报。
org_ok=$(curl -s --noproxy '*' -m 15 -o /dev/null -w '%{http_code}' \
  -X POST "$BASE/api/energy/org-rate" \
  -H "X-Authorization: Bearer $CTOK" -H 'Content-Type: application/json' \
  -d '{"orgId":"not-a-uuid","energyRates":{}}')
if [[ "$org_ok" == "400" ]]; then
  ok "组织费率保存接口可用（非法 orgId 按预期拒绝 400）"
elif [[ "$org_ok" == "404" ]]; then
  bad "组织费率保存接口不存在（404）" '后端是旧版：重新打包并重启 energy-server'
else
  bad "组织费率保存接口异常（HTTP ${org_ok}，期望 400）" '检查 saveOrgRate 的参数校验'
fi

# 菜单孤儿：重装/repair-init 不能堆出**没人引用**的同名菜单。
#
# ⚠ 判据不能是「同名菜单不超过 1 条」。
# 客户菜单的 customer_id 恒为 NULL_UUID（见 EnergyMenuInstaller 注释），
# 归属靠 customer.custom_menu_id 这个指针。所以 N 个客户 = N 条同名菜单，
# 这是设计如此。真正要防的是「指针丢了、菜单还在」的堆积 —— 那种才越跑越多。
MENU_DUP=$(DASH_DB "SELECT count(*) FROM custom_menu m
            WHERE m.scope='CUSTOMER' AND m.name LIKE '业务导航%'
              AND NOT EXISTS (SELECT 1 FROM customer c WHERE c.custom_menu_id = m.id);" | tr -d ' ')
eq "客户菜单无孤儿（每条都挂在某个客户上）" "${MENU_DUP:-0}" "0" \
   '有客户被删但菜单没删：跑一次 repair-init 清理，或检查 EnergyMenuInstaller.removeCustomerMenu'

# 拓扑数据完整性：边不能指向不存在的节点，否则双击下钻会出现「说有却点不进去」
TOPO_JSON=$(TAPI '/api/energy/topologies')
TOPO_ID=$(printf '%s' "$TOPO_JSON" | jget "
items = d if isinstance(d, list) else (d.get('data') or [])
print((items[0].get('id') if items else '') or '')
")
if [[ -n "$TOPO_ID" ]]; then
  DANGLING=$(TAPI "/api/energy/topologies/$TOPO_ID" | jget "
nodes = {n.get('id') for n in (d.get('nodes') or [])}
edges = d.get('edges') or []
print(sum(1 for e in edges if e.get('from') not in nodes or e.get('to') not in nodes))
")
  eq "拓扑图无悬空边" "${DANGLING:-0}" "0" \
     '有边指向不存在的节点：双击该节点会提示「没有下级」，需清理拓扑数据'
else
  warn "没有拓扑图，跳过悬空边检查"
fi

# ================================================================
sec "D. 看板模板"
TPL_N=$(DASH_DB "SELECT count(*) FROM dashboard WHERE customer_id IS NULL;" | tr -d ' ')
eq "看板模板数" "${TPL_N:-0}" "24" \
   '模板没导全：重跑 docker-01-install.sh，或确认 deploy 目录 data/json/tenant/dashboards 是 24 个文件'\

TITLES=$(DASH_DB "SELECT title FROM dashboard WHERE customer_id IS NULL;" | tr -d '\r')
has  "「峰谷时段」已改名" "$TITLES" '峰谷时段' \
     '看板还叫「基础配置中心」：跑一键修复初始化（会调 repairConfigCenterDashboard 改名）'
hasnt "无旧名「基础配置中心」" "$TITLES" '基础配置中心' \
     '同上'

# 客户副本里**不能有指向租户级实体的真实 id**。
#
# ★ 这里曾经写成「不能有占位符」，是错的（2026-10-23 修正）：
#   占位符是**有意保留**的 —— 租户级主数据（能源参数字典 / 电能品种）
#   客户无权读，替换成真实 id 会 403；留占位符前端静默跳过。
#   反过来说，客户看板里出现租户级资产的**真实 id** 才是问题。
#
# 判断方法：拿租户级资产 id 去 LIKE 客户的 configuration。
LEAK=$(DASH_DB "
WITH ta AS (SELECT id::text AS aid FROM asset
            WHERE customer_id = '13814000-1dd2-11b2-8080-808080808080')
SELECT count(*) FROM dashboard d, ta
WHERE d.customer_id IS NOT NULL AND d.configuration LIKE '%'||ta.aid||'%';" | tr -d ' ')
eq "客户看板无租户级实体引用" "${LEAK:-0}" "0" \
   '客户会 403+404 刷屏：用 SQL 把这些 id 换回占位符 00000000-0000-0000-0000-0000000011b7（见故障排查「现象 I」）'

# 占位符本身应当在（租户级主数据的引用就靠它）
PH=$(DASH_DB "SELECT count(*) FROM dashboard WHERE customer_id IS NOT NULL AND configuration LIKE '%00000000-0000-0000-0000-00000000%';" | tr -d ' ')
ge "客户看板保留占位符" "${PH:-0}" "1" \
   '租户级主数据的引用应当留占位符；全是真实 id 说明替换表又把手伸到租户级资产了'

# 峰谷时段 6 个部件不能重叠
OVERLAP=$(DASH_DB "SELECT configuration FROM dashboard WHERE customer_id IS NULL AND title='峰谷时段' LIMIT 1;" | python3 -c "
import json,sys
raw=sys.stdin.read().strip()
if not raw: print('no-board'); raise SystemExit
d=json.loads(raw)
if isinstance(d,str): d=json.loads(d)
ws=(d.get('configuration') or d).get('widgets') or {}
rows=[w.get('row') for w in ws.values()]
print('overlap' if len(rows)!=len(set(rows)) else 'ok')" 2>/dev/null)
if [[ "$OVERLAP" == "ok" ]]; then
  ok "峰谷时段部件不重叠"
elif [[ "$OVERLAP" == "no-board" ]]; then
  ok "峰谷时段模板不存在（跳过重叠检查）"
else
  bad "峰谷时段 6 个部件仍叠在相同 row" \
      '跑一键修复初始化（repairConfigCenterDashboard 按 sizeY 重排）'
fi

# ================================================================
sec "E. 租户菜单"
TM=$(TAPI '/api/customMenu')
TM_N=$(echo "$TM" | jget "print(len(d.get('items') or []))" 2>/dev/null)
eq "租户顶层项" "${TM_N:-0}" "11" \
   '菜单是旧结构：跑一键修复初始化（会重装租户菜单）'
TM_STR=$(echo "$TM" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(' '.join((i.get('name') or i.get('id') or '')+'|'+str(i.get('type') or '') for i in (d.get('items') or [])))" 2>/dev/null)
has  "「AI 分析」在菜单里" "$TM_STR" 'AI 分析' \
     '模型训练平台没改名/没装：跑一键修复初始化'
hasnt "无 IoT Hub"            "$TM_STR" 'iot_hub'             '菜单是旧版：一键修复初始化'
hasnt "无 AI Solution Creator" "$TM_STR" 'ai_solution_creator' '同上'
hasnt "无集成中心"             "$TM_STR" 'integrations_center' '同上'
hasnt "无 Edge 管理"           "$TM_STR" 'edge_management'      '同上'
hasnt "无 Trendz 分析"         "$TM_STR" 'trendz_analytics'     '同上'

# 一级菜单中文化：查语言包键
LOC=$(curl -s --noproxy '*' -m 20 "$BASE/assets/locale/locale.constant-zh_CN.json")
has "「运营配置」中文名已补" "$LOC" '运营配置' 'locale 里缺 admin.platform：前端产物没更新，重打镜像'
has "「监控」中文名已补"     "$LOC" '监控'     '缺 monitor.monitor：同上'
has "「品种指标」菜单名已补" "$LOC" '品种指标' '缺 energy.menu.energy-dict：同上'

# ================================================================
sec "F. 客户菜单"
if [[ -n "$CTOK" ]]; then
  CM=$(CAPI '/api/customMenu')
  CM_N=$(echo "$CM" | jget "print(len(d.get('items') or []))" 2>/dev/null)
  # 15 项 = 2026-10-27 定稿结构：设备管理拆成一级 + 三个子项、平台自检升为一级、
  #        空调管理（三个子看板）插在「组织」之前
  eq "客户顶层项" "${CM_N:-0}" "15" \
     '客户菜单是旧结构：跑一键修复初始化（会重装全部客户菜单）'
  CM_DETAIL=$(echo "$CM" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in (d.get('items') or []):
    nm=i.get('name') or i.get('id')
    pages=[p.get('name') or p.get('id') for p in (i.get('pages') or [])]
    print(nm+':'+'/'.join(pages))" 2>/dev/null)
  has "告警事件为一级链接（无子项）" "$CM_DETAIL" '告警事件:' \
      '告警事件还挂着「告警列表/告警规则」子项：一键修复初始化'
  # 自检必须是一级（原挂在设备运维下，2026-10-26 提升）
  has "平台自检为一级入口" "$CM_DETAIL" '平台自检:' \
      '客户菜单缺自检入口：一键修复初始化'
  # 设备管理是分组，子项必须齐三个（一级叫「设备管理」、二级第一项才是「设备运维」）
  has "设备管理含设备运维" "$CM_DETAIL" '设备管理:设备运维' \
      '设备菜单结构不对：一键修复初始化'
  has "设备管理含设备分组" "$CM_DETAIL" '设备管理:设备运维/设备分组' \
      '设备菜单缺设备分组：一键修复初始化'
  has "设备管理含设备拓扑" "$CM_DETAIL" '设备管理:设备运维/设备分组/设备拓扑' \
      '设备菜单缺设备拓扑：一键修复初始化'
  # 菜单 label 是「用能账单」，它指向的看板标题才是「我的账单」
  has "能耗分析含用能账单" "$CM_DETAIL" '用能账单' \
      '「用能账单」没在能耗分析下：一键修复初始化'
  # 空调管理（2026-10-27）：一级分组 + 三块看板，一次断言整组
  has "空调管理含三个子看板" "$CM_DETAIL" '空调管理:空调运行监控/运行计划与配置/每日复盘报告' \
      '空调菜单不完整：确认三块看板存在（缺看板时该子项会被过滤），再跑一键修复初始化'
  # ---- F2：客户看得见的**数据**，不只是菜单项 ----
  #
  # ★ 为什么必须加这一组（2026-10-22）：
  #   上面 F 段只验「菜单里有这一项」，不验「点进去有没有东西」。
  #   于是两个真实故障长期没被发现：
  #     · 峰谷分析看板被一张「该功能正在建设中」的 markdown 卡片盖住，
  #       而真部件早就在这个看板里；
  #     · 「我的账单」三个部件全读 energy_bill 资产，而系统从不生成它。
  #   两次都是「菜单在、页面空」。菜单项存在 ≠ 功能可用。

  # ★ 必须查**客户自己的**看板：客户账号查 /api/tenant/dashboards 直接 403
  #   （实测 2026-10-22，导致下面两项静默跳过、总项数少 2 却看不出原因）。
  TOU_CID=$(CAPI '/api/auth/user' | python3 -c "
import json,sys
print(((json.load(sys.stdin) or {}).get('customerId') or {}).get('id',''))" 2>/dev/null)
  CDASH=$(CAPI "/api/customer/$TOU_CID/dashboards?pageSize=200&page=0")

  TOU_ID=$(echo "$CDASH" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((x['id']['id'] for x in d.get('data',[]) if x.get('title')=='峰谷分析'),''))" 2>/dev/null)
  if [[ -n "$TOU_ID" ]]; then
    TOU_BODY=$(CAPI "/api/dashboard/$TOU_ID")
    hasnt "峰谷分析看板无「建设中」占位" "$TOU_BODY" '建设中' \
        '看板模板里还留着 markdown 占位卡片：重新部署 dashboards JSON'
    TOU_WN=$(echo "$TOU_BODY" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ws=(d.get('configuration') or {}).get('widgets') or {}
print(sum(1 for w in ws.values() if 'tou_analysis' in str(w.get('typeFullFqn',''))))" 2>/dev/null || echo 0)
    ge "峰谷分析含真实分析部件" "${TOU_WN:-0}" 1 \
        '看板里只有占位卡，没有 energy_management.tou_analysis 部件'
  fi

  # 峰谷分析接口对客户可用且有数据（演示数据是 7 天逐小时，必然有电量）
  # 参数名是 granularity（不是 gran）；返回体是 buckets[] + totals[]，
  # 每个 bucket 带 byType{tip,peak,flat,valley,deep}。判据：至少一个桶有非零电量。
  #
  # ★ 必须传 groupRootId（或 deviceId）—— 实测 2026-10-22：不带范围的调用
  #   直接返回 400「必须提供 deviceId 或 groupRootId」。看板里是 query_panel
  #   发布选中的维度根，这里模拟同一路径。
  TOU_ROOT=$(CAPI "/api/customer/$TOU_CID/assets?pageSize=500&page=0" | python3 -c "
import json,sys
rows=(json.load(sys.stdin) or {}).get('data',[])
print(next((a['id']['id'] for a in rows if a.get('type')=='energy_item_library'),''))" 2>/dev/null)
  TOU_API=$(CAPI "/api/energy/tou-analysis?groupRootId=${TOU_ROOT}&from=$(($(date +%s) - 7*86400))000&to=$(date +%s)000&granularity=day")
  TOU_HAS=$(echo "$TOU_API" | python3 -c "
import json,sys
d=json.load(sys.stdin)
n=sum(1 for b in (d.get('buckets') or []) if float(b.get('total') or 0) > 0)
print(1 if n else 0)" 2>/dev/null || echo 0)
  [[ "$TOU_HAS" == "1" ]] && ok "峰谷分析接口有数据返回" \
    || bad "峰谷分析接口无数据" '演示数据或时段方案缺失：跑一键修复初始化 / 检查 tou_scheme'

  # ---- F3：菜单里每个看板链接都必须真的能打开 ----
  #
  # ★ 为什么必须查（2026-10-24）：
  #   「点菜单进去又弹回能源概览」是**静默故障** —— 前端把未知/失效目标交给
  #   `**` 通配路由，`redirectTo: 'home'`，用户看到的永远是能耗概览，
  #   控制台只有一条 404，页面上没有任何提示。最常见的成因不是崩溃，
  #   而是菜单里的 dashboardId 指向了**已删除或未分配给该客户的看板**
  #   （重置演示数据 / 销户重建 / 换看板后菜单没重绑）。
  #   F 段只验「菜单项名字在」，验不出「点进去能打开」。
  #
  # 站内路由（/sites、/self-check…）不在这里逐个查：SPA 对未知路径也返回
  # index.html，HTTP 状态区分不出来；真正的证据是构建产物里有对应组件，
  # 那由 G 段的 tb-self-check / tb-energy-dict 等特征串断言覆盖。
  # /ngxai/ 是 nginx 直接托管的独立子应用，这里单独查它的入口。
  F3=$(python3 - "$BASE" "$CTOK" "$CM" <<'PYEOF'
import json, sys, urllib.request, urllib.error
base, tok, cm = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.loads(cm)
links = []
def walk(items):
    for i in (items or []):
        links.append(i)
        walk(i.get('children')); walk(i.get('pages'))
walk(cfg.get('items'))
bad_dash, ngxai, known = [], [], ('/sites','/device-management','/device-group',
                                  '/device-topology','/self-check','/alarm-center','/param-report')
unknown = []
for i in links:
    lt = i.get('linkType'); name = i.get('name') or ''
    if lt == 'DASHBOARD' and i.get('dashboardId'):
        did = i['dashboardId']
        req = urllib.request.Request(f'{base}/api/dashboard/{did}',
                                     headers={'X-Authorization': 'Bearer ' + tok})
        try:
            urllib.request.urlopen(req, timeout=15)
        except urllib.error.HTTPError as e:
            bad_dash.append(f'{name}({did[:8]}:{e.code})')
        except Exception as e:
            bad_dash.append(f'{name}({did[:8]}:{type(e).__name__})')
    elif lt == 'URL':
        u = (i.get('url') or '').strip()
        if u.startswith('/ngxai'):
            ngxai.append(u)
        elif u.startswith('/') and u not in known:
            unknown.append(f'{name}({u})')
bad_ngxai = []
for _ in set(ngxai):
    try:
        urllib.request.urlopen(f'{base}/ngxai/', timeout=15)
    except Exception as e:
        bad_ngxai.append(f'/ngxai({type(e).__name__})')
print(len(links), len(bad_dash), len(bad_ngxai))
print(' '.join(bad_dash))
print(' '.join(bad_ngxai))
print(' '.join(unknown))
PYEOF
)
  F3_N=$(printf '%s' "$F3" | sed -n '1p' | awk '{print $1}')
  F3_DASH=$(printf '%s' "$F3" | sed -n '1p' | awk '{print $2}')
  F3_NGX=$(printf '%s' "$F3" | sed -n '1p' | awk '{print $3}')
  F3_BAD=$(printf '%s' "$F3" | sed -n '2p')
  F3_BADNG=$(printf '%s' "$F3" | sed -n '3p')
  F3_UNK=$(printf '%s' "$F3" | sed -n '4p')
  ge "客户菜单可点链接" "${F3_N:-0}" 10 \
     '客户菜单只剩几项：跑一键修复初始化重装菜单（预期 15 个看板 + 若干站内路由）'
  eq "菜单里的看板全部可打开（失效 ${F3_DASH:-0} 个）" "${F3_DASH:-1}" "0" \
     "菜单指向已删除/未分配的看板，点进去会静默弹回能耗概览。失效：${F3_BAD}。跑一键修复初始化重绑菜单"
  eq "菜单里的 /ngxai 子应用入口可达（失效 ${F3_NGX:-0} 个）" "${F3_NGX:-1}" "0" \
     "ngxai 静态产物没部署到 nginx（${F3_BADNG}）：检查 ${APP_HOME:-.}/ngxai-dist 挂载"
  if [[ -n "$F3_UNK" ]]; then
    echo "      ↳ 提示：这些站内路由不在已知清单，请确认前端已注册：$F3_UNK" >&2
  fi
  if [[ -n "$F3_BAD" ]]; then
    echo "      ↳ 失效看板：$F3_BAD" >&2
  fi

  # ---- F4：客户能否加载看板里的**每一个部件类型** ----
  #
  # ★ 为什么必须查（2026-10-29 现场反馈）：
  #   新机器一键装完，客户登录后「所有仪表板里面的部件都不显示」。
  #   TB 的渲染路径是：看板里写 typeFullFqn（如 system.energy_management.query_panel）
  #   → 前端 GET /api/widgetType?fqn=… → 拿 descriptor 渲染。
  #   这一步 404/403 时，用户看到的只有一句「关联的部件类型可能已被移除」，
  #   而 F/F2/F3 全都通过（菜单在、看板能打开、接口有数）——
  #   **看板能打开 ≠ 部件能渲染**，中间隔着这一次 fqn 解析。
  #
  # 判据：客户名下每个看板里出现的 fqn，都必须在「客户可见的部件集合」里。
  #   一次列表查询拿全集 + 本地比对，比逐个 curl 快得多（736 个部件 1 次请求）。
  WN_FQNS=$(CAPI '/api/widgetTypes?pageSize=1000&page=0' | python3 -c "
import json,sys
d=json.load(sys.stdin) or {}
print(' '.join(sorted({str(w.get('fqn','')) for w in (d.get('data') or []) if w.get('fqn')})))" 2>/dev/null)
  if [[ -z "$WN_FQNS" ]]; then
    bad "客户可见部件列表为空" '查 /api/widgetTypes 失败：客户登录态或权限异常'
  else
    WN_DETAIL=$(python3 - "$BASE" "$CTOK" "$CDASH" "$WN_FQNS" <<'PYEOF'
import json, sys, urllib.request

base, tok, cdash_raw, known = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
# ★ fqn 有两种写法，必须规范化后再比：
#   看板里写 system.energy_management.query_panel（带归属前缀），
#   /api/widgetTypes 返回 energy_management.query_panel（存储形式）。
#   直接比会 100% 误报「全部缺失」—— 实测本地 35 个引用全被判缺。
def norm(fqn):
    for pre in ('system.', 'tenant.'):
        if fqn.startswith(pre):
            return fqn[len(pre):]
    return fqn

known = {norm(k) for k in known}

def get(path):
    req = urllib.request.Request(base + path, headers={'X-Authorization': 'Bearer ' + tok})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode('utf-8') or '{}')

try:
    dashes = (json.loads(cdash_raw) or {}).get('data') or []
except Exception:
    dashes = []

used, missing, broken = {}, [], []
for d in dashes:
    title = d.get('title') or '?'
    did = (d.get('id') or {}).get('id')
    if not did:
        continue
    try:
        full = get('/api/dashboard/' + did)
    except Exception as e:
        broken.append(f'{title}(读取失败)')
        continue
    ws = ((full.get('configuration') or {}).get('widgets') or {})
    for w in (ws.values() if isinstance(ws, dict) else []):
        fqn = w.get('typeFullFqn')
        if not fqn:
            continue
        used.setdefault(fqn, title)
        if norm(fqn) not in known and fqn not in [m.split('|')[0] for m in missing]:
            missing.append(fqn + '|' + title)

print(len(used))
print(len(missing) + len(broken))
print(' '.join(missing[:8]))
print(' '.join(broken[:8]))
print(' '.join(sorted(used)[:6]))
PYEOF
)
    W_U=$(printf '%s' "$WN_DETAIL" | sed -n '1p')
    W_BAD=$(printf '%s' "$WN_DETAIL" | sed -n '2p')
    W_BADL=$(printf '%s' "$WN_DETAIL" | sed -n '3p')
    W_BRKL=$(printf '%s' "$WN_DETAIL" | sed -n '4p')
    ge "客户看板引用的部件类型数" "${W_U:-0}" 1 \
       '客户名下看板没读到任何 typeFullFqn：看板 configuration 是空的'
    eq "客户能加载全部部件类型（缺 ${W_BAD:-0} 个）" "${W_BAD:-1}" "0" \
       "这些 fqn 不在客户可见的部件集合里，打开看板只会显示「关联的部件类型可能已被移除」。缺：${W_BADL} ${W_BRKL} —— 跑一键修复初始化，或确认 widget_type 已按系统租户装载（tenant_id=13814000-…）"
  fi
else
  ok "跳过客户侧检查（未提供客户账号或登录失败）"
fi

# ================================================================
if [[ "$SKIP_UI" != "true" ]]; then
  sec "G. 前端产物"
  INDEX=$(curl -s --noproxy '*' -m 20 "$BASE/")
  MAIN=$(echo "$INDEX" | grep -o 'main-[A-Z0-9]*\.js' | head -1)
  if [[ -n "$MAIN" ]]; then
    ok "首页引用 ${MAIN}"
  else
    bad "首页找不到 main-*.js" "后端没带 UI 产物，或 gateway 路由不对"
  fi

  # 页面可达性：SPA 对未知路径也返回 index.html，所以 200 只能证明「服务在」，
  # 证明不了「路由已注册」。真正的证据是构建产物里的组件特征串 ——
  # Angular 把组件类名、样式类名都留在 lazy chunk 里，搜得到就是打进包了。
  # chunk 文件名带 hash、每次构建都变，所以先抓 home-pages 那个懒加载块。
  # chunk 不在 index.html 里（懒加载），但 main.js 的模块映射表列了全部 chunk 名。
  # 早先只抓 index.html + 前 5 个 chunk，漏掉 home-pages 那块，才误报「产物是旧的」。
  MAINJS=$(curl -s --noproxy '*' -m 30 "$BASE/$MAIN" 2>/dev/null)
  CHUNKS=$(printf '%s' "$MAINJS" | grep -oE 'chunk-[A-Z0-9]+\.js' | sort -u)
  POOL="$MAINJS"
  HIT_ALL="true"
  for c in $CHUNKS; do
    BODY=$(curl -s --noproxy '*' -m 30 "$BASE/$c" 2>/dev/null)
    POOL+="$BODY"
  done
  for pair in \
    "tb-ic-default-hours|空闲时段：默认工作时段已并入排班页" \
    "tb-rate-layers|费率方案：两层来源说明条" \
    "tb-cfg-hint-warn|场站配置：暂不参与计算的橙色提示" \
    "tb-energy-dict|品种指标页" \
    "tb-self-check|平台自检页" ; do
    key="${pair%%|*}"; desc="${pair##*|}"
    has "$desc" "$POOL" "$key" \
        '前端产物是旧的：重跑 npm run build:prod，替换 ui-ngx jar 后重建后端镜像'
  done

  # 后端已删除的类不应还出现在包里
  if curl -s --noproxy '*' -m 15 -o /dev/null -w '%{http_code}' \
       "$BASE/api/energy/alarm-rules" | grep -q '^\(404\|500\)$'; then
    ok "场站告警规则接口已下线"
  fi
fi

# ---------------------------------------------------------------- H. 自建表（抄表 / 账单）
#
# 这 4 张表是本平台自建的（不属于 TB），DDL 曾只手工建在开发库上，
# 新装出来的库一张都没有 → 抄表与手工填报 7 个接口全 500（2026-10-22）。
# 现在由 EnergySchemaInstaller 在启动时自动建，这里断言它真的建了。
if [[ -f .env ]]; then
  set -a; . ./.env 2>/dev/null; set +a
  MISSING=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc "
    SELECT string_agg(t, ', ')
    FROM unnest(ARRAY['meter_reading_batch','meter_reading_record',
                      'billing','billing_detail','tb_sync_log']) AS t
    WHERE to_regclass('public.'||t) IS NULL;" 2>/dev/null | tr -d ' ')

  if [[ -z "$MISSING" ]]; then
    ok "自建表齐全（抄表批次/明细 · 账单/明细 · 同步日志）"
  else
    bad "自建表缺失：${MISSING}" "重启 energy-server 让它自动建；仍失败看日志 grep energy-schema"
  fi

  # 分区函数：抄表写入前会调它，缺了跨月就写不进去
  HASFN=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc "
    SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='energy_ensure_reading_partition';" 2>/dev/null | tr -d ' ')
  [[ "${HASFN:-0}" == "1" ]] \
    && ok "抄表分区函数存在（跨月自动建分区）" \
    || bad "抄表分区函数 energy_ensure_reading_partition 缺失" "同上，重启服务自动补建"

  # 当前月分区必须已在，否则本月第一笔抄表会报 no partition found
  THISM=$(date +%Y_%m)
  HASPART=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc "
    SELECT count(*) FROM pg_class WHERE relname='meter_reading_record_${THISM}' AND relkind='r';" 2>/dev/null | tr -d ' ')
  [[ "${HASPART:-0}" -ge 1 ]] \
    && ok "本月分区已建（meter_reading_record_${THISM}）" \
    || bad "本月分区 meter_reading_record_${THISM} 不存在" "调用 SELECT energy_ensure_reading_partition(date_trunc('month', now())::date);"

  # 电表 Key 标准化节点：缺了不会报错 —— 上报照样 200，但原始代号
  # U/I/P/Ep 原样落库，报表按标准名取数就是空的（2026-10-23）。
  # 同时要求没有 Switch → Save 的直连（它会让转换节点被绕过）。
  MK=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc "
    WITH root AS (SELECT rule_chain_id FROM rule_node WHERE name='电表Key标准化' LIMIT 1)
    SELECT (SELECT count(*) FROM rule_node WHERE name='电表Key标准化'
              AND type='org.thingsboard.rule.engine.transform.TbTransformMsgNode')
        || ',' ||
           (SELECT count(*) FROM relation r
              JOIN rule_node n1 ON n1.id=r.from_id JOIN rule_node n2 ON n2.id=r.to_id
             WHERE r.relation_type_group='RULE_NODE' AND n1.rule_chain_id=(SELECT rule_chain_id FROM root)
               AND ((n1.name='Message Type Switch' AND r.relation_type='Post telemetry' AND n2.name='电表Key标准化')
                 OR (n1.name='电表Key标准化' AND r.relation_type='Success' AND n2.name='Save Timeseries')))
        || ',' ||
           (SELECT count(*) FROM relation r
              JOIN rule_node n1 ON n1.id=r.from_id JOIN rule_node n2 ON n2.id=r.to_id
             WHERE r.relation_type_group='RULE_NODE' AND n1.rule_chain_id=(SELECT rule_chain_id FROM root)
               AND n1.name='Message Type Switch' AND n2.name='Save Timeseries'
               AND r.relation_type='Post telemetry');" 2>/dev/null | tr -d ' ')
  if [[ "${MK}" == "1,2,0" ]]; then
    ok "电表 Key 标准化节点就绪（节点 1 · 连线 2 · 无直连）"
  else
    bad "电表 Key 标准化节点异常（节点/连线/直连 = ${MK:-空}，期望 1,2,0）" \
        "POST /api/energy/repair-init 自动补装；仍异常看手册 ③ 五之二"
  fi
fi

# ---------------------------------------------------------------- I. 接口语义与统计口径

# I-1. 缺参数必须返回 400，不能是 500。
#      500 会让前端去查服务端日志、让监控把「调用方写错」计入 5xx 告警，
#      真正的服务故障被噪声淹没（实测 2026-10-23：tou-analysis 缺 from 返回 500）。
CODE=$(curl -s --noproxy '*' -m 30 -o /tmp/verify_badparam.json -w '%{http_code}' \
       -H "X-Authorization: Bearer $CTOK" "$BASE/api/energy/tou-analysis" 2>/dev/null)
ERRC=$(jget < /tmp/verify_badparam.json "print(d.get('errorCode'))" 2>/dev/null)
if [[ "$CODE" == "400" && "$ERRC" == "31" ]]; then
  ok "缺参数返回 400（BAD_REQUEST_PARAMS）"
else
  bad "缺参数返回 ${CODE:-空} / errorCode=${ERRC:-空}，期望 400 / 31" \
      "看 ThingsboardErrorResponseHandler.handle：参数类异常要先分流成 400"
fi

# I-2. 台账用量必须是「账期累计」，不是「最后一次抄表的增量」。
#      一个月内多次抄表时，后者会把月用量算成 0（实测：实际 94.575 kWh → 台账 0.0000，
#      账单金额跟着变 0）。合法值域：usage 为 null（无表底/倒走）或 >= lastUsage。
LEDGER=$(CAPI '/api/energy/meter-reading/ledger')
# 有账单时 usage 合法地来自账单（计费口径），此时不要求 periodOpen；
# 没有账单时才必须能追溯到「期初/期末表底」。
LED_OK=$(echo "$LEDGER" | jget "
items = d.get('items') or []
def ok(x):
    if x.get('usage') is None:
        return True
    # 虚拟表（手工填报）没有表底概念：月填报值是整月总量，不是「期末-期初」的差，
    # 要求它有 periodOpen 等于要求它伪造表底。source/quality=manual 直接放行。
    if x.get('source') == 'manual' or x.get('quality') == 'manual':
        return True
    if x.get('usageSource') == 'bill':
        b = x.get('bill') or {}
        return b.get('billUsage') is not None and abs(float(x['usage']) - float(b['billUsage'])) < 1e-4
    return x.get('periodOpen') is not None
print('1' if items and all(ok(x) for x in items) else '0')" 2>/dev/null)
MONO=$(echo "$LEDGER" | jget "
bad = 0
for x in (d.get('items') or []):
    u, lu = x.get('usage'), x.get('lastUsage')
    if u is not None and lu is not None:
        try:
            if float(u) + 1e-6 < float(lu): bad += 1
        except Exception: pass
print('1' if bad == 0 else '0')" 2>/dev/null)
if [[ "$LED_OK" == "1" && "$MONO" == "1" ]]; then
  ok "台账用量为账期累计口径（含 periodOpen/periodClose）"
else
  bad "台账用量口径异常（字段缺失或累计 < 本次增量）" \
      "看 EnergyMeterReadingController.ledger：应按「期末表底 − 期初表底」计费"
fi

# I-3. 峰谷分析必须与「表底首末差」逐日对齐。
#
#      这个断言防的是一类极难发现的错：报表看起来正常、各档合计也等于总量，
#      但边界那一个小时被算重/算漏。实测过的三种表现：
#        · 少了 to 那一刻的点      → 每天少 1/24（57.09 应为 58.09）
#        · 拿桶中心当数据时间比较  → 边界小时错位半小时
#        · 上界延一小时取点        → to 之后的数据混进同一小时桶（多 0.5）
#      统一成「整段落在 (from, to] 内」后三种都消失。
#
#      选一台数据完整的表，任取 3 天逐日比对表底差。
if [[ -f .env ]]; then
  set -a; . ./.env 2>/dev/null; set +a
  # ★ 必须挑**演示设备**（additional_info.demo=true）。
  #   树的第一台可能是现场接进来的真实 RTU 表：它今天才上线、只在非整点
  #   上报过几个点，历史 2~4 天完全没有 energy_reading → 本断言恒失败，
  #   看起来像「峰谷分析算错了」，实际是取样取错了设备（2026-10-24 实测）。
  TOU_DEV=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc "
    SELECT d.id FROM device d
     WHERE d.type IN ('单相电能表','电能表')
       AND substring(d.additional_info from '\"demo\"\s*:\s*(true|\"true\")') IS NOT NULL
     ORDER BY d.name LIMIT 1" 2>/dev/null | tr -d ' ')
  # 兜底：老库里演示设备没打 demo 标记时，退回按名字挑（演示表统一带「园-」前缀）
  if [[ -z "$TOU_DEV" ]]; then
    TOU_DEV=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc "
      SELECT d.id FROM device d
       WHERE d.type IN ('单相电能表','电能表')
         AND d.name LIKE '%园-%'
       ORDER BY d.name LIMIT 1" 2>/dev/null | tr -d ' ')
  fi
  if [[ -n "$TOU_DEV" ]]; then
    TOU_BAD=0
    TOU_CHECKED=0
    for OFF in 2 3 4; do
      read -r F T <<< "$(python3 -c "
import time,datetime
bj=datetime.timezone(datetime.timedelta(hours=8))
now=datetime.datetime.now(bj).replace(minute=0,second=0,microsecond=0)
d=now-datetime.timedelta(days=$OFF)
print(int(d.timestamp()*1000), int((d+datetime.timedelta(days=1)).timestamp()*1000))")"
      T1=$(TAPI "/api/energy/tou-analysis?deviceId=$TOU_DEV&granularity=day&from=$F&to=$T" \
        | jget "print(round(sum(b['total'] for b in d.get('buckets',[])),2))" 2>/dev/null)
      DBV=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
        "SELECT round((max(dbl_v)-min(dbl_v))::numeric,2) FROM ts_kv t
         JOIN key_dictionary k ON k.key_id=t.key
         WHERE t.entity_id='$TOU_DEV'::uuid AND k.key='energy_reading'
           AND t.ts >= $F AND t.ts <= $T" 2>/dev/null | tr -d ' ')
      if [[ -n "$T1" && -n "$DBV" && "$DBV" != "0" ]]; then
        TOU_CHECKED=$((TOU_CHECKED+1))
        DIFF=$(python3 -c "print(abs(float('$T1')-float('$DBV')))" 2>/dev/null)
        LESS=$(python3 -c "print(1 if ${DIFF:-9} <= 0.05 else 0)" 2>/dev/null)
        [[ "$LESS" == "1" ]] || TOU_BAD=$((TOU_BAD+1))
      fi
    done
    if [[ "$TOU_CHECKED" -eq 0 ]]; then
      bad "峰谷分析无法核对（设备无整点表底）" "确认演示数据已生成；或换一台有 energy_reading 的设备"
    elif [[ "$TOU_BAD" -eq 0 ]]; then
      ok "峰谷分析逐日 == 表底首末差（${TOU_CHECKED} 天）"
    else
      bad "峰谷分析与表底首末差不一致（${TOU_BAD}/${TOU_CHECKED} 天）" \
          "看 EnergyAnalysisController.readHourlyUsageDetailed：边界按「整段落在 (from,to]」过滤"
    fi
  else
    bad "峰谷分析核对跳过：找不到有设备的维度" "确认演示数据已生成"
  fi
fi

# I-3b. 出账必须能跑通，且账单金额 = 四项费用之和。
#
#      账单是客户最终看到的东西，金额算错比页面报错严重得多。
#      这里只做结构性校验（能出账 / 金额自洽 / 幂等），
#      具体单价的复算由手册里的「三步核对」人工完成。
BILL=$(curl -s --noproxy '*' -m 60 -X POST \
       -H "X-Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
       -d "{\"period\":\"$(date +%Y-%m)\",\"dryRun\":true}" \
       "$BASE/api/energy/billing/generate" 2>/dev/null)
BILL_N=$(echo "$BILL" | jget "print(d.get('total') or 0)" 2>/dev/null)
BILL_OK=$(echo "$BILL" | jget "
items = [x for x in (d.get('items') or []) if x.get('usable')]
def ok(x):
    try:
        parts = [float(x.get(k) or 0) for k in ('energyFee','basicFee','powerFactorFee','surchargeFee')]
        return abs(sum(parts) - float(x.get('amount') or 0)) < 0.02
    except Exception:
        return False
print('1' if items and all(ok(x) for x in items) else '0')" 2>/dev/null)
if [[ "${BILL_N:-0}" -gt 0 && "$BILL_OK" == "1" ]]; then
  ok "出账试算通过（${BILL_N} 台表，金额四项合计自洽）"
elif [[ "${BILL_N:-0}" -eq 0 ]]; then
  bad "出账试算没有任何明细" "检查 /api/energy/billing/generate 返回的 items 与失败原因"
else
  bad "账单金额与四项费用之和对不上" "看 EnergyBillingService.billOne：energyFee+basicFee+powerFactorFee+surchargeFee 应等于 amount"
fi

# I-3b-2. 虚拟表（手工填报）也必须出账。
#
#          虚拟表没有 energy_reading，用量只存在于「月首 00:00 的 energy 点」。
#          曾因判定读错位置（查 SERVER_SCOPE 属性而不是 device.additionalInfo），
#          2 台虚拟表被当成实表，报「读数不足两点」→ 永远不进账单，
#          客户对出来「账单用量 < 实际用电」却查不出原因。
VBAD=$(echo "$BILL" | jget "
vs = [x for x in (d.get('items') or []) if x.get('usageSource') == 'manual']
bad = [x.get('deviceName') for x in vs if not x.get('usable')]
print(len(vs))
print('|'.join(bad))" 2>/dev/null)
VS_N=$(echo "$VBAD" | sed -n 1p)
VS_BAD=$(echo "$VBAD" | sed -n 2p)
if [[ "${VS_N:-0}" -eq 0 ]]; then
  [[ "$QUIET" == "true" ]] || printf '\033[33m  - 跳过：本库没有虚拟表（手工填报设备）\033[0m\n'
elif [[ -z "${VS_BAD:-}" ]]; then
  ok "虚拟表也出账（${VS_N} 台，usageSource=manual）"
else
  bad "虚拟表未出账：${VS_BAD}" "看 MeteringMath.isVirtual：判定依据是 device.additionalInfo.deviceVirtual，不是 SERVER_SCOPE 属性"
fi

# I-3b-3. 台账不能漏掉虚拟表。
#
#          台账主体来自 meter_reading_record，虚拟表没有抄表记录。
#          不补这段时：账单有金额、台账看不到这台表，客户以为多收钱。
VLED=$(CAPI '/api/energy/meter-reading/ledger' | jget "
vs = [x for x in (d.get('items') or []) if x.get('quality') == 'manual' or x.get('source') == 'manual']
bad = [x.get('deviceName') for x in vs if x.get('usage') is None]
print(len(vs))
print('|'.join(bad))" 2>/dev/null)
VL_N=$(echo "$VLED" | sed -n 1p)
VL_BAD=$(echo "$VLED" | sed -n 2p)
if [[ "${VS_N:-0}" -gt 0 && "${VL_N:-0}" -eq 0 ]]; then
  bad "台账漏掉虚拟表（出账 ${VS_N} 台，台账 0 台）" "看 EnergyMeterReadingController.appendVirtualRows：虚拟表要补成台账行"
elif [[ -z "${VL_BAD:-}" ]]; then
  ok "台账包含虚拟表行（${VL_N} 台）"
else
  bad "虚拟表在台账里没有用量：${VL_BAD}" "已出账时台账应取 billUsage；未出账时读手工填报的月首值"
fi

# I-3c. 账单号必须含表码，否则同客户同品种的多块表会互相覆盖。
#
#      实测踩过：账单号只到「客户+账期+能源」时，11 块电表算出同一个号，
#      后一笔覆盖前一笔，17 台表出完账只剩 4 张。
DUP=$(TAPI '/api/energy/billing/summary?period='"$(date +%Y-%m)" | jget "
items = d.get('items') or []
codes = [x.get('billingNo') for x in items]
print('1' if len(codes) == len(set(codes)) else '0')" 2>/dev/null)
if [[ "$DUP" == "1" ]]; then
  ok "账单号唯一（每个客户/账期/品种/表码一张）"
else
  bad "账单号有重复" "看 EnergyBillingService.billingNo：必须带 meterNo 或设备 id 前 8 位"
fi

# I-3d. 演示数据的用电层级必须守恒：父表 >= Σ 子表。
#
#      这是演示数据「看起来真实」的底线。客户会拿进线表底减去各分项之和，
#      差值应当等于线损 + 未装表负荷（正数），而不是负数。
#
#      实测踩过（2026-10-23）：手工用模拟器注入 --seed-reading 2800 到一个
#      表底已到 6.7 万的车间总表上，min(表底) 被拉到 2800，
#      于是「车间 64,980 + 办公 3,917 = 68,897 > 进线 68,109」——
#      看着像演示数据算错，实际是测试污染。这个断言就是为了让这类问题
#      在验收时直接暴露，而不是靠人肉盯数。
if [[ -f .env ]]; then
  set -a; . ./.env 2>/dev/null; set +a
  HIER=$(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc "
    WITH span AS (
        SELECT v.entity_id, max(v.dbl_v) - min(v.dbl_v) AS delta
        FROM ts_kv v JOIN key_dictionary k ON k.key_id = v.key AND k.key = 'energy_reading'
        GROUP BY v.entity_id
    ),
    edge AS (
        SELECT r.from_id AS pid, r.to_id AS cid
        FROM relation r
        JOIN device pf ON pf.id = r.from_id
        JOIN device cf ON cf.id = r.to_id
        WHERE r.relation_type_group = 'COMMON' AND r.relation_type = 'Contains'
    ),
    bad AS (
        SELECT DISTINCT pf.name AS pname, sp.delta AS pdelta, SUM(sc.delta) AS cdelta
        FROM edge e
        JOIN device pf ON pf.id = e.pid
        JOIN span sp ON sp.entity_id = e.pid
        JOIN span sc ON sc.entity_id = e.cid
        GROUP BY pf.name, sp.delta, e.pid
        HAVING sp.delta < SUM(sc.delta) - 0.5
    )
    SELECT COALESCE(string_agg(pname || ' ' || round(pdelta::numeric,1) || '<' || round(cdelta::numeric,1), '; '), '')
    FROM bad;" 2>/dev/null | tr -d '\r')
  if [[ -z "$HIER" ]]; then
    ok "演示用电层级守恒（父表 >= Σ 子表，差值 = 线损 + 未装表）"
  else
    bad "父表小于子表之和：${HIER}" \
        "多为手工注入表底造成（换表 / 重放数据）—— 看手册 ③ 九之四：总分差为负怎么办"
  fi
fi

# I-4. 现场补抄提交后，记录列表必须能读到 fieldStatus。
#
#      写进去了但列表不返回 → 工人刷新一看没变化，重复提交；管理员也看不到待审。
#      （实测 2026-10-23：field-submit 返回 pending，records 里却是 null。）
#
#      全新库刚装完时本月还没有抄表记录（抄表由定时任务/规则链触发），
#      此时 items 为空 —— 那是「还没抄」，不是「字段缺失」。
#      先主动触发一次抄表再查，既验证了抄表链路，也验证了字段。
CAPI_POST() { curl -s --noproxy '*' -m 90 -X POST -H "X-Authorization: Bearer $CTOK" \
               -H 'Content-Type: application/json' -d '{}' "$BASE$1"; }
CAPI_POST '/api/energy/meter-reading/run' >/dev/null 2>&1 || true
RECS=$(CAPI '/api/energy/meter-reading/records?period='"$(date +%Y-%m)")
HAS_FIELD=$(echo "$RECS" | jget "
items=d.get('items') or []
print('1' if items and all('fieldStatus' in x for x in items) else ('0' if items else '-'))" 2>/dev/null)
if [[ "$HAS_FIELD" == "1" ]]; then
  ok "抄表记录含现场补抄状态字段（fieldValue/fieldStatus）"
elif [[ "$HAS_FIELD" == "-" ]]; then
  [[ "$QUIET" == "true" ]] || printf '\033[33m  - 跳过：本月尚无抄表记录（设备可能未上报，非字段缺陷）\033[0m\n'
  PASS=$((PASS+1))
else
  bad "抄表记录缺 fieldStatus 字段" \
      "看 EnergyMeterReadingController.records：SELECT 要带上 field_value/field_status/field_note"
fi

# I-5. 设备计量配置端点必须可用（meterLevel + 倍率）
#
#      这个端点补的是「meterLevel 只有演示数据会写、真实客户没入口」的缺口。
#      没有它，客户自建表的分层汇总永远失效 → 总表+分表相加，金额虚高 2~3 倍。
#      只验「读得出来且字段齐全」，不写数据（避免改动演示配置）。
ANYDEV=$(TAPI '/api/tenant/devices?pageSize=1&page=0' | jget "print((d.get('data') or [{}])[0].get('id',{}).get('id',''))" 2>/dev/null)
if [[ -n "$ANYDEV" ]]; then
  DC=$(TAPI "/api/energy/device-config?deviceId=$ANYDEV")
  HAS=$(echo "$DC" | jget "
need = {'meterLevel','ctRatio','ptRatio','meterRatio','ratioApplied','effectiveRatio','storage'}
print('1' if need.issubset(set(d.keys())) else '0')" 2>/dev/null)
  if [[ "$HAS" == "1" ]]; then
    ok "设备计量配置端点可用（层级 + 倍率三件套）"
  else
    bad "设备计量配置端点字段缺失" \
        "看 EnergyMeterReadingController.deviceConfig：应返回 meterLevel/ctRatio/ptRatio/meterRatio/ratioApplied/effectiveRatio"
  fi
else
  bad "取不到设备，无法验证计量配置端点" "确认演示数据已生成"
fi

# I-5b. 资产汇总遥测必须存在（看板「选场站/分项」读的就是它）
#
#      看板部件在目标实体是 ASSET 时读 energy_total，不是设备的 energy。
#      初始化只写设备遥测时，客户一选场站，卡片全是「--」——
#      看起来像部件坏了，实际是资产维度缺数（实测 2026-10-23）。
#      这里验「至少一个资产有 energy_total 点」，并验组织 = 各场站之和。
ASSET_TOT=$(docker exec energy-postgres psql -U postgres -d thingsboard -tAc "
SELECT count(*) FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
WHERE kd.key = 'energy_total'" 2>/dev/null | tr -d ' ')
if [[ "${ASSET_TOT:-0}" -gt 0 ]]; then
  ok "资产汇总遥测已写入（energy_total ${ASSET_TOT} 点）"
else
  bad "资产上没有 energy_total（看板选场站会是空的）" \
      "点「平台自检 → 一键修复初始化」补算，或看 EnergyBootstrapInstaller.seedAssetTotals"
fi

# I-5c. 客户能给自己重算资产汇总（自建场站/设备后必需）
#
#      平台不会在设备上报时自动把电量汇总到资产。客户自建场站后
#      不重算，看板选场站就是空的。这个端点必须对客户开放且只影响自己。
REBUILD=$(curl -s --noproxy '*' -m 120 -X POST \
          -H "X-Authorization: Bearer $CTOK" -H 'Content-Type: application/json' \
          -d '{"days":7}' "$BASE/api/energy/asset-totals/rebuild" 2>/dev/null)
RB_OK=$(echo "$REBUILD" | jget "print('1' if d.get('ok') and 'assetsWritten' in d else '0')" 2>/dev/null)
if [[ "$RB_OK" == "1" ]]; then
  ok "客户可重算资产汇总（写入了 $(echo "$REBUILD" | jget "print(d.get('assetsWritten'))" 2>/dev/null) 个资产）"
else
  bad "客户无法重算资产汇总" \
      "看 EnergyDemoDataController.rebuildAssetTotals：客户账号应限定在自己域内并返回 assetsWritten"
fi

# I-5d. 客户视角权限探针：客户打开页面时部件发的请求不能有 4xx
#
#       之前的验收只调「我们认为重要」的接口，而客户打开页面是**部件**在发请求。
#       部件会去读租户级主数据（能源品种、参数字典），客户没权限 → 403 → 图表空白。
#       实测 2026-10-23：74 项全绿的同时，客户看板有 22 条 403。
#
#       探针脚本 27-customer-surface-probe.py 以客户身份打 295 条请求，
#       任何 401/403/5xx 都算缺陷。--strict 时有失败会退出码 2。
PROBE="$APP_HOME/scripts/27-customer-surface-probe.py"
if [[ -f "$PROBE" ]]; then
  PROBE_OUT=$(python3 "$PROBE" --base "$BASE" \
      --tenant "$TENANT" --tenant-pass "$TENANT_PASS" \
      --customer "$CUST" --customer-pass "$CUST_PASS" \
      --strict --json 2>/dev/null)
  PROBE_RC=$?
  PROBE_FAIL=$(echo "$PROBE_OUT" | jget "print(d.get('failed', 999))" 2>/dev/null)
  PROBE_TOTAL=$(echo "$PROBE_OUT" | jget "print(d.get('total', 0))" 2>/dev/null)
  if [[ "${PROBE_FAIL:-999}" == "0" && "$PROBE_RC" == "0" ]]; then
    ok "客户视角无 4xx（${PROBE_TOTAL:-0} 条请求全通）"
  else
    FIRST=$(echo "$PROBE_OUT" | jget "
bad = [x for x in (d.get('items') or []) if x.get('code') in (401,403) or (x.get('code') or 0) >= 500]
print((bad[0].get('label','') + ' → ' + str(bad[0].get('code',''))) if bad else '')" 2>/dev/null)
    bad "客户视角有 ${PROBE_FAIL} 条请求失败（首条：${FIRST}）" \
        "看 scripts/27-customer-surface-probe.py 的 --json 输出；403 多为部件读租户级主数据，见「现象 I-2」"
  fi
else
  printf '  \033[33m  - 跳过：缺少 scripts/27-customer-surface-probe.py\033[0m\n'
fi

# I-6. SQL 埋点必须默认开启
#
#      用户要的是「页面数字能用 SQL 复核」。埋点被关掉（哪怕只是降到 debug），
#      这个能力就没了，而且不会有人发现 —— 所以把它变成断言。
TRACE_ON=$(docker logs energy-server 2>&1 | grep -c "SQL 埋点已开启" || true)
if [[ "${TRACE_ON:-0}" -ge 1 ]]; then
  ok "SQL 埋点默认开启（日志可复制 SQL 对照页面）"
else
  if docker logs energy-server 2>&1 | grep -q "SQL 埋点被关闭"; then
    bad "SQL 埋点被关闭（页面数字将无法用 SQL 复核）" \
        "去掉 energy.sql-trace.enabled=false；默认必须为 true"
  else
    printf '  \033[33m  - 跳过：日志里没有埋点开关记录（容器可能刚重启未打印）\033[0m\n'
  fi
fi

# I-7. 计量设备的「能源分项」属性必须齐全
#
#       AI 三页的「按分项」全靠 device.additional_info.energyCategory：
#       为空 → 分项下拉 disabled、按分项分析 0 台设备、「分项」汇总落到「其他」。
#       新建客户由 EnergyBootstrapInstaller 按「档案 + 分项 + 层级」自动写入；
#       这条断言防的是存量数据 / 手工建的设备，以及今后改初始化代码时漏写。
CAT_MISSING=$(DASH_DB "
select count(*) from device d join device_profile p on p.id = d.device_profile_id
where (p.name like '%电能%' or p.name like '%水表%' or p.name like '%燃气%' or p.name like '%蒸汽%')
  and coalesce(d.additional_info::jsonb->>'deviceVirtual','') <> 'virtual'
  -- 区域汇总表（办公区总表）有意不参与分项聚合，不算缺失；判据与
  -- EnergyBootstrapInstaller#resolveEnergyCategory 保持一致
  and not (d.name like '%总表%' and d.name not like '%进线%' and d.name not like '%动力%'
           and d.name not like '%照明%' and d.name not like '%插座%' and d.name not like '%空调%')
  and coalesce(nullif(d.additional_info::jsonb->>'energyCategory',''),'') = ''")
eq "计量设备都有能源分项属性" "${CAT_MISSING:-0}" "0" \
   "跑 scripts/24-device-categories.py --fix（幂等，只补空值）；新装客户由初始化自动写入"

# I-8. 能源分析类看板的数据源必须覆盖整个客户
#
#       综合能耗 / 能耗洞察 / 能源流向 / 电能质量 / 盘查报告 的「场站」别名
#       曾指向占位符 …05a1（= 单相园区），复制给客户后范围被锁在一个场站：
#       场站排名只出一行、能源构成缺了三相园的生产蒸汽表（实测 2026-10-25）。
#       现在模板用 …05a2（= 客户组织）。这条断言防回退。
SCOPE_BAD=$(DASH_DB "
select count(*) from dashboard d
join jsonb_each(d.configuration::jsonb->'entityAliases') al on true
join asset a on a.id = (al.value->'filter'->'singleEntity'->>'id')::uuid
where d.customer_id is not null
  and d.title in ('综合能耗','能耗洞察','能源流向','电能质量','盘查报告')
  and a.type = '场站'")
eq "能源分析看板未被锁在单一场站" "${SCOPE_BAD:-0}" "0" \
   "看板的「场站」数据源应指向客户组织（type=组织），不是某个 type=场站 的资产；跑 scripts/25-fix-analysis-scope.py --apply"

# I-9. 节能记录演示数据
#
#       页面是 saving_record 资产驱动。没造数据时列表 0 条、三张 KPI 全 0，
#       客户会以为功能没做完。演示包按三种状态各造一条。
SAVING_N=$(DASH_DB "select count(*) from asset where type='saving_record'")
ge "节能记录演示数据" "${SAVING_N:-0}" 3 \
   "重建客户（09-onboard-customer.sh）或对已有客户调 POST /api/energy/demo-data 补齐"

# ================================================================
echo
echo "============================================================"
printf '  通过 %d 项' "$PASS"
[[ "$FAIL" -gt 0 ]] && printf '，失败 %d 项' "$FAIL"
echo
if [[ "$FAIL" -gt 0 ]]; then
  echo
  echo "  失败明细："
  for it in "${FAILED_ITEMS[@]}"; do echo "    · $it"; done
  echo
  echo "  多数问题可用「平台自检 → 一键修复初始化」解决（幂等，不动业务数据）。"
  echo "  入口：登录后左侧「运营配置 → 平台自检」。"
  echo "============================================================"
  exit 1
fi
echo "  这一版的功能点全部到位。"
# 项数自校验：全部通过但项数对不上，说明脚本被改过而 EXPECTED_PASS 没跟着改。
# 这种漂移会让手册里的「通过 N 项」变成假话，所以当成失败处理。
if [[ "${PASS}" -ne "${EXPECTED_PASS}" ]]; then
  echo
  # 变量必须写成 ${VAR}：后面紧跟中文时，bash 3.2（macOS 自带）
  # 会把中文字节当成变量名的一部分，报 "PASS，: unbound variable"。
  echo "  ⚠ 项数与预期不符：实际 ${PASS} 项，预期 ${EXPECTED_PASS} 项"
  echo "    检查项被增删过。请同步更新本脚本的 EXPECTED_PASS 与手册里的「通过 N 项」。"
  echo "============================================================"
  exit 1
fi
echo "============================================================"
exit 0
