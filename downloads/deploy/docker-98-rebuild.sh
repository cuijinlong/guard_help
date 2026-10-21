#!/usr/bin/env bash
#
# 能源管理平台 · 一键重装（反复验证用）
#
# 一条命令跑完整个循环：
#   卸载 → 重新组装部署目录（带最新 jar / 模板）→ 建库 → 启动 →
#   建管理员 → 建租户 + 客户（触发演示数据初始化）
#   → 结构验收 → 数据验收 → 全链路验收 → 发布内容验收
#
# 用法（在仓库根目录执行）：
#   bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
#     --admin admin@your.com   --admin-pass 'Admin@123' \
#     --tenant tenant@your.com --tenant-pass 'Tenant@123' \
#     --customer customer@your.com --customer-pass 'Customer@123' \
#     --tenant-title 星河集团 --customer-title 星河工业园
#
# 常用开关：
#   --app-home DIR     部署目录，默认 ~/energy-app
#   --rebuild-web      强制重建 AI 前端产物（默认源码没变就复用，省 1 分钟）
#   --drop-images      连镜像一起删（最干净，但重建慢 10-20 分钟）
#   --no-verify        跳过最后四步验收
#   --keep-data        不卸载数据库，只换 jar 并重建租户（走 B 路）
#   --yes              不交互确认
#
# 每次跑完会在部署目录写 DEPLOY-CREDENTIALS.txt（权限 600），
# 反复测试时不用翻历史记录找密码。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

ADMIN=""       ; ADMIN_PASS=""
TENANT=""      ; TENANT_PASS=""   ; TENANT_TITLE="能源租户"
CUSTOMER=""    ; CUST_PASS=""     ; CUST_TITLE="演示客户"
APP_HOME="$HOME/energy-app"
DROP_IMAGES="false"
NO_VERIFY="false"
KEEP_DATA="false"
ASSUME_YES="false"
REBUILD_WEB_OPT=""

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin)          ADMIN="$2"; shift 2 ;;
    --admin-pass)     ADMIN_PASS="$2"; shift 2 ;;
    --tenant)         TENANT="$2"; shift 2 ;;
    --tenant-pass)    TENANT_PASS="$2"; shift 2 ;;
    --tenant-title)   TENANT_TITLE="$2"; shift 2 ;;
    --customer)       CUSTOMER="$2"; shift 2 ;;
    --customer-pass)  CUST_PASS="$2"; shift 2 ;;
    --customer-title) CUST_TITLE="$2"; shift 2 ;;
    --app-home)       APP_HOME="$2"; shift 2 ;;
    --rebuild-web)    REBUILD_WEB_OPT="--rebuild-web"; shift ;;
    --drop-images)    DROP_IMAGES="true"; shift ;;
    --no-verify)      NO_VERIFY="true"; shift ;;
    --keep-data)      KEEP_DATA="true"; shift ;;
    --yes|-y)         ASSUME_YES="true"; shift ;;
    -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$ADMIN" && -n "$ADMIN_PASS" ]] || die "必须提供 --admin 与 --admin-pass"
[[ -n "$TENANT" && -n "$TENANT_PASS" ]] || die "必须提供 --tenant 与 --tenant-pass"
[[ -n "$CUSTOMER" && -n "$CUST_PASS" ]] || die "必须提供 --customer 与 --customer-pass"

JAR="$ROOT/guard-server/target/guard-server-4.4.0.jar"
[[ -f "$JAR" ]] || die "找不到 jar：$JAR
     先构建：cd $ROOT/guard-server && mvn package -DskipTests"

# 版本自检：模板数，防止部署目录装的是旧数据。
# 具体下限由 check-docs.py 从代码算出来，这里只做存在性兜底。
TPL="$ROOT/guard-server/src/main/data/json/tenant/dashboards"
TPL_N=$(ls "$TPL" 2>/dev/null | wc -l | tr -d ' ')
[[ "$TPL_N" -ge 1 ]] || die "仓库里没有仪表板模板：$TPL"

# 手册与代码一致性：重装后你会照手册验收，手册数字不对就是白验一遍。
# 不一致只警告不中断 —— 重装本身不该被文档问题挡住，但你要知道。
if [[ -x "$ROOT/shiyongshouce/check-docs.py" ]]; then
  if ! DOC_OUT="$("$ROOT/shiyongshouce/check-docs.py" 2>&1)"; then
    warn "手册与代码不一致（不影响本次重装，但验收时别照手册的数字）："
    echo "$DOC_OUT" | sed -n '/✗/,$p' | sed 's/^/     /'
  fi
