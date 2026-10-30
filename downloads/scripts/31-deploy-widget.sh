#!/usr/bin/env bash
#
# 能源管理平台 · 部署单个/多个部件（widget type）JSON
#
# 用途：你改了 guard-server/src/main/data/json/system/widget_types/xxx.json，
#       想让它立刻生效 —— 这条命令把「推库」和「同步挂载目录」一次做完。
#
# 用法（在仓库根目录执行）：
#   bash shiyongshouce/downloads/scripts/31-deploy-widget.sh energy_management_meter_reading_board
#   bash shiyongshouce/downloads/scripts/31-deploy-widget.sh meter_reading_board meter_plan
#   bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --all
#   bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --check xxx
#
# 常用开关：
#   --all          推所有 energy_management_*.json
#   --check        只校验 JSON 与字段，不改任何东西
#   --restart      额外重启 energy-server（通常**不需要**，见下方说明）
#   --app-home DIR 部署目录，默认 ~/energy-app
#   --db NAME      postgres 容器名，默认 energy-postgres
#   --yes          不交互确认
#
# ★★ 为什么改部件不需要重启后端 ★★
#
#   部件定义存在两处：
#     ① 数据库  widget_type.descriptor   ← 前端实际读这里
#     ② 挂载目录 $APP_HOME/data/json/system/widget_types/*.json
#                                          ← 后端**启动时**从这里装载，写回 ①
#
#   前端调 /api/widgetType?fqn=… 读的是 ①，所以 **UPDATE ① 立即生效**
#   （实测：改库后 2 秒内接口就返回新内容，无需重启、无需重启容器）。
#   浏览器需要硬刷新（Ctrl/Cmd+Shift+R）才会重新拉 descriptor。
#
#   但那**不等于**只改 ① 就够 —— 后端每次启动都会跑 loadSystemWidgets()：
#   把 ② 里的每个 JSON 重新 saveWidgetType 一遍（fqn 相同则覆盖）。
#   所以只改库不改文件的话，**下一次重启（换 jar、改 .env、机器重启）
#   改动就被文件覆盖回去了**，而且不报任何错。
#
#   这就是本脚本必须同时做两件事的原因：
#     · 推 ① → 立刻生效
#     · 同步 ② → 重启后还在
#
# ★★ 不影响客户看板副本 ★★
#
#   看板里只存 typeFullFqn（如 system.energy_management.query_panel），
#   不存在「部件被复制到客户名下」这回事 —— 改一次，所有看板一起变。
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
APP_HOME="${APP_HOME:-$HOME/energy-app}"
DB_CONTAINER="energy-postgres"
DB_NAME="thingsboard"
ALL="false"
CHECK_ONLY="false"
DO_RESTART="false"
ASSUME_YES="false"
BASE="${BASE:-http://127.0.0.1:8090}"

WT_DIR="$ROOT/guard-server/src/main/data/json/system/widget_types"
APP_WT_DIR="$APP_HOME/data/json/system/widget_types"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

NAMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)        ALL="true"; shift ;;
    --check)      CHECK_ONLY="true"; shift ;;
    --restart)    DO_RESTART="true"; shift ;;
    --app-home)   APP_HOME="$2"; APP_WT_DIR="$APP_HOME/data/json/system/widget_types"; shift 2 ;;
    --db)         DB_CONTAINER="$2"; shift 2 ;;
    --base)       BASE="$2"; shift 2 ;;
    --yes|-y)     ASSUME_YES="true"; shift ;;
    -h|--help)    sed -n '2,45p' "$0"; exit 0 ;;
    -*)           die "未知参数：$1（用 --help 看用法）" ;;
    *)            NAMES+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------- 0. 环境检查
[[ -d "$WT_DIR" ]] || die "找不到部件源目录：$WT_DIR
   这个脚本要在仓库里执行（仓库根应包含 guard-server/）"
command -v docker >/dev/null 2>&1 || die "找不到 docker 命令"

if ! docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
  die "容器 $DB_CONTAINER 没在运行
   先启动：cd $APP_HOME && docker compose --profile split up -d"
fi

