<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 实时能耗

> 菜单位置：运维管理 / 客户 / 能耗查询 / 实时能耗

> 看板：**实时能耗**　`74466b60-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 实时能耗（3 个功能点）|
| 部件 | `energy_management.realtime_kpi`、`energy_management.realtime_trend`、`energy_management.query_panel` |
| 接口 | `/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/deviceProfileInfo/`… |
| 数据表 | `customer`、`device`、`key_dictionary`、`ts_kv_latest` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 每台设备的最新值（看板读的就是 ts_kv_latest）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT d.name AS 设备, kd.key AS 键, t.dbl_v AS 值,
       to_timestamp(t.ts / 1000) AS 时间
FROM ts_kv_latest t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN device d ON d.id = t.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('energy', 'power_total')
ORDER BY 设备, 键;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 设备 | 键 | 值 | 时间 |
| --- | --- | --- | --- |
| A栋 新风机组·平台演示中心 | energy | 0.4 | 2026-11-24 02:00:00+08 |
| A栋 热水泵(大)·平台演示中心 | energy | 0 | 2026-11-24 02:00:00+08 |
| A栋 热水泵(小)·平台演示中心 | energy | 0 | 2026-11-24 02:00:00+08 |
| Breaker-SIM·平台演示中心 | energy | 0.2517 | 2026-11-19 14:51:33+08 |
| B栋 新风机组·平台演示中心 | energy | 0.4 | 2026-11-24 02:00:00+08 |
| C栋 新风机组·平台演示中心 | energy | 0.4 | 2026-11-24 02:00:00+08 |
| GasMeter-SIM·平台演示中心 | energy | 0.0007 | 2026-11-26 01:44:48+08 |
| HeatMeter-SIM·平台演示中心 | energy | 0.0048 | 2026-11-26 01:44:49+08 |

**判据**：每个计量点都有值。**要找出掉线的**：把末尾的 `ORDER BY 设备, 键` 改成 `ORDER BY t.ts`，时间最早的就是最久没上报的。