fi

T0=$(date +%s)
elapsed() { printf '%ds' $(( $(date +%s) - T0 )); }

# ---------------------------------------------------------------- 0. 确认
if [[ "$ASSUME_YES" != "true" ]]; then
  if [[ "$KEEP_DATA" == "true" ]]; then
    cat <<BANNER

============================================================
 保留数据库模式（换 jar + 重建租户）
============================================================
  部署目录：${APP_HOME}
  会删掉：该租户下的全部客户、设备、仪表板（演示数据一并重建）
  会保留：系统管理员账号、平台级配置

BANNER
  else
    cat <<BANNER

============================================================
 彻底重装
============================================================
  部署目录：${APP_HOME}
  会删掉：容器、数据卷（数据库全部数据）、部署目录本身
  会重建：库、管理员、租户、客户、演示数据

BANNER
  fi
  read -r -p "  确认继续？输入 yes：" _ans
  [[ "$_ans" == "yes" ]] || { echo "  已取消"; exit 1; }
fi

# ---------------------------------------------------------------- 1. 卸载
if [[ "$KEEP_DATA" != "true" ]]; then
  log "步骤 1/9　卸载旧部署"
  if [[ -f "$APP_HOME/docker-99-uninstall.sh" ]]; then
    IMG_OPT="--images=none"
    [[ "$DROP_IMAGES" == "true" ]] && IMG_OPT="--images=app"
    # 脚本会删掉自己所在的目录，必须在子 shell 里跑，且失败不中断
    ( cd "$APP_HOME" && bash docker-99-uninstall.sh --purge --yes "$IMG_OPT" ) \
      || warn "卸载脚本返回非零（可能本来就没装全），继续"
    ok "旧部署已清理"
  else
    # 没有卸载脚本 = 目录不是本平台的部署目录，不能盲删
    if [[ -e "$APP_HOME" ]]; then
      if [[ -f "$APP_HOME/docker-compose.yml" ]]; then
        warn "目录存在但没有 docker-99-uninstall.sh，手工清理这条："
        echo "     cd $APP_HOME && docker compose down -v --remove-orphans"
        echo "     rm -rf $APP_HOME"
        die "为安全起见不自动删除"
      fi
      die "目录 $APP_HOME 已存在且不含本平台文件，换个 --app-home"
    fi
    ok "无旧部署，跳过"
  fi
else
  log "步骤 1/9　备份数据库（保留数据模式）"
  [[ -f "$APP_HOME/.env" ]] || die "保留数据模式要求 $APP_HOME/.env 已存在"
  ( cd "$APP_HOME" \
    && docker compose exec -T postgres pg_dump -U postgres thingsboard 2>/dev/null \
       | gzip > "$HOME/backup-rebuild-$(date +%Y%m%d-%H%M%S).sql.gz" ) \
    || warn "备份失败（可能服务没起），继续但不建议"
  ok "备份完成：$(ls -1t "$HOME"/backup-rebuild-*.sql.gz 2>/dev/null | head -1)"
fi

# ---------------------------------------------------------------- 2. 组装目录
log "步骤 2/9　重新组装部署目录（带最新 jar 与模板）"
if [[ "$KEEP_DATA" == "true" ]]; then
  # 保留 .env：prepare 遇到已有 .env 会拒绝，这里只换文件
  cp "$JAR" "$APP_HOME/guard-server-4.4.0.jar"
  rm -rf "$APP_HOME/data/json/tenant/dashboards" "$APP_HOME/data/json/system/widget_types"
  cp -R "$ROOT/guard-server/src/main/data/json/tenant/dashboards" "$APP_HOME/data/json/tenant/"
  cp -R "$ROOT/guard-server/src/main/data/json/system/widget_types" "$APP_HOME/data/json/system/"
  # 运维脚本全量同步 —— 同样不写死文件名。
  # 早先这里只拷 02/03/04/06，05、07、08 都漏了，
  # 走 --keep-data 之后手册里让跑的 08-verify-release.sh 就不存在。
  mkdir -p "$APP_HOME/scripts"
  cp "$HERE/../scripts/"0[2-9]-* "$APP_HOME/scripts/" 2>/dev/null || true
  chmod +x "$APP_HOME/scripts/"0[2-9]-* 2>/dev/null || true
  ok "jar 与模板已替换（.env 与数据库保留）"
