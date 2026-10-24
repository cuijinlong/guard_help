#!/usr/bin/env bash
#
# 增量编译 + 原地更新 fat jar（开发期反复改代码时用）
#
# 为什么需要它
# ------------
# `mvn package` 改一行代码要 452 秒：Maven 的增量编译对这个模块失效，
# 每次重编 8351 / 9315 个 class。
# 实测同一台机器：
#   mvn compile   改一行 → 452 s
#   javac 单文件 改一行 → 7.5 s
# 打包（426MB fat jar）57 s，复制 5 s，容器重启到 healthy 224 s。
#
# 本脚本把「编译 + 打包」从 509 秒压到十几秒：
#   1. 只编改动的那几个 .java（javac 直接调，不经 Maven）
#   2. 用 `jar uf` 原地把 .class 写进 fat jar（不重打 426MB）
#   3. 容器重启仍需 224 s（这是 Spring 启动，脚本无法省略）
#
# 用法
# ----
#   bash tools/dev-fast-build.sh                       # 自动找最近改动的 .java
#   bash tools/dev-fast-build.sh Foo.java Bar.java     # 指定文件（相对 src/main/java）
#   bash tools/dev-fast-build.sh --all                 # 改动很多时退回全量 javac（仍比 Maven 快）
#   bash tools/dev-fast-build.sh --deploy              # 编完顺便部署 + 重启容器
#   bash tools/dev-fast-build.sh --sync                # 只同步 .build 缓存（jar 更新后跑一次）
#
# 前提
# ----
#   $APP_HOME/.build/ 里已有 classes 与 lib（脚本首次运行会自动解出，约 40 秒）。
#   改了 pom.xml（新增依赖）、改了资源文件、改了 lombok 注解结构 → 请用 mvn package。
#
# ⚠ 边界（务必知道）
# ------------------
#   · 只改**方法体**最安全；改了方法签名/字段类型时，依赖它的类必须一起重编，
#     否则运行期 NoSuchMethodError。脚本会检查最近改动的文件数，超过 20 个就提示用 --all。
#   · 资源文件（src/main/resources/**）不在本脚本范围内 —— `jar uf` 也能更新，
#     但容易被漏掉，统一走 mvn package 更稳。
#
set -euo pipefail

# 仓库根：优先环境变量，其次从脚本位置推导（脚本可能被复制到部署目录）
if [[ -n "${REPO:-}" && -d "$REPO/guard-server" ]]; then
  :
elif [[ -d "$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/guard-server" ]]; then
  REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
elif [[ -d "$HOME/Documents/workspace/iot-rule-engine/guard-server" ]]; then
  REPO="$HOME/Documents/workspace/iot-rule-engine"
else
  echo "找不到仓库（设置 REPO=/path/to/iot-rule-engine 后重试）" >&2
  exit 1
fi
MOD="$REPO/guard-server"
APP_HOME="${APP_HOME:-$HOME/energy-app}"
JAR="$APP_HOME/guard-server-4.4.0.jar"
BUILD="$APP_HOME/.build"
SRC="$MOD/src/main/java"

DEPLOY="false"
MODE="auto"
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy) DEPLOY="true"; shift ;;
    --sync)   MODE="sync"; shift ;;
    --all)    MODE="all"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) die_unknown="$1"; echo "未知参数：$1" >&2; exit 1 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$JAR" ]] || die "找不到 ${JAR}（先跑一次 docker-01-install 或 mvn package）"

# ---------------------------------------------------------------- 同步缓存
sync_cache() {
  local jar_ts cache_ts
  jar_ts=$(stat -f %m "$JAR" 2>/dev/null || stat -c %Y "$JAR")
  cache_ts=$(stat -f %m "$BUILD/classes" 2>/dev/null || stat -c %Y "$BUILD/classes" 2>/dev/null || echo 0)
  if [[ "$cache_ts" -ge "$jar_ts" && -d "$BUILD/lib" ]]; then
    return 0
  fi
  log "同步编译缓存（jar 有更新，重新解出 classes/lib，约 40 秒）"
  rm -rf "$BUILD"; mkdir -p "$BUILD"
  ( cd "$BUILD" && unzip -q -o "$JAR" 'BOOT-INF/classes/*' 'BOOT-INF/lib/*' )
  mv -f "$BUILD/BOOT-INF/classes" "$BUILD/classes"
  mv -f "$BUILD/BOOT-INF/lib" "$BUILD/lib"
  rmdir "$BUILD/BOOT-INF" 2>/dev/null || true
  ok "缓存已就绪（classes $(du -sh "$BUILD/classes" | cut -f1) / lib $(du -sh "$BUILD/lib" | cut -f1)）"
}

if [[ "$MODE" == "sync" ]]; then
  rm -rf "$BUILD"
  sync_cache
  exit 0
fi

sync_cache

CP="$BUILD/classes:$(ls "$BUILD/lib"/*.jar | tr '\n' ':')"