if [[ ! -d "$APP_WT_DIR" ]]; then
  warn "部署目录里没有 $APP_WT_DIR"
  warn "  推库仍会生效（前端读库），但**下次重启会被源文件覆盖**。"
  warn "  确认 --app-home 指向正确的部署目录（当前 $APP_HOME）。"
fi

# ---------------------------------------------------------------- 1. 确定目标
if [[ "$ALL" == "true" ]]; then
  for f in "$WT_DIR"/energy_management_*.json; do
    [[ -f "$f" ]] && NAMES+=("$(basename "$f" .json)")
  done
  [[ ${#NAMES[@]} -gt 0 ]] || die "没找到任何 energy_management_*.json"
fi

if [[ ${#NAMES[@]} -eq 0 ]]; then
  echo "用法：bash $0 <部件名> [部件名...] [--all] [--check]"
  echo
  echo "可用的部件（前 20 个）："
  ls "$WT_DIR"/energy_management_*.json 2>/dev/null | head -20 | xargs -n1 basename | sed 's/\.json$//;s/^/    /'
  echo "    …共 $(ls "$WT_DIR"/energy_management_*.json 2>/dev/null | wc -l | tr -d ' ') 个，用 --all 全部部署"
  exit 2
fi

# ---------------------------------------------------------------- 2. 逐个校验
#
# 先把所有文件校验一遍再动手：半途发现第 5 个文件语法错，
# 前面 4 个已经推库了 —— 用户会得到一棵"改了一半"的树，比全不动更难查。
log "校验 ${#NAMES[@]} 个部件 JSON"

RESOLVED=()      # 绝对路径列表
FQNS=()          # 对应的 fqn

for name in "${NAMES[@]}"; do
  # 允许三种写法：完整文件名 / 不带扩展名 / 完整 fqn
  cand=""
  for try in \
      "$WT_DIR/${name}" \
      "$WT_DIR/${name}.json" \
      "$WT_DIR/$(echo "$name" | tr '.' '_').json"; do
    [[ -f "$try" ]] && { cand="$try"; break; }
  done
  [[ -n "$cand" ]] || die "找不到部件文件：$name
   在 $WT_DIR 下找不到 ${name}.json —— 检查文件名是否拼错"

  res=$(python3 - "$cand" <<'PYEOF' 2>&1
import json, sys

path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        d = json.load(f)
except json.JSONDecodeError as e:
    print(f'JSONERR|{e.lineno}:{e.colno} {e.msg}')
    sys.exit(0)
except Exception as e:
    print(f'READERR|{e}')
    sys.exit(0)

if not isinstance(d, dict):
    print('SHAPE|顶层必须是对象')
    sys.exit(0)

fqn = d.get('fqn')
if not fqn or not isinstance(fqn, str):
    print('NOFQN|缺少 fqn 字段')
    sys.exit(0)

desc = d.get('descriptor')
if not isinstance(desc, dict):
    print('NODESC|缺少 descriptor 对象（部件就是它的模板/脚本/样式）')
    sys.exit(0)

need = ['templateHtml']
miss = [k for k in need if not desc.get(k)]
if miss:
    print('NODESCKEY|descriptor 里缺少 ' + ','.join(miss))
    sys.exit(0)

# psql 用 $w$ 做定界符，内容里不能出现它，否则 SQL 会被截断
blob = json.dumps(desc, ensure_ascii=False)
if '$w$' in blob:
    print('DELIM|content 里出现 $w$，会破坏 SQL 定界符')
    sys.exit(0)

print(f'OK|{fqn}|{len(blob)}')
PYEOF
)

  if [[ "$res" != OK\|* ]]; then
    code="${res%%|*}"
    detail="${res#*|}"
    case "$code" in
      JSONERR)   die "$(basename "$cand")：JSON 语法错误 —— $detail" ;;
      READERR)   die "$(basename "$cand")：读不了 —— $detail" ;;
      NOFQN)     die "$(basename "$cand")：$detail" ;;
      NODESC)    die "$(basename "$cand")：$detail" ;;
      NODESCKEY) die "$(basename "$cand")：$detail" ;;
      DELIM)     die "$(basename "$cand")：$detail" ;;
      *)         die "$(basename "$cand")：校验失败 —— $res" ;;
    esac
  fi

  IFS='|' read -r _ fqn size <<< "$res"
  RESOLVED+=("$cand")
  FQNS+=("$fqn")
  printf '    %-52s %-42s %6s B\n' "$(basename "$cand")" "$fqn" "$size"
