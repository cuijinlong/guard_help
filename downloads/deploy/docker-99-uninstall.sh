#!/usr/bin/env bash
#
# 能源管理平台 · 彻底卸载（不留痕）
#
# 用法：
#   bash docker-99-uninstall.sh              # 只停服务，保留数据（可随时再起）
#   bash docker-99-uninstall.sh --purge      # 删容器 + 卷 + 网络 + 部署目录，数据全丢
#   bash docker-99-uninstall.sh --purge --yes            # 上面那条不再询问
#   bash docker-99-uninstall.sh --purge --yes --purge-images  # 连两个公共镜像一起删
#
# 卸载后自检会列出「容器 / 卷 / 网络 / 端口 / 目录 / 镜像」六项，全部为空才算干净。
#
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose"
PURGE="false"
YES="false"
PURGE_IMAGES="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge)        PURGE="true"; shift ;;
    --yes|-y)       YES="true"; shift ;;
    --purge-images) PURGE_IMAGES="true"; shift ;;
    -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -f .env ]] && { set -a; . ./.env; set +a; }
APP_HOME="${APP_HOME:-$(pwd)}"
PORT="${HTTP_PORT:-8090}"

if [[ "$PURGE" != "true" ]]; then
  log "停止服务（保留数据卷，可随时再启动）"
  $COMPOSE down --remove-orphans 2>/dev/null || true
  ok "已停止。数据仍在卷 energy-pgdata 与 $APP_HOME/data"
  echo "   重新启动：bash docker-02-start.sh"
  echo "   彻底删除：bash docker-99-uninstall.sh --purge"
  exit 0
fi

echo
warn "即将彻底删除以下内容，不可恢复："
echo "   · 容器 energy-server / energy-postgres"
echo "   · 数据卷 energy-pgdata（数据库全部数据）"
echo "   · 网络 energy_default"
echo "   · 目录 ${APP_HOME}（jar、data、日志）"
[[ "$PURGE_IMAGES" == "true" ]] && echo "   · 镜像 postgres:16-alpine、eclipse-temurin:25-jre"

if [[ "$YES" != "true" ]]; then
  echo
  read -r -p "确认请输入大写 YES： " answer
  [[ "$answer" == "YES" ]] || die "已取消"
fi

# ---------------- 1. 容器 / 网络 / 命名卷 ----------------
log "删除容器、网络、卷"
$COMPOSE down -v --remove-orphans 2>/dev/null || true
# down -v 对「未在 compose 里声明的外部卷」不生效，这里按名字兜底
docker volume rm -f energy-pgdata >/dev/null 2>&1 || true
docker network rm energy_default >/dev/null 2>&1 || true
# install 是一次性容器，异常中断时可能留下
docker ps -aq --filter "name=energy-install" | xargs -r docker rm -f >/dev/null 2>&1 || true

# ---------------- 2. 部署目录 ----------------
log "删除部署目录 $APP_HOME"
case "$APP_HOME" in
  /|/opt|/usr|/etc|/var|/home|"$HOME")
    die "拒绝删除 $APP_HOME —— 这看起来不是部署目录，请检查 .env 里的 APP_HOME" ;;
esac
rm -rf "$APP_HOME"

# ---------------- 3. 镜像（可选）----------------
if [[ "$PURGE_IMAGES" == "true" ]]; then
  log "删除公共镜像"
  # 只有没有其他容器在用时才会删成功，否则 Docker 会拒绝，这是预期行为
  docker rmi postgres:16-alpine 2>/dev/null || warn "postgres:16-alpine 仍被其他容器使用，已跳过"
  docker rmi eclipse-temurin:25-jre 2>/dev/null || warn "eclipse-temurin:25-jre 仍被其他容器使用，已跳过"
fi

# ---------------- 4. 自检 ----------------
echo
log "卸载自检"
FAIL=0
check_empty() {
  local label="$1" cmd="$2"
  local out
  out=$(eval "$cmd" 2>/dev/null || true)
  if [[ -z "$out" ]]; then ok "${label}：无残留"
  else warn "$label 仍有残留："; echo "$out" | sed 's/^/      /'; FAIL=1; fi
}
check_empty "容器" "docker ps -a --format '{{.Names}}' | grep -E '^energy-'"
check_empty "卷"   "docker volume ls --format '{{.Name}}' | grep -E '^energy-|^energy_'"
check_empty "网络" "docker network ls --format '{{.Name}}' | grep -E '^energy_'"
if command -v lsof >/dev/null 2>&1; then
  check_empty "端口 ${PORT}" "lsof -nP -iTCP:${PORT} -sTCP:LISTEN 2>/dev/null"
else
  if (exec 3<>/dev/tcp/127.0.0.1/"${PORT}") >/dev/null 2>&1; then
    exec 3>&- 2>/dev/null || true
    warn "端口 ${PORT} 仍可连接"; FAIL=1
  else
    ok "端口 ${PORT}：已释放"
  fi
fi
if [[ -d "$APP_HOME" ]]; then warn "目录仍存在：$APP_HOME"; FAIL=1; else ok "目录：已删除"; fi

echo
if [[ "$FAIL" == "0" ]]; then
  ok "卸载完成，无残留"
else
  warn "以上列出的项目需要手工处理，或重启 Docker Desktop 后重试"
fi
