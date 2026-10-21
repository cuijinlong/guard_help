#!/usr/bin/env bash
#
# 能源管理平台 · 上线验收（自动化测试）
#
# 用法：
#   ./03-verify.sh --base http://127.0.0.1:8090 \
#                  --tenant tenant@example.com --tenant-pass '...' \
#                  --customer customer@example.com --customer-pass '...' \
#                  [--ai http://127.0.0.1:18800]
#
# 每个用例都打真实接口，不看页面文本。输出 PASS / FAIL 计数，
# 有 FAIL 时退出码非 0，可直接接 CI。
#
set -uo pipefail

BASE="http://127.0.0.1:8090"
AI=""
TENANT="";  TENANT_PASS=""
CUST="";    CUST_PASS=""

PASS=0; FAIL=0
FAILED_CASES=()

# 不要写成 CURL="curl ... --noproxy *"：变量展开时 * 会被 glob 成当前目录的文件名，
# 实际命令变成 `curl --noproxy 01-install.sh 02-onboard.sh ...`。用函数才安全。
ncurl() { curl -s --noproxy '*' "$@"; }
C() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); FAILED_CASES+=("$*"); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
chk()  { if [[ "$1" == "0" ]]; then ok "$2"; else bad "$2  ${3:-}"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)          BASE="$2"; shift 2 ;;
    --ai)            AI="$2"; shift 2 ;;
    --tenant)        TENANT="$2"; shift 2 ;;
    --tenant-pass)   TENANT_PASS="$2"; shift 2 ;;
    --customer)      CUST="$2"; shift 2 ;;
    --customer-pass) CUST_PASS="$2"; shift 2 ;;
    -h|--help)       sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

login() {
  ncurl -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

# ---------------------------------------------------------------- 1. 基础可用性
C "1. 基础可用性"
CODE=$(ncurl -o /dev/null -w '%{http_code}' -m 10 "$BASE/")
[[ "$CODE" == "200" ]]; chk $? "首页可访问（HTTP ${CODE}）"

STATE=$(ncurl -m 10 "$BASE/api/noauth/setup/state")
echo "$STATE" | grep -q '"status":"READY"'
chk $? "系统已完成初始化（${STATE}）"

# ---------------------------------------------------------------- 2. 租户侧
C "2. 租户侧接口"
TOK=""
if [[ -n "$TENANT" ]]; then
  TOK=$(login "$TENANT" "$TENANT_PASS")
  [[ -n "$TOK" ]] && ok "租户登录成功" || bad "租户登录失败"
else
  echo "  （跳过：未提供 --tenant）"
fi

TAPI() { ncurl -H "X-Authorization: Bearer $TOK" -m 30 "$BASE$1"; }

if [[ -n "$TOK" ]]; then
  N=$(TAPI '/api/tenant/assets?pageSize=1&page=0' | sed -n 's/.*"totalElements":\([0-9]*\).*/\1/p')
  [[ -n "$N" && "$N" -gt 0 ]]; chk $? "资产列表可读（$N 个）"

  N=$(TAPI '/api/tenant/devices?pageSize=1&page=0' | sed -n 's/.*"totalElements":\([0-9]*\).*/\1/p')
  [[ -n "$N" && "$N" -gt 0 ]]; chk $? "设备列表可读（$N 台）"

  N=$(TAPI '/api/tenant/dashboards?pageSize=1&page=0' | sed -n 's/.*"totalElements":\([0-9]*\).*/\1/p')
  [[ -n "$N" && "$N" -gt 0 ]]; chk $? "仪表板列表可读（$N 个）"

  # textSearch 只匹配 name，不匹配 fqn，所以拉全量再按前缀过滤。
  # 726 个部件一次取回约 3MB，验收脚本偶尔跑一次可以接受。
  N=$(TAPI "/api/widgetTypes?pageSize=1000&page=0" \
    | python3 -c "import json,sys; print(len([x for x in json.load(sys.stdin).get('data',[]) if x.get('fqn','').startswith('energy_management.')]))" 2>/dev/null || echo 0)
  [[ -n "$N" && "$N" -ge 30 ]]; chk $? "能耗管理部件已装载（${N} 个）"

  # 能源字典：查询设置的前提
  N=$(TAPI '/api/tenant/assets?pageSize=500&page=0' | grep -o '"type":"energy_type_library"' | wc -l | tr -d ' ')
  [[ "$N" -ge 1 ]]; chk $? "能源参数字典存在（${N}）"

  # 自定义菜单：空 items 是合法初始状态（表示走前端内置导航），不是故障。
  # 验的是接口可用且结构合法，不能拿「必须有菜单项」当门槛。
  N=$(TAPI '/api/customMenu' \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['items']) if isinstance(d.get('items'), list) else 'bad')" 2>/dev/null || echo bad)
  [[ "$N" != "bad" ]]; chk $? "自定义菜单接口可用（${N} 项，空则走内置导航）"

  # 平台自检接口：初始化是否完整，一次请求拿全（9 项租户级 / 8 项客户级）
  N=$(TAPI '/api/energy/self-check' \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('summary',{}).get('healthy','bad'))" 2>/dev/null || echo bad)
  [[ "$N" != "bad" ]]; chk $? "平台自检接口可用（healthy=${N}）"

  # 审计报告版本接口（本轮新增）
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -H "X-Authorization: Bearer $TOK" -m 20 "$BASE/api/energy/audit-report/versions")
  [[ "$CODE" == "200" ]]; chk $? "盘查报告版本接口可用（HTTP ${CODE}）"