done

ok "${#RESOLVED[@]} 个文件语法与字段都合格"

if [[ "$CHECK_ONLY" == "true" ]]; then
  echo
  log "--check：只校验，未改动任何东西"
  exit 0
fi

# ---------------------------------------------------------------- 3. 确认
echo
if [[ "$ASSUME_YES" != "true" ]]; then
  echo "即将："
  echo "  ① 推库（${DB_CONTAINER} / ${DB_NAME}）→ 前端**立即可用**"
  echo "  ② 同步到 $APP_WT_DIR → 保证**重启后仍在**"
  echo
  read -r -p "继续？[y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "已取消"; exit 0; }
  echo
fi

# ---------------------------------------------------------------- 4. 推库 + 同步文件
PUSHED=0
for i in "${!RESOLVED[@]}"; do
  file="${RESOLVED[$i]}"
  fqn="${FQNS[$i]}"
  name="$(basename "$file")"

  # 生成 SQL：descriptor 用 $w$ 包裹，避免引号/反斜杠转义问题。
  #
  # ★ 顶层字段（name / description / deprecated / tags）也要一起推。
  #   它们不是 descriptor 的一部分，只 UPDATE descriptor 的话，
  #   你把 JSON 里的显示名改掉、库里还是旧的 —— 前端按 fqn 加载时显示的
  #   就是库里的 name。实测踩过：只推 descriptor，name 改动完全不生效。
  if ! python3 - "$file" "$fqn" > /tmp/deploy-widget.sql <<'PYEOF'
import json, sys

path, fqn = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    d = json.load(f)

def sql_str(v):
    if v is None:
        return 'NULL'
    return '$s$' + str(v).replace('$s$', "'") + '$s$'

desc = json.dumps(d['descriptor'], ensure_ascii=False)

sets = [f'descriptor = $w${desc}$w$']
if 'name' in d:
    sets.append(f"name = {sql_str(d['name'])}")
if 'description' in d:
    sets.append(f"description = {sql_str(d['description'])}")
if 'deprecated' in d:
    sets.append(f"deprecated = {'true' if d['deprecated'] else 'false'}")
if d.get('tags'):
    arr = ', '.join(sql_str(t) for t in d['tags'])
    sets.append(f'tags = ARRAY[{arr}]')

print(f"UPDATE widget_type SET {', '.join(sets)} WHERE fqn = '{fqn}';")
PYEOF
  then
    die "$name：生成 SQL 失败"
  fi

  out=$(docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -v ON_ERROR_STOP=1 < /tmp/deploy-widget.sql 2>&1)
  rc=$?
  rm -f /tmp/deploy-widget.sql

  if [[ $rc -ne 0 ]]; then
    echo "$out" | tail -5
    die "$name：推库失败（fqn=$fqn）"
  fi

  # 「UPDATE 0」= 库里没有这个 fqn，前端会报「部件类型已被移除」
  if echo "$out" | grep -q 'UPDATE 0'; then
    die "$name：库里没有 fqn=$fqn 这条记录
   → 该部件还没被装载过。先确认后端启动日志里有 loadSystemWidgets，
     或跑一次：bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh --keep-data ..."
  fi

  # 同步挂载目录（缺失时只警告：推库已生效，但重启会丢）
  if [[ -d "$APP_WT_DIR" ]]; then
    cp "$file" "$APP_WT_DIR/$name" || die "$name：同步到部署目录失败（权限？）"
  fi

  PUSHED=$((PUSHED + 1))
  ok "$name"
done

# ---------------------------------------------------------------- 5. 回读验证
#
# 只信「库里现在是什么」，不信「psql 说 UPDATE 1」——
# 如果 SQL 写错（比如多推了别的字段），UPDATE 照样返回 1。
log "回读验证"

