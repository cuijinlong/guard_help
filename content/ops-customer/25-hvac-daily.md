<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 每日复盘报告

> 菜单位置：运维管理 / 客户 / 空调管理 / 每日复盘报告

> 看板：**每日复盘报告**　`73ed9d00-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 每日复盘报告（1 个功能点）|
| 部件 | `hvac_management.daily_report` |
| 接口 | `/api/energy/visible-sites`、`/api/hvac/daily-report` |
| 数据表 | `customer`、`device`、`key_dictionary`、`now`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 复盘用到的机组遥测（当日）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT kd.key AS 键, count(*) AS 点数,
       round(avg(k.dbl_v)::numeric, 2) AS 均值,
       to_timestamp(max(k.ts) / 1000) AS 最新
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('indoor_temp', 'indoor_co2', 'ahu_freq')
  AND k.ts > (extract(epoch FROM now() - interval '1 day') * 1000)::bigint
GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果**（显示前 3 行，共可能更多）：

| 键 | 点数 | 均值 | 最新 |
| --- | --- | --- | --- |
| ahu_freq | 3700 | 28.07 | 2026-11-26 01:46:19+08 |
| indoor_co2 | 2799 | 671.65 | 2026-11-26 01:46:23+08 |
| indoor_temp | 2799 | 23.36 | 2026-11-26 01:46:23+08 |

**判据**：当日有数才算得出口径。空白报告 = 当天机组没上报。