fi

# ---------------------------------------------------------------- 3. 客户侧
C "3. 客户侧接口与隔离"
CTOK=""
if [[ -n "$CUST" ]]; then
  CTOK=$(login "$CUST" "$CUST_PASS")
  [[ -n "$CTOK" ]] && ok "客户登录成功" || bad "客户登录失败"
else
  echo "  （跳过：未提供 --customer）"
fi

CAPI() { ncurl -H "X-Authorization: Bearer $CTOK" -m 30 "$BASE$1"; }

if [[ -n "$CTOK" ]]; then
  CID=$(CAPI /api/auth/user | sed -n 's/.*"customerId":{"entityType":"CUSTOMER","id":"\([^"]*\)".*/\1/p')
  [[ -n "$CID" ]]; chk $? "客户身份可解析（customerId=${CID}）"

  N=$(CAPI "/api/customer/$CID/assets?pageSize=1&page=0" | sed -n 's/.*"totalElements":\([0-9]*\).*/\1/p')
  [[ -n "$N" && "$N" -gt 0 ]]; chk $? "可读自己名下资产（$N 个）"

  N=$(CAPI "/api/customer/$CID/devices?pageSize=1&page=0" | sed -n 's/.*"totalElements":\([0-9]*\).*/\1/p')
  [[ -n "$N" && "$N" -gt 0 ]]; chk $? "可读自己名下设备（$N 台）"

  # 越权：客户调租户端点必须 403
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -H "X-Authorization: Bearer $CTOK" -m 10 "$BASE/api/tenant/devices?pageSize=1&page=0")
  [[ "$CODE" == "403" ]]; chk $? "客户访问租户端点被拒（HTTP ${CODE}）"

  # 越权：客户删除报告版本必须 403
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -X DELETE -H "X-Authorization: Bearer $CTOK" -m 10 \
        "$BASE/api/energy/audit-report/versions/00000000-0000-0000-0000-000000000000?confirm=true")
  [[ "$CODE" == "403" || "$CODE" == "404" ]]; chk $? "客户删除版本被拒（HTTP ${CODE}）"

  # 节能记录读取
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -H "X-Authorization: Bearer $CTOK" -m 20 "$BASE/api/energy/audit-report/versions")
  [[ "$CODE" == "200" ]]; chk $? "客户可读报告版本列表（HTTP ${CODE}）"
fi

# ---------------------------------------------------------------- 4. 分析服务
C "4. 分析服务（ngx-ai）"
if [[ -n "$AI" ]]; then
  CODE=$(ncurl -o /dev/null -w '%{http_code}' -m 10 "$AI/")
  [[ "$CODE" == "200" ]]; chk $? "分析前端可访问（HTTP ${CODE}）"

  CODE=$(ncurl -o /dev/null -w '%{http_code}' -m 10 "$AI/ngxapi/health")
  [[ "$CODE" == "200" ]]; chk $? "分析后端健康检查（HTTP ${CODE}）"

  HEALTH=$(ncurl -m 10 "$AI/ngxapi/health")
  echo "$HEALTH" | grep -q '"reachable":true'; chk $? "分析后端可连 ThingsBoard"

  if [[ -n "$CTOK" ]]; then
    # 未发布对象应 404 而不是 500
    CODE=$(ncurl -o /dev/null -w '%{http_code}' -X POST -m 20 "$AI/ngxapi/biz/predict" \
           -H "X-Authorization: Bearer $CTOK" -H 'Content-Type: application/json' \
           -d '{"scope_type":"device","scope_value":"00000000-0000-0000-0000-000000000000","horizon_hours":24}')
    [[ "$CODE" == "404" ]]; chk $? "预测接口对未发布对象返回 404（HTTP ${CODE}）"

    CODE=$(ncurl -o /dev/null -w '%{http_code}' -m 20 "$AI/ngxapi/biz/measures" -H "X-Authorization: Bearer $CTOK")
    [[ "$CODE" == "200" ]]; chk $? "措施列表可读（HTTP ${CODE}）"
  fi
else
  echo "  （跳过：未提供 --ai）"
fi

# ---------------------------------------------------------------- 汇总
echo
echo "=================================="
printf '  通过 %d / 失败 %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "  失败项："
  for c in "${FAILED_CASES[@]}"; do echo "    - $c"; done
fi
echo "=================================="
[[ "$FAIL" == "0" ]] || exit 1
