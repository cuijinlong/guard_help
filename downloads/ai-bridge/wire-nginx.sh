#!/usr/bin/env bash
#
# 把 AI 桥接服务接进 nginx（幂等，可重复执行）
#
# 用法：
#   bash ai-bridge/wire-nginx.sh          # 写入 / 更新配置并重载 nginx
#   bash ai-bridge/wire-nginx.sh --check  # 只看会改什么，不动手
#   bash ai-bridge/wire-nginx.sh --remove # 摘掉这段配置（回滚）
#
# 它做什么：
#   在 ~/energy-app/nginx/energy.conf 里维护一段**带标记**的配置块：
#
#     # >>> ngx-ai-bridge >>>
#     upstream ngx_ai_bridge { server host.docker.internal:8092; }
#     location ^~ /api/ngx/ai/ { ... proxy_set_header X-Ngx-Ai-Key "..."; }
#     # <<< ngx-ai-bridge <<<
#
#   然后 nginx -t 校验 + reload。
#
# 为什么密钥写在这个文件里而不是挂在 compose 环境变量：
#   nginx 没有「从文件读变量」的能力（除非上 lua 模块）。而这个文件在
#   部署目录、不进 git，chmod 600 就足够。写进 compose 反而更容易被提交走。
#
# 为什么用标记块而不是 sed 插行：
#   重复执行不会叠加，--remove 能精确摘掉，出了事能一键回滚。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="${APP_HOME:-$HOME/energy-app}"
NGINX_CONF="$APP_HOME/nginx/energy.conf"
KEY_FILE="$APP_HOME/ai-bridge/.key"
GATEWAY="${NGX_GATEWAY_CONTAINER:-energy-gateway}"
PORT="${NGX_AI_PORT:-8092}"

BEGIN_MARK="# >>> ngx-ai-bridge >>>"
END_MARK="# <<< ngx-ai-bridge <<<"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die()   { red "  ✗ $*"; exit 1; }

MODE="apply"
case "${1:-}" in
  --check)  MODE="check" ;;
  --remove) MODE="remove" ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  "") ;;
  *) die "未知参数：$1（--help 看用法）" ;;
esac

[[ -f "$NGINX_CONF" ]] || die "找不到 $NGINX_CONF —— 确认 APP_HOME 对吗（当前 ${APP_HOME}）"

# ── 生成要写的配置块 ────────────────────────────────────────────────
build_block() {
  local key="$1"
  cat <<EOF
$BEGIN_MARK
# 3D-NGX AI 搭建桥接（由 ai-bridge/wire-nginx.sh 维护，不要手改）
#
# host.docker.internal 在 Docker Desktop（macOS / Windows）上指向宿主机。
# Linux 上要在 compose 里加 extra_hosts: host.docker.internal:host-gateway。
#
# 超时 180s > 桥接服务的 150s：让桥接先超时并返回结构化错误，
# 而不是 nginx 先断开、前端只看到一个 504（没有任何可读信息）。
upstream ngx_ai_bridge {
    server host.docker.internal:$PORT;
    keepalive 4;
}

location ^~ /api/ngx/ai/ {
    proxy_pass http://ngx_ai_bridge;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Connection "";

    # 透传登录凭据（2026-11-24）。桥接拿它去 /api/auth/user 验身份。
    #
    # nginx 默认会透传未列出的请求头，但**显式写出来**更稳：
    # 将来若有人在上面加一条 proxy_set_header（某些写法会重置继承的头），
    # 漏掉这一行就会导致「所有人都被当成未登录」，而报错只说缺凭据。
    proxy_set_header X-Authorization \$http_x_authorization;

    # 密钥只在这条转发上出现，不下发到浏览器
    proxy_set_header X-Ngx-Ai-Key "$key";

    proxy_connect_timeout 5s;
    proxy_send_timeout 180s;
    proxy_read_timeout 180s;

    # 不让 nginx 缓冲响应：模型回答可能较长，直通更省内存
    proxy_buffering off;
}
$END_MARK
EOF
}

strip_block() {
  # 用 awk 精确删除标记块（含标记行）。文件里没有这段时原样输出。
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  ' "$1"
}

