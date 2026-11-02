#!/usr/bin/env bash
# ==============================================================================
# RTU 演示环境一键部署（2026-11-02）
#
# 一条命令把演示环境从「刚装好的空库」推进到「客户登录就能看到数据」。
#
# ⚠️ 它**不是**从裸库开始的第一步。完整链路：
#     ① 01-install.sh  建表 + 装系统资源 + 建 SYS_ADMIN
#     ② 02-onboard.sh  建租户 + 租户管理员（默认 tenant@126.com）
#     ③ 29-rtu-demo-up.sh  ← 本脚本：客户 / 场站 / 设备 / 数据
#   裸库直接跑本脚本会卡在「租户管理员登录」（账号不存在）。
#
# ★ 数据来源可以任一、可以并存（2026-11-02 客户要求）：
#
#   真实 RTU 自己上报（硬件行为，脚本控制不了）；
#   模拟上报由本脚本跑 31-rtu-simulate.py 控制。
#   两者写的是**不同设备**，互不覆盖，场站总量是两者之和。
#
#   ┌──────────────────┬────────┬────────┬──────────────────────────────┐
#   │ 场景             │ 模拟   │ 真实   │ 命令                         │
#   ├──────────────────┼────────┼────────┼──────────────────────────────┤
#   │ 纯演示（无硬件） │  开    │   --   │ --sim-only                   │
#   │ 纯现场（真表）   │  关    │  开    │ --no-sim                     │
#   │ 混合（真表+模拟）│  开    │  开    │ 默认（不加这两个参数）       │
#   │ 只看不跑         │   --   │   --   │ --status                     │
#   └──────────────────┴────────┴────────┴──────────────────────────────┘
#
# 用法：
#   bash scripts/29-rtu-demo-up.sh                          # 默认：初始化 + 混合数据
#   bash scripts/29-rtu-demo-up.sh --customer "新客户名"     # 给新客户初始化
#   bash scripts/29-rtu-demo-up.sh --sim-only               # 只跑模拟上报（长期）
#   bash scripts/29-rtu-demo-up.sh --no-sim                 # 不跑模拟，只靠真实 RTU
#   bash scripts/29-rtu-demo-up.sh --backfill-days 0        # 不回填历史
#   bash scripts/29-rtu-demo-up.sh --status                 # 看谁在报、谁停了
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
NO_SIM=0
STATUS_ONLY=0
CHECK_ONLY=0
INTERVAL=30
# ★ 默认回填 30 天（2026-11-02 干净库实测）：
#   29 只发一轮实时数据的话，7 天窗口里只有 1 个点，客户打开看板看到的是
#   「0.59 kW·h + 一条平线」—— 演示效果等同于没数据。
#   综合能耗看板默认周期就是「近 30 天」，回填 30 天才能直接出曲线。
#   传 --backfill-days 0 可关闭（真实 RTU 现场不需要造历史）。
BACKFILL_DAYS=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer)  CUSTOMER="$2"; shift 2 ;;
    --base)      BASE="$2"; shift 2 ;;
    --tenant)    TENANT="$2"; shift 2 ;;
    --password)  TENANT_PASS="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --backfill-days) BACKFILL_DAYS="$2"; shift 2 ;;
    --sim-only)  SIM_ONLY=1; shift ;;
    --no-sim)    NO_SIM=1; shift ;;
    --status)    STATUS_ONLY=1; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    -h|--help)   sed -n '2,42p' "$0"; exit 0 ;;
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
ok "标准 key ${KEYS:-?} 个（电能 122 项，按 tier 分级；详见手册"电能质量覆盖"一节）"

