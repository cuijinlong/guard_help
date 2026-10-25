#!/usr/bin/env bash
#
# 能源管理平台 · Cassandra commitlog 损坏自愈
#
# 症状（2026-10-25 实测）：
#   energy-cassandra 每 10~20 秒重启一次，RestartCount 一路涨到几十；
#   9042 端口拒连，平台整体 502；容器日志里能看到
#
#     ERROR JVMStabilityInspector - Exiting due to error while processing commit log
#     CommitLogReadHandler$CommitLogReadException:
#       Could not read commit log descriptor in file .../CommitLog-7-<ts>.log
#
# 根因：
#   Cassandra 被**非优雅终止**（docker stop 超时后 SIGKILL、Docker VM 被强杀、
#   宿主机内存压力 OOM）。commitlog 段写到一半，头部描述符没落盘，下次启动
#   读到半截文件就直接退出 —— 而 restart: unless-stopped 让它无限重试，
#   于是形成「起→读到坏文件→退出→再起」的死循环。
#
# 这个脚本做什么：
#   1. 判定：容器不存在 / 健康 / 正在坏循环 三种情形分开处理
#   2. 备份：把整个 commitlog 目录拷到宿主机（默认 ~/.cassandra-commitlog-backup/<时间戳>）
#   3. 清理：只删 commitlog/*.log —— **SSTable 一个字节都不动**
#   4. 重启：等健康（最长 10 分钟），验证 keyspace 可读
#
# 为什么清 commitlog 是安全的：
#   commitlog 只是「已确认但还没刷进 SSTable」的写入重放日志。Cassandra 每次
#   flush 之后对应的段就可以丢。清掉最多丢掉最后一次 flush 之后的几百毫秒写入，
#   而坏文件根本读不出来 —— 留着它等于平台永远起不来。备份也在，可人工取证。
#
# 用法：
#   bash scripts/12-cassandra-recover.sh              # 先诊断，需要恢复时询问
#   bash scripts/12-cassandra-recover.sh --yes        # 诊断 + 直接恢复
#   bash scripts/12-cassandra-recover.sh --dry-run    # 只看会做什么
#   bash scripts/12-cassandra-recover.sh --status     # 只看现状，不恢复
#
# 退出码：0 = 健康或恢复成功；1 = 参数/环境错误；2 = 恢复失败
#
set -uo pipefail

cd "$(dirname "$0")/.."
COMPOSE="docker compose"
CONTAINER="energy-cassandra"
VOLUME="energy-cassandra-data"
ASSUME_YES="false"
DRY="false"
STATUS_ONLY="false"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m  ✗\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)   ASSUME_YES="true"; shift ;;
    --dry-run)  DRY="true"; shift ;;
    --status)   STATUS_ONLY="true"; shift ;;
    -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
    *) bad "未知参数：$1"; exit 1 ;;
  esac
done

[[ -f .env ]] && { set -a; . ./.env; set +a; }
APP_HOME="${APP_HOME:-$(pwd)}"
TS_TYPE="${DATABASE_TS_TYPE:-cassandra}"
BACKUP_ROOT="${CASSANDRA_COMMITLOG_BACKUP:-$HOME/.cassandra-commitlog-backup}"

echo "============================================================"
echo " Cassandra commitlog 自愈 · $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo "  遥测后端（.env）：$TS_TYPE"
echo "  容器：$CONTAINER    数据卷：$VOLUME"
echo

# ---------------------------------------------------------------- 1. 是否存在
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  if [[ "$TS_TYPE" == "sql" ]]; then
    ok "当前遥测后端是 sql，本机本来就不需要 Cassandra —— 无需处理"
    exit 0
  fi
  warn "容器 $CONTAINER 不存在，但 .env 要求 cassandra"
  echo "     起法：docker compose --profile split --profile cassandra up -d cassandra"
  echo "     或：  bash scripts/11-cassandra.sh enable"
  exit 0
