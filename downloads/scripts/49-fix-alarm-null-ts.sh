#!/usr/bin/env bash
#
# 能源管理平台 · 修复 alarm 表里 NULL 的时间戳（导致告警列表整页 500）
#
# ============================================================================
# 这个脚本解决什么问题
# ============================================================================
#
# 症状：打开「设备运维」或「告警」页时，顶部弹红条：
#
#   Cannot invoke "java.lang.Long.longValue()" because
#   the return value of "java.util.Map.get(Object)" is null
#
# 触发条件（实测，2026-11-23）：statusList=ACTIVE 且 siteId 指向的场站下
# 存在 ack_ts / clear_ts / end_ts 为 SQL NULL 的告警。
#
# 精确判据（比"某些参数组合"更准）：
#
#   pageSize=1&page=0  → 200   （只取第一行，那行时间戳齐全）
#   pageSize=2&page=0  → 500   （第二行 ack_ts 是 NULL，拆箱即炸）
#
# 也就是说：**不是参数组合问题，是某几行数据本身有问题**。
#
# ============================================================================
# 根因（TB 4.4.0 内核）
# ============================================================================
#
# guard-core/dao/sql/query/DefaultAlarmQueryRepository.java:316
#   List<Map<String, Object>> rows = jdbcTemplate.queryForList(dataQuery, ctx);
#   AlarmDataAdapter.createAlarmData(pageLink, rows, ...)
#
# guard-core/dao/model/alarm/AlarmDataAdapter.java:52-56
#   alarm.setAckTs((long) row.get(ALARM_ACK_TS_PROPERTY));
#   alarm.setClearTs((long) row.get(...));
#   alarm.setAssignTs((long) row.get(...));
#   alarm.setEndTs((long) row.get(...));
#
# `(long) Object` 会先 checkcast 成 Long 再拆箱。列值为 SQL NULL 时
# Map.get 返回 null → NPE，消息正是
#   Cannot invoke "java.lang.Long.longValue()" because
#   the return value of "java.util.Map.get(Object)" is null
#
# TB 自己写入时一律填 0（实测 1443 行里 1438 行 ack_ts=0），
# 所以这不是内核的常规路径缺陷，而是**库里有非 TB 写入路径留下的 NULL**。
#
# ============================================================================
# 为什么改数据、不改内核代码
# ============================================================================
#
# AGENTS.md A4 铁律：不污染 TB 内核。
# AlarmDataAdapter 是 TB 原生类，加 null 守卫属于改内核 —— 不采用。
# TB 的语义本身就允许 0 表示"未设置"（acknowledged / cleared 另有布尔列），
# 所以把 NULL 归 0 是与平台约定一致的最小修复：
#
#   ack_ts   NULL → 0         表示从未确认
#   clear_ts NULL → 0         表示从未清除
#   end_ts   NULL → start_ts  end_ts 语义是"最后活跃时间"，从未更新过就等于开始时间
#
# 实测证据：正常活跃告警 72130388 的 end_ts 与 start_ts 完全相等，
# 印证 above 的语义判断。
#
# ============================================================================
# 用法（在部署目录执行）
# ============================================================================
#
#   bash scripts/49-fix-alarm-null-ts.sh --check    # 只看有多少脏数据（默认）
#   bash scripts/49-fix-alarm-null-ts.sh --fix     # 备份 + 修复
#
# 退出码：0 = 没有脏数据（或已修好）；1 = --check 时发现脏数据；2 = 执行失败
#
set -uo pipefail

DB_CONTAINER="${TB_DB_CONTAINER:-energy-postgres}"
DB_USER="${TB_DB_USER:-postgres}"
DB_NAME="${TB_DB_NAME:-thingsboard}"

MODE="check"
case "${1:-}" in
  --check|"") MODE="check" ;;
  --fix)      MODE="fix" ;;
  -h|--help)  sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "未知参数：$1（可用 --check / --fix）" >&2; exit 2 ;;
esac

psql_q() {
  docker exec "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -tAc "$1" 2>&1
}

# 容器在不在，先判一次 —— 否则 psql 的报错会混进数据里，看起来像"有脏数据"
if ! docker inspect "${DB_CONTAINER}" >/dev/null 2>&1; then
  echo "✗ 找不到容器 ${DB_CONTAINER}（可用 TB_DB_CONTAINER 覆盖）" >&2
  exit 2
