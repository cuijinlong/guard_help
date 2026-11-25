<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 空调运行监控

> 菜单位置：运维管理 / 客户 / 空调管理 / 空调运行监控

> 看板：**空调运行监控**　`73f58c40-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 空调运行监控（1 个功能点）|
| 部件 | `hvac_management.operation_monitor` |
| 接口 | `/api/energy/visible-sites`、`/api/hvac/overview`、`/api/plugins/telemetry/DEVICE/`、`/api/plugins/telemetry/DEVICE/{id}/values/timeseries` |
| 数据表 | `customer`、`device`、`key_dictionary`、`ts_kv_latest` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 空调设备的实时键

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT d.name AS 设备, kd.key AS 键, k.dbl_v AS 值,
       to_timestamp(k.ts / 1000) AS 时间
FROM ts_kv_latest k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('indoor_temp', 'indoor_co2', 'ahu_freq', 'boiler_run_count',
                 'pump_freq_big', 'pump_freq_small', 'pump_run_big', 'pump_run_small')
ORDER BY 设备, 键;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 设备 | 键 | 值 | 时间 |
| --- | --- | --- | --- |
| AHU-SIM·平台演示中心 | ahu_freq | 42.7 | 2026-11-25 17:51:19+08 |
| A栋 1#锅炉·平台演示中心 | boiler_run_count |  | 2026-11-25 17:51:22+08 |
| A栋 2#锅炉·平台演示中心 | boiler_run_count |  | 2026-11-25 17:51:22+08 |
| A栋 室内环境·平台演示中心 | indoor_co2 | 490 | 2026-11-25 17:51:22+08 |
| A栋 室内环境·平台演示中心 | indoor_temp | 22.9 | 2026-11-25 17:51:22+08 |
| A栋 新风机组·平台演示中心 | ahu_freq | 42.5 | 2026-11-25 17:51:22+08 |
| A栋 热水泵(大)·平台演示中心 | pump_freq_big | 40.72 | 2026-11-25 17:51:22+08 |
| A栋 热水泵(大)·平台演示中心 | pump_run_big |  | 2026-11-25 17:51:22+08 |

**判据**：室内温湿度/CO₂ 有空值 = 该设备没接环境传感器（不影响机组本身）。
