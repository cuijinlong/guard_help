#!/usr/bin/env bash
#
# 能源管理平台 · 一键准备「演示账号 + 演示数据」
#
# 用途：给别人做产品演示时，需要一个**独立的、数据满的、随时可重置**的客户账号，
#       又不想动真实客户的数据。
#
# 默认（不带任何参数就跑）：
#   客户    平台演示中心
#   账号    demo@126.com
#   密码    demo123456
#
# 用法：
#   bash scripts/13-demo-account.sh                 # 建/修演示账号（幂等）
#   bash scripts/13-demo-account.sh --check         # 只检查现状，不创建
#   bash scripts/13-demo-account.sh --reset         # 先清演示数据再重建
#   bash scripts/13-demo-account.sh --with-rtu      # 另外备好现场真机（RTU）要用的 4 台设备
#   bash scripts/13-demo-account.sh --email x@y.com --password 'Abc@123456' --name '演示中心'
#
# --with-rtu 做什么（现场演示接真机时必加）：
#   调 21-rtu-onboard.py 备好 ED1-Gateway / PowerMeter-DDSU777 /
#   Sensor-HZ8706 / Relay-8CH 四台设备，网关令牌固定（重装不用重烧固件）。
#   电表 meterLevel=0：不计入场站汇总，不会把演示数字改乱 —— 但设备管理、
#   实时数据、一键抄表、台账出账都能看到它。
#
# 为什么单独一个脚本，而不是让人自己记 09 的参数：
#   演示账号要能**随时重建**，参数一多就容易记错（写成 tenant@ 或密码不足 8 位）。
#   固定默认值 + 幂等 = 任何时候跑一次都能回到「可演示」状态。
#
# 它做什么：
#   1. 复用 09-onboard-customer.sh（建客户 → 账号 → 演示数据 → 菜单 → 18 个看板）
#   2. 额外校验「演示可用性」：场站 / 分项 / 设备 / 看板 / 登录，缺一项就报错
#   3. 打印演示入口与建议路线
#
# 幂等：同一邮箱重复执行会复用客户并重置密码，不会建出第二个「平台演示中心」。
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${BASE:-http://127.0.0.1:8090}"

EMAIL="${DEMO_EMAIL:-demo@126.com}"
PASS="${DEMO_PASS:-demo123456}"
NAME="${DEMO_NAME:-平台演示中心}"

TENANT_EMAIL=""
TENANT_PASS=""
MODE="ensure"
WITH_RTU="false"
RTU_SITE=""

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
    --with-rtu)     WITH_RTU="true"; shift ;;
    --rtu-site)     WITH_RTU="true"; RTU_SITE="$2"; shift 2 ;;
    --check)        MODE="check"; shift ;;
    --reset)        MODE="reset"; shift ;;
    -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

ncurl() { curl -s --noproxy '*' "$@"; }

