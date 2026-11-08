#!/usr/bin/env bash
#
# 能源管理平台 · RTU 接入一键诊断（只读，不改任何东西）
#
# 场景：客户现场插上 RTU、配好网络，但「实时能耗」看不到数据变化。
# 本脚本按顺序把**平台侧能查的都查一遍**，最后给出一句话结论。
#
# 用法（在部署目录执行）：
#   bash scripts/34-rtu-diagnose.sh
#   bash scripts/34-rtu-diagnose.sh --customer '某某厂区'
#   bash scripts/34-rtu-diagnose.sh --serial /dev/tty.usbserial-XXXX   # 顺带读板子日志
#   bash scripts/34-rtu-diagnose.sh --firmware /path/to/rtu/main.py     # 指定固件路径
#
# ★ 它查什么、为什么这么排：
#
#   ① 本机 IP        —— RTU 必须连「这台机器」，不是 127.0.0.1
#   ② 固件 TB_HOST   —— 换电脑后最常见的坑：仓库改了、板子上没改
#   ③ 端口监听 + 局域网可达 —— 11883 映射到容器 1883，缺一个都连不上
#   ④ 已建立的 MQTT 连接 —— **平台侧最硬的证据**：0 条 = RTU 没连上来
#   ⑤ 局域网里的 ESP32 —— 用 ARP 的 MAC 前缀找板子，确认它到底在不在网内
#   ⑥ 设备上报时间   —— 区分「真实 RTU 设备」与「模拟设备」，别被 SIM 误导
#
#   排障顺序很重要：③ 不通就别看 ④⑤⑥；④ 有连接但 ⑥ 没数据，问题在规则链。
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="$(cd "$HERE/.." && pwd)"
[ -f "$APP_HOME/.env" ] && { set -a; . "$APP_HOME/.env" 2>/dev/null; set +a; }

PORT="${HTTP_PORT:-8090}"
MQTT_PORT="${MQTT_PORT:-1883}"
RTU_PORT="${MQTT_RTU_PORT:-11883}"
PSQL_CONTAINER="${PSQL_CONTAINER:-energy-postgres}"
CUSTOMER=""
SERIAL=""
FIRMWARE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer) CUSTOMER="$2"; shift 2 ;;
    --serial)   SERIAL="$2"; shift 2 ;;
    --firmware) FIRMWARE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

