#!/usr/bin/env bash
#
# 能源管理平台 · 清空一个客户的演示数据（保留结构，可反复重测）
#
# 与 10-cleanup-customer.sh 的分工：
#   10-cleanup-customer.sh  删客户本身（账号/资产/设备/看板全没）——「不合作了」
#   47-reset-customer-data.sh  只清数据，客户/设备/组织/看板原样保留 ——「再测一遍」
#
# 为什么需要它：
#   调统计口径时，上一轮的遥测、资产汇总、抄表记录、账单会混在结果里，
#   「这个数是我这次改对了」还是「上一次留下的」分不清。
#   清空后灌 1~2 条已知数据，每个数字都能手算复核。
#
# 用法（在部署目录内）：
#   bash scripts/47-reset-customer-data.sh --customer '平台演示中心' --dry-run
#   bash scripts/47-reset-customer-data.sh --customer '平台演示中心' --yes
#
#   --customer <名称|id>   要清的客户（精确名或 uuid）
#   --dry-run              只统计会删什么（默认）
#   --yes                  真正执行
#   --keep-telemetry       保留原始遥测，只清派生数据（账单/抄表/告警/基线）
#   --container <名字>     非 compose 环境时直连容器名（如 energy-postgres）
#
# 清什么（**不可恢复**，删前自动打印清单）：
#   ① ts_kv / ts_kv_latest   该客户设备 + 资产的原始遥测与汇总
#   ② meter_reading_record   抄表记录（含所有分区）
#   ③ energy_bill 资产       账单（含其属性、关系、遥测）
#   ④ energy_analysis_finding 用能诊断结论
#   ⑤ alarm                  该客户的告警
#   ⑥ billing / billing_detail 新账单表（当前为空，一并清）
#   ⑦ 设备属性 lastReading / lastReadingTs   抄表基线
#
# 为什么 ⑦ 必须清：
#   抄表把「上次读数」存成设备属性。只清遥测不清基线，下次抄表会拿
#   旧基线（比如 12970）去减新上报的种子值（比如 100）→ 判「表底倒走」，
#   于是 quality=abnormal、不产生用量 —— 看起来像统计坏了，其实是基线没清。
#
# 保留什么（结构不动）：
#   租户 / 客户 / 用户 / 资产 / 设备 / 关系 / 看板 / 菜单 / 字典 / 费率模板 /
#   分时方案 / 组织档案 / 设备档案 / 一切配置类属性
#
# 安全性：
#   删前删后各做一次「非目标世界」指纹（其他客户的实体数 + id md5），
#   必须逐位相同；遥测总数必须满足「删后 = 删前 − 实删」。不符则退出码 2。
#
# 退出码：0 成功（含 dry-run）/ 1 参数或前置失败 / 2 隔离校验不通过
#
set -uo pipefail

# 定位工作根：部署目录（有 .env）或仓库根（有 pom.xml）。
# 不能简单地用 dirname/.. —— 脚本在仓库里时那是 shiyongshouce/downloads，
# 备份会错位到 shiyongshouce/downloads/backups（2026-11-15 实测踩到）。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ -f "$SCRIPT_DIR/../../../pom.xml" ]]; then
  APP_HOME="$(cd "$SCRIPT_DIR/../../.." && pwd)"
else
  APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$APP_HOME"

CUSTOMER=""
MODE="dry"
KEEP_TS="false"
CONTAINER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer)       CUSTOMER="$2"; shift 2 ;;
    --dry-run)        MODE="dry"; shift ;;
    --yes|-y)         MODE="real"; shift ;;
    --keep-telemetry) KEEP_TS="true"; shift ;;
    --container)      CONTAINER="$2"; shift 2 ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

[[ -n "$CUSTOMER" ]] || { echo "必须提供 --customer（客户名称或 id）" >&2; exit 1; }

# ---------------------------------------------------------------- 连库

if [[ -n "$CONTAINER" ]]; then
  PSQL=(docker exec -i "$CONTAINER" psql -U postgres -d thingsboard)
else
  [[ -f .env ]] || { echo "缺少 .env；若不在部署目录，请用 --container 指定容器" >&2; exit 1; }
  set -a; . ./.env; set +a
  PSQL=(docker compose exec -T postgres psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-thingsboard}")
fi