FAIL=0
for i in "${!RESOLVED[@]}"; do
  file="${RESOLVED[$i]}"
  fqn="${FQNS[$i]}"
  name="$(basename "$file")"

  docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -tA \
    -c "SELECT descriptor FROM widget_type WHERE fqn = '$fqn';" > /tmp/deploy-widget-db.json 2>/dev/null

  # ★ 不能用 `python3 - <<EOF` 再叠加 `<<<` 输入：两个 heredoc 会抢同一个 stdin，
  #   实际读到的是脚本本身而不是库内容 —— 判定会永远走 DIFF 分支。
  #   先把库内容落到文件，python 只从文件读，判据才可靠。
  verdict=$(python3 - "$file" /tmp/deploy-widget-db.json <<'PYEOF'
import json, sys

with open(sys.argv[1], encoding='utf-8') as f:
    want = json.load(f)['descriptor']
try:
    with open(sys.argv[2], encoding='utf-8') as f:
        raw = f.read().strip()
except Exception:
    print('READERR')
    sys.exit(0)

if not raw:
    print('EMPTY')
    sys.exit(0)
try:
    got = json.loads(raw)
except Exception:
    print('BADJSON')
    sys.exit(0)
print('MATCH' if got == want else 'DIFF')
PYEOF
)
  rm -f /tmp/deploy-widget-db.json

  case "$verdict" in
    MATCH)   ok "$name 库内一致" ;;
    EMPTY)   warn "$name：库里查不到该 fqn"; FAIL=$((FAIL + 1)) ;;
    BADJSON) warn "$name：库内 descriptor 不是合法 JSON"; FAIL=$((FAIL + 1)) ;;
    READERR) warn "$name：读库结果失败"; FAIL=$((FAIL + 1)) ;;
    *)       warn "$name：库内与文件不完全一致（可能是推送被截断）"; FAIL=$((FAIL + 1)) ;;
  esac
done

# 文件侧也看一眼：部署目录里的副本是否与源文件同 md5
if [[ -d "$APP_WT_DIR" ]]; then
  SYNC_BAD=0
  for file in "${RESOLVED[@]}"; do
    name="$(basename "$file")"
    if [[ -f "$APP_WT_DIR/$name" ]]; then
      if [[ "$(md5 -q "$file" 2>/dev/null || md5sum "$file" | cut -d' ' -f1)" != \
            "$(md5 -q "$APP_WT_DIR/$name" 2>/dev/null || md5sum "$APP_WT_DIR/$name" | cut -d' ' -f1)" ]]; then
        warn "$name：部署目录副本与源文件不一致"; SYNC_BAD=$((SYNC_BAD + 1))
      fi
    fi
  done
  [[ "$SYNC_BAD" -eq 0 ]] && ok "部署目录副本与源文件一致（重启不会被覆盖）"
fi

# ---------------------------------------------------------------- 6. 可选重启
if [[ "$DO_RESTART" == "true" ]]; then
  log "重启 energy-server（通常不需要，仅当你强制要求）"
  ( cd "$APP_HOME" && docker compose --profile split restart energy-server ) >/tmp/deploy-widget-restart.log 2>&1 \
    || { tail -20 /tmp/deploy-widget-restart.log; die "重启失败"; }
  for i in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' energy-server 2>/dev/null)" == "healthy" ]] && break
    sleep 5
  done
  ok "energy-server 已恢复"
fi

# ---------------------------------------------------------------- 7. 收尾提示
echo
echo "============================================================"
[[ "$FAIL" -eq 0 ]] && echo "  已部署 $PUSHED 个部件，库内一致" || echo "  已部署 $PUSHED 个部件，其中 $FAIL 个需复查（见上方 !）"
echo
echo "  下一步：浏览器 **硬刷新**（Ctrl/Cmd + Shift + R）"
echo "    前端会重新拉 descriptor；普通刷新可能命中缓存，看不到改动。"
echo
echo "  验证某个部件现在长什么样："
echo "    curl -s --noproxy '*' -H \"X-Authorization: Bearer \$TOKEN\" \\"
echo "      '$BASE/api/widgetType?fqn=system.<fqn>' | head -c 400"
echo
echo "  确认重启后仍在（模拟一次装载，不改数据）："
echo "    ls -l $APP_WT_DIR/$(basename "${RESOLVED[0]}" 2>/dev/null || echo '<name>.json')"
echo "============================================================"

[[ "$FAIL" -eq 0 ]] || exit 1