fi

STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)
HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo none)
RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo 0)
STARTED=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || echo '-')

printf '  状态：%-10s 健康：%-10s 重启次数：%s\n' "$STATE" "$HEALTH" "$RESTARTS"
echo "  启动于：$STARTED"

# ---------------------------------------------------------------- 2. 找证据
# 三个来源都要看：docker logs（stdout）、容器内 system.log、容器内 debug.log
CL_HIT=""
for src in "docker" "system.log" "debug.log"; do
  case "$src" in
    docker)
      HIT=$(docker logs --tail 400 "$CONTAINER" 2>&1 | grep -c "Could not read commit log descriptor" 2>/dev/null || echo 0)
      ;;
    *)
      HIT=$(docker exec "$CONTAINER" sh -c \
        "grep -c 'Could not read commit log descriptor' /var/log/cassandra/$src 2>/dev/null || echo 0" 2>/dev/null || echo 0)
      ;;
  esac
  HIT=$(printf '%s' "$HIT" | tr -dc '0-9')
  [ -z "$HIT" ] && HIT=0
  printf '  %-12s commitlog 错误命中：%s\n' "$src" "$HIT"
  if [ "$HIT" -gt 0 ]; then CL_HIT="yes"; fi
done

# 容器已经起不来时 docker exec 会失败，退回到直接看日志
if [ -z "$CL_HIT" ] && [ "$STATE" != "running" ]; then
  LASTLOG=$(docker logs --tail 120 "$CONTAINER" 2>&1 | grep -c "commit log" || echo 0)
  [ "${LASTLOG:-0}" -gt 0 ] && CL_HIT="yes"
fi

echo

if [[ "$STATUS_ONLY" == "true" ]]; then
  if [ -n "$CL_HIT" ]; then bad "检测到 commitlog 损坏痕迹"; else ok "未发现 commitlog 损坏"; fi
  exit 0
fi

# ---------------------------------------------------------------- 3. 是否需要动手
if [ "$HEALTH" = "healthy" ] && [ -z "$CL_HIT" ]; then
  ok "Cassandra 健康且无 commitlog 错误 —— 无需恢复"
  exit 0
fi
if [ "$HEALTH" = "healthy" ] && [ -n "$CL_HIT" ]; then
  warn "当前健康，但日志里有历史 commitlog 错误（可能早已自愈）"
  echo "     容器能正常服务就不该清日志；只有再次起不来时才跑本脚本 --yes"
  exit 0
fi
if [ -z "$CL_HIT" ] && [ "$STATE" = "running" ]; then
  warn "容器在跑但不健康，没找到 commitlog 损坏证据 —— 先别清，按下面排查："
  echo "     docker logs --tail 80 $CONTAINER"
  echo "     docker exec $CONTAINER tail -40 /var/log/cassandra/system.log"
  exit 0
fi

bad "判定：commitlog 损坏导致启动失败（重启 $RESTARTS 次）"
echo
echo "  恢复计划："
echo "    1) 停止容器（最多等 180 秒让它自己收尾）"
echo "    2) 备份 ${VOLUME}:/var/lib/cassandra/commitlog → ${BACKUP_ROOT}/<时间戳>/"
echo "    3) 只删 commitlog/*.log（SSTable 不动）"
echo "    4) 重新启动并等健康（最长 10 分钟）"
echo

if [[ "$DRY" == "true" ]]; then
  log "dry-run：以上步骤不会执行"
  exit 0
fi
if [[ "$ASSUME_YES" != "true" ]]; then
  printf '继续？[y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

# ---------------------------------------------------------------- 4. 停容器
log "停止容器（阻止重启循环）"
docker stop -t 180 "$CONTAINER" >/dev/null 2>&1 || true
# 极端情况：容器卡在 restarting，stop 不一定生效
if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = "restarting" ]; then
  warn "仍在 restarting，强制删除容器（数据卷保留）"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi
