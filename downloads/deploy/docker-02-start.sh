#!/usr/bin/env bash
#
# 能源管理平台 · Docker 部署 第 2 步：启动服务 + 创建系统管理员
#
# 用法（在 energy-deploy 目录内，且已跑完 docker-01-install.sh）：
#   bash docker-02-start.sh --admin-email admin@example.com --admin-pass 'ChangeMe123!'
#
# 若服务已经启动、管理员也已存在，脚本只做校验，不会重复创建。
#
# --public-url 是客户实际访问的地址（如 https://energy.example.com），
#   用于生成激活链接 / 重置密码链接。不传时优先读 .env 的 PUBLIC_URL，
#   再没有就自动探测本机 IP + HTTP_PORT。生产环境建议显式传域名。
#
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose"
ADMIN_EMAIL=""
ADMIN_PASS=""
PUBLIC_URL_CLI=""

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-pass)  ADMIN_PASS="$2"; shift 2 ;;
    --public-url)  PUBLIC_URL_CLI="$2"; shift 2 ;;
    -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -f .env ]] || die "缺少 .env。先跑 bash docker-01-install.sh（它会生成并校验配置）"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

# ===== Docker 可用性快检（精简版）=====
# 完整版（自动拉起 + 三平台分类报错）在 docker-01-install.sh。
# 这里只拦一个痑心场景：上一次还能跑，这次 daemon 没了/卡死了 ——
# 不拦就会在后面一堆 docker compose 调用里报些看不懂的错。
# ⚠ 改 01 的那段时请回来同步此处。
#
# 必须带超时：daemon 卡死时 docker info 不是报错而是**挂住**，
# 不加超时用户看到的就是脚本卡死（macOS 实测 3 分钟不返回）。
_docker_ok() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 docker info >/dev/null 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 10 docker info >/dev/null 2>&1
  else
    docker info >/dev/null 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
      if (( i >= 10 )); then
        # 先收子孙再收本体：子进程握着输出管道会让调用方继续等
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        pkill -KILL -P "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 1
      fi
      i=$((i + 1))
      sleep 1
    done
    wait "$pid" 2>/dev/null
  fi
}

if ! _docker_ok; then
  case "$(uname -s)" in
    Darwin)
      die "Docker Desktop 未运行或未响应
  启动：open -a Docker，等鲸鱼图标不再转动后重跑
  已启动但仍报错：osascript -e 'quit app \"Docker\"' && pkill -f com.docker.backend && open -a Docker"
      ;;
    *)
      die "Docker 守护进程未运行或无权限
  sudo systemctl start docker
  仍报权限错：sudo usermod -aG docker \$USER && newgrp docker"
      ;;
  esac
fi

# APP_HOME 是 compose 里挂载 jar 与 data 的基准路径，空值会让 compose 直接报错。
# 正常流程是 01 → 02，这里只是防止跳过 01 直接跑 02。
if [[ -z "${APP_HOME:-}" || ! -f "${APP_HOME}/guard-server-4.4.0.jar" ]]; then
  die "APP_HOME 未设置或无效（当前：${APP_HOME:-空}）。先跑 bash docker-01-install.sh，它会自动修正"
fi
PORT="${HTTP_PORT:-8090}"
BASE="http://127.0.0.1:${PORT}"
MODE="${DEPLOY_MODE:-split}"
case "$MODE" in
  # waveform-store 必须一起拉起：问题详情里的波形读它。
  # 它起不来不会阻断平台（Java 侧降级为"每次重新生成、不落盘"），
  # 但漏在这里的话，客户点「详情」永远看不到「已缓存」。
  split)    PROFILE_ARGS="--profile split";    TARGET="energy-server gateway waveform-store" ;;
  allinone) PROFILE_ARGS="--profile allinone"; TARGET="allinone" ;;
  *) die "DEPLOY_MODE 只能是 split 或 allinone，当前：$MODE" ;;
esac
# Cassandra 是预留能力，默认不启用（2026-11-07）。
# 只有 .env 显式写 DATABASE_TS_TYPE=cassandra 时才带 cassandra profile。
#
# ★ 默认值必须是 sql，不能是 cassandra：变量未定义（.env 丢失 / 新环境）
#   时的兜底行为必须是「不启动 Cassandra」。写成 cassandra 会去拉一个
#   2GB 内存的容器，而业务侧根本没用它 —— 白吃内存且连不上就报
#   InvalidKeyspaceException，排查方向全错。
if [[ "$MODE" == "split" && "${DATABASE_TS_TYPE:-sql}" == "cassandra" ]]; then
  PROFILE_ARGS="$PROFILE_ARGS --profile cassandra"
