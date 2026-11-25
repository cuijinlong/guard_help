<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 综合能耗

> 菜单位置：运维管理 / 客户 / 综合能耗

> 看板：**综合能耗**　`73ba09e0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 综合能耗（5 个功能点）|
| 部件 | `comprehensive.kpi`、`comprehensive.share`、`comprehensive.trend`、`comprehensive.table`、`energy_management.analysis_bar` |
| 接口 | `/api/asset/`、`/api/asset/{id}`、`/api/auth/user`、`/api/device/`、`/api/device/{id}`、`/api/energy/comprehensive`… |
| 数据表 | `asset`、`customer`、`key_dictionary`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 折标煤 / 碳排 / 费用 的输入：各品种合计

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT kd.key AS 键, count(*) AS 点数, round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN asset a ON a.id = k.entity_id
WHERE a.customer_id = (SELECT id FROM c)
  AND kd.key LIKE '%\_total' ESCAPE '\'
GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果**（显示前 6 行，共可能更多）：

| 键 | 点数 | 合计 |
| --- | --- | --- |
| energy_total | 112090 | 263792.09 |
| power_total | 112078 | 17243891.54 |
| water_total | 23765 | 1621.94 |
| gas_total | 22779 | 1150.32 |
| steam_total | 18218 | 50.39 |
| heat_total | 18086 | 181.99 |

### 2. 折算系数（字典没填时用国标兜底，响应里会告警）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
-- 电能 0.1229 tce/kWh、碳排 0.5703 kg/kWh、电价 0.65 元/kWh
SELECT 'elec' AS 品种, 0.1229 AS 折标煤系数, 0.5703 AS 碳排系数, 0.65 AS 单价
UNION ALL SELECT 'water', 0.2429, 0.3440, 3.50
UNION ALL SELECT 'gas',   1.3300, 2.1620, 3.20
UNION ALL SELECT 'steam', 94.300, 110.00, 260
UNION ALL SELECT 'heat',  34.120, 110.00, 90;
SQL
```

**本机实测结果**（显示前 5 行，共可能更多）：

| 品种 | 折标煤系数 | 碳排系数 | 单价 |
| --- | --- | --- | --- |
| elec | 0.1229 | 0.5703 | 0.65 |
| water | 0.2429 | 0.3440 | 3.50 |
| gas | 1.3300 | 2.1620 | 3.20 |
| steam | 94.300 | 110.00 | 260 |
| heat | 34.120 | 110.00 | 90 |

**判据**：tce ≈ Σ(各品种用量 × 系数) / 1000。数字为 0 且显示「当前 N 台计量点」→ 汇总资产上没写 `*_total`。
