#!/usr/bin/env bash
# ==============================================================================
# 部署目录该有哪些运维脚本 —— 唯一真相（2026-11-02）
#
# 为什么要有这个文件：
#   这条规则原来散落在三处，靠注释互相提醒「改这里必须同步改那边」：
#     ① shiyongshouce/downloads/deploy/docker-00-prepare.sh    （拷贝）
#     ② shiyongshouce/downloads/deploy/docker-97-preflight.sh  （比对）
#     ③ shiyongshouce/downloads/scripts/32-check-deploy-sync.sh（比对 + 同步）
#   三处不一致的代价都是实测踩过的：
#     · preflight 曾用 `*` 全比，误报「部署目录缺 01-install.sh」
#     · prepare 只写 `0[2-9]-*`，漏了 10-cleanup-customer.sh
#     · prepare 的 aux 列表只写 ts-mirror.sh，漏了 dev-fast-build.sh
#       → 手册让 `cd ~/energy-app && bash scripts/dev-fast-build.sh`
#         ——这条命令从来就跑不了
#
# 用法（三个调用方都是同一段）：
#   source "<同目录>/_deploy-manifest.sh"
#   deploy_list_scripts "$目录"          # 列出该目录里「应部署」的脚本名
#   deploy_script_paths "$目录"          # 同上，但输出带目录的完整路径
#
# ★ 它自己也在 AUX 里 —— 部署目录里的 preflight / 32 也要能 source 到它。
# ==============================================================================

# 数字前缀的运维脚本：02..99。01 是裸机路径，Docker 部署故意不带。
DEPLOY_SCRIPT_GLOBS=('0[2-9]-*' '[1-9][0-9]-*')

# 不带数字前缀的辅助脚本。加新文件时只改这一行。
#   ts-mirror.sh        验收脚本（04/06/08）的依赖：把 Cassandra 遥测镜像到 PG
#   dev-fast-build.sh   开发期增量编译，靠 APP_HOME 更新部署目录的 jar
#   _deploy-manifest.sh 本文件（部署目录里的 preflight / 32 要 source 它）
DEPLOY_SCRIPT_AUX=('ts-mirror.sh' 'dev-fast-build.sh' '_deploy-manifest.sh')

# 部署根目录的 docker-*.sh。排除 00（组装脚本，要求在仓库根跑）。
DEPLOY_DOCKER_GLOB='docker-[0-9][0-9]-*.sh'
DEPLOY_DOCKER_EXCLUDE=('docker-00-prepare.sh')

# 列出 <目录> 里应部署的 docker-*.sh（排序去重）
deploy_list_docker() {
  local d="$1" f b ex skip
  for f in "$d"/$DEPLOY_DOCKER_GLOB; do
    [[ -f "$f" ]] || continue
    b=$(basename "$f")
    skip=0
    for ex in "${DEPLOY_DOCKER_EXCLUDE[@]}"; do
      [[ "$b" == "$ex" ]] && skip=1
    done
    [[ "$skip" == "0" ]] && echo "$b"
  done 2>/dev/null | sort -u
}

# 列出 <目录> 里应部署的脚本文件名（排序去重）
deploy_list_scripts() {
  local d="$1" g a f
  {
    for g in "${DEPLOY_SCRIPT_GLOBS[@]}"; do
      for f in "$d"/$g; do
        [[ -f "$f" ]] && basename "$f"
      done
    done
    for a in "${DEPLOY_SCRIPT_AUX[@]}"; do
      [[ -f "$d/$a" ]] && echo "$a"
    done
  } 2>/dev/null | sort -u
}

# 同上，但输出完整路径（拷贝用）
deploy_script_paths() {
  local d="$1" n
  deploy_list_scripts "$d" | while IFS= read -r n; do
    [[ -n "$n" ]] && printf '%s/%s\n' "$d" "$n"
  done
}
