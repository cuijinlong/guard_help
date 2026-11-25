#!/usr/bin/env bash
#
# 能源管理平台 · 让本机连**另一台电脑**上的 PostgreSQL（2026-11-26）
#
# 用法（在部署目录内，`docker-00-prepare.sh` / `docker-01-install.sh` 已跑过）：
#   bash docker-50-use-remote-db.sh --host 192.168.31.198 --port 15432 \
#        --db guarddb --user administrator --password 'CJLqh@163'
#
# 不加参数时读 .env 里已有的 DB_HOST / DB_HOST_PORT / DB_NAME / DB_USER / DB_PASSWORD。
#
# 它做四件事：
#   1. 把远程库参数写进 .env（含 DB_HOST / DB_HOST_PORT）；
#   2. **确认远程库真的连得上**（连不上就退出，不留下半配状态）；
#   3. 停掉本机的 postgres 容器（同一份数据只能有一个库在写）；
#   4. 用 --no-deps 起 energy-server / gateway / waveform-store
#      —— 跳过 install，因为远程库已经有完整的 schema 与数据。
#
# ⚠ **不要**在远程库模式下跑 docker-01-install.sh 或 docker-99-uninstall.sh：
#   前者会重跑 TB install（建表/装载系统资源），后者 --purge 会删数据卷。
#   远程库模式只需要本脚本。
#
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 读已有 .env（不 source：密码里有特殊字符，source 会被 shell 解释）----
env_get() {
  local key="$1"
  [[ -f .env ]] || return 0
  sed -n "s/^${key}=//p" .env | head -1
}

DB_HOST_ARG=""
DB_PORT_ARG=""
DB_NAME_ARG=""
DB_USER_ARG=""
DB_PASS_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)     DB_HOST_ARG="$2"; shift 2 ;;
    --port)     DB_PORT_ARG="$2"; shift 2 ;;
    --db)       DB_NAME_ARG="$2"; shift 2 ;;
    --user)     DB_USER_ARG="$2"; shift 2 ;;
    --password) DB_PASS_ARG="$2"; shift 2 ;;
    -h|--help)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
done

RH="${DB_HOST_ARG:-$(env_get DB_HOST)}"
RP="${DB_PORT_ARG:-$(env_get DB_HOST_PORT)}"
RN="${DB_NAME_ARG:-$(env_get DB_NAME)}"
RU="${DB_USER_ARG:-$(env_get DB_USER)}"
RW="${DB_PASS_ARG:-$(env_get DB_PASSWORD)}"

# 兜底：没给就用用户这台机器的既定值
RH="${RH:-192.168.31.198}"
RP="${RP:-15432}"
RN="${RN:-guarddb}"
RU="${RU:-administrator}"
[[ -n "$RW" ]] || die "缺密码：加 --password '...'（或先在 .env 写 DB_PASSWORD）"

[[ -f .env ]] || die "当前目录没有 .env。先跑 bash docker-00-prepare.sh 生成"

APP_HOME_VAL="$(env_get APP_HOME)"
JAR="${APP_HOME_VAL:-.}/guard-server-4.4.0.jar"
[[ -f "$JAR" ]] || die "找不到 jar：$JAR
  先在仓库里构建：cd guard-server && bash pack.sh --skip-ui --no-sync
  构建产物拷到 ${APP_HOME_VAL:-当前目录}/ 下（文件名 guard-server-4.4.0.jar）"

log "目标库：${RH}:${RP}/${RN}  用户 ${RU}"

# ★ 防呆：本脚本会**停掉本机 postgres**。如果目标库其实就是本机的库，
#   停掉之后自己就连不上了 —— 把「数据库服务器」误当「开发机」跑过一次
#   就会得到「库连不上 + 本机库已停」的双重故障。
LOCAL_IPS="127.0.0.1 localhost $(hostname 2>/dev/null || true)"
case "$(uname -s)" in
  Darwin) LOCAL_IPS="$LOCAL_IPS $(ipconfig getifaddr en0 2>/dev/null || true) $(ipconfig getifaddr en1 2>/dev/null || true)" ;;
  Linux)  LOCAL_IPS="$LOCAL_IPS $(hostname -I 2>/dev/null || true)" ;;
esac
for ip in $LOCAL_IPS; do
  [[ -z "$ip" ]] && continue
  if [[ "$RH" == "$ip" ]]; then
    die "目标库 ${RH} 就是本机的 IP。
  本脚本会停掉本机 postgres —— 在数据库服务器上跑它，等于自己把自己的库关掉。
  这个脚本只应在**另一台开发机**上跑；数据库服务器用 .env 的默认 DB_HOST 即可。"
  fi
done

# ---- 1. 连通性校验（用一次性容器，不污染本机）----
log "校验远程库连通性"
if ! docker run --rm -e PGPASSWORD="$RW" postgres:16-alpine \
      psql -h "$RH" -p "$RP" -U "$RU" -d "$RN" -tAc "select 1" >/tmp/remote-db-probe.txt 2>&1; then
  warn "连不上，错误："
  tail -5 /tmp/remote-db-probe.txt | sed 's/^/      /'
  die "远程库不可达。检查：① 对方 postgres 是否在跑 ② 端口 ${RP} 是否映射到 0.0.0.0 ③ 防火墙 ④ 密码"