# ---------------------------------------------------------------- 状态检查
#
# 「谁在上报」不能靠猜。真实 RTU 是硬件自己发的，模拟是脚本发的，
# 两者都可能静默停掉（RTU 断电/断网、模拟脚本被 Ctrl-C 或进程被杀）。
# 判据只有一个：**库里最后一次写入距今多久**。
#
# 为什么不用 ps 查进程：脚本可能被 nohup / systemd / 另一个终端跑着，
# 进程名、工作目录都不固定，漏判比误判更危险。
show_status() {
  step "数据来源状态（${CUSTOMER}）"
  local sql_out
  sql_out=$(docker exec energy-postgres psql -U postgres -d thingsboard -t -A -F'|' -c "
    SELECT
      CASE WHEN (d.additional_info::json->>'simulated')::text = 'true'
           THEN 'sim' ELSE 'real' END AS src,
      d.name,
      count(t.ts) AS pts,
      coalesce(round(extract(epoch from (now() - to_timestamp(max(t.ts)/1000)))), -1) AS age_s
    FROM device d
    LEFT JOIN ts_kv t ON t.entity_id = d.id
    WHERE d.customer_id = (SELECT id FROM customer WHERE title = '${CUSTOMER}')
      -- ★ 只看真正产生业务遥测的设备（2026-11-02 修）：
      --   网关是转发节点，本身不上报业务量。把它列进来会永远显示「已停」，
      --   掩盖真正停掉的表 —— 判活列表必须只含表计与采集设备。
      AND coalesce((d.additional_info::json->>'gateway')::text, 'false') <> 'true'
      AND d.type <> '网关'
    GROUP BY 1, 2
    ORDER BY 1 DESC, 4 ASC;" 2>/dev/null)

  if [[ -z "$sql_out" ]]; then
    warn "查不到设备（客户名对吗？库里有这个客户吗？）"
    warn "手动查：docker exec energy-postgres psql -U postgres -d thingsboard"
    return
  fi

  local real_ok=0 real_bad=0 sim_ok=0 sim_bad=0
  # 中文按 2 格宽对齐（printf 的 %-Ns 按字符数算，中文会歪）
  pad() {
    local s="$1" w="${2:-34}" n=0 ch
    for ((i = 0; i < ${#s}; i++)); do
      ch="${s:i:1}"
      if [[ "$ch" =~ [\x{4e00}-\x{9fff}－] ]]; then n=$((n + 2)); else n=$((n + 1)); fi
    done
    printf '%s' "$s"
    local k=$((w - n)); ((k > 0)) && printf '%*s' "$k" ''
  }
  printf '  %s %s %s %s\n' "$(pad 来源 6)" "$(pad 设备 34)" "$(pad 最后上报 10)" "判定"
  printf '  %s\n' "────────────────────────────────────────────────────────────"
  while IFS='|' read -r src name pts age; do
    [[ -z "$src" ]] && continue
    local label fresh
    # 真实 RTU 按 2 分钟判活（现场间隔可能到 1 分钟）；模拟按 5 分钟（默认 30s 一轮）
    if [[ "$src" == "real" ]]; then
      if [[ "$age" -le 120 && "$age" -ge 0 ]]; then
        label="实时"; fresh=1; ((real_ok++))
      else
        label="已停"; fresh=0; ((real_bad++))
      fi
    else
      if [[ "$age" -le 300 && "$age" -ge 0 ]]; then
        label="实时"; fresh=1; ((sim_ok++))
      else
        label="已停"; fresh=0; ((sim_bad++))
      fi
    fi
    local ago
    if [[ "$age" -lt 0 ]]; then ago="从未上报"
    elif [[ "$age" -lt 90 ]]; then ago="${age}s 前"
    elif [[ "$age" -lt 5400 ]]; then ago="$((age/60)) 分钟前"
    else ago="$((age/3600)) 小时前"; fi
    local tag
    [[ "$src" == "real" ]] && tag="真实" || tag="模拟"
    if [[ $fresh == 1 ]]; then
      printf '  %s %s %s \033[32m✓ %s\033[0m\n' "$(pad "$tag" 6)" "$(pad "$name" 34)" "$(pad "$ago" 10)" "$label"
    else
      printf '  %s %s %s \033[33m! %s\033[0m\n' "$(pad "$tag" 6)" "$(pad "$name" 34)" "$(pad "$ago" 10)" "$label"
    fi
  done <<< "$sql_out"

  echo
  if [[ $real_bad -eq 0 && $real_ok -gt 0 ]]; then
    ok "真实 RTU：${real_ok} 台在上报"
  elif [[ $real_ok -eq 0 && $real_bad -eq 0 ]]; then
    warn "真实 RTU：这个客户下没有真实设备"
  else
    warn "真实 RTU：${real_bad} 台已停（查板子供电 / WiFi / 平台地址）"
  fi
  if [[ $sim_bad -eq 0 && $sim_ok -gt 0 ]]; then
    ok "模拟上报：${sim_ok} 台在上报"
  elif [[ $sim_ok -eq 0 && $sim_bad -eq 0 ]]; then
    warn "模拟上报：这个客户下没有模拟设备"
  else
    warn "模拟上报：${sim_bad} 台已停 → 启动: bash \$0 --sim-only"
  fi

  # 进程检查只做提示，不作为判据
  local procs
  procs=$(pgrep -fl "31-rtu-simulate.py" 2>/dev/null | wc -l | tr -d ' ')
  echo
  if [[ "$procs" != "0" ]]; then
    ok "模拟脚本进程：${procs} 个在跑"
  else
    warn "模拟脚本进程：未检测到（没在跑，或跑在另一台机器上）"
    # ★ 进程不在但数据「新鲜」= 残留读数，不是真的在报（2026-11-02）
    #   判活看「最后写入时间」，它最多能反映 5 分钟前的状态。
    #   不说明这一点，客户会以为模拟还在跑，等 5 分钟后数字突然不动。
    if [[ $sim_ok -gt 0 ]]; then
      echo "      ↑ 上面 ${sim_ok} 台显示「实时」是**残留读数**（5 分钟内的最后写入），"
      echo "        不会继续更新。要真正继续报：bash $0 --sim-only"
    fi
  fi
}

if [[ $STATUS_ONLY == 1 ]]; then
  show_status
  exit 0
fi

if [[ $SIM_ONLY == 1 || $CHECK_ONLY == 1 ]]; then
  if [[ $CHECK_ONLY == 1 ]]; then
    step "体检结果"
    "$PY" "$HERE/30-rtu-env-init.py" --base "${BASE}" --customer "${CUSTOMER}" \
      --tenant "${TENANT}" --tenant-pass "$TENANT_PASS" --dry-run | tail -20
    exit 0
  fi
  step "只跑模拟上报（${CUSTOMER}，每 ${INTERVAL}s 一轮）"
  echo "  真实 RTU 不受影响，会照常上报（两者写不同设备，互不覆盖）"
  echo "  Ctrl-C 停"
  show_status
  echo
  exec "$PY" -u "$HERE/31-rtu-simulate.py" --base "${BASE}" --customer "${CUSTOMER}" \
    --tenant "${TENANT}" --tenant-pass "$TENANT_PASS" --interval "${INTERVAL}"
fi

# ---------------------------------------------------------------- 3. 客户 + 场站 + 设备
step "3. 客户 / 场站 / 设备（${CUSTOMER}）"
"$PY" "$HERE/30-rtu-env-init.py" \
  --base "${BASE}" --customer "${CUSTOMER}" \
  --tenant "${TENANT}" --tenant-pass "$TENANT_PASS"
RC=$?
# ★ 必须在此终止（2026-11-02 干净库实测）：
#   旧版只打一行「有失败项」就继续往下跑，第 4b 步照样重算汇总、
#   末尾照样打印「完成」—— 干净环境首次部署时客户建超时、一台设备都没建，
#   用户看到的却是「完成」，以为部署好了。
#   初始化没成，后面两步都是无意义的（汇总只能汇总到后端自动建的演示数据）。
if [[ $RC -ne 0 ]]; then
  bad "初始化有失败项（退出码 ${RC}）—— 已停在这里，后面的发数据/重算不会执行"
  echo
  echo "  排查建议："
  echo "    1) 看上面 ✗ 那一段的具体错误"
  echo "    2) 首次部署大概率是「后端正在异步初始化演示数据」—— 等 1 分钟重跑本脚本"
  echo "    3) 仍失败就加 --check 看体检结果：bash \$0 --check --base ${BASE}"
  exit 1
fi

# ---------------------------------------------------------------- 4. 发一轮数据
#
# --no-sim：完全不碰模拟设备（不发、不回填）。
#   适用：现场已经接了真实 RTU，客户不想看到任何假数据。
#   注意：此时看板能不能出数，**完全取决于真实表有没有在报** ——
#   没报的话页面就是空的，这是真实状态，不是故障。
if [[ $NO_SIM == 1 ]]; then
  step "4. 跳过模拟数据（--no-sim：只依赖真实 RTU）"
  warn "不发模拟数据、不做历史回填"
  echo "  看板能不能出数，取决于真实表是否在报；用 --status 确认"
else
  step "4. 发一轮数据 + 回填 ${BACKFILL_DAYS} 天历史（让客户立刻看到曲线）"
  "$PY" "$HERE/31-rtu-simulate.py" \
    --base "${BASE}" --customer "${CUSTOMER}" \
    --tenant "${TENANT}" --tenant-pass "$TENANT_PASS" --once \
    --backfill-days "${BACKFILL_DAYS}" 2>&1 | tail -16
fi

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
  数据来源  : $([[ $NO_SIM == 1 ]] && echo "仅真实 RTU（未发模拟数据）" || echo "真实 RTU + 模拟（两者并存）")

  下一步    :

    # 看谁在报、谁停了（最常用）
    bash $0 --status

    # 持续跑模拟上报（演示期间保持运行，Ctrl-C 停）
    #   ★ 不影响真实 RTU —— 它自己在上报，两者写不同设备
    bash $0 --sim-only

    # 只靠真实表、完全不要模拟数据
    bash $0 --no-sim

  客户登录  :
    账号在初始化输出里（形如 demo+xxxxxxxx@126.com / demo123456）
    也可以在「客户与用户 → 用户」里查

EOF