# ---------------------------------------------------------------- 选文件
if [[ "$MODE" != "all" && ${#FILES[@]} -eq 0 ]]; then
  # 最近 2 小时内改过的 .java（排除 target）
  while IFS= read -r f; do
    FILES+=("${f#"$SRC"/}")
  done < <(find "$SRC" -name '*.java' -newermt '-2 hours' 2>/dev/null || true)
fi

if [[ "$MODE" != "all" && ${#FILES[@]} -eq 0 ]]; then
  warn "最近 2 小时没有 .java 改动。要全量编译请加 --all"
  exit 0
fi

if [[ "$MODE" != "all" && ${#FILES[@]} -gt 20 ]]; then
  warn "改动文件 ${#FILES[@]} 个（>20），改用全量编译（--all 语义）"
  MODE="all"
fi

# ---------------------------------------------------------------- 编译
PATCH="$BUILD/patch"
rm -rf "$PATCH"
mkdir -p "$PATCH/BOOT-INF/classes"

START=$(date +%s)

if [[ "$MODE" == "all" ]]; then
  log "全量 javac（$(find "$SRC" -name '*.java' | wc -l | tr -d ' ') 个源文件）"
  find "$SRC" -name '*.java' > "$BUILD/sources.txt"
  javac -nowarn -proc:none -encoding UTF-8 \
        -cp "$CP" -d "$PATCH/BOOT-INF/classes" \
        @"$BUILD/sources.txt" 2>&1 | grep -v "^注:" | head -40 || true
else
  log "单文件编译 ${#FILES[@]} 个"
  ABS=()
  for f in "${FILES[@]}"; do
    if [[ -f "$SRC/$f" ]]; then
      ABS+=("$SRC/$f")
    elif [[ -f "$f" ]]; then
      ABS+=("$f")
    elif [[ -f "$SRC/com/guard/server/$f" ]]; then
      # 常见笔误：漏了 com/guard/server 前缀
      ABS+=("$SRC/com/guard/server/$f")
    else
      # 只给了文件名（Foo.java）→ 按名字搜索
      hit=$(find "$SRC" -name "$(basename "$f")" 2>/dev/null | head -1)
      if [[ -n "$hit" ]]; then
        ABS+=("$hit")
        warn "按文件名匹配到：${hit#"$SRC"/}"
      else
        die "找不到源文件：$f"
      fi
    fi
  done
  javac -nowarn -proc:none -encoding UTF-8 \
        -cp "$CP" -d "$PATCH/BOOT-INF/classes" \
        "${ABS[@]}" 2>&1 | grep -v "^注:" | head -40 || true
fi

N=$(find "$PATCH/BOOT-INF/classes" -name '*.class' | wc -l | tr -d ' ')
[[ "$N" -gt 0 ]] || die "没有生成任何 .class（看上面的 javac 报错）"
ok "编译完成：${N} 个 class，耗时 $(( $(date +%s) - START ))s"

# 同步到缓存，供下次编译做 classpath
( cd "$PATCH/BOOT-INF/classes" && find . -name '*.class' -print0 | \
    while IFS= read -r -d '' c; do
      mkdir -p "$BUILD/classes/$(dirname "$c")"
      cp -f "$c" "$BUILD/classes/$c"
    done )

# ---------------------------------------------------------------- 原地更新 jar
log "原地更新 fat jar（不重打 426MB）"
UPD_START=$(date +%s)
if [[ "$MODE" == "all" ]]; then
  # 全量时逐个列文件会超出命令行长度上限，整目录更新即可
  ( cd "$PATCH" && jar uf "$JAR" -C . BOOT-INF ) || die "jar uf 失败"
else
  ( cd "$PATCH" && find BOOT-INF/classes -name '*.class' > "$BUILD/changed.txt" )
  ( cd "$PATCH" && jar uf "$JAR" -C . $(cat "$BUILD/changed.txt" | tr '\n' ' ') ) \
    || die "jar uf 失败"
fi
ok "jar 已更新 ${N} 个 entry，耗时 $(( $(date +%s) - UPD_START ))s"

echo
log "总耗时 $(( $(date +%s) - START ))s（对比 mvn package 约 509s）"

# ---------------------------------------------------------------- 部署
if [[ "$DEPLOY" == "true" ]]; then
  log "重启服务（约 224 秒，Spring 启动无法省）"
  ( cd "$APP_HOME" && docker compose --profile split restart energy-server >/dev/null 2>&1 )
  for i in $(seq 1 90); do
    st=$(docker inspect --format '{{.State.Health.Status}}' energy-server 2>/dev/null || echo unknown)
    [[ "$st" == "healthy" ]] && { ok "服务 healthy（$(( i * 5 ))s）"; exit 0; }
    sleep 5
  done
  die "服务未在 450 秒内 healthy，看 docker logs energy-server"
else
  echo
  echo "  下一步：cd $APP_HOME && docker compose --profile split restart energy-server"
  echo "  或直接加 --deploy 让脚本重启"
fi
