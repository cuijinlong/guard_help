<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 负载预测

> 菜单位置：运维管理 / 客户 / 能耗优化 / 负载预测

> 看板：**负载预测**　`741d86a0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 负载预测（3 个功能点）|
| 部件 | `energy_management.forecast_context`、`energy_management.forecast_chart`、`energy_management.diagnosis_brief` |
| 接口 | `/api/energy/diagnosis/brief`、`/api/energy/diagnosis/forecast`、`/api/energy/diagnosis/sites`、`/api/energy/forecast/context`、`/api/energy/forecast/predict`、`/api/energy/time-anchor`… |
| 数据表 | `customer`、`device`、`key_dictionary`、`now`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 预测的输入：近 7 天逐小时功率

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT date_trunc('day', to_timestamp(k.ts / 1000)) AS 日期,
       count(*) AS 点数,
       round(avg(k.dbl_v)::numeric, 2) AS 平均功率,
       round(max(k.dbl_v)::numeric, 2) AS 最大功率
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key = 'power_total'
  AND k.ts > (extract(epoch FROM now() - interval '7 day') * 1000)::bigint
GROUP BY 1 ORDER BY 1;
SQL
```

**本机实测结果**（显示前 6 行，共可能更多）：

| 日期 | 点数 | 平均功率 | 最大功率 |
| --- | --- | --- | --- |
| 2026-11-19 00:00:00+08 | 792 | 98.89 | 162.39 |
| 2026-11-20 00:00:00+08 | 2785 | 18.76 | 53.12 |
| 2026-11-21 00:00:00+08 | 2492 | 8.14 | 18.98 |
| 2026-11-22 00:00:00+08 | 1484 | 24.03 | 57.55 |
| 2026-11-24 00:00:00+08 | 1792 | 12.26 | 28.71 |
| 2026-11-25 00:00:00+08 | 9226 | 25.66 | 220.28 |

**判据**：每天都有点。历史不足 7 天时预测会退化（算法需要至少两个完整周期）。
