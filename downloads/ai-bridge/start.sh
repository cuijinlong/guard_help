#!/usr/bin/env bash
#
# 3D-NGX · AI 搭建桥接服务 · 启动 / 停止 / 查看状态
#
# 用法：
#   bash ai-bridge/start.sh              # 后台启动（已在跑则提示）
#   bash ai-bridge/start.sh --restart    # 先停再起
#   bash ai-bridge/start.sh --stop
#   bash ai-bridge/start.sh --status
#   bash ai-bridge/start.sh --foreground # 前台跑，便于看日志（调试用）
#
# 它做什么：
#   1. 确认 codewhale 可用（没有就明确报错，不要起一个注定不通的服务）
#   2. 读或生成共享密钥（~/energy-app/ai-bridge/.key，权限 600）
#   3. 后台拉起 server.js，日志写 ~/energy-app/ai-bridge/bridge.log
#   4. 等 /healthz 通过才算启动成功
#
# 为什么密钥落文件而不是写进 compose：
#   密钥要给 nginx 与 bridge 两边用。写进 compose 会被 git 带走，
#   而这是能花用户模型额度的东西。落一个 600 的文件，两边都读它。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="${APP_HOME:-$HOME/energy-app}"
BRIDGE_HOME="$APP_HOME/ai-bridge"
KEY_FILE="$BRIDGE_HOME/.key"
LOG_FILE="$BRIDGE_HOME/bridge.log"
PID_FILE="$BRIDGE_HOME/bridge.pid"
PORT="${NGX_AI_PORT:-8092}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die()   { red "  ✗ $*"; exit 1; }

MODE="start"
case "${1:-}" in
  --stop)       MODE="stop" ;;
  --restart)    MODE="restart" ;;
  --status)     MODE="status" ;;
  --foreground) MODE="foreground" ;;
  -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
  "")           ;;
  *)            die "未知参数：$1（--help 看用法）" ;;
esac

running_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  # kill -0 只测「进程存在」，不真的发信号
  kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
  return 1
}

do_stop() {
  local pid
  if pid="$(running_pid)"; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
      yellow "  ! 未在 5 秒内退出，强制结束 $pid"
      kill -9 "$pid" 2>/dev/null || true
    fi
    green "  ✓ 已停止（pid ${pid}）"
  else
    yellow "  ! 没有在跑的桥接服务"
  fi
  rm -f "$PID_FILE"
}

do_status() {
  local pid
  if pid="$(running_pid)"; then
    green "  ✓ 运行中（pid ${pid}，本脚本拉起）"
  elif curl -s --max-time 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    green "  ✓ 运行中（launchd/systemd 托管，无 pid 文件）"
  else
    yellow "  ! 未运行"
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    local body
    body="$(curl -s --max-time 3 "http://127.0.0.1:$PORT/healthz" || true)"
    [[ -n "$body" ]] && echo "    $body"
  fi
}

if [[ "$MODE" == "stop" ]]; then do_stop; exit 0; fi
if [[ "$MODE" == "status" ]]; then do_status; exit $?; fi
if [[ "$MODE" == "restart" ]]; then do_stop; fi

# ── 已在跑就不重复起（除非 --restart）─────────────────────────────────
#
# ★ 两个来源都要查（2026-11-24 实测踩到）：
#   ① 本脚本自己的 pid 文件；
#   ② **端口上是否已有实例** —— 那可能是 launchd / systemd 拉起的，没有 pid 文件。
#      只查 pid 文件会「再起一个」，第二个 EADDRINUSE 立刻退出，
#      而脚本仍打印「已启动」—— 用户以为起来了，实际在跑的是另一个。
if [[ "$MODE" != "foreground" ]]; then
  if pid="$(running_pid)"; then
    green "  ✓ 已在运行（pid ${pid}），无需重启。要重启加 --restart"
    exit 0
  fi
  if curl -s --max-time 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    green "  ✓ 端口 ${PORT} 上已有实例在跑（可能由 launchd/systemd 托管）"
    echo "    查状态： bash install-service.sh --status"
    echo "    换配置： bash install-service.sh --uninstall，再 install-service.sh"
    exit 0
  fi
fi

# ── 前置检查 ─────────────────────────────────────────────────────────
command -v node >/dev/null 2>&1 || die "找不到 node。桥接服务是 Node 脚本，需要 node 18+。"
command -v codewhale >/dev/null 2>&1 || die "找不到 codewhale。先装：curl -fsSL https://codewhale.net/install.sh | sh"

# codewhale 得是「能跑起来」的，不只是存在
if ! codewhale --version >/dev/null 2>&1; then
  die "codewhale 存在但跑不起来。手动试一次：codewhale --version"
fi

mkdir -p "$BRIDGE_HOME"

# ── 共享密钥 ─────────────────────────────────────────────────────────
if [[ ! -f "$KEY_FILE" ]]; then
  node -e "console.log(require('crypto').randomBytes(24).toString('hex'))" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  green "  ✓ 已生成共享密钥：${KEY_FILE}（权限 600）"
fi
NGX_AI_KEY="$(cat "$KEY_FILE")"

# ── 前台模式（调试）──────────────────────────────────────────────────
if [[ "$MODE" == "foreground" ]]; then
  export NGX_AI_KEY NGX_AI_PORT="$PORT"
  exec node "$HERE/server.js"
fi

# ── 后台启动 ─────────────────────────────────────────────────────────
export NGX_AI_KEY NGX_AI_PORT="$PORT"
nohup node "$HERE/server.js" >> "$LOG_FILE" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"

# 等 /healthz 通（最多 15 秒）
ok=false
for _ in $(seq 1 30); do
  if ! kill -0 "$NEW_PID" 2>/dev/null; then break; fi
  if curl -s --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then ok=true; break; fi
  sleep 0.5
done

if [[ "$ok" != "true" ]]; then
  red "  ✗ 启动失败。最近日志："
  tail -20 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
  rm -f "$PID_FILE"
  exit 1
fi

green "  ✓ 桥接服务已启动（pid ${NEW_PID}，端口 ${PORT}）"
echo "    健康检查： curl -s http://127.0.0.1:$PORT/healthz"
echo "    日志：     $LOG_FILE"
echo
yellow "  下一步：nginx 要能转发 /api/ngx/ai/ 到这里。"
echo "    已配置过则无需操作；首次部署见 ai-bridge/README.md。"
