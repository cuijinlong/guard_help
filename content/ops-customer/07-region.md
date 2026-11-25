<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 区域能耗

> 菜单位置：运维管理 / 客户 / 能耗分析 / 区域能耗

> 看板：**区域能耗**　`7397b4d0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 区域能耗（5 个功能点）|
| 部件 | `energy_management.ranking_list`、`energy_management.distribution_chart`、`energy_management.asset_stats_chart`、`energy_management.analysis_bar`、`energy_management.ranking_list` |
| 接口 | `/api/asset/`、`/api/asset/{id}`、`/api/auth/user`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/device/{id}`… |
| 数据表 | `asset`、`customer`、`key_dictionary`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 区域资产上各品种的汇总

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 区域, kd.key AS 键, count(*) AS 点数,
       round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN asset a ON a.id = k.entity_id
WHERE a.type = '区域' AND a.customer_id = (SELECT id FROM c)
  AND kd.key LIKE '%\_total' ESCAPE '\'
GROUP BY 1, 2 ORDER BY 1, 2;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 区域 | 键 | 点数 | 合计 |
| --- | --- | --- | --- |
| 公共区域区域·办公园区·平台演示中心 | energy_total | 2248 | 618.18 |
| 公共区域区域·办公园区·平台演示中心 | gas_total | 1912 | 88.73 |
| 公共区域区域·办公园区·平台演示中心 | power_total | 2248 | 19294.45 |
| 公共区域区域·办公园区·平台演示中心 | water_total | 1901 | 125.03 |
| 生产车间区域·生产园区·平台演示中心 | energy_total | 2479 | 18009.24 |
| 生产车间区域·生产园区·平台演示中心 | heat_total | 1518 | 14.38 |
| 生产车间区域·生产园区·平台演示中心 | power_total | 2478 | 452223.23 |
| 生产车间区域·生产园区·平台演示中心 | steam_total | 1529 | 4.19 |

**判据**：同一台表挂两个区域会双算 —— 用 ⑧ §6.1 的归属 SQL 查重复。