fi
# 本机代理会把 127.0.0.1 也接管，必须绕过
ncurl() { curl -s --noproxy '*' "$@"; }

# ---------------- 1. 检查 install 是否做过 ----------------
if [[ "$MODE" == "allinone" ]]; then
  # 单容器的表在容器内，先确保容器起来再问表数
  $COMPOSE $PROFILE_ARGS up -d --build allinone
  log "等待容器内 PostgreSQL 与 install 完成（首次约 3-5 分钟）"
else
TABLES=$($COMPOSE $PROFILE_ARGS exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d ' ' || echo 0)
[[ "${TABLES:-0}" -ge 100 ]] || die "库还没初始化（${TABLES:-0} 张表）。先跑 bash docker-01-install.sh"
fi

# ---------------- 1.5 Cassandra commitlog 自愈预检 ----------------
# 为什么放在启动之前：
#   commitlog 段损坏时 Cassandra 会「起→读到坏文件→退出」无限循环
#   （restart: unless-stopped），平台整体 502，而且**不会自己好**。
#   等它循环几十次再人工排查，成本远高于启动前一次 2 秒的探测。
# 判定交给专门脚本（12-cassandra-recover.sh）：只在「确实损坏」时才动手，
# 健康或没启用 Cassandra 时直接退出，不影响正常启动。
if [[ "$MODE" == "split" && "${DATABASE_TS_TYPE:-sql}" == "cassandra" ]]    && [[ -f "$(dirname "$0")/scripts/12-cassandra-recover.sh" ]]; then
  RECOVER="$(dirname "$0")/scripts/12-cassandra-recover.sh"
  if ! bash "$RECOVER" --status 2>/dev/null | grep -q "未发现 commitlog 损坏"; then
    warn "检测到 Cassandra 状态异常，尝试自愈（详见 scripts/12-cassandra-recover.sh）"
    bash "$RECOVER" --yes 2>&1 | sed 's/^/    /' || \
      die "Cassandra 自愈失败。按提示查看 docker logs energy-cassandra，或改用 DATABASE_TS_TYPE=sql"
  fi
fi

# ---------------- 2. 启动服务 ----------------
if [[ "$MODE" == "allinone" ]]; then
  log "启动单容器（已在上一步拉起，等待就绪）"
else
log "启动服务"
# 不带服务名：把 postgres / energy-server / spsspro-backend / gateway 一起拉起来。
# 首次运行会构建 spsspro 后端镜像（pip 装 numpy/scipy/catboost/shap，约 10-15 分钟）。
log "启动全部服务（首次构建 spsspro 镜像较慢，请耐心）"
$COMPOSE $PROFILE_ARGS up -d --build
fi

if [[ "$MODE" == "allinone" ]]; then
  WAIT_MAX=180   # 单容器首次要跑 install，给 15 分钟
  log "等待服务就绪（单容器首次含 install，约 3–5 分钟）"
elif [[ "${DATABASE_TS_TYPE:-sql}" == "cassandra" ]]; then
  # Cassandra 模式启动明显更慢：实体缓存预热 + 驱动连接池 + 分区索引都要从
  # 远端拉。实测 2026-10-23：冷启动到 200 约 7 分钟，旧的 240 秒必然超时。
  WAIT_MAX=120   # 600 秒
  log "等待服务就绪（Cassandra 首次约 5–8 分钟）"
else
  WAIT_MAX=48
  log "等待服务就绪（首次约 60–120 秒）"
fi

STATE=""
for i in $(seq 1 $WAIT_MAX); do
  sleep 5
  # 只认 JSON 响应。nginx 在上游还没起来时会返回 502 HTML，
  # 那不是"就绪"——旧逻辑只判断"有输出"，会把 502 当成功。
  RESP=$(ncurl -m 4 "$BASE/api/noauth/setup/state" 2>/dev/null || true)
  if echo "$RESP" | grep -q '"status"'; then
    STATE="$RESP"
    ok "服务已就绪（$((i*5))s）：$STATE"
    break
  fi
  if [[ "$i" == "$WAIT_MAX" ]]; then
    $COMPOSE $PROFILE_ARGS logs --tail=60 $TARGET
    die "等待超时（$((WAIT_MAX*5)) 秒），上面是容器日志尾部"
  fi
done

# ---------------- 3. 创建管理员 ----------------
if echo "$STATE" | grep -q "READY"; then
  ok "系统已有管理员，跳过创建"
