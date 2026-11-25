#!/usr/bin/env bash
#
# 把 AI 桥接服务注册成系统服务（macOS launchd / Linux systemd）
#
# 用法：
#   bash ai-bridge/install-service.sh            # 安装并启动
#   bash ai-bridge/install-service.sh --uninstall
#   bash ai-bridge/install-service.sh --status
#
# 为什么必须有这一步，而不是 inohup 起来就算完：
#
#   ★ 后台进程挂在启动它的 shell 上。终端一关、或脚本一退出，
#     进程组收到 SIGHUP/终止信号就没了 —— 表现为「明明启动了，
#     过一会儿访问就 connection refused」，而日志里只有启动那三行。
#     这不是代码问题，是托管方式不对。
#
#   launchd / systemd 是系统级的进程托管：不依赖任何 shell，
#   崩溃自动拉起（KeepAlive / Restart=always），开机自启。
#
# 平台差异：
#   macOS  → ~/Library/LaunchAgents/com.ngx.ai-bridge.plist（用户级，不需 sudo）
#   Linux  → /etc/systemd/system/ngx-ai-bridge.service（需要 sudo）

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="${APP_HOME:-$HOME/energy-app}"
BRIDGE_HOME="$APP_HOME/ai-bridge"
KEY_FILE="$BRIDGE_HOME/.key"
LOG_FILE="$BRIDGE_HOME/bridge.log"
PORT="${NGX_AI_PORT:-8092}"
LABEL="com.ngx.ai-bridge"
SERVICE="ngx-ai-bridge"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die()   { red "  ✗ $*"; exit 1; }

MODE="install"
case "${1:-}" in
  --uninstall) MODE="uninstall" ;;
  --status)    MODE="status" ;;
  -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
  "")          ;;
  *)           die "未知参数：$1（--help 看用法）" ;;
esac

[[ -f "$BRIDGE_HOME/server.js" ]] || die "找不到 $BRIDGE_HOME/server.js —— 先部署 ai-bridge 目录"
[[ -f "$KEY_FILE" ]] || die "找不到密钥 $KEY_FILE —— 先跑一次 ai-bridge/start.sh 生成"

NODE_BIN="$(command -v node || true)"
[[ -n "$NODE_BIN" ]] || die "找不到 node"
CODEWHALE_BIN="$(command -v codewhale || true)"
[[ -n "$CODEWHALE_BIN" ]] || yellow "  ! 找不到 codewhale，服务会起来但每次对话都会失败"

# ────────────────────────────── macOS ──────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]]; then
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

  if [[ "$MODE" == "status" ]]; then
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
      green "  ✓ launchd 已加载"
      launchctl list | grep "$LABEL" | sed 's/^/    /'
    else
      yellow "  ! launchd 未加载"
    fi
    curl -s --max-time 3 "http://127.0.0.1:$PORT/healthz" | sed 's/^/    /' || true
    echo
    exit 0
  fi

  if [[ "$MODE" == "uninstall" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    green "  ✓ 已卸载（plist 已删）"
    exit 0
  fi

  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$BRIDGE_HOME/server.js</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$BRIDGE_HOME</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>NGX_AI_PORT</key>
    <string>$PORT</string>
    <key>NGX_AI_HOST</key>
    <string>0.0.0.0</string>
    <key>NGX_AI_KEY</key>
    <string>__REPLACE_KEY__</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$(dirname "$NODE_BIN")</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <!-- 崩溃自动拉起。刻意不用 KeepAlive=true：那会在「密钥错」这类
       必然失败的场景下无限重启刷日志。设成「非正常退出才重启」。 -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>StandardOutPath</key>
  <string>$LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>

  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
EOF

  # 密钥单独注入：不写进 heredoc 变量，避免被 ps / 日志顺手带出
  python3 - "$PLIST" "$KEY_FILE" <<'PY'
import sys
plist, keyfile = sys.argv[1], sys.argv[2]
key = open(keyfile, encoding="utf-8").read().strip()
s = open(plist, encoding="utf-8").read().replace("__REPLACE_KEY__", key)
open(plist, "w", encoding="utf-8").write(s)
PY
  chmod 600 "$PLIST"

  # 先卸载旧的（幂等），再加载
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

  ok=false
  for _ in $(seq 1 30); do
    if curl -s --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then ok=true; break; fi
    sleep 0.5
  done
  if [[ "$ok" == "true" ]]; then
    green "  ✓ 已注册为 launchd 服务并运行（${LABEL}）"
    echo "    状态： bash $BRIDGE_HOME/install-service.sh --status"
    echo "    日志： $LOG_FILE"
  else
    red "  ✗ 已注册但健康检查不通。看日志："
    tail -20 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
    exit 1
  fi
  exit 0
fi

# ────────────────────────────── Linux ──────────────────────────────
UNIT="/etc/systemd/system/$SERVICE.service"

if [[ "$MODE" == "status" ]]; then
  systemctl status "$SERVICE" --no-pager 2>/dev/null | head -15 || yellow "  ! 服务未安装"
  exit 0
fi

if [[ "$MODE" == "uninstall" ]]; then
  sudo systemctl disable --now "$SERVICE" 2>/dev/null || true
  sudo rm -f "$UNIT"
  sudo systemctl daemon-reload
  green "  ✓ 已卸载"
  exit 0
fi

sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=3D-NGX AI build bridge (codewhale)
After=network-online.target

[Service]
Type=simple
Environment=NGX_AI_PORT=$PORT
Environment=NGX_AI_HOST=0.0.0.0
EnvironmentFile=$KEY_FILE
WorkingDirectory=$BRIDGE_HOME
ExecStart=$NODE_BIN $BRIDGE_HOME/server.js
Restart=on-failure
RestartSec=3
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

# EnvironmentFile 要 KEY=VALUE 格式，而 .key 里只有裸值 —— 转成一份 systemd 能读的
sudo sh -c "printf 'NGX_AI_KEY=%s\n' \"\$(cat '$KEY_FILE')\" > '$BRIDGE_HOME/.env' && chmod 600 '$BRIDGE_HOME/.env'"
sudo sed -i "s#EnvironmentFile=.*#EnvironmentFile=$BRIDGE_HOME/.env#" "$UNIT"

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"

ok=false
for _ in $(seq 1 30); do
  if curl -s --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then ok=true; break; fi
  sleep 0.5
done
if [[ "$ok" == "true" ]]; then
  green "  ✓ 已注册为 systemd 服务并运行（${SERVICE}）"
  echo "    状态： systemctl status $SERVICE"
else
  red "  ✗ 已注册但健康检查不通。"
  sudo journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
  exit 1
fi
