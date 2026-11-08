#!/usr/bin/env bash
#
# 能源管理平台 · RTU 固件上传（把仓库里的 main.py + lib 推到板子）
#
# 为什么需要它：
#   改电脑上的 rtu/main.py **不会**影响板子 —— 板子跑的是它自己 flash 里的副本。
#   换电脑 / 换网段之后，TB_HOST 必须改，改完**必须重新上传**才生效。
#   这是现场最常见的「改了没反应」。
#
# 用法：
#   bash scripts/35-rtu-flash.sh --dry-run          # 只看板子上现在是什么（推荐先跑）
#   bash scripts/35-rtu-flash.sh                    # 上传并重启
#   bash scripts/35-rtu-flash.sh --serial /dev/tty.wchusbserial1410
#   bash scripts/35-rtu-flash.sh --diff             # 只比对板子与本地差异，不上传
#
# ★ 上传前会做的事：
#   ① 检查串口是否被 Thonny / mpremote 占用（被占就停，不去抢）
#   ② 读出板子上现有的 TB_HOST / TB_TOKEN / GATEWAY_NAME 打出来
#   ③ 与本地 rtu/main.py 比对，明确告诉你「哪个变了」
#
# ⚠️ 上传会**重启板子**，正在打印的串口日志会中断，这是正常的。
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="$(cd "$HERE/.." && pwd)"

SERIAL=""
DRY_RUN=false
DIFF_ONLY=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)   SERIAL="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --diff)     DIFF_ONLY=true; shift ;;
    --yes|-y)   ASSUME_YES=true; shift ;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 找固件目录
RTU_DIR=""
for cand in "$APP_HOME/rtu" \
            "$APP_HOME/../iot-rule-engine/rtu" \
            "$HOME/Documents/workspace/iot-rule-engine/rtu" \
            "$HOME/iot-rule-engine/rtu"; do
  [[ -f "$cand/main.py" ]] && { RTU_DIR="$(cd "$cand" && pwd)"; break; }
done
[[ -n "$RTU_DIR" ]] || die "找不到 rtu/main.py（用 --serial 时也需在仓库或部署目录里有 rtu/）"
log "固件目录 $RTU_DIR"

# ---------------------------------------------------------------- 找串口
if [[ -z "$SERIAL" ]]; then
  # macOS 的 /dev/tty.* 与 /dev/cu.* 是同一设备，mpremote 更认 cu.*
  for d in /dev/cu.wchusbserial* /dev/cu.usbserial* /dev/cu.SLAB_USBtoUART* \
           /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$d" ]] && { SERIAL="$d"; break; }
  done
fi
[[ -n "$SERIAL" ]] || die "没找到串口。板子插了吗？macOS: ls /dev/cu.*"
log "串口 $SERIAL"

command -v mpremote >/dev/null 2>&1 || die "缺 mpremote：pip3 install --user mpremote
     装完如果还找不到，把它加进 PATH：
       export PATH=\"\$HOME/Library/Python/3.9/bin:\$PATH\""

# ---------------------------------------------------------------- 串口占用检查
# Thonny 连上板子时会带 interrupt_on_connect，把正在跑的程序打断 ——
# 现场「RTU 明明通电、平台却 0 连接」有一半是 Thonny 挂着占了串口。
log "检查串口占用"
# mpremote 认 cu.*，Thonny 可能占的是 tty.*，两个都查
BASE="${SERIAL##*/}"
BASE="${BASE/cu./tty.}"
for d in "$SERIAL" "/dev/${BASE}"; do
  [[ -e "$d" ]] || continue
  if command -v lsof >/dev/null 2>&1 && lsof "$d" >/dev/null 2>&1; then
    die "$d 被占用（很可能是 Thonny）
     先**完全退出 Thonny**（Cmd+Q，不是关窗口），再跑本脚本。
     原因：Thonny 连上板子时会中断正在运行的程序，RTU 就不上报了。"
  fi
done
ok "串口空闲"

MP="mpremote connect $SERIAL"