# ── --remove ────────────────────────────────────────────────────────
if [[ "$MODE" == "remove" ]]; then
  if ! grep -qF "$BEGIN_MARK" "$NGINX_CONF"; then
    yellow "  ! 配置里没有 ngx-ai-bridge 段，无需摘除"
    exit 0
  fi
  cp "$NGINX_CONF" "$NGINX_CONF.bak-$(date +%Y%m%d_%H%M%S)"
  strip_block "$NGINX_CONF" > "$NGINX_CONF.tmp" && mv "$NGINX_CONF.tmp" "$NGINX_CONF"
  green "  ✓ 已摘除 ngx-ai-bridge 段（原文件已备份 .bak-*）"
  docker exec "$GATEWAY" nginx -t >/dev/null 2>&1 \
    && docker exec "$GATEWAY" nginx -s reload >/dev/null 2>&1 \
    && green "  ✓ nginx 已重载" \
    || yellow "  ! nginx 未重载（容器不在跑？手动：docker exec $GATEWAY nginx -s reload）"
  exit 0
fi

# ── apply / check ───────────────────────────────────────────────────
[[ -f "$KEY_FILE" ]] || die "找不到密钥 $KEY_FILE —— 先跑一次 ai-bridge/start.sh 生成"
KEY="$(cat "$KEY_FILE")"
[[ -n "$KEY" ]] || die "密钥文件是空的：$KEY_FILE"

NEW_BODY="$(build_block "$KEY")"
CURRENT_BODY="$(strip_block "$NGINX_CONF")"

# 拼出新文件内容：先摘掉旧块，再把新块插在 server { 之前
# （upstream 放在 http 级，location 必须在 server 里 —— 分开处理）
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

python3 - "$NGINX_CONF" "$TMP" "$KEY" "$PORT" "$BEGIN_MARK" "$END_MARK" <<'PY'
import sys, re

path, out, key, port, begin, end = sys.argv[1:7]
src = open(path, encoding="utf-8").read()

# 1) 去掉旧块
src = re.sub(
    re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
    "",
    src,
    flags=re.S,
)

upstream = f"""upstream ngx_ai_bridge {{
    server host.docker.internal:{port};
    keepalive 4;
}}
"""

location = f"""    location ^~ /api/ngx/ai/ {{
        proxy_pass http://ngx_ai_bridge;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Connection "";

        # 密钥只在这条转发上出现，不下发到浏览器
        proxy_set_header X-Ngx-Ai-Key "{key}";

        proxy_connect_timeout 5s;
        proxy_send_timeout 180s;
        proxy_read_timeout 180s;
        proxy_buffering off;
    }}
"""

# 2) upstream 插到第一个 server { 之前（http 级）
m = re.search(r"^server\s*\{", src, flags=re.M)
if not m:
    print("ERR:找不到 server { 块", file=sys.stderr)
    sys.exit(2)
src = src[: m.start()] + begin + "\n" + upstream + end + "\n\n" + src[m.start():]

# 3) location 插到该 server 块内、第一个 location 之前；没有 location 就插在 server { 之后
srv_start = re.search(r"^server\s*\{", src, flags=re.M)
m2 = re.search(r"^\s*location\s", src[srv_start.end():], flags=re.M)
if m2:
    insert_at = srv_start.end() + m2.start()
else:
    insert_at = srv_start.end()
src = src[:insert_at] + begin + "\n" + location + end + "\n\n" + src[insert_at:]

open(out, "w", encoding="utf-8").write(src)
PY

if [[ "$MODE" == "check" ]]; then
  yellow "  （--check）将写入的配置："
  echo "$NEW_BODY" | sed 's/^/    /'
  echo
  diff -u "$NGINX_CONF" "$TMP" | head -40 | sed 's/^/  /' || true
  exit 0
fi

cp "$NGINX_CONF" "$NGINX_CONF.bak-$(date +%Y%m%d_%H%M%S)"
mv "$TMP" "$NGINX_CONF"
chmod 600 "$NGINX_CONF"
green "  ✓ 已写入 ${NGINX_CONF}（原文件已备份 .bak-*，权限 600）"

if docker inspect "$GATEWAY" >/dev/null 2>&1; then
  if docker exec "$GATEWAY" nginx -t 2>&1 | grep -q "successful"; then
    docker exec "$GATEWAY" nginx -s reload
    green "  ✓ nginx 校验通过并已重载"
  else
    red "  ✗ nginx 配置校验失败，已回滚"
    LATEST_BAK="$(ls -t "$NGINX_CONF".bak-* 2>/dev/null | head -1)"
    [[ -n "$LATEST_BAK" ]] && cp "$LATEST_BAK" "$NGINX_CONF"
    docker exec "$GATEWAY" nginx -t 2>&1 | sed 's/^/    /'
    exit 1
  fi
else
  yellow "  ! 容器 $GATEWAY 不存在 —— 配置已写好，下次启动生效"
fi

echo
green "  验证："
echo "    curl -s http://127.0.0.1:8090/api/ngx/ai/chat -X POST \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}'"
