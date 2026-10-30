#!/usr/bin/env bash
#
# 演示用：给「正泰单相电表」持续灌实时数据（模拟 RTU 上报）
#
# 用途：演示前跑一下，让办公园区那台正泰表有"刚刚上报"的读数 ——
#       抄表不会因为「数据陈旧」判失败，设备树里它也会顶到最前面
#       （排序规则：子树里有数据优先）。
#
# 用法：
#   bash 32-simulate-rtu.sh                 # 补一批历史（过去 3 小时）+ 最近一次
#   bash 32-simulate-rtu.sh --live          # 持续上报，每 10 秒一条，Ctrl-C 停止
#   bash 32-simulate-rtu.sh --label 正泰单相电表 --hours 6
#
# 为什么需要它：
#   「一键抄表」默认 pull=true，会向 RTU 网关下发 RPC 并等 15~30 秒。
#   RTU 不在线时这一批会全部超时失败。演示时要么让 RTU 真连着，
#   要么用本脚本把遥测灌进库里（pull 仍会超时，但"最近一次读数"可用，
#   台账/批次明细/趋势图都有数据可看）。
#
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:8090}"
TENANT_EMAIL="${TENANT_EMAIL:-tenant@126.com}"
TENANT_PASS="${TENANT_PASS:-12345678}"
LABEL="${LABEL:-正泰单相电表}"
HOURS="${HOURS:-3}"
STEP_MIN="${STEP_MIN:-5}"
LIVE="false"
LIVE_INTERVAL="${LIVE_INTERVAL:-10}"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)     LIVE="true"; shift ;;
    --label)    LABEL="$2"; shift 2 ;;
    --hours)    HOURS="$2"; shift 2 ;;
    --step)     STEP_MIN="$2"; shift 2 ;;
    --base)     BASE="$2"; shift 2 ;;
    --email)    TENANT_EMAIL="$2"; shift 2 ;;
    --password) TENANT_PASS="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *)          die "未知参数：$1" ;;
  esac
done

command -v curl >/dev/null || die "需要 curl"
command -v python3 >/dev/null || die "需要 python3"

NO_PROXY_ARGS=(--noproxy '*')
log "登录 $BASE"
TOKEN=$(curl -s "${NO_PROXY_ARGS[@]}" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$TENANT_EMAIL\",\"password\":\"$TENANT_PASS\"}" \
  | python3 -c "import sys,json;print((json.load(sys.stdin) or {}).get('token',''))" 2>/dev/null)
[[ -n "$TOKEN" ]] || die "登录失败 —— 检查 --email / --password"

# 找设备 id（按 label 精确匹配，找不到再按包含匹配）
DID=$(curl -s "${NO_PROXY_ARGS[@]}" -H "X-Authorization: Bearer $TOKEN" \
  "$BASE/api/tenant/devices?pageSize=200&page=0" \
  | python3 -c "
import sys, json
want = '''$LABEL'''
rows = (json.load(sys.stdin) or {}).get('data') or []
exact = [d for d in rows if (d.get('label') or '') == want]
fuzzy = [d for d in rows if want in (d.get('label') or '') or want in (d.get('name') or '')]
hit = exact or fuzzy
print((hit[0].get('id') or {}).get('id', '') if hit else '')")

[[ -n "$DID" ]] || die "找不到设备「$LABEL」—— 用 --label 指定正确的名称"
ok "设备 $LABEL → $DID"

# 生成并上传一个数据点
# 参数：ts（毫秒）。读数在 now.json 里累积，避免每次重来都从同一个值开始。
upload_one() {
  local ts="$1"
  local payload
  payload=$(python3 - "$ts" <<'PY'
import json, os, random, sys
ts = int(sys.argv[1])
state_path = '/tmp/rtu-sim-state.json'
try:
    st = json.load(open(state_path))
except Exception:
    st = {'reading': 1280.5, 'day': 2.8}
step = round(random.uniform(0.06, 0.12), 3)
st['reading'] = round(st['reading'] + step, 2)
# 每天归零一次（跨天时重置当日用电）
if random.random() < 0.002:
    st['day'] = 0.0
st['day'] = round(st['day'] + step, 3)
json.dump(st, open(state_path, 'w'))
print(json.dumps({
    'ts': ts,
    'values': {
        'energy_reading': st['reading'],
        'energy': step,
        'energy_day': st['day'],
        'voltage_a': round(random.uniform(219.5, 223.5), 2),
        'current_a': round(random.uniform(0.8, 1.6), 3),
        'power_total': round(random.uniform(0.18, 0.35), 3),
        'power_factor_a': round(random.uniform(0.90, 0.97), 3),
        'frequency': round(random.uniform(49.9, 50.1), 2),
    }
}, ensure_ascii=False))
PY
)
  # ★ 路径必须是 .../timeseries/{scope}，scope 是路径变量（值随便填）。
  #   写成 .../timeseries 会被当成缺少路径变量，返回 400。
  curl -s "${NO_PROXY_ARGS[@]}" -o /dev/null -w '%{http_code}' -X POST \
    "$BASE/api/plugins/telemetry/DEVICE/$DID/timeseries/ANY" \
    -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$payload"
}

if [[ "$LIVE" == "true" ]]; then
  log "持续上报中（每 ${LIVE_INTERVAL}s 一条），Ctrl-C 停止"
  trap 'echo; log "已停止"; exit 0' INT
  while true; do
    now_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
    code=$(upload_one "$now_ms")
    printf '  %s  %s\n' "$(date +%H:%M:%S)" "$([[ "$code" == "200" ]] && echo '上报成功' || echo "失败 HTTP $code")"
    sleep "$LIVE_INTERVAL"
  done
fi

log "补历史：过去 ${HOURS} 小时，每 ${STEP_MIN} 分钟一个点"
total=$(( HOURS * 60 / STEP_MIN ))
fail=0
for i in $(seq "$total" -1 1); do
  ts=$(python3 -c "import time;print(int(time.time()*1000) - $i*$STEP_MIN*60*1000)")
  code=$(upload_one "$ts")
  [[ "$code" == "200" ]] || fail=$((fail + 1))
done
# 最后补一个"此刻"，让 lastTs 落在现在
now_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
code=$(upload_one "$now_ms")
[[ "$code" == "200" ]] || fail=$((fail + 1))

echo
ok "完成：$((total + 1 - fail)) 个数据点写入成功，失败 $fail"
echo
echo "  下一步："
echo "    · 看当前读数：curl -s --noproxy '*' -H \"X-Authorization: Bearer \$TOKEN\" \\"
echo "        '$BASE/api/plugins/telemetry/DEVICE/$DID/values/timeseries?keys=energy_reading,voltage_a'"
echo "    · 演示持续上报：bash $0 --live"
echo
echo "  注意：抄表（pull=true）仍会向 RTU 网关下发采集指令并等待上报。"
echo "        RTU 不在线时那一批会超时失败 —— 本脚本灌的是"已有读数"，"
echo "        能用来看趋势/台账/批次明细，但不会让 RPC 成功。"
rm -f /tmp/rtu-sim-state.json 2>/dev/null