elif echo "$STATE" | grep -q "ACCOUNT_REQUIRED"; then
  [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" ]] \
    || die "系统还没有管理员，请加参数：--admin-email ... --admin-pass ..."

  log "创建系统管理员 $ADMIN_EMAIL"
  # ⚠ 必须带 `|| CODE=000`（2026-11-03 实测踩过）：
  #   set -euo pipefail 下，`CODE=$(curl ...)` 一旦 curl 自己失败（连不上 /
  #   超时，退出码非 0），赋值语句就整体非零 → **脚本静默退出**，
  #   用户只看到「服务已就绪」然后什么都没了，既不知道失败也不知道为什么。
  #   更旧的版本里还会拖到后面报 `CODE: unbound variable`。
  #   带上 || 之后，任何传轮失败都会走下面的分支给出明确错误。
  rm -f /tmp/energy-setup.json
  CODE=$(ncurl -m 120 -o /tmp/energy-setup.json -w '%{http_code}' \
    -X POST "$BASE/api/noauth/setup/complete" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"loadDemo\":false}") || CODE="000"
  if [[ "$CODE" != "200" ]]; then
    if [[ -s /tmp/energy-setup.json ]]; then
      cat /tmp/energy-setup.json
      echo
    else
      warn "没有响应体 —— 请求没打到服务"
    fi
    case "$CODE" in
      000) die "创建管理员失败：连不上 ${BASE}
  服务刚启动时 gateway 可能还没就上后端，等 30 秒重跑同一条命令即可
  仍是 000：bash docker-97-preflight.sh 看容器状态" ;;
      502|503|504) die "创建管理员失败：HTTP ${CODE}（gateway 起来了但后端还没就绪）
  等 1-2 分钟重跑同一条命令。先确认：docker ps | grep energy-server" ;;
    esac
    die "创建管理员失败（HTTP ${CODE}）"
  fi
  ok "管理员已创建"
else
  die "无法识别的 setup 状态：$STATE"
fi

# ---------------- 3b. 配置对外访问地址（激活链接用） ----------------
#
# 为什么必须配：客户账号的激活链接、忘记密码链接都由后端拼出来。
# 采用哪个地址取决于 admin_settings.general：
#   prohibitDifferentUrl=false（默认）→ 从请求头推导，依赖 nginx 传 X-Forwarded-Port
#   prohibitDifferentUrl=true          → 只能用这里配的 baseUrl
# 而出厂默认 baseUrl 是 http://localhost:8080 —— 客户拿到手点不开。
# 这里把它改成实际对外地址，让两条路都对。

# 取值优先级：--public-url > .env 的 PUBLIC_URL > 自动探测
# 注意：.env 是在参数解析**之后**加载的，所以命令行值必须先存到 PUBLIC_URL_CLI，
# 否则会被 .env 覆盖（踩过）。
if [[ -z "$PUBLIC_URL_CLI" ]]; then
  PUBLIC_URL_CLI="${PUBLIC_URL:-}"
fi

if [[ -z "$PUBLIC_URL_CLI" ]]; then
  # 跨平台探测第一个非回环 IPv4：
  #   Linux  hostname -I
  #   macOS  没有 -I，用 ipconfig getifaddr（en0/en1 逐个试）
  HOST_IP=""
  if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
    HOST_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^127\.|^$' | head -1 || true)
  fi
  if [[ -z "$HOST_IP" ]] && command -v ipconfig >/dev/null 2>&1; then
    for IFACE in en0 en1 en2; do
      HOST_IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
      [[ -n "$HOST_IP" ]] && break
    done
  fi
  [[ -n "$HOST_IP" ]] || HOST_IP="localhost"

  if [[ "$PORT" == "80" ]]; then
    PUBLIC_URL_CLI="http://${HOST_IP}"
  else
    PUBLIC_URL_CLI="http://${HOST_IP}:${PORT}"
  fi
  log "未指定对外地址，自动探测为 ${PUBLIC_URL_CLI}（生产环境请用 --public-url 传域名）"
else
  log "对外访问地址：$PUBLIC_URL_CLI"
fi

PUBLIC_URL="$PUBLIC_URL_CLI"

# 只改 baseUrl，保留 prohibitDifferentUrl 等其他字段
if [[ "$MODE" == "allinone" ]]; then
  PSQL_CMD="$COMPOSE $PROFILE_ARGS exec -T allinone psql -U ${DB_USER:-postgres} -d ${DB_NAME:-thingsboard}"
else
  PSQL_CMD="$COMPOSE $PROFILE_ARGS exec -T postgres psql -U ${DB_USER:-postgres} -d ${DB_NAME:-thingsboard}"
fi

