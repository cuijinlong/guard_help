#!/usr/bin/env bash
# ==============================================================================
# RTU 演示环境一键部署（2026-11-02）
#
# 一条命令把演示环境从「刚装好的空库」推进到「客户登录就能看到数据」。
#
# 用法：
#   bash scripts/29-rtu-demo-up.sh                          # 默认客户「平台演示中心」
#   bash scripts/29-rtu-demo-up.sh --customer "新客户名"     # 给新客户初始化
#   bash scripts/29-rtu-demo-up.sh --sim-only               # 只跑模拟上报
#   bash scripts/29-rtu-demo-up.sh --check                  # 只体检，不改数据
#
# 幂等：反复执行无害。
# ==============================================================================
set -uo pipefail

BASE="http://127.0.0.1:8090"
TENANT="tenant@126.com"
TENANT_PASS="12345678"
CUSTOMER="平台演示中心"
SIM_ONLY=0
CHECK_ONLY=0
INTERVAL=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer)  CUSTOMER="$2"; shift 2 ;;
    --base)      BASE="$2"; shift 2 ;;
    --tenant)    TENANT="$2"; shift 2 ;;
    --password)  TENANT_PASS="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --sim-only)  SIM_ONLY=1; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python3}"
step() { printf '\n\033[1;36m━━ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

# ---------------------------------------------------------------- 0. 探活
step "0. 平台探活"
for i in $(seq 1 30); do
  code=$(curl -s --noproxy '*' -m 3 -o /dev/null -w '%{http_code}' "$BASE/api/noauth/energy/health" 2>/dev/null)
  [[ "${code}" == "200" ]] && { ok "平台在线（${BASE}）"; break; }
  [[ $i == 30 ]] && { bad "连不上 $BASE —— 先确认容器起来了：docker ps | grep energy-server"; exit 1; }
  sleep 2
done

# ---------------------------------------------------------------- 1. 登录
step "1. 租户管理员登录"
TOKEN=$(curl -s --noproxy '*' -m 20 -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$TENANT\",\"password\":\"$TENANT_PASS\"}" \
  | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
if [[ -z "${TOKEN}" ]]; then
  bad "登录失败：$TENANT —— 账号或密码不对？"
  exit 1
fi
ok "登录成功"
echo "${TOKEN}" > /tmp/.rtu_demo_token

# ---------------------------------------------------------------- 2. 品种库
step "2. 品种库（能源参数字典）"
LIB=$(curl -s --noproxy '*' -m 30 -H "X-Authorization: Bearer ${TOKEN}" \
  "$BASE/api/tenant/assets?pageSize=500&page=0" \
  | "$PY" -c '
import sys,json
d=json.load(sys.stdin)
hit=[a for a in (d.get("data") or []) if a.get("name")=="能源参数字典"]
print(hit[0]["id"]["id"] if hit else "")' 2>/dev/null)

if [[ -z "${LIB}" ]]; then
  warn "品种库不存在 —— 调一次 repair-init（会装档案/规则/菜单，约 1-3 分钟）"
  if [[ $CHECK_ONLY == 1 ]]; then
    bad "体检模式：需要先跑一次「平台自检 → 一键修复初始化」"
    exit 1
  fi
  curl -s --noproxy '*' -m 600 -X POST -H "X-Authorization: Bearer ${TOKEN}" \
    "$BASE/api/energy/repair-init" -o /tmp/.rtu_repair.json -w '  HTTP %{http_code}  %{time_total}s\n'
  LIB=$(curl -s --noproxy '*' -m 30 -H "X-Authorization: Bearer ${TOKEN}" \
    "$BASE/api/tenant/assets?pageSize=500&page=0" \
    | "$PY" -c '
import sys,json
d=json.load(sys.stdin)
hit=[a for a in (d.get("data") or []) if a.get("name")=="能源参数字典"]
print(hit[0]["id"]["id"] if hit else "")' 2>/dev/null)
  [[ -z "${LIB}" ]] && { bad "repair-init 跑完仍没有品种库，看服务端日志"; exit 1; }
  ok "品种库已建（${LIB}）"
else
  ok "品种库已存在（${LIB}）"
fi

# 字典 key 数（体检用）
KEYS=$(curl -s --noproxy '*' -m 30 -H "X-Authorization: Bearer ${TOKEN}" \
  "$BASE/api/energy/core-dictionaries" \
  | "$PY" -c 'import sys,json;d=json.load(sys.stdin);print(len(d.get("standardKeys") or []))' 2>/dev/null)
ok "标准 key ${KEYS:-?} 个（含电能质量 62 个）"

if [[ $SIM_ONLY == 1 || $CHECK_ONLY == 1 ]]; then
  if [[ $CHECK_ONLY == 1 ]]; then
    step "体检结果"
    "$PY" "$HERE/30-rtu-env-init.py" --base "${BASE}" --customer "${CUSTOMER}" \
      --tenant "${TENANT}" --tenant-pass "$TENANT_PASS" --dry-run | tail -20
    exit 0
  fi
  step "只跑模拟上报（${CUSTOMER}，每 ${INTERVAL}s 一轮）"
  exec "$PY" -u "$HERE/31-rtu-simulate.py" --base "${BASE}" --customer "${CUSTOMER}" \
    --tenant "${TENANT}" --tenant-pass "$TENANT_PASS" --interval "${INTERVAL}"
fi

# ---------------------------------------------------------------- 3. 客户 + 场站 + 设备
step "3. 客户 / 场站 / 设备（${CUSTOMER}）"
"$PY" "$HERE/30-rtu-env-init.py" \
  --base "${BASE}" --customer "${CUSTOMER}" \
  --tenant "${TENANT}" --tenant-pass "$TENANT_PASS"
RC=$?
[[ $RC -ne 0 ]] && { bad "初始化有失败项（退出码 ${RC}）"; }

# ---------------------------------------------------------------- 4. 发一轮数据
step "4. 发一轮数据（让客户立刻看到东西）"
"$PY" "$HERE/31-rtu-simulate.py" \
  --base "${BASE}" --customer "${CUSTOMER}" \
  --tenant "${TENANT}" --tenant-pass "$TENANT_PASS" --once 2>&1 | tail -12

# ---------------------------------------------------------------- 4b. 重算资产汇总
# ★ 必需：看板「选场站/选分项」读的是资产上的汇总遥测（energy_total / energy_day），
#   平台不会在每次设备上报时自动往上汇总。不重算，客户打开看板就是一片空的
#   （实测 2026-11-02：设备有数据、资产汇总为 0，页面显示 -/-）。
step "4b. 重算资产汇总"
curl -s --noproxy '*' -m 300 -X POST -H "X-Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  "${BASE}/api/energy/asset-totals/rebuild" -d '{}' \
  | "$PY" -c 'import sys,json;d=json.load(sys.stdin);print("  写入资产: %s 个，窗口 %s 天" % (d.get("assetsWritten"), d.get("days")))' \
  2>/dev/null || warn "汇总重算失败（不影响数据，稍后可手工重跑）"

# ---------------------------------------------------------------- 5. 收尾
step "完成"
cat <<EOF

  客户      : $CUSTOMER
  下一步    :

    # 持续上报（演示期间保持运行，Ctrl-C 停）
    bash $0 --customer "${CUSTOMER}"

    # 或只跑上报、不碰数据
    bash $0 --customer "${CUSTOMER}" --sim-only

  客户登录  :
    账号在初始化输出里（形如 demo+xxxxxxxx@126.com / demo123456）
    也可以在「客户与用户 → 用户」里查

EOF
