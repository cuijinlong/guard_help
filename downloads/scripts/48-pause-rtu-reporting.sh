#!/usr/bin/env bash
#
# 能源管理平台 · 暂停 / 恢复真实设备的上报（用于受控重测）
#
# 为什么需要它（2026-11-15 实测）：
#   现场 RTU 每 3 秒上报一轮。只清库不停上报，清完立刻又有新数据 ——
#   「清空后灌 2 条已知数据再核对」根本做不到，因为库里永远不止 2 条。
#   本脚本通过轮换设备访问令牌（ACCESS_TOKEN）让上报被拒，从而真正暂停。
#
# 为什么不是断网 / 断电：
#   那要动硬件，且恢复后设备会补传积压数据，反而更乱。
#   轮换令牌只影响平台侧鉴权，设备网还在、心跳还在，恢复后立即继续。
#
# 为什么要连网关和设备都暂停：
#   实测：RTU 走**网关模式**（MQTT v1/gateway/telemetry），用的是网关的令牌。
#   只改子设备令牌，数据照样进来（子设备令牌在这条路径上根本不参与鉴权）。
#   而 HX2-StationController 走独立通道，必须单独暂停。
#   所以 --pause 默认处理「所有近期活跃设备」，而不是只处理一台。
#
# 用法（在部署目录内）：
#   bash scripts/48-pause-rtu-reporting.sh --list
#   bash scripts/48-pause-rtu-reporting.sh --pause
#   bash scripts/48-pause-rtu-reporting.sh --pause --device 'ED1-Gateway'
#   bash scripts/48-pause-rtu-reporting.sh --resume
#   bash scripts/48-pause-rtu-reporting.sh --resume --file backups/rtu-tokens/xxx.txt
#
# 退出码：0 成功 / 1 参数或前置失败 / 2 恢复失败（备份缺失）
#
set -uo pipefail

# 定位工作根：部署目录（有 .env）或仓库根（有 pom.xml）。
# 否则备份目录会错位到 shiyongshouce/downloads/backups（同 47 脚本）。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ -f "$SCRIPT_DIR/../../../pom.xml" ]]; then
  APP_HOME="$(cd "$SCRIPT_DIR/../../.." && pwd)"
else
  APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$APP_HOME"

MODE=""
ONLY=""
FILE=""
BASE="${BASE:-http://127.0.0.1:8090}"
TENANT="${TENANT:-tenant@126.com}"
TENANT_PASS="${TENANT_PASS:-12345678}"
WINDOW_MIN="${WINDOW_MIN:-10}"
TOKEN_DIR="backups/rtu-tokens"
CONTAINER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)   MODE="list"; shift ;;
    --pause)  MODE="pause"; shift ;;
    --resume) MODE="resume"; shift ;;
    --device) ONLY="$2"; shift 2 ;;
    --file)   FILE="$2"; shift 2 ;;
    --base)   BASE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done
[[ -n "$MODE" ]] || { echo "必须指定 --list / --pause / --resume" >&2; exit 1; }

# 直连容器（非 compose 环境，如仓库根目录调试）还是走 compose
if [[ -n "$CONTAINER" ]]; then
  PSQL=(docker exec -i "$CONTAINER" psql -U postgres -d thingsboard)
else
  if [[ -f .env ]]; then set -a; . ./.env 2>/dev/null; set +a; fi
  PSQL=(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}")
fi

# ---------------------------------------------------------------- 平台 API