login() {
  ncurl -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

# 租户凭据：显式参数优先，其次读部署目录的 DEPLOY-CREDENTIALS.txt
load_tenant_cred() {
  [[ -n "$TENANT_EMAIL" && -n "$TENANT_PASS" ]] && return 0
  local cred="$HERE/../DEPLOY-CREDENTIALS.txt"
  [[ -f "$cred" ]] || return 1
  [[ -z "$TENANT_EMAIL" ]] && TENANT_EMAIL=$(sed -n 's/^租户管理员[[:space:]]*\([^ ]*\) \/.*/\1/p' "$cred" | head -1)
  [[ -z "$TENANT_PASS" ]]  && TENANT_PASS=$(sed -n 's/^租户管理员[[:space:]]*[^ ]* \/ \(.*\)$/\1/p' "$cred" | head -1)
  [[ -n "$TENANT_EMAIL" && -n "$TENANT_PASS" ]]
}

# 客户 id（按标题精确匹配）
customer_id() {
  local tok="$1" title="$2"
  ncurl "$BASE/api/customers?pageSize=100&page=0" -H "X-Authorization: Bearer $tok" \
    | TITLE="$title" python3 -c '
import json, os, sys
try:
    rows = (json.load(sys.stdin) or {}).get("data") or []
except Exception:
    rows = []
want = os.environ["TITLE"]
hit = next((c for c in rows if c.get("title") == want), None)
print(hit["id"]["id"] if hit else "")
' 2>/dev/null
}

# ---------------------------------------------------------------- 计数助手
# 定义必须在使用之前：--check 分支也会调它。bash 顺序执行，函数未定义会报
# "command not found"，在 set -uo pipefail 下表现为静默空值，很难查。
#
# JSON 走临时文件而不是拼进 python 源码：接口返回里含中文与引号，
# 内插到源码里遇到单引号就语法错误。
counts_json() {
  local tok="$1" cid="$2" dir
  dir=$(mktemp -d 2>/dev/null) || dir="/tmp/demo-counts-$$"
  mkdir -p "$dir" 2>/dev/null
  ncurl "$BASE/api/customer/$cid/assets?pageSize=500&page=0"   -H "X-Authorization: Bearer $tok" > "$dir/assets.json"
  ncurl "$BASE/api/customer/$cid/devices?pageSize=500&page=0"  -H "X-Authorization: Bearer $tok" > "$dir/devices.json"
  ncurl "$BASE/api/tenant/dashboards?pageSize=200&page=0"      -H "X-Authorization: Bearer $tok" > "$dir/dash.json"
  python3 - "$dir" "$cid" <<'PYEOF' 2>/dev/null
import json, os, sys

d, cid = sys.argv[1], sys.argv[2]

def load(name):
    try:
        with open(os.path.join(d, name), encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}

assets = load('assets.json').get('data') or []
devices = load('devices.json').get('data') or []
dashes = load('dash.json').get('data') or []

sites = sum(1 for x in assets if x.get('type') == '场站')
items = sum(1 for x in assets if x.get('type') == '分项')
mine = sum(1 for x in dashes if ((x.get('customerId') or {}).get('id') == cid))

print('场站 %d' % sites)
print('分项 %d' % items)
print('设备 %d' % len(devices))
print('看板 %d' % mine)
PYEOF
  rm -rf "$dir" 2>/dev/null
}

echo "============================================================"
echo " 演示账号 · ${NAME} <${EMAIL}>"
echo " $(date '+%Y-%m-%d %H:%M:%S')  平台 ${BASE}"
echo "============================================================"
echo

# ---------------------------------------------------------------- 0. 前置检查
command -v python3 >/dev/null 2>&1 || die "需要 python3（解析接口返回）"
CODE=$(ncurl -o /dev/null -w '%{http_code}' -m 10 "$BASE/api/noauth/setup/state" 2>/dev/null || echo 000)
if [[ "$CODE" != "200" ]]; then
  die "平台不可达或未就绪（HTTP ${CODE}）
    · 未装：先跑 docker-01-install.sh 与 docker-02-start.sh
    · 刚起：等 /api/noauth/setup/state 返回 200（首次约 2~7 分钟）"
fi
ok "平台可达"

# ---------------------------------------------------------------- --check 只读
if [[ "$MODE" == "check" ]]; then
  log "只检查现状（不写任何数据）"
  if [[ -z "$(login "$EMAIL" "$PASS")" ]]; then
    warn "演示账号不存在或密码不对：${EMAIL}"
    echo "     创建：bash scripts/13-demo-account.sh"
    exit 0
  fi
  ok "账号可登录：${EMAIL}"
  if ! load_tenant_cred; then
    warn "没有租户凭据，跳过数据量检查（传 --tenant-email / --tenant-pass）"
    exit 0
  fi
  TOKEN=$(login "$TENANT_EMAIL" "$TENANT_PASS")
  [[ -n "$TOKEN" ]] || die "租户管理员登录失败：${TENANT_EMAIL}"
  CID=$(customer_id "$TOKEN" "$NAME")
  [[ -n "$CID" ]] || { warn "查不到客户「${NAME}」"; exit 0; }
  counts_json "$TOKEN" "$CID" | sed 's/^/     /'
  exit 0
fi

# ---------------------------------------------------------------- 1. 重置（可选）
if [[ "$MODE" == "reset" ]]; then
  log "步骤 1/5　清除旧演示数据"
  load_tenant_cred || die "重置需要租户凭据：
    要么部署目录有 DEPLOY-CREDENTIALS.txt，要么传 --tenant-email / --tenant-pass"
  TOKEN=$(login "$TENANT_EMAIL" "$TENANT_PASS")
  [[ -n "$TOKEN" ]] || die "租户管理员登录失败"
  CID=$(customer_id "$TOKEN" "$NAME")
  if [[ -n "$CID" ]]; then
    ncurl -X DELETE "$BASE/api/energy/demo-data?customerId=$CID" \
      -H "X-Authorization: Bearer $TOKEN" -o /dev/null 2>&1 || warn "清理接口返回异常（继续）"
    ok "已清理「${NAME}」的演示数据（客户与账号保留）"
  else
    warn "客户「${NAME}」还不存在，无需清理"
  fi
else
  log "步骤 1/5　跳过重置（要重建加 --reset）"
fi

# ---------------------------------------------------------------- 2. 建账号 + 数据
log "步骤 2/5　建客户 / 账号 / 演示数据（复用 09-onboard-customer.sh，幂等）"
[[ -f "$HERE/09-onboard-customer.sh" ]] || die "找不到 $HERE/09-onboard-customer.sh"

ARGS=(--base "$BASE" --email "$EMAIL" --password "$PASS" --name "$NAME")
[[ -n "$TENANT_EMAIL" ]] && ARGS+=(--tenant-email "$TENANT_EMAIL" --tenant-pass "$TENANT_PASS")

LOG="/tmp/demo-account-$(date +%H%M%S).log"
if bash "$HERE/09-onboard-customer.sh" "${ARGS[@]}" > "$LOG" 2>&1; then
  ok "开通完成（日志 ${LOG}）"
  sed -n 's/^  ✓ /    ✓ /p' "$LOG" | head -14
else
  tail -30 "$LOG" | sed 's/^/    /'
  die "开通失败，完整日志：${LOG}"
fi

# ---------------------------------------------------------------- 3. 演示可用性校验
log "步骤 3/5　校验演示可用性"

load_tenant_cred || die "校验需要租户凭据（传 --tenant-email / --tenant-pass）"
TOKEN=$(login "$TENANT_EMAIL" "$TENANT_PASS")
[[ -n "$TOKEN" ]] || die "租户管理员登录失败"
CID=$(customer_id "$TOKEN" "$NAME")
[[ -n "$CID" ]] || die "建完了但查不到客户「${NAME}」"

COUNTS=$(counts_json "$TOKEN" "$CID")
printf '%s\n' "$COUNTS" | sed 's/^/    /'

# 逐项硬校验：演示时缺任何一项都会当场尴尬，所以不给「看起来成功」留余地
FAIL=0
for pair in "场站:2" "分项:12" "设备:21" "看板:18"; do
  key="${pair%%:*}"
  want="${pair##*:}"
  got=$(printf '%s\n' "$COUNTS" | awk -v k="$key" '$1==k{print $2}')
  if [[ "${got:-0}" -ge "$want" ]]; then
    ok "${key} ${got}（≥${want}）"
  else
    warn "${key} 只有 ${got:-0}，期望 ≥${want}"
    FAIL=1
  fi
done
[[ "$FAIL" == "0" ]] || die "演示数据不完整 —— 加 --reset 重建"

# 演示用的是客户账号，不是租户：必须用客户身份验一次登录
DEMO_TOKEN=$(login "$EMAIL" "$PASS")
[[ -n "$DEMO_TOKEN" ]] || die "演示账号登录失败（密码不对）"
ok "演示账号可登录"

# 客户视角真的能看到看板（归属可能是 customer_id 或 assignedCustomers 两种）
VIS_N=$(ncurl "$BASE/api/tenant/dashboards?pageSize=200&page=0" -H "X-Authorization: Bearer $DEMO_TOKEN" \
  | python3 -c '
import json, sys
try:
    rows = (json.load(sys.stdin) or {}).get("data") or []
except Exception:
    rows = []
print(len(rows))
' 2>/dev/null)
if [[ "${VIS_N:-0}" -ge 1 ]]; then
  ok "演示账号能看到 ${VIS_N} 个看板"
else
  warn "演示账号看不到任何看板（看板可能没复制到该客户）"
fi

# ---------------------------------------------------------------- 4. 交付说明
# ---------------------------------------------------------------- 4. 现场真机（可选）
if [[ "$WITH_RTU" == "true" ]]; then
  log "步骤 4/5　准备现场真机（RTU）设备"

  if [[ ! -f "$HERE/21-rtu-onboard.py" ]]; then
    warn "找不到 $HERE/21-rtu-onboard.py —— 跳过 RTU（部署包可能没带全）"
  else
    RTU_ARGS=(--base "$BASE" --tenant "$TENANT_EMAIL" --tenant-pass "$TENANT_PASS"
              --customer "$NAME")
    [[ -n "$RTU_SITE" ]] && RTU_ARGS+=(--site "$RTU_SITE")

    RTU_LOG="/tmp/demo-rtu-$(date +%H%M%S).log"
    if python3 "$HERE/21-rtu-onboard.py" "${RTU_ARGS[@]}" > "$RTU_LOG" 2>&1; then
      sed -n 's/^  ✓ /    ✓ /p' "$RTU_LOG" | head -8
      ok "RTU 设备就绪（日志 ${RTU_LOG}）"
      # 现场最容易错的一步：把 127.0.0.1 填进固件，板子连不上。
      # 这里主动探测本机局域网 IP 并提示。
      LAN_IP=""
      if command -v ipconfig >/dev/null 2>&1; then
        for ifc in en0 en1 en2; do
          ip=$(ipconfig getifaddr "$ifc" 2>/dev/null || true)
          [[ -n "$ip" ]] && { LAN_IP="$ip"; break; }
        done
      fi
      if [[ -n "$LAN_IP" ]]; then
        echo "    RTU 侧配置（rtu/main.py 的配置区）："
        echo "      TB_HOST = \"${LAN_IP}\"    ← 用局域网 IP，不要填 127.0.0.1"
        echo "      TB_PORT = 11883          （平台另有 1883，固件会自动回退）"
        echo "    ⚠ 演示机的防火墙要放行 11883；RTU 与演示机必须在同一网段。"
      else
        warn "取不到本机局域网 IP —— 现场请手动填 RTU 的 TB_HOST（不能是 127.0.0.1）"
      fi
    else
      tail -20 "$RTU_LOG" | sed 's/^/    /'
      warn "RTU 设备准备失败（日志 ${RTU_LOG}）—— 其余演示数据不受影响"
    fi
  fi
else
  log "步骤 4/5　跳过 RTU（要接现场真机加 --with-rtu）"
fi

log "步骤 5/5　完成"
echo
echo "------------------------------------------------------------"
echo " 演示入口"
echo "------------------------------------------------------------"
echo "  地址    ${BASE}"
echo "  账号    ${EMAIL}"
echo "  密码    ${PASS}"
echo "  客户    ${NAME}"
echo "  客户ID  ${CID}"
echo
echo " 建议演示路线："
echo "   ① 能耗概览      —— 本月/今年汇总、分项对比、排名、日历热力图"
echo "   ② 实时能耗      —— 当场改「窗口」看曲线跟着动"
echo "   ③ 历史能耗      —— 切时间范围 / 勾设备"
echo "   ④ 峰谷分析      —— 分时电价拆分（尖峰平谷）"
echo "   ⑤ 分项能耗      —— 按分项堆叠"
echo "   ⑥ 用能账单      —— 出账与明细"
echo
echo " 重置演示数据（保留账号）：bash scripts/13-demo-account.sh --reset"
echo " 只查现状：                bash scripts/13-demo-account.sh --check"
echo "------------------------------------------------------------"