ok "已停止"

# ---------------------------------------------------------------- 5. 备份 + 清理
STAMP=$(date +%Y%m%d_%H%M%S)
DEST="$BACKUP_ROOT/$STAMP"
mkdir -p "$DEST"
log "备份 commitlog → $DEST"
# 用一次性 alpine 挂卷；--entrypoint 避免镜像默认命令干扰
if docker run --rm -v "$VOLUME":/d -v "$DEST":/b alpine \
     sh -c 'cp -a /d/commitlog/. /b/ 2>/dev/null; echo "N=$(ls /b 2>/dev/null | wc -l | tr -d " ")"' 2>/dev/null | grep -q "N="; then
  N=$(ls "$DEST" 2>/dev/null | wc -l | tr -d ' ')
  ok "已备份 $N 个文件（$(du -sh "$DEST" 2>/dev/null | cut -f1)）"
else
  warn "备份失败（卷可能被占用）—— 中止，不删任何东西"
  exit 2
fi

log "清理 commitlog/*.log（SSTable 与 data 目录不动）"
if docker run --rm -v "$VOLUME":/d alpine \
     sh -c 'rm -f /d/commitlog/*.log; echo "LEFT=$(ls /d/commitlog 2>/dev/null | wc -l | tr -d " ")"' 2>/dev/null | tee /tmp/.cass_clean.$$ | grep -q "LEFT="; then
  ok "$(cat /tmp/.cass_clean.$$ | tr -d '\n')"
  rm -f /tmp/.cass_clean.$$
else
  bad "清理失败"; exit 2
fi

# ---------------------------------------------------------------- 6. 重启并等健康
log "启动 Cassandra"
$COMPOSE --profile split --profile cassandra up -d cassandra 2>&1 | tail -3 || {
  bad "启动命令失败；检查 compose 与 .env 的 profile 设置"
  exit 2
}

WAIT_MAX=600
t=0
while [ $t -lt $WAIT_MAX ]; do
  H=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo none)
  S=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo none)
  if [ "$H" = "healthy" ]; then
    ok "容器健康（${t}s）"; break
  fi
  if [ "$S" = "exited" ] || [ "$S" = "restarting" ]; then
    bad "容器又退出了（${t}s）—— 可能不是 commitlog 问题"
    docker logs --tail 40 "$CONTAINER" 2>&1 | sed 's/^/     /'
    exit 2
  fi
  [ $((t % 30)) -eq 0 ] && printf '  [%3ds] status=%s health=%s\n' "$t" "$S" "$H"
  sleep 5; t=$((t+5))
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" = "healthy" ] || {
  bad "等待超时（${WAIT_MAX}s）仍未健康"; exit 2
}

# ---------------------------------------------------------------- 7. 验证
log "验证 keyspace"
if docker exec "$CONTAINER" cqlsh -e "describe keyspaces" 2>/dev/null | grep -q "thingsboard"; then
  ok "keyspace thingsboard 可读"
else
  warn "keyspace 不可读 —— 若这是首次启用，先跑 bash scripts/11-cassandra.sh init"
fi

NEW_RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo 0)
echo
echo "============================================================"
echo " 恢复完成"
echo "   重启计数：$RESTARTS → $NEW_RESTARTS"
echo "   commitlog 备份：$DEST"
echo "============================================================"
echo
echo "  下次避免同类故障："
echo "   · docker-compose.yml 已给 cassandra 配 stop_grace_period: 180s（正常关闭会等它 flush）"
echo "   · 不要在有数据写入时 docker kill / 强退 Docker Desktop"
echo "   · Docker VM 内存 ≥ 6144 MiB（Cassandra 堆 2G + 页缓存；压到 4G 会被 OOM 打断）"
echo "   · 平台若不需要长期高频遥测，用 DATABASE_TS_TYPE=sql 可以彻底绕开 Cassandra"
exit 0