# ---------------------------------------------------------------- 读板子现状
log "读取板子上现有的配置"
REMOTE_MAIN=$($MP exec "print(open('main.py').read()[:0] if False else '')" 2>/dev/null || true)
REMOTE_CFG=$($MP exec "
import re
try:
    src = open('main.py').read()
except Exception as e:
    print('NOFILE|' + str(e)); raise SystemExit
def g(p, d=''):
    m = re.search(p, src, re.M)
    return m.group(1) if m else d
print('|'.join([g(r'^TB_HOST\s*=\s*\"([^\"]*)\"'),
                g(r'^TB_TOKEN\s*=\s*\"([^\"]*)\"'),
                g(r'^GATEWAY_NAME\s*=\s*\"([^\"]*)\"'),
                g(r'^TB_PORT\s*=\s*(\d+)')]))
" 2>&1 | tail -1)

LOCAL_CFG=$(python3 - "$RTU_DIR/main.py" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
def g(p, d=''):
    m = re.search(p, src, re.M)
    return m.group(1) if m else d
print('|'.join([g(r'^TB_HOST\s*=\s*"([^"]*)"'),
                g(r'^TB_TOKEN\s*=\s*"([^"]*)"'),
                g(r'^GATEWAY_NAME\s*=\s*"([^"]*)"'),
                g(r'^TB_PORT\s*=\s*(\d+)')]))
PY
)

echo
echo "  项目            板子上                    本地"
IFS='|' read -r rh rt rg rp <<< "${REMOTE_CFG:-|||}"
IFS='|' read -r lh lt lg lp <<< "${LOCAL_CFG:-|||}"
fmt() { printf '  %-14s %-26s %s\n' "$1" "${2:-（无）}" "${3:-（无）}"; }
fmt "TB_HOST"   "$rh" "$lh"
fmt "TB_PORT"   "$rp" "$lp"
fmt "GATEWAY"   "$rg" "$lg"
# 令牌只显示末四位，避免明文刷屏
short() { [[ -n "${1:-}" && ${#1} -gt 4 ]] && echo "…${1: -4}" || echo "${1:-（无）}"; }
fmt "TB_TOKEN"  "$(short "$rh")" "$(short "$lt")"

SAME=false
[[ "$rh" == "$lh" && "$rt" == "$lt" && "$rg" == "$lg" && "$rp" == "$lp" ]] && SAME=true
echo
if $SAME; then
  ok "板子与本地配置一致"
else
  warn "板子与本地配置**不一致** —— 这就是「改了没生效」"
fi

if $DRY_RUN || $DIFF_ONLY; then
  echo
  log "--dry-run/--diff：不做任何写入"
  echo
  echo "  要真正上传：bash $0 --serial $SERIAL"
  exit 0
fi

# ---------------------------------------------------------------- 确认
if ! $ASSUME_YES; then
  echo
  read -r -p "  上传会重启板子，继续？[y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "  已取消"; exit 0; }
fi

# ---------------------------------------------------------------- 建 lib 目录
log "上传 lib/"
$MP fs mkdir lib 2>/dev/null || true
for f in "$RTU_DIR"/lib/*.py; do
  [[ -f "$f" ]] || continue
  $MP fs cp "$f" ":lib/$(basename "$f")" || die "上传 $f 失败"
  ok "lib/$(basename "$f")"
done

# ---------------------------------------------------------------- 上传 main.py
log "上传 main.py"
$MP fs cp "$RTU_DIR/main.py" :main.py || die "上传 main.py 失败"
ok "main.py（$(wc -c < "$RTU_DIR/main.py" | tr -d ' ') 字节）"

# ---------------------------------------------------------------- 重启 + 读日志
log "软复位板子，读 8 秒串口日志"
echo "----------------------------------------"
$MP reset 2>/dev/null || true
sleep 1
$MP exec "print('reset-ok')" >/dev/null 2>&1 || true
python3 - "$SERIAL" <<'PY' 2>/dev/null || warn "读日志失败（不影响上传结果）"
import sys, time
try:
    import serial
except ImportError:
    raise SystemExit(0)
try:
    s = serial.Serial(sys.argv[1], 115200, timeout=1)
except Exception:
    raise SystemExit(0)
end = time.time() + 8
while time.time() < end:
    line = s.readline()
    if line:
        t = line.decode('utf-8', 'replace').rstrip()
        if t:
            print('  ' + t)
s.close()
PY
echo "----------------------------------------"

echo
ok "上传完成"
echo
echo "  预期串口输出顺序："
echo "    配置自检（WiFi / 平台 IP / 端口 / 令牌末四位 / 设备名）"
echo "    WiFi OK  <ip>"
echo "    平台在线"
echo "    MQTT OK"
echo "    开始打印读数"
echo
echo "  然后验证平台侧真的收到了："
echo "    bash scripts/34-rtu-diagnose.sh --customer '<客户名>'"