q() { "${PSQL[@]}" -X -q -A -F'|' -t -v ON_ERROR_STOP=1 -c "$1"; }
qx() { "${PSQL[@]}" -X -q -v ON_ERROR_STOP=1 -c "$1"; }

if ! q 'SELECT 1' >/dev/null 2>&1; then
  echo "连不上数据库。确认服务在跑（docker compose ps）" >&2
  exit 1
fi

# 遥测后端不是 PostgreSQL 时没有 ts_kv，本脚本不适用
if [[ "$(q "SELECT to_regclass('public.ts_kv')")" == "" ]]; then
  echo "本库没有 ts_kv（遥测后端不是 SQL 模式），本脚本不适用" >&2
  exit 1
fi

# ---------------------------------------------------------------- 定位客户

CUST_ID="$(q "SELECT id FROM customer WHERE id::text = '$CUSTOMER' OR title = '$CUSTOMER' LIMIT 1")"
if [[ -z "$CUST_ID" ]]; then
  echo "找不到客户：$CUSTOMER" >&2
  echo "现有客户：" >&2
  q "SELECT title || '  ' || id FROM customer ORDER BY title" >&2
  exit 1
fi
CUST_TITLE="$(q "SELECT title FROM customer WHERE id = '$CUST_ID'")"

echo "════════════════════════════════════════════════════════"
echo " 客户：$CUST_TITLE"
echo " id  ：$CUST_ID"
echo " 模式：$([[ "$MODE" == "dry" ]] && echo 'DRY-RUN（不删任何东西）' || echo '真实执行')"
echo " 遥测：$([[ "$KEEP_TS" == "true" ]] && echo '保留' || echo '删除')"
echo "════════════════════════════════════════════════════════"

DEV_IDS="SELECT id FROM device WHERE customer_id = '$CUST_ID'"
ASSET_IDS="SELECT id FROM asset WHERE customer_id = '$CUST_ID' AND asset_profile_id NOT IN
             (SELECT id FROM asset_profile WHERE name = 'energy_bill')"

# ---------------------------------------------------------------- 影响范围

stat() { q "$1" | tr -d ' '; }