else
  PREP_ARGS=()
  [[ -n "$REBUILD_WEB_OPT" ]] && PREP_ARGS+=("$REBUILD_WEB_OPT")
  bash "$HERE/docker-00-prepare.sh" "${PREP_ARGS[@]+"${PREP_ARGS[@]}"}" "$APP_HOME" >/tmp/rebuild-prepare.log 2>&1 \
    || { tail -30 /tmp/rebuild-prepare.log; die "组装部署目录失败，日志：/tmp/rebuild-prepare.log"; }
  ok "部署目录已生成"
fi

N=$(ls "$APP_HOME/data/json/tenant/dashboards" 2>/dev/null | wc -l | tr -d ' ')
[[ "$N" -ge 20 ]] || die "部署目录的仪表板模板只有 ${N} 个，预期 ≥20 —— 换文件没生效"
ok "仪表板模板 ${N} 个"

# ---------------------------------------------------------------- 3. 建库
log "步骤 3/9　建库并导入部件（约 1–2 分钟）"
( cd "$APP_HOME" && bash docker-01-install.sh ) >/tmp/rebuild-install.log 2>&1 \
  || { tail -40 /tmp/rebuild-install.log; die "建库失败，日志：/tmp/rebuild-install.log"; }
ok "库与部件就绪"

# ---------------------------------------------------------------- 4. 启动
log "步骤 4/9　启动服务并创建管理员（首次 1–3 分钟）"
( cd "$APP_HOME" && bash docker-02-start.sh \
    --admin-email "$ADMIN" --admin-pass "$ADMIN_PASS" ) >/tmp/rebuild-start.log 2>&1 \
  || { tail -40 /tmp/rebuild-start.log; die "启动失败，日志：/tmp/rebuild-start.log"; }
ok "服务已启动"

# ---------------------------------------------------------------- 5. 建租户客户
log "步骤 5/9　建租户与客户（演示数据在这一步生成）"
( cd "$APP_HOME" && bash scripts/02-onboard.sh \
    --base http://127.0.0.1:8090 \
    --admin "$ADMIN" --admin-pass "$ADMIN_PASS" \
    --tenant "$TENANT_TITLE" --tenant-email "$TENANT" --tenant-pass "$TENANT_PASS" \
    --customer "$CUST_TITLE" --customer-email "$CUSTOMER" --customer-pass "$CUST_PASS" ) \
  >/tmp/rebuild-onboard.log 2>&1 \
  || { tail -40 /tmp/rebuild-onboard.log; die "建租户失败，日志：/tmp/rebuild-onboard.log"; }
ok "租户与客户已创建"
sed -n 's/^  ✓ /     /p' /tmp/rebuild-onboard.log | head -20 || true

