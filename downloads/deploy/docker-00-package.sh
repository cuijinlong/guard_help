#!/usr/bin/env bash
#
# 能源管理平台 · 生成 Docker 部署包（在开发机 / 构建机执行）
#
# 用法（在仓库根目录）：
#   bash docker-00-package.sh [输出目录]
#
# 产出：
#   energy-deploy-<日期>.tar.gz
#     内含 jar、data/（json + sql）、docker-compose.yml、env.example、脚本
#
# 为什么单独打包 data：
#   install 要从文件系统读 json/（部件、仪表板、规则链）和 sql/（建表脚本）。
#   jar 里只有 java 资源，没有这两类文件，漏了会直接初始化失败。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT_DIR="${1:-$ROOT/dist}"
STAGE="$OUT_DIR/energy-deploy"
DATA_SRC="$ROOT/guard-server/src/main/data"
SQL_SRC="$ROOT/dao/src/main/resources/sql"
JAR="$ROOT/guard-server/target/guard-server-4.4.0.jar"

die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }

[[ -f "$JAR" ]] || die "找不到 $JAR —— 先执行：cd guard-server && mvn package -DskipTests"
[[ -d "$DATA_SRC/json" ]] || die "找不到 $DATA_SRC/json"
[[ -d "$SQL_SRC" ]] || die "找不到 $SQL_SRC"

rm -rf "$STAGE"
mkdir -p "$STAGE/data/sql" "$STAGE/logs" "$STAGE/scripts"

cp "$JAR" "$STAGE/"
cp -R "$DATA_SRC/json" "$STAGE/data/"
# 注意：仓库里 data/sql 是符号链接，必须从 dao 的真实目录拷贝，不能 cp -R 链接本身
cp "$SQL_SRC"/*.sql "$STAGE/data/sql/"
cp "$(dirname "$0")/docker-compose.yml" "$STAGE/"
cp "$(dirname "$0")/env.example" "$STAGE/"
cp "$(dirname "$0")/docker-01-install.sh" "$STAGE/"
cp "$(dirname "$0")/docker-02-start.sh" "$STAGE/"
cp "$(dirname "$0")/docker-99-uninstall.sh" "$STAGE/"
cp "$(dirname "$0")/../scripts/02-onboard.sh" "$STAGE/scripts/"
cp "$(dirname "$0")/../scripts/03-verify.sh" "$STAGE/scripts/"
chmod +x "$STAGE"/docker-*.sh "$STAGE"/scripts/*.sh

TAR="$OUT_DIR/energy-deploy-$(date +%Y%m%d).tar.gz"
tar -czf "$TAR" -C "$OUT_DIR" energy-deploy

ok "发布包：$TAR"
echo "    大小：$(du -h "$TAR" | cut -f1)"
echo "    内容："
tar -tzf "$TAR" | grep -vE "data/(json|sql)/.+/" | head -15
echo
echo "上传到服务器："
echo "    scp $TAR user@server:/opt/"
echo "    ssh user@server 'cd /opt && tar -xzf $(basename "$TAR") && cd energy-deploy && cp env.example .env'"