fi
ok "连接成功"

# 库里有 TB 的表吗？空库说明对方还没 install，连上去也只会白屏
TBL=$(docker run --rm -e PGPASSWORD="$RW" postgres:16-alpine \
      psql -h "$RH" -p "$RP" -U "$RU" -d "$RN" -tAc \
      "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d ' ')
if [[ "${TBL:-0}" -lt 50 ]]; then
  die "远程库只有 ${TBL:-0} 张表，不像已初始化的平台库。在**持有数据的那台机器**上确认库名/实例正确"
fi
ok "库结构正常（${TBL} 张表）"

# ---- 2. 写 .env（幂等：有则替换，无则追加）----
log "写入 .env"
python3 - "$RH" "$RP" "$RN" "$RU" "$RW" <<'PY'
import pathlib, re, sys
host, port, name, user, pwd = sys.argv[1:6]
p = pathlib.Path('.env')
lines = p.read_text().splitlines()
want = {
    'DB_HOST': host,
    'DB_HOST_PORT': port,
    'DB_NAME': name,
    'DB_USER': user,
    'DB_PASSWORD': pwd,
}
seen = set()
out = []
for line in lines:
    m = re.match(r'^([A-Z_]+)=', line)
    if m and m.group(1) in want:
        k = m.group(1)
        out.append(f'{k}={want[k]}')
        seen.add(k)
    else:
        out.append(line)
if 'DB_HOST' not in seen:
    out.insert(0, '# 远程库模式（docker-50-use-remote-db.sh 写入，2026-11-26）')
for k, v in want.items():
    if k not in seen:
        out.append(f'{k}={v}')
p.write_text('\n'.join(out) + '\n')
print('  已写入 DB_HOST/DB_HOST_PORT/DB_NAME/DB_USER/DB_PASSWORD')
PY
ok ".env 已更新"

# ---- 3. 停本机 postgres（同一份数据不能两处写）----
if docker ps --format '{{.Names}}' | grep -qx 'energy-postgres'; then
  log "停本机 postgres 容器（远程库模式下不需要它）"
  $COMPOSE --profile split stop postgres >/dev/null 2>&1 || true
  ok "已停"
else
  ok "本机 postgres 未运行（符合预期）"
fi

# ---- 4. 起服务（--no-deps 跳过 postgres 依赖）----
MODE="${DEPLOY_MODE:-split}"
[[ "$MODE" == "split" ]] || die "远程库模式只支持 DEPLOY_MODE=split（当前：$MODE）"

log "启动 energy-server / gateway / waveform-store（不跑 install）"
$COMPOSE --profile split up -d --no-deps energy-server gateway waveform-store

log "等待 energy-server 健康（最多 5 分钟）"
for i in $(seq 1 60); do
  st=$(docker inspect energy-server --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
  if [[ "$st" == "healthy" ]]; then ok "healthy（$((i*5))s）"; break; fi
  if [[ "$st" == "unhealthy" ]]; then
    docker logs --tail 30 energy-server 2>&1 | tail -15
    die "energy-server 不健康，日志见上"
  fi
  sleep 5
  [[ $i -eq 60 ]] && die "超时：energy-server 5 分钟未 healthy"
done

# ---- 5. 自检：真的能登录吗 ----
PORT="${HTTP_PORT:-8090}"
U="${TB_API_USERNAME:-tenant@126.com}"
P="${TB_API_PASSWORD:-12345678}"
log "自检登录 ${U} @ http://127.0.0.1:${PORT}"
sleep 3
RESP=$(curl -s -X POST "http://127.0.0.1:${PORT}/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${U}\",\"password\":\"${P}\"}" || true)
if printf '%s' "$RESP" | grep -q '"token"'; then
  ok "登录成功 —— 本机已连上 ${RH}:${RP}/${RN}"
else
  warn "登录失败，返回：$(printf '%s' "$RESP" | head -c 200)"
  die "服务起来了但连不上库里的账号。确认远程库里有这个用户，或改 .env 的 TB_API_USERNAME/PASSWORD"
fi

cat <<EOF

────────────────────────────────────────────────
 已切换到远程库
   库地址   ${RH}:${RP}/${RN}
   用户     ${RU}
   访问     http://127.0.0.1:${PORT}

 局域网其他电脑访问本机页面：http://<本机IP>:${PORT}

 ⚠ 两个提醒
   1. 本机的演示模拟器**不要再开**（docker-50 之外的环境变量 SPSSPRO_SIMULATOR_ENABLED=false），
      两台机器同时写同一份数据会互相覆盖。
   2. 改回本机库：把 .env 的 DB_HOST 改回 postgres、DB_HOST_PORT 改回 5432，
      然后 docker compose --profile split up -d postgres energy-server，并重启本机 postgres。
────────────────────────────────────────────────
EOF