N_DEV=$(stat "SELECT count(*) FROM device WHERE customer_id='$CUST_ID'")
N_ASSET=$(stat "SELECT count(*) FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id NOT IN
              (SELECT id FROM asset_profile WHERE name='energy_bill')")
N_DEV_PTS=$(stat "SELECT count(*) FROM ts_kv WHERE entity_id IN ($DEV_IDS)")
N_ASSET_PTS=$(stat "SELECT count(*) FROM ts_kv WHERE entity_id IN ($ASSET_IDS)")
N_BILL=$(stat "SELECT count(*) FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id IN
              (SELECT id FROM asset_profile WHERE name='energy_bill')")
N_BILL_PTS=$(stat "SELECT count(*) FROM ts_kv WHERE entity_id IN
              (SELECT id FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id IN
               (SELECT id FROM asset_profile WHERE name='energy_bill'))")
N_READING=$(stat "SELECT count(*) FROM meter_reading_record WHERE device_id IN ($DEV_IDS)")
N_ALARM=$(stat "SELECT count(*) FROM alarm WHERE customer_id='$CUST_ID'")
N_FINDING=$(stat "SELECT count(*) FROM energy_analysis_finding WHERE customer_id='$CUST_ID'")
N_BASE=$(stat "SELECT count(*) FROM attribute_kv WHERE attribute_type=2
             AND entity_id IN ($DEV_IDS) AND attribute_key IN
             (SELECT key_id FROM key_dictionary WHERE key IN ('lastReading','lastReadingTs'))")

echo
echo "将清理："
printf '  %-28s %s\n' "设备遥测 ts_kv"        "$N_DEV_PTS 点 / $N_DEV 台设备"
printf '  %-28s %s\n' "资产汇总 ts_kv"        "$N_ASSET_PTS 点 / $N_ASSET 个资产"
printf '  %-28s %s\n' "账单资产"              "$N_BILL 个（$N_BILL_PTS 点遥测）"
printf '  %-28s %s\n' "抄表记录"              "$N_READING 条"
printf '  %-28s %s\n' "告警"                  "$N_ALARM 条"
printf '  %-28s %s\n' "用能诊断结论"          "$N_FINDING 条"
printf '  %-28s %s\n' "抄表基线属性"          "$N_BASE 条"
echo
echo "保留：客户 / 账号 / 设备 / 资产 / 关系 / 看板 / 菜单 / 字典 / 费率 / 组织架构"
echo

if [[ "$MODE" == "dry" ]]; then
  echo "（dry-run 结束。确认无误后加 --yes 执行）"
  exit 0
fi

# ---------------------------------------------------------------- 非目标世界指纹

# 只算「不属于该客户」的实体，删完必须一模一样。
# 少一个 id 就说明动到了别人的数据。
fingerprint() {
  q "SELECT md5(string_agg(id::text, ',' ORDER BY id::text)) FROM (
       SELECT id FROM device  WHERE customer_id IS DISTINCT FROM '$CUST_ID'
       UNION ALL SELECT id FROM asset WHERE customer_id IS DISTINCT FROM '$CUST_ID'
       UNION ALL SELECT id FROM customer WHERE id <> '$CUST_ID'
     ) x" | tr -d ' '
}
FP_BEFORE=$(fingerprint)
TS_BEFORE=$(stat "SELECT count(*) FROM ts_kv")

echo "非目标实体指纹（删前）：$FP_BEFORE"
echo "全库遥测总数（删前）  ：$TS_BEFORE"
echo

# ---------------------------------------------------------------- 备份影响范围

BK_DIR="backups/reset-${CUST_ID%%-*}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK_DIR" 2>/dev/null || true
if [[ -d "$BK_DIR" ]]; then
  q "SELECT 'device', id, name FROM device WHERE customer_id='$CUST_ID'" > "$BK_DIR/devices.txt"
  q "SELECT 'asset', id, name FROM asset WHERE customer_id='$CUST_ID'"   > "$BK_DIR/assets.txt"
  q "SELECT 'reading', id, device_name, period, curr_reading FROM meter_reading_record
      WHERE device_id IN ($DEV_IDS)" > "$BK_DIR/readings.txt"
  cat > "$BK_DIR/summary.txt" <<EOF
客户: $CUST_TITLE ($CUST_ID)
时间: $(date -u +%FT%TZ)
设备遥测: $N_DEV_PTS / 资产遥测: $N_ASSET_PTS
账单: $N_BILL / 抄表: $N_READING / 告警: $N_ALARM / 诊断: $N_FINDING / 基线: $N_BASE
全库遥测删前: $TS_BEFORE
EOF
  echo "影响范围已备份到 $BK_DIR"
  echo
fi

# ---------------------------------------------------------------- 执行清理

t0=$(date +%s)

say() { printf '  → %s\n' "$1"; }

say "抄表基线属性"
qx "DELETE FROM attribute_kv WHERE attribute_type=2
      AND entity_id IN ($DEV_IDS)
      AND attribute_key IN (SELECT key_id FROM key_dictionary
                            WHERE key IN ('lastReading','lastReadingTs'))" >/dev/null

say "用能诊断结论"
qx "DELETE FROM energy_analysis_finding WHERE customer_id='$CUST_ID'" >/dev/null

say "账单明细与新账单表"
qx "DELETE FROM billing_detail WHERE billing_id IN (SELECT id FROM billing WHERE customer_id='$CUST_ID')" >/dev/null
qx "DELETE FROM billing WHERE customer_id='$CUST_ID'" >/dev/null

say "抄表记录（含分区）"
qx "DELETE FROM meter_reading_record WHERE device_id IN ($DEV_IDS)" >/dev/null

say "告警"
qx "DELETE FROM alarm WHERE customer_id='$CUST_ID'" >/dev/null

say "账单资产（及其属性/关系/遥测）"
qx "DELETE FROM ts_kv WHERE entity_id IN
      (SELECT id FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id IN
        (SELECT id FROM asset_profile WHERE name='energy_bill'))" >/dev/null
qx "DELETE FROM relation WHERE (from_id IN
        (SELECT id FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id IN
          (SELECT id FROM asset_profile WHERE name='energy_bill')) AND from_type='ASSET')
     OR (to_id IN
        (SELECT id FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id IN
          (SELECT id FROM asset_profile WHERE name='energy_bill')) AND to_type='ASSET')" >/dev/null
qx "DELETE FROM attribute_kv WHERE entity_id IN
      (SELECT id FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id IN
        (SELECT id FROM asset_profile WHERE name='energy_bill'))" >/dev/null
qx "DELETE FROM asset WHERE customer_id='$CUST_ID' AND asset_profile_id IN
      (SELECT id FROM asset_profile WHERE name='energy_bill')" >/dev/null

if [[ "$KEEP_TS" != "true" ]]; then
  say "资产汇总遥测（energy_total / power_total / energy_day 等）"
  qx "DELETE FROM ts_kv_latest WHERE entity_id IN ($ASSET_IDS)" >/dev/null
  qx "DELETE FROM ts_kv WHERE entity_id IN ($ASSET_IDS)" >/dev/null

  say "设备遥测（这一步最慢，约 1~2 分钟）"
  qx "DELETE FROM ts_kv_latest WHERE entity_id IN ($DEV_IDS)" >/dev/null
  qx "DELETE FROM ts_kv WHERE entity_id IN ($DEV_IDS)" >/dev/null
fi

t1=$(date +%s)
echo
echo "清理完成，耗时 $((t1 - t0)) 秒"

# ---------------------------------------------------------------- 校验

FP_AFTER=$(fingerprint)
TS_AFTER=$(stat "SELECT count(*) FROM ts_kv")

echo
echo "────────────── 校验 ──────────────"
RC=0

if [[ "$FP_BEFORE" == "$FP_AFTER" ]]; then
  echo "✓ 其他客户数据未被触碰（指纹一致）"
else
  echo "✗ 非目标实体指纹变化！删前 $FP_BEFORE / 删后 $FP_AFTER"
  echo "  立即停止使用本库，先查清动了什么"
  RC=2
fi

if [[ "$KEEP_TS" == "true" ]]; then
  echo "· 遥测按要求保留，跳过遥测增量校验"
else
  EXPECT=$((TS_BEFORE - N_DEV_PTS - N_ASSET_PTS - N_BILL_PTS))
  DELTA=$((TS_BEFORE - TS_AFTER))
  echo "  遥测：删前 $TS_BEFORE → 删后 ${TS_AFTER}（实际删除 ${DELTA}，预期 $((N_DEV_PTS + N_ASSET_PTS + N_BILL_PTS))）"
  if [[ "$TS_AFTER" == "$EXPECT" ]]; then
    echo "✓ 遥测增量与预期一致"
  else
    echo "✗ 遥测增量不符（差 $((TS_AFTER - EXPECT)) 点）—— 可能有其他来源仍在写入"
    RC=2
  fi
fi

# 残留检查：清完后再查一遍这些计数，必须全 0
LEFT=$(q "SELECT
   (SELECT count(*) FROM meter_reading_record WHERE device_id IN ($DEV_IDS))
 + (SELECT count(*) FROM alarm WHERE customer_id='$CUST_ID')
 + (SELECT count(*) FROM energy_analysis_finding WHERE customer_id='$CUST_ID')
 + (SELECT count(*) FROM attribute_kv WHERE attribute_type=2 AND entity_id IN ($DEV_IDS)
     AND attribute_key IN (SELECT key_id FROM key_dictionary WHERE key IN ('lastReading','lastReadingTs')))" | tr -d ' ')

if [[ "$LEFT" == "0" ]]; then
  echo "✓ 派生数据已清零（抄表/告警/诊断/基线）"
else
  echo "✗ 仍有 $LEFT 条派生数据残留"
  RC=2
fi

echo
if [[ "$RC" == "0" ]]; then
  echo "现在可以重新灌数据了。推荐只发 1~2 条，便于手算复核："
  echo
  echo "  python3 scripts/20-rtu-simulator.py --base http://127.0.0.1:8090 \\"
  echo "    --tenant <租户邮箱> --tenant-pass '<密码>' \\"
  echo "    --device 'PowerMeter-DDSU666' --count 1 --seed-reading 1000 --seed-usage 10"
  echo
  echo "  发完用这条核对（应等于 10）："
  echo "  docker compose exec -T postgres psql -U postgres -d thingsboard -c \\"
  echo "    \"SELECT max(coalesce(dbl_v,long_v::double precision))-min(coalesce(dbl_v,long_v::double precision)) FROM ts_kv t JOIN key_dictionary k ON k.key_id=t.key \\"
  echo "     WHERE k.key='energy_reading' AND t.entity_id='<设备id>'\""
fi

exit "$RC"