fi

echo "容器：${DB_CONTAINER}　库：${DB_NAME}"

# 四个列各自统计。分开数比 count(*) FILTER 更容易看出是哪一列出的问题
ACK=$(psql_q "SELECT count(*) FROM alarm WHERE ack_ts IS NULL;")
CLEAR=$(psql_q "SELECT count(*) FROM alarm WHERE clear_ts IS NULL;")
END=$(psql_q "SELECT count(*) FROM alarm WHERE end_ts IS NULL;")
ASSIGN=$(psql_q "SELECT count(*) FROM alarm WHERE assign_ts IS NULL;")

# psql 出错时输出不是纯数字，统一兜住
for v in "${ACK}" "${CLEAR}" "${END}" "${ASSIGN}"; do
  case "${v}" in
    ''|*[!0-9]*) echo "✗ 查询失败：$v" >&2; exit 2 ;;
  esac
done

TOTAL=$((ACK + CLEAR + END + ASSIGN))
echo "ack_ts 空=${ACK}　clear_ts 空=${CLEAR}　end_ts 空=${END}　assign_ts 空=$ASSIGN"

if [ "${TOTAL}" -eq 0 ]; then
  echo "✓ 没有 NULL 时间戳，告警列表不会因此 500"
  exit 0
fi

# 有脏数据时，把行明细打出来 —— 修之前要能看见修的是哪几条
echo ""
echo "受影响的告警："
psql_q "
SELECT a.id || ' | ' || a.type || ' | cleared=' || a.cleared
       || ' ack=' || a.acknowledged
       || ' | ack_ts=' || coalesce(a.ack_ts::text, 'NULL')
       || ' clear_ts=' || coalesce(a.clear_ts::text, 'NULL')
       || ' end_ts=' || coalesce(a.end_ts::text, 'NULL')
       || ' | ' || to_char(to_timestamp(a.created_time / 1000) AT TIME ZONE 'Asia/Shanghai', 'MM-DD HH24:MI')
FROM alarm a
WHERE a.ack_ts IS NULL OR a.clear_ts IS NULL OR a.end_ts IS NULL OR a.assign_ts IS NULL
ORDER BY a.created_time DESC;" | while IFS= read -r line; do
  [ -n "${line}" ] && echo "  · $line"
done

if [ "${MODE}" = "check" ]; then
  echo ""
  echo "⚠️ 这些行会让对应的 statusList 查询返回 500。执行 --fix 修复。"
  exit 1
fi

# ─────────── 修复 ───────────
STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP="alarm_backup_null_ts_${STAMP}"
echo ""
echo "备份到表 ${BACKUP} …"
psql_q "CREATE TABLE ${BACKUP} AS SELECT * FROM alarm
        WHERE ack_ts IS NULL OR clear_ts IS NULL OR end_ts IS NULL OR assign_ts IS NULL;" >/dev/null
if [ $? -ne 0 ]; then
  echo "✗ 备份失败，中止（一个字节都没改）" >&2
  exit 2
fi

# 事务里一次改完：中途失败不会留下半成品（A2l 记过这个坑）
echo "修复中 …"
OUT=$(psql_q "
BEGIN;
UPDATE alarm SET ack_ts   = 0        WHERE ack_ts   IS NULL;
UPDATE alarm SET clear_ts = 0        WHERE clear_ts IS NULL;
UPDATE alarm SET assign_ts = 0       WHERE assign_ts IS NULL;
UPDATE alarm SET end_ts   = start_ts WHERE end_ts   IS NULL AND start_ts IS NOT NULL;
COMMIT;
SELECT count(*) FROM alarm
 WHERE ack_ts IS NULL OR clear_ts IS NULL OR end_ts IS NULL OR assign_ts IS NULL;")

REMAIN=$(printf '%s\n' "${OUT}" | tail -n1)
if [ "${REMAIN}" = "0" ]; then
  echo "✓ 已修复，剩余 NULL = 0（备份表：${BACKUP}）"
  echo "  浏览器硬刷新（Cmd/Ctrl+Shift+R）后重开设备运维页，红条应消失。"
  exit 0
else
  echo "✗ 修复后仍有 NULL：${REMAIN}（详见上方输出，备份表 ${BACKUP} 可回滚）" >&2
  exit 2
fi
