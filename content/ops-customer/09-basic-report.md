<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 基础报表

> 菜单位置：运维管理 / 客户 / 综合报表 / 基础报表

> 看板：**基础报表**　`73b500d0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 基础报表（2 个功能点）|
| 部件 | `energy_management.query_panel`、`energy_management.basic_report_workspace` |
| 接口 | `/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/deviceProfileInfo/`… |
| 数据表 | `customer`、`device`、`key_dictionary`、`now`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 报表取数的设备键（与历史能耗同一口径）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT d.name AS 设备, kd.key AS 键, count(*) AS 点数,
       to_timestamp(max(k.ts) / 1000) AS 最新
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('energy_reading', 'energy', 'power_total')
  -- 时间范围：与页面顶部「查询设置」一致；下面给的是近 90 天
  AND k.ts >= (extract(epoch FROM now() - interval '90 day') * 1000)::bigint
GROUP BY 1, 2 ORDER BY 1, 2;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 设备 | 键 | 点数 | 最新 |
| --- | --- | --- | --- |
| A栋 新风机组·平台演示中心 | energy | 339 | 2026-11-24 02:00:00+08 |
| A栋 新风机组·平台演示中心 | energy_reading | 339 | 2026-11-24 02:00:00+08 |
| A栋 热水泵(大)·平台演示中心 | energy | 339 | 2026-11-24 02:00:00+08 |
| A栋 热水泵(大)·平台演示中心 | energy_reading | 339 | 2026-11-24 02:00:00+08 |
| A栋 热水泵(小)·平台演示中心 | energy | 339 | 2026-11-24 02:00:00+08 |
| A栋 热水泵(小)·平台演示中心 | energy_reading | 339 | 2026-11-24 02:00:00+08 |
| Breaker-SIM·平台演示中心 | energy | 264 | 2026-11-19 14:51:33+08 |
| Breaker-SIM·平台演示中心 | energy_reading | 264 | 2026-11-19 14:51:33+08 |

**判据**：报表的数字来自同一批键 —— 与历史能耗页对不上时，先比这两页的查询条件（时间窗、设备树）。