jq_py() { python3 -c "
import json,sys
d=json.load(sys.stdin)
$1
"; }

login() {
  curl -s -m 15 -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$TENANT\",\"password\":\"$TENANT_PASS\"}" \
    | jq_py "print(d.get('token',''))"
}

TOK=$(login)
[[ -n "$TOK" ]] || { echo "登录失败：$TENANT @ $BASE" >&2; exit 1; }

get()  { curl -s -m 30 -H "X-Authorization: Bearer $TOK" "$BASE$1"; }
post() { curl -s -m 30 -X POST -H "X-Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
           "$BASE$1" -d "$2"; }

# 设备清单（名称 → id）
device_map() {
  local page=0
  while :; do
    local d
    d=$(get "/api/tenant/devices?pageSize=100&page=$page")
    echo "$d" | jq_py "
for x in d.get('data',[]): print(x['id']['id'] + '|' + x['name'])"
    echo "$d" | jq_py "print('HASNEXT:' + str(d.get('hasNext',False)))" | sed -n 's/^HASNEXT://p' | grep -q True || break
    page=$((page+1))
  done
}

# 最近活跃设备（有遥测写入的）
active_devices() {
  local since_ms
  since_ms=$(( ($(date +%s) - WINDOW_MIN * 60) * 1000 ))
  "${PSQL[@]}" -X -q -A -F'|' -t -c "
    SELECT DISTINCT d.name, count(*) AS pts
    FROM ts_kv_latest t JOIN device d ON d.id = t.entity_id
    WHERE t.ts >= $since_ms
    GROUP BY 1 ORDER BY 2 DESC" 2>/dev/null
}

# ---------------------------------------------------------------- 列表

if [[ "$MODE" == "list" ]]; then
  echo "最近 ${WINDOW_MIN} 分钟内有上报的设备："
  echo
  if ! active_devices | grep -q .; then
    echo "  （无。可能服务未运行，或确实没有设备在上报）"
    exit 0
  fi
  active_devices | while IFS='|' read -r name pts; do
    local_tok=$(get "/api/device/$(device_map | awk -F'|' -v n="$name" '$2==n{print $1}')/credentials" \
      | jq_py "print(d.get('credentialsId',''))")
    state="正常"
    [[ "$local_tok" == PAUSED* ]] && state="已暂停"
    printf '  %-40s %6s 点  %s\n' "$name" "$pts" "$state"
  done
  echo
  echo "暂停全部：bash scripts/48-pause-rtu-reporting.sh --pause"
  exit 0
fi

# ---------------------------------------------------------------- 暂停

if [[ "$MODE" == "pause" ]]; then
  mkdir -p "$TOKEN_DIR"
  STAMP=$(date +%Y%m%d-%H%M%S)
  BAK="$TOKEN_DIR/tokens-$STAMP.txt"

  if [[ -n "$ONLY" ]]; then
    TARGET_ID=$(device_map | awk -F'|' -v n="$ONLY" '$2==n{print $1}')
    [[ -n "$TARGET_ID" ]] || { echo "找不到设备：$ONLY" >&2; exit 1; }
    TARGETS="$ONLY|$TARGET_ID"
  else
    TARGETS=$(active_devices)
    [[ -n "$TARGETS" ]] || { echo "最近 ${WINDOW_MIN} 分钟没有设备上报，无需暂停" ; exit 0; }
  fi

  # ── 把网关父设备一并纳入 ──────────────────────────
  # 实测（2026-11-15）：RTU 走 MQTT 网关模式（v1/gateway/telemetry），
  # 鉴权用的是**网关**的令牌。只改子设备令牌，数据照样进来 ——
  # 子设备令牌在这条路径上根本不参与鉴权。
  # 所以必须沿 relation 找到 from=DEVICE 的父边（ED1-Gateway），一起暂停。
  #
  # 反过来：子设备也照样暂停，因为直连 HTTP 模式（v1/{token}/telemetry）
  # 用的是子设备自己的令牌。两种上报方式都堵上。
  GW_LIST=""
  while IFS='|' read -r name _rest; do
    [[ -n "$name" ]] || continue
    # 不假设第二列是 id：active_devices 输出的是「名字|点数」，ONLY 分支才是「名字|id」。
    # 统一按名字回查，避免把点数当成 uuid 拼进 URL（实测 2026-11-15：
    # dose 16 会被当成 id → API 400 → 解析报 'str' object has no attribute 'get'）。
    did=$(device_map | awk -F'|' -v n="$name" '$2==n{print $1}')
    [[ -n "$did" ]] || continue
    PARS=$(get "/api/relations?toId=$did&toType=DEVICE" | jq_py "
for r in d:
    f=r.get('from',{})
    if f.get('entityType')=='DEVICE': print(f.get('id',''))")
    for pid in $PARS; do
      [[ -n "$pid" ]] || continue
      pname=$(device_map | awk -F'|' -v i="$pid" '$1==i{print $2}')
      [[ -n "$pname" ]] || continue
      if ! echo "$GW_LIST" | grep -qx "$pname"; then
        GW_LIST="${GW_LIST}${GW_LIST:+$'\n'}$pname|$pid"
      fi
    done
  done <<< "$TARGETS"

  if [[ -n "$GW_LIST" ]]; then
    echo "检测到网关子设备，网关一并暂停（它才是鉴权主体）："
    echo "$GW_LIST" | while IFS='|' read -r n _; do [[ -n "$n" ]] && echo "  + ${n}（网关）"; done
    # 合并去重
    MERGED=$(printf '%s\n%s\n' "$TARGETS" "$GW_LIST" | awk -F'|' 'NF && !seen[$1]++')
    TARGETS="$MERGED"
    echo
  fi

  echo "将暂停以下设备的上报（令牌轮换，可 --resume 恢复）："
  echo "$TARGETS" | while IFS='|' read -r name _; do echo "  · $name"; done
  echo

  : > "$BAK"
  printf '# %s 暂停前的原始令牌（勿删，--resume 依赖它）\n' "$STAMP" >> "$BAK"

  FAIL=0
  while IFS='|' read -r name _; do
    [[ -n "$name" ]] || continue
    DID=$(device_map | awk -F'|' -v n="$name" '$2==n{print $1}')
    [[ -n "$DID" ]] || { echo "  ! 找不到 $name"; FAIL=1; continue; }
    CUR=$(get "/api/device/$DID/credentials")
    OLD=$(echo "$CUR" | jq_py "print(d.get('credentialsId',''))")
    CID=$(echo "$CUR" | jq_py "print(d['id']['id'])")
    if [[ "$OLD" == PAUSED* ]]; then
      echo "  · $name 已是暂停状态，跳过"
      continue
    fi
    printf '%s|%s|%s\n' "$name" "$DID" "$OLD" >> "$BAK"
    NEW="PAUSED-$(date +%s)-$RANDOM"
    RESP=$(post "/api/device/credentials" \
      "{\"id\":{\"id\":\"$CID\"},\"deviceId\":{\"entityType\":\"DEVICE\",\"id\":\"$DID\"},\"credentialsType\":\"ACCESS_TOKEN\",\"credentialsId\":\"$NEW\"}")
    if echo "$RESP" | grep -q "$NEW"; then
      echo "  ✓ $name 已暂停"
    else
      echo "  ✗ $name 暂停失败：$(echo "$RESP" | head -c 120)"
      FAIL=1
    fi
  done <<< "$TARGETS"

  echo
  echo "原始令牌已备份到：$BAK"
  [[ "$FAIL" == "0" ]] || { echo "有设备暂停失败，见上" >&2; exit 1; }
  echo "恢复：bash scripts/48-pause-rtu-reporting.sh --resume"
  exit 0
fi

# ---------------------------------------------------------------- 恢复

if [[ "$MODE" == "resume" ]]; then
  if [[ -z "$FILE" ]]; then
    FILE=$(ls -t "$TOKEN_DIR"/tokens-*.txt 2>/dev/null | head -1)
  fi
  [[ -n "$FILE" && -f "$FILE" ]] || {
    echo "找不到备份文件（$TOKEN_DIR/tokens-*.txt）" >&2
    echo "无法恢复：原始令牌已丢失，需要按设备重新配置令牌" >&2
    exit 2
  }

  echo "从 $FILE 恢复："
  FAIL=0
  while IFS='|' read -r name did old; do
    [[ "$name" == \#* || -z "$name" ]] && continue
    CUR=$(get "/api/device/$did/credentials")
    CID=$(echo "$CUR" | jq_py "print(d['id']['id'])")
    RESP=$(post "/api/device/credentials" \
      "{\"id\":{\"id\":\"$CID\"},\"deviceId\":{\"entityType\":\"DEVICE\",\"id\":\"$did\"},\"credentialsType\":\"ACCESS_TOKEN\",\"credentialsId\":\"$old\"}")
    if echo "$RESP" | grep -q "\"credentialsId\":\"$old\""; then
      echo "  ✓ $name 已恢复"
    else
      echo "  ✗ $name 恢复失败：$(echo "$RESP" | head -c 120)"
      FAIL=1
    fi
  done < "$FILE"

  echo
  [[ "$FAIL" == "0" ]] && echo "恢复完成。等 1 分钟确认数据重新进来：" && \
    echo "  bash scripts/48-pause-rtu-reporting.sh --list"
  [[ "$FAIL" == "0" ]] || exit 2
  exit 0
fi
