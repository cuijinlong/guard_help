<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 分项能耗

> 菜单位置：运维管理 / 客户 / 能耗分析 / 分项能耗

> 看板：**分项能耗**　`7412d840-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 分项能耗（4 个功能点）|
| 部件 | `energy_management.asset_stats_chart`、`energy_management.distribution_chart`、`energy_management.ranking_list`、`energy_management.analysis_bar` |
| 接口 | `/api/asset/`、`/api/asset/{id}`、`/api/auth/user`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/device/{id}`… |
| 数据表 | `asset`、`customer`、`key_dictionary`、`now`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 分项资产上各品种的汇总

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT a.name AS 分项, kd.key AS 键, count(*) AS 点数,
       round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN asset a ON a.id = k.entity_id
WHERE a.type = '分项' AND a.customer_id = (SELECT id FROM c)
  AND kd.key LIKE '%\_total' ESCAPE '\'
  -- 时间范围：与页面顶部「查询设置」一致；下面给的是近 90 天
  AND k.ts >= (extract(epoch FROM now() - interval '90 day') * 1000)::bigint
GROUP BY 1, 2 ORDER BY 1, 2;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 分项 | 键 | 点数 | 合计 |
| --- | --- | --- | --- |
| 动力分项·生产园区·平台演示中心 | energy_total | 2732 | 14243.22 |
| 动力分项·生产园区·平台演示中心 | power_total | 2732 | 287686.65 |
| 插座分项·办公园区·平台演示中心 | energy_total | 1 | 120.00 |
| 炊事分项·办公园区·平台演示中心 | gas_total | 2132 | 89.11 |
| 照明分项·办公园区·平台演示中心 | energy_total | 1467 | 323.39 |
| 照明分项·办公园区·平台演示中心 | power_total | 1468 | 8807.17 |
| 照明分项·生产园区·平台演示中心 | energy_total | 2467 | 4403.45 |
| 照明分项·生产园区·平台演示中心 | power_total | 2468 | 101713.49 |

**判据**：选「电」时水/气/汽/热为空是正常的。分项合计 > 场站总量 = 有表挂了两个分项（重复计）。