$PSQL_CMD -tAc "
UPDATE admin_settings
SET json_value = jsonb_set(json_value::jsonb, '{baseUrl}', to_jsonb('${PUBLIC_URL}'::text))::text
WHERE key = 'general';" >/dev/null 2>&1 \
  && ok "已写入 baseUrl=$PUBLIC_URL" \
  || warn "写入 baseUrl 失败（不影响启动；可从「系统设置 → 通用」手工填）"

# ---------------- 4. 登录验证 ----------------
TOKEN=$(ncurl -m 30 -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || TOKEN=""

if [[ -z "$TOKEN" ]]; then
  warn "登录失败。若管理员已在别处创建，请用当时设置的密码；"
  warn "忘记密码可在容器内重置（见手册「故障排查」）。"
  die "管理员登录验证未通过"
fi

ME=$(ncurl -m 20 -H "X-Authorization: Bearer $TOKEN" "$BASE/api/auth/user") || ME=""
echo "$ME" | grep -q '"authority":"SYS_ADMIN"' || die "登录成功但不是 SYS_ADMIN，返回：$ME"

# 设备接入通道。
#
# 不能用「/api/v1/xxx/telemetry 返回什么」来判断 —— 端点没装配是 404，
# 端点装了但 token 不对也是 404，两者分不出来。直接看装配条件：
#   DeviceApiController 要求 service.type=monolith 且 transport.http.enabled=true
SVC_TYPE=$($COMPOSE $PROFILE_ARGS exec -T energy-server \
  sh -c 'printf "%s" "${SERVICE_TYPE:-}"' 2>/dev/null | tr -d '\r\n') || SVC_TYPE=""
HTTP_ON=$($COMPOSE $PROFILE_ARGS exec -T energy-server \
  sh -c 'printf "%s" "${HTTP_ENABLED:-}"' 2>/dev/null | tr -d '\r\n') || HTTP_ON=""

if [[ "$SVC_TYPE" == "monolith" && "$HTTP_ON" == "true" ]]; then
  ok "设备接入通道已开放（HTTP + MQTT）"
else
  cat <<MSG >&2
  ✗ 设备接入通道未开放：SERVICE_TYPE=${SVC_TYPE:-空} HTTP_ENABLED=${HTTP_ON:-空}

    平台自己的接口全正常，但 RTU / 网关会全部上报失败，界面上看不出来。
    需要 .env 与 docker-compose.yml 同时满足：
      SERVICE_TYPE=monolith
      HTTP_ENABLED=true
      MQTT_ENABLED=true

    排查：docker compose logs energy-server | grep -i transport

MSG
  warn "继续往下走，但在修好之前设备上报不通"
fi

# MQTT 端口：容器在跑不代表端口映射成功
MQTT_P="${MQTT_PORT:-1883}"
if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$MQTT_P" -sTCP:LISTEN >/dev/null 2>&1; then
    ok "MQTT 端口 ${MQTT_P} 正在监听"
  else
    warn "MQTT 端口 ${MQTT_P} 未监听 —— RTU 会连不上。看 docker compose ps 的端口映射"
  fi
  # RTU 现场固件用 11883（写死在 main.py 里），单独确认一次
  RTU_P="${MQTT_RTU_PORT:-}"
  if [[ -n "$RTU_P" ]]; then
    if lsof -nP -iTCP:"$RTU_P" -sTCP:LISTEN >/dev/null 2>&1; then
      ok "RTU 别名端口 ${RTU_P} 正在监听"
    else
      warn "RTU 别名端口 ${RTU_P} 未监听 —— 现场 RTU 会连不上（见 .env 的 MQTT_RTU_PORT）"
    fi
  fi
fi

# ---------------- 2.6 双入口自检 ----------------
#
# 为什么要两个口都测：
#   只有 Web 入口时，现场出问题无法区分「Java 挂了」还是「nginx 挂了」——
#   两者的表现都是页面打不开。有了直连口，一条命令就能定位：
#     Web 通、直连不通 → gateway / nginx 问题
#     两个都不通        → energy-server 本身问题
#     两个都通          → 问题在浏览器侧 / 网络 / 防火墙
#
# 前面已经用 $BASE（=HTTP_PORT）等到 setup/state 返回 JSON，
# 所以走到这里 Web 入口理论上是通的。再确认一次是为了在
# 「中途 nginx 挂了」或「宿主机端口被别的进程抢走」时能报出来。
DIRECT_P="${SERVER_DIRECT_PORT:-}"
WEB_OK=0
DIRECT_OK=0

WEB_CODE=$(ncurl -o /dev/null -w '%{http_code}' -m 5 "${BASE}/api/noauth/energy/health" 2>/dev/null || echo 000)
if [[ "$WEB_CODE" == "200" ]]; then
  WEB_OK=1
  ok "Web 入口 ${PORT} 正常（经 gateway）"
else
  warn "Web 入口 ${PORT} 返回 ${WEB_CODE} —— 浏览器会打不开"
fi

if [[ -n "$DIRECT_P" ]]; then
  D_CODE=$(ncurl -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:${DIRECT_P}/api/noauth/energy/health" 2>/dev/null || echo 000)
  if [[ "$D_CODE" == "200" ]]; then
    DIRECT_OK=1
    ok "直连入口 ${DIRECT_P} 正常（绕过 nginx）"
  else
    warn "直连入口 ${DIRECT_P} 返回 ${D_CODE}"
  fi

  if [[ "$WEB_OK" == "1" && "$DIRECT_OK" == "0" ]]; then
    warn "诊断：Java 活着但 nginx 不通。看 docker compose logs gateway"
  elif [[ "$WEB_OK" == "0" && "$DIRECT_OK" == "1" ]]; then
    warn "诊断：Java 正常，问题在 gateway。浏览器暂时可用 http://本机IP:${DIRECT_P}/ 应急"
  elif [[ "$WEB_OK" == "0" && "$DIRECT_OK" == "0" ]]; then
    warn "诊断：两个口都不通，energy-server 本身有问题：docker compose logs --tail=80 energy-server"
  fi
fi

# 远程访问（客户从自己电脑访问）还要过一道宿主机防火墙 —— 容器映射只管本机
if [[ "$WEB_OK" == "1" ]]; then
  cat <<FIREWALL

  ── 远程访问前提（客户机器/公网访问）───────────────────
  容器端口映射只保证「本机可访问」。从别的机器访问还需放行防火墙：
    Ubuntu/Debian  sudo ufw allow ${PORT}/tcp
    CentOS/RHEL    sudo firewall-cmd --add-port=${PORT}/tcp --permanent && sudo firewall-cmd --reload
    云服务器       在控制台安全组放行 TCP ${PORT}
  设备上报还需放行 MQTT：TCP ${MQTT_PORT}${MQTT_RTU_PORT:+ / ${MQTT_RTU_PORT}}
  ─────────────────────────────────────────────────────
FIREWALL
fi

cat <<DONE

============================================================
 第 3 步完成：服务已启动，管理员已就绪
============================================================

  访问地址（浏览器）
    http://本机IP:${PORT}/           ← Web 入口（经 gateway）
    http://本机IP:${DIRECT_P:-8091}/   ← 直连口，仅排查用

  ★ ${PORT}（.env 里的 HTTP_PORT）是 **gateway(nginx)**，不是 Java。
    nginx 挂了页面打不开，但 Java 可能还活着 —— 用直连口区分。
    不要把浏览器入口改成直连口：会丢掉 /spsspro 反代与 SPA 回退。

  系统管理员
    ${ADMIN_EMAIL}

  现在可以用浏览器登录了。

------------------------------------------------------------
 下一步：开一个租户和一个客户（可选，不建也能登录）
------------------------------------------------------------

  cd ${APP_HOME} && bash scripts/02-onboard.sh \\
    --base http://127.0.0.1:${PORT} \\
    --admin ${ADMIN_EMAIL} --admin-pass '你刚设的密码' \\
    --tenant "环宇能源集团" \\
    --tenant-email tenant@example.com --tenant-pass 'Tenant@12345' \\
    --customer "星河工业园" \\
    --customer-email customer@example.com --customer-pass 'Customer@123'

  开完后跑验收：
  cd ${APP_HOME} && bash scripts/03-verify.sh \\
    --base http://127.0.0.1:${PORT} \\
    --tenant tenant@example.com --tenant-pass 'Tenant@12345' \\
    --customer customer@example.com --customer-pass 'Customer@123' \\
    --ai http://127.0.0.1:${PORT}

  预期最后一行：通过 22 / 失败 0

------------------------------------------------------------
 设备接入（RTU / 网关上报）
------------------------------------------------------------

  MQTT    ${MQTT_P}
          主题：v1/devices/me/telemetry
          用户名：设备的 Access Token（不是账号密码）
          密码：留空

  HTTP    http://本机IP:${PORT}/api/v1/{AccessToken}/telemetry
          Content-Type: application/json
          {"energy":2.88,"power_total":2.88,"voltage_a":220.5}

  每台设备的 Access Token 在平台里查：
    设备 → 点开某台 → 复制访问令牌

DONE
