#!/usr/bin/env bash
#
# 能源管理平台 · 停止 / 卸载 / 清理镜像
#
# 用法（在部署目录内执行）：
#   bash docker-99-uninstall.sh                    只停容器，保留数据（可随时再起）
#   bash docker-99-uninstall.sh --purge            删容器 + 卷 + 网络 + 目录（数据全丢）
#   bash docker-99-uninstall.sh --purge --yes      同上，不再询问
#
# 镜像清理是独立开关，默认【保留】镜像：
#   bash docker-99-uninstall.sh --purge --yes --images=app      只删自建镜像（推荐）
#   bash docker-99-uninstall.sh --purge --yes --images=all      连公共基础镜像一起删
#   bash docker-99-uninstall.sh --purge --yes --images=none     一个都不删（默认）
#
# 为什么默认保留：
#   ngx-ai 后端镜像要 pip 装依赖 + 编译 Stan，重建约 5-10 分钟；
#   all-in-one 镜像更大。第二次部署时保留它们能省大量时间。
#   公共镜像（postgres/nginx/temurin）可能被其他项目复用，更不该默认删。
#
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose"
PURGE="false"
YES="false"
IMAGES="none"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge)      PURGE="true"; shift ;;
    --yes|-y)     YES="true"; shift ;;
    --images=*)   IMAGES="${1#*=}"; shift ;;
    --purge-images) IMAGES="all"; shift ;;   # 兼容旧参数
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

case "$IMAGES" in
  none|app|all) ;;
  *) die "--images 只能是 none / app / all，当前：$IMAGES" ;;
esac

[[ -f .env ]] && { set -a; . ./.env; set +a; }
APP_HOME="${APP_HOME:-$(pwd)}"
PORT="${HTTP_PORT:-8090}"
MODE="${DEPLOY_MODE:-split}"

case "$MODE" in
  split)    PROFILE_ARGS="--profile split" ;;
  allinone) PROFILE_ARGS="--profile allinone" ;;
  *)        PROFILE_ARGS="" ;;
esac

# ---------------------------------------------------------------- 只停服务
if [[ "$PURGE" != "true" ]]; then
  log "停止服务（保留数据卷与镜像）"
  $COMPOSE $PROFILE_ARGS down --remove-orphans 2>/dev/null || $COMPOSE down --remove-orphans 2>/dev/null || true
  ok "已停止。数据仍在卷里，镜像保留"
  echo "   重新启动：bash docker-02-start.sh"
  echo "   彻底删除：bash docker-99-uninstall.sh --purge"
  echo "   连镜像一起删：在上面基础上加 --images=app（只删自建）或 --images=all（全删）"
  exit 0
fi

echo
warn "即将彻底删除以下内容，不可恢复："
echo "   · 本项目全部容器"
echo "   · 数据卷 energy-pgdata / energy-ngxai-data / energy-allinone-data"
echo "   · 网络 energy_default"
echo "   · 目录 ${APP_HOME}（jar、data、日志、前端产物）"
case "$IMAGES" in
  none) echo "   · 镜像：保留（下次部署可省 5-10 分钟）" ;;
  app)  echo "   · 镜像：删除自建镜像 energy/ngxai-backend、energy/allinone" ;;
  all)  echo "   · 镜像：删除自建镜像 + postgres:16-alpine、nginx:1.27-alpine、eclipse-temurin:25-jre" ;;
esac

if [[ "$YES" != "true" ]]; then
  echo
  read -r -p "确认请输入大写 YES： " answer
  [[ "$answer" == "YES" ]] || die "已取消"
fi

# ---------------------------------------------------------------- 1. 容器 / 网络 / 卷
log "删除容器、网络、卷"
$COMPOSE $PROFILE_ARGS down -v --remove-orphans 2>/dev/null || $COMPOSE down -v --remove-orphans 2>/dev/null || true
# down -v 对未在 compose 声明的外部卷不生效，按名字兜底
docker volume rm -f energy-pgdata energy-ngxai-data energy-allinone-data >/dev/null 2>&1 || true
docker network rm energy_default >/dev/null 2>&1 || true
docker ps -aq --filter "name=energy-" | xargs -r docker rm -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 2. 部署目录
log "删除部署目录 ${APP_HOME}"
case "$APP_HOME" in
  /|/opt|/usr|/etc|/var|/home|"$HOME")
    die "拒绝删除 ${APP_HOME} —— 这看起来不是部署目录，请检查 .env 里的 APP_HOME" ;;
esac
rm -rf "$APP_HOME"

# ---------------------------------------------------------------- 3. 镜像（可选）
if [[ "$IMAGES" != "none" ]]; then
  log "清理镜像（模式：${IMAGES}）"

  # 自建镜像：删失败通常是还有容器在用，跳过即可，不打断流程
  for img in "${AI_IMAGE:-energy/ngxai-backend:4.4.0}" "${ALLINONE_IMAGE:-energy/allinone:4.4.0}"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      if docker rmi "$img" >/dev/null 2>&1; then ok "已删除 $img"
      else warn "$img 仍被其他容器使用，已跳过"; fi
    fi
  done

  if [[ "$IMAGES" == "all" ]]; then
    for img in postgres:16-alpine nginx:1.27-alpine eclipse-temurin:25-jre python:3.10-slim-bookworm node:22-slim; do
      if docker image inspect "$img" >/dev/null 2>&1; then
        if docker rmi "$img" >/dev/null 2>&1; then ok "已删除 $img"
        else warn "$img 仍被其他项目使用，已跳过"; fi
      fi
    done
  fi
else
  log "按要求保留全部镜像"
fi

# ---------------------------------------------------------------- 4. 自检
echo
log "卸载自检"
FAIL=0
check_empty() {
  local label="$1" cmd="$2" out
  out=$(eval "$cmd" 2>/dev/null || true)
  if [[ -z "$out" ]]; then ok "${label}：无残留"
  else warn "${label} 仍有残留："; echo "$out" | sed 's/^/      /'; FAIL=1; fi
}
check_empty "容器" "docker ps -a --format '{{.Names}}' | grep -E '^energy(-|$)'"
check_empty "卷"   "docker volume ls --format '{{.Name}}' | grep -E '^energy(-|$)'"
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

if [[ -d "$APP_HOME" ]]; then warn "目录仍存在：${APP_HOME}"; FAIL=1; else ok "目录：已删除"; fi

echo
if [[ "$IMAGES" == "app" || "$IMAGES" == "all" ]]; then
  REMAIN=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(energy/|postgres:16-alpine|nginx:1.27-alpine|eclipse-temurin:25-jre)' || true)
  if [[ -z "$REMAIN" ]]; then ok "自建镜像：已清空"
  else
    warn "以下镜像被其他项目占用，保留："
    echo "$REMAIN" | sed 's/^/      /'
  fi
fi

echo
if [[ "$FAIL" == "0" ]]; then
  ok "卸载完成，无残留"
else
  warn "以上列出的项目需要手工处理，或重启 Docker Desktop 后重试"
fi