RC=0
step() { printf '\n\033[1;36m━━ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; RC=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

psql_q() {
  docker exec "$PSQL_CONTAINER" psql -U postgres -d thingsboard -t -A -c "$1" 2>/dev/null
}

echo "============================================================"
echo " RTU 接入诊断"
echo " 部署目录 $APP_HOME"
echo " 时间     $(date '+%F %T')"
echo "============================================================"

# ---------------------------------------------------------------- ① 本机 IP
step "① 本机 IP（RTU 要连这个地址）"
LAN_IPS=()
for i in en0 en1 en2 en3 en4 en5 eth0 eth1 wlan0 wlp2s0 ens33 ens160; do
  ip=$(ipconfig getifaddr "$i" 2>/dev/null || ip -4 addr show "$i" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  if [[ -n "${ip:-}" && "$ip" != 127.* ]]; then
    LAN_IPS+=("$ip")
    info "$i = $ip"
  fi
done
if [[ ${#LAN_IPS[@]} -eq 0 ]]; then
  bad "没有局域网 IP —— 这台机器没连网络，RTU 无从连起"
else
  ok "局域网地址：${LAN_IPS[*]}"
  info "RTU 固件 TB_HOST 必须填上面其中之一（不能填 127.0.0.1）"
fi

# ---------------------------------------------------------------- ② 固件配置
step "② 固件配置（仓库里的 rtu/main.py）"
# 固件可能在两处：部署目录自带一份，或仓库里（现场常见）
FW=""
for cand in \
    "${FIRMWARE:-}" \
    "$APP_HOME/rtu/main.py" \
    "$APP_HOME/../iot-rule-engine/rtu/main.py" \
    "$HOME/Documents/workspace/iot-rule-engine/rtu/main.py" \
    "$HOME/iot-rule-engine/rtu/main.py"; do
  [[ -n "$cand" && -f "$cand" ]] && { FW="$cand"; break; }
done
if [[ -z "$FW" ]]; then
  warn "找不到 rtu/main.py，跳过（不影响平台侧判断）"
else
  # BSD sed 不认 \s，统一用 python 提取（脚本本来就依赖 python3）
  fw_vars=$(python3 - "$FW" <<'PYFW'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
def grab(pat, default=''):
    m = re.search(pat, src, re.M)
    return m.group(1) if m else default
print('|'.join([
    grab(r'^TB_HOST\s*=\s*"([^"]*)"'),
    grab(r'^TB_TOKEN\s*=\s*"([^"]*)"'),
    grab(r'^GATEWAY_NAME\s*=\s*"([^"]*)"'),
    grab(r'^TB_PORT\s*=\s*(\d+)'),
    grab(r'^METER_DEVICE\s*=\s*"([^"]*)"'),
]))
PYFW
)
  IFS='|' read -r fw_host fw_tok fw_gw fw_port fw_meter <<< "$fw_vars"
  info "文件      $FW"
  info "TB_HOST   ${fw_host:-未找到}"
  info "TB_PORT   ${fw_port:-未找到}"
  info "GATEWAY   ${fw_gw:-未找到}"
  info "TB_TOKEN  ${fw_tok:0:6}…（末四位 ${fw_tok: -4}）"

  host_ok=false
  for ip in "${LAN_IPS[@]:-}"; do
    [[ "$fw_host" == "$ip" ]] && host_ok=true
  done
  if [[ "$fw_host" == "127.0.0.1" || "$fw_host" == "localhost" ]]; then
    bad "TB_HOST 填的是 $fw_host —— 板子连不到本机回环地址"
  elif $host_ok; then
    ok "TB_HOST 与本机 IP 一致"
  else
    bad "TB_HOST=$fw_host 不是本机当前 IP（${LAN_IPS[*]:-无}）"
    info "换电脑 / 换网络后必须改这里，并**重新上传到板子**"
  fi

  # 令牌与平台侧比对
  if [[ -n "${fw_tok:-}" ]]; then
    plat_tok=$(psql_q "select dc.credentials_id from device d
                        join device_credentials dc on dc.device_id=d.id
                        where d.name='$fw_gw' limit 1;")
    if [[ -z "$plat_tok" ]]; then
      bad "平台上没有网关设备 $fw_gw —— 跑 scripts/30-rtu-env-init.py"
    elif [[ "$plat_tok" == "$fw_tok" ]]; then
      ok "令牌与平台一致（板子不用改）"
    else
      bad "令牌不一致：固件 ${fw_tok:0:6}… vs 平台 ${plat_tok:0:6}…"
      info "要么重跑 30-rtu-env-init.py 固定令牌，要么把固件改成平台这个值"
    fi
  fi
  warn "★ 改了这个文件 ≠ 板子生效：必须用 mpremote / Thonny 重新上传到板子"
fi

# ---------------------------------------------------------------- ③ 端口
step "③ 端口监听与局域网可达"
for pair in "$MQTT_PORT:MQTT" "$RTU_PORT:RTU约定口" "$PORT:HTTP"; do
  p="${pair%%:*}"; label="${pair##*:}"
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    ok "$p ($label) 已监听"
  else
    bad "$p ($label) 没有监听 —— 容器没起？docker compose ps 看一眼"
    continue
  fi
  # 从局域网 IP 测，模拟 RTU 视角
  if [[ ${#LAN_IPS[@]} -gt 0 ]]; then
    if nc -z -G 3 "${LAN_IPS[0]}" "$p" >/dev/null 2>&1; then
      info "从 ${LAN_IPS[0]} 可达"
    else
      bad "从 ${LAN_IPS[0]} 不可达 —— 防火墙拦了"
      info "macOS: 系统设置 → 网络 → 防火墙；Linux: ufw allow $p/tcp"
    fi
  fi
done

# ---------------------------------------------------------------- ④ MQTT 连接
step "④ 已建立的 MQTT 连接（最硬的证据）"
CONN=$(netstat -an 2>/dev/null | grep -E "\.$MQTT_PORT|\.$RTU_PORT" | grep -c ESTABLISHED)
if [[ "$CONN" -gt 0 ]]; then
  ok "$CONN 条连接已建立"
  netstat -an 2>/dev/null | grep -E "\.$MQTT_PORT|\.$RTU_PORT" | grep ESTABLISHED | head -5 | sed 's/^/    /'
else
  bad "0 条连接 —— RTU 没有连到平台"
  info "这条是分水岭：0 条说明问题在 RTU 侧（网络/地址/令牌）或还没上电连上 WiFi"
  info "排查顺序：WiFi 连上没有 → TB_HOST 对不对 → 令牌对不对"
fi

# ---------------------------------------------------------------- ⑤ 找板子
step "⑤ 局域网里的 ESP32 / RTU"
# 84:c7:bb = Espressif；也认乐鑫其它常见前缀
FOUND=$(arp -an 2>/dev/null | grep -iE "84:c7:bb|(^|[^0-9a-f])(24:0a:c4|30:ae:a4|7c:df:a1|a0:76:4e|b4:8a:0a)" || true)
if [[ -n "$FOUND" ]]; then
  ok "ARP 表里找到疑似 ESP32："
  echo "$FOUND" | sed 's/^/    /'
  info "能 ARP 到说明二层通；板子不一定响应 ping（MicroPython 网络栈常见）"
  for ip in $(echo "$FOUND" | sed -n 's/.*(\([0-9.]*\)).*/\1/p'); do
    if ping -c 2 -W 1000 "$ip" >/dev/null 2>&1; then
      info "$ip  ping 通"
    else
      info "$ip  ping 不通（可能是正常的，不能据此判定板子挂了）"
    fi
  done
else
  warn "ARP 表里没有 ESP32 的 MAC"
  info "说明这块网段里没有板子 —— 检查：板子上电了吗？连的是同一个 WiFi 吗？"
  info "（同一路由器下不同 SSID 也可能互相隔离，尤其「访客网络」）"
fi

# ---------------------------------------------------------------- ⑥ 上报时间
step "⑥ 设备上报时间（区分真实 RTU 与模拟）"
if [[ -n "$CUSTOMER" ]]; then
  CID=$(psql_q "select id from customer where title='$CUSTOMER' limit 1;")
  [[ -n "$CID" ]] || { bad "找不到客户「$CUSTOMER」"; CID=""; }
else
  CID=$(psql_q "select id from customer order by created_time limit 1;")
  [[ -n "$CID" ]] && info "未指定 --customer，用第一个客户 $(psql_q "select title from customer where id='$CID';")"
fi

if [[ -n "${CID:-}" ]]; then
  echo
  echo "  真实 RTU 设备（由板子直接上报）"
  psql_q "
    select '    ' || d.name || '  ' ||
           coalesce(to_char(to_timestamp(max(k.ts)/1000) at time zone 'Asia/Shanghai','MM-DD HH24:MI:SS'),'从未上报')
      from device d left join ts_kv k on k.entity_id=d.id
     where d.customer_id='$CID'
       and d.name ~ 'DDSU666|HZ8706|Relay-8CH'
     group by d.name order by d.name;" || true

  echo
  echo "  模拟设备（由 31-rtu-simulate.py 上报，与服务端无关）"
  psql_q "
    select '    ' || d.name || '  ' ||
           coalesce(to_char(to_timestamp(max(k.ts)/1000) at time zone 'Asia/Shanghai','MM-DD HH24:MI:SS'),'从未上报')
      from device d left join ts_kv k on k.entity_id=d.id
     where d.customer_id='$CID' and d.name like '%SIM%'
     group by d.name order by d.name limit 3;" || true

  rt_n=$(psql_q "
    select count(*) from ts_kv k join device d on d.id=k.entity_id
     where d.customer_id='$CID' and d.name ~ 'DDSU666|HZ8706|Relay-8CH'
       and k.ts > (extract(epoch from now())-600)*1000;")
  if [[ "${rt_n:-0}" -gt 0 ]]; then
    ok "真实 RTU 设备最近 10 分钟有 $rt_n 个数据点"
  else
    bad "真实 RTU 设备最近 10 分钟没有数据"
  fi
fi

# ---------------------------------------------------------------- 串口日志（可选）
if [[ -n "$SERIAL" ]]; then
  step "⑦ 板子串口日志（5 秒）"
  if [[ ! -e "$SERIAL" ]]; then
    bad "串口 $SERIAL 不存在（macOS: ls /dev/tty.usb*）"
  elif ! command -v python3 >/dev/null 2>&1; then
    bad "需要 python3 + pyserial：pip3 install pyserial"
  else
    info "读 $SERIAL …"
    python3 - "$SERIAL" <<'PY' 2>/dev/null || warn "读串口失败（被 Thonny 占用？先关掉 Thonny）"
import sys, time
try:
    import serial
except ImportError:
    print('    缺 pyserial：pip3 install pyserial')
    raise SystemExit(1)
s = serial.Serial(sys.argv[1], 115200, timeout=1)
end = time.time() + 5
while time.time() < end:
    line = s.readline()
    if line:
        print('    ' + line.decode('utf-8', 'replace').rstrip())
s.close()
PY
  fi
fi

# ---------------------------------------------------------------- 结论
step "结论"
if [[ "$CONN" -eq 0 ]]; then
  cat <<'EOT'
  RTU 没有连上平台。按这个顺序处理（越靠前越省事）：

  ① 板子上电、连上现场 WiFi
     串口应打印 "WiFi OK  <ip>"。没有就查 SSID/密码/2.4G 频段。

  ② 把 TB_HOST 改成**这台机器**的局域网 IP，并重新上传到板子
     ⚠ 只改电脑上的 main.py 不会生效，必须 mpremote / Thonny 上传。

  ③ 核对令牌
     平台上「设备 → ED1-Gateway → 复制访问令牌」，
     与固件 TB_TOKEN 必须一字不差。跑一次 30-rtu-env-init.py 会自动固定。

  ④ 看串口第二屏
     "平台在线" → "MQTT OK" → 开始打印读数。
     卡在哪一步，就是哪一段不通。
EOT
else
  cat <<'EOT'
  RTU 已连上平台。如果「实时能耗」还没变化，问题在数据链路：

  ① 确认看的是哪台设备
     界面显示「正泰单相电表 DDSU666」= 真实 RTU 那台
     界面显示「单相电表」          = 模拟设备（PowerMeter-1P-SIM）

  ② 看「实时能耗」的数据源范围
     它默认只看「单相园区」这一个场站。若真实电表没挂进这个场站，
     页面上就看不到它 —— 用「设备管理 → 设备运维」按名字直查更准。

  ③ 规则链是否把厂家代号翻译成了平台 key
     板子发 U/I/P/Ep，平台读 voltage_a / current_a / power_total / energy_reading。
     规则链「电表Key标准化」没跑通就是「有连接、没数据」。
EOT
fi

echo
echo "============================================================"
if [[ $RC -eq 0 ]]; then
  echo -e " \033[32m平台侧检查全部通过\033[0m"
else
  echo -e " \033[33m上面有 ✗ 项，先按提示修\033[0m"
fi
echo "============================================================"
exit $RC
