<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 能耗概览

> 菜单位置：运维管理 / 客户 / 能耗概览

> 看板：**能耗概览**　`73dd2240-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 能耗概览（8 个功能点）|
| 部件 | `energy_management.analysis_bar`、`energy_management.overview_stats`、`energy_management.calendar_heatmap`、`energy_management.asset_stats_chart`、`energy_management.distribution_chart`、`energy_management.ranking_list`… |
| 接口 | `/api/asset/`、`/api/asset/{id}`、`/api/auth/user`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/device/{id}`… |
| 数据表 | `asset`、`customer`、`key_dictionary`、`relation`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 资产汇总键：各品种 *_total 的点数与合计

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT kd.key AS 键, count(*) AS 点数,
       round(sum(t.dbl_v)::numeric, 2) AS 合计,
       to_timestamp(max(t.ts) / 1000) AS 最新
FROM ts_kv t
JOIN key_dictionary kd ON kd.key_id = t.key
JOIN asset a ON a.id = t.entity_id
WHERE a.customer_id = (SELECT id FROM c)
  -- 括号不能省：AND 优先级高于 OR
  AND (kd.key LIKE '%\_total' ESCAPE '\' OR kd.key = 'energy_day')
GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果**（显示前 7 行，共可能更多）：

| 键 | 点数 | 合计 | 最新 |
| --- | --- | --- | --- |
| energy_total | 112577 | 263566.91 | 2026-11-25 16:32:18+08 |
| energy_day | 112576 | 93120337.25 | 2026-11-25 16:32:18+08 |
| power_total | 112564 | 17215072.79 | 2026-11-25 16:32:18+08 |
| gas_total | 23195 | 1150.95 | 2026-11-25 16:32:16+08 |
| water_total | 23063 | 1620.52 | 2026-11-25 16:32:16+08 |
| steam_total | 18216 | 50.39 | 2026-11-25 16:32:16+08 |
| heat_total | 18084 | 181.98 | 2026-11-25 16:32:16+08 |

### 2. 哪些场站的汇总没写（空节点也要写，否则整页空白）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT s.name AS 场站,
       count(t.*) AS 该场站资产上的汇总点数
FROM asset s
LEFT JOIN relation r ON r.to_id = s.id AND r.relation_type = 'Contains'
LEFT JOIN asset ch ON ch.id = r.from_id
LEFT JOIN ts_kv t ON t.entity_id = ch.id
     AND t.key = (SELECT key_id FROM key_dictionary WHERE key = 'energy_total')
WHERE s.type = '场站' AND s.customer_id = (SELECT id FROM c)
GROUP BY 1 ORDER BY 2;
SQL
```

**本机实测结果**（显示前 3 行，共可能更多）：

| 场站 | 该场站资产上的汇总点数 |
| --- | --- |
| 三相园区·平台演示中心 | 19541 |
| 单相园区·平台演示中心 | 19541 |
| 质量示范·平台演示中心 | 19541 |

**判据**：电/水/气/汽/热各有对应的 `*_total`；`最新` 在近 1 小时内（数据滞后会显示「数据滞后 N 小时」标记，那是数据源停了，不是看板坏）。
