#!/bin/bash
# 演示模拟器常驻包装（2026-11-25 新增）。
#
# 为什么需要它：23-demo-simulator.py 原来**没有任何常驻配置**，
# 只在手工跑 `--once` 时才写一轮数据。结果是几小时后全站停更 ——
# 看板显示「数据滞后 N 小时」，功率因数/需量/能耗全部缩在最后一个点。
#
# 环境变量可覆盖（与 scada-sim/run.sh 同一套约定）：
#   TB_BASE / TB_USER / TB_PASS / TB_CUSTOMER / TB_INTERVAL
set -u
cd "$(dirname "$0")" || exit 1

BASE="${TB_BASE:-http://127.0.0.1:8090}"
USER="${TB_USER:-tenant@126.com}"
PASS="${TB_PASS:-12345678}"
CUST="${TB_CUSTOMER:-平台演示中心}"
INTERVAL="${TB_INTERVAL:-60}"

exec /usr/bin/python3 ../23-demo-simulator.py \
  --base "$BASE" --tenant "$USER" --tenant-pass "$PASS" \
  --customer "$CUST" --interval "$INTERVAL" --rebuild-totals