# ---------------------------------------------------------------- 6. 结构验收
FAILED=0
if [[ "$NO_VERIFY" != "true" ]]; then
  log "步骤 6/9　结构验收（接口与权限）"
  if ( cd "$APP_HOME" && bash scripts/03-verify.sh \
        --base http://127.0.0.1:8090 \
        --tenant "$TENANT" --tenant-pass "$TENANT_PASS" \
        --customer "$CUSTOMER" --customer-pass "$CUST_PASS" \
        --ai http://127.0.0.1:8090 ) >/tmp/rebuild-verify.log 2>&1; then
    ok "$(grep '通过' /tmp/rebuild-verify.log | tail -1 | tr -s ' ')"
  else
    FAILED=1
    warn "结构验收有失败项"
    grep -A20 '失败项' /tmp/rebuild-verify.log | head -25 || tail -20 /tmp/rebuild-verify.log
  fi
else
  log "步骤 6/9　跳过结构验收（--no-verify）"
fi

# ---------------------------------------------------------------- 7. 数据验收
if [[ "$NO_VERIFY" != "true" ]]; then
  log "步骤 7/9　数据验收（量值准确性与自洽）"
  if ( cd "$APP_HOME" && bash scripts/04-verify-data.sh ) >/tmp/rebuild-data.log 2>&1; then
    ok "$(grep '通过' /tmp/rebuild-data.log | tail -1 | tr -s ' ')"
  else
    FAILED=1
    warn "数据验收有失败项"
    sed -n '/失败项/,$p' /tmp/rebuild-data.log | head -25 || tail -25 /tmp/rebuild-data.log
  fi
else
  log "步骤 7/9　跳过数据验收（--no-verify）"
fi

# ---------------------------------------------------------------- 8. 全链路
if [[ "$NO_VERIFY" != "true" ]]; then
  log "步骤 8/9　全链路验收（组织→设备→上报→存储→报表）"
  if ( cd "$APP_HOME" && bash scripts/06-verify-e2e.sh \
        --base http://127.0.0.1:8090 \
        --tenant "$TENANT" --tenant-pass "$TENANT_PASS" \
        --customer "$CUSTOMER" --customer-pass "$CUST_PASS" \
        --mqtt-port "${MQTT_PORT:-1883}" ) >/tmp/rebuild-e2e.log 2>&1; then
    ok "$(grep '通过' /tmp/rebuild-e2e.log | tail -1 | tr -s ' ')"
  else
    FAILED=1
    warn "全链路验收有失败项"
    sed -n '/失败项/,$p' /tmp/rebuild-e2e.log | head -25 || tail -25 /tmp/rebuild-e2e.log
  fi
else
  log "步骤 8/9　跳过全链路验收（--no-verify）"
fi

# ---------------------------------------------------------------- 9. 发布内容
if [[ "$NO_VERIFY" != "true" ]]; then
  log "步骤 9/9　发布内容验收（这一版的功能点是否都在）"
  if [[ ! -f "$APP_HOME/scripts/08-verify-release.sh" ]]; then
    FAILED=1
    warn "缺少 scripts/08-verify-release.sh（部署目录里没有）"
    warn "修复：把仓库 shiyongshouce/downloads/scripts/*.sh 拷到 $APP_HOME/scripts/"
  elif ( cd "$APP_HOME" && bash scripts/08-verify-release.sh \
        --tenant "$TENANT" --tenant-pass "$TENANT_PASS" \
        --customer "$CUSTOMER" --customer-pass "$CUST_PASS" ) \
        >/tmp/rebuild-release.log 2>&1; then
    ok "$(grep '通过' /tmp/rebuild-release.log | tail -1 | tr -s ' ')"
  else
    FAILED=1
    warn "发布内容有缺口（菜单/看板/字典/计算字段未达预期）"
    sed -n '/失败/,$p' /tmp/rebuild-release.log | head -30 \
      || tail -30 /tmp/rebuild-release.log
  fi
else
  log "步骤 9/9　跳过发布内容验收（--no-verify）"
fi

# ---------------------------------------------------------------- 凭据
CRED="$APP_HOME/DEPLOY-CREDENTIALS.txt"
{
  echo "# 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# 每次重装都会覆盖；删掉这个文件不影响系统运行"
  echo
  echo "平台入口       http://127.0.0.1:8090"
  echo "系统管理员     $ADMIN / $ADMIN_PASS"
  echo "租户管理员     $TENANT / $TENANT_PASS"
  echo "客户用户       $CUSTOMER / $CUST_PASS"
  echo "租户名称       $TENANT_TITLE"
  echo "客户名称       $CUST_TITLE"
  echo
  echo "重装命令（在仓库根目录）："
  echo "  bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \\"
  echo "    --admin $ADMIN --admin-pass '$ADMIN_PASS' \\"
  echo "    --tenant $TENANT --tenant-pass '$TENANT_PASS' --tenant-title '$TENANT_TITLE' \\"
  echo "    --customer $CUSTOMER --customer-pass '$CUST_PASS' --customer-title '$CUST_TITLE' \\"
  echo "    --yes"
} > "$CRED"
chmod 600 "$CRED" 2>/dev/null || true

echo
echo "============================================================"
printf '  重装完成，耗时 %s\n' "$(elapsed)"
[[ "$FAILED" == "0" ]] && echo "  验收：全部通过" || echo "  验收：有失败项，见上方输出"
echo
echo "  入口      http://127.0.0.1:8090"
echo "  凭据      $CRED"
echo "  日志      /tmp/rebuild-{prepare,install,start,onboard,verify,data,e2e}.log"
echo "============================================================"
[[ "$FAILED" == "0" ]] || exit 1
