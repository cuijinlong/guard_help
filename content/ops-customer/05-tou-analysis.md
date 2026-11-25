<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 峰谷分析

> 菜单位置：运维管理 / 客户 / 能耗分析 / 峰谷分析

> 看板：**峰谷分析**　`745670f0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 峰谷分析（2 个功能点）|
| 部件 | `energy_management.query_panel`、`energy_management.tou_analysis` |
| 接口 | `/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/deviceProfileInfo/`… |
| 数据表 | `asset`、`attribute_kv`、`customer`、`device`、`key_dictionary`、`now`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 五个时段键各自的点数与合计

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT kd.key AS 时段键, count(*) AS 点数,
       round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
WHERE d.customer_id = (SELECT id FROM c)
  AND kd.key IN ('energy_tip', 'energy_peak', 'energy_flat', 'energy_valley', 'energy_deep')
  -- 时间范围：与页面顶部「查询设置」一致；下面给的是近 90 天
  AND k.ts >= (extract(epoch FROM now() - interval '90 day') * 1000)::bigint
GROUP BY 1 ORDER BY 1;
SQL
```

**本机实测结果**（显示前 5 行，共可能更多）：

| 时段键 | 点数 | 合计 |
| --- | --- | --- |
| energy_deep | 2163 | 521705.72 |
| energy_flat | 2163 | 521449.61 |
| energy_peak | 2163 | 520667.42 |
| energy_tip | 2163 | 519120.00 |
| energy_valley | 2163 | 520227.75 |

### 2. 时段方案（★ 租户级资产，**不要按客户过滤**）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
-- 坑：tou_scheme 的 customer_id 是占位值（13814000-…），
--     按客户过滤会返回 0 行，看起来像「方案没配」，其实是查错了。
SELECT a.name AS 方案, a.label, kd.key AS 属性, left(ak.str_v, 120) AS 值
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'tou_scheme'
ORDER BY 1, 3;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 方案 | label | 属性 | 值 |
| --- | --- | --- | --- |
| 冬季周末及节假日 | 冬季周末及节假日 | blocks |  |
| 冬季周末及节假日 | 冬季周末及节假日 | code | winter_weekend |
| 冬季周末及节假日 | 冬季周末及节假日 | dayType | weekend |
| 冬季周末及节假日 | 冬季周末及节假日 | note | 冬季周末及法定节假日：无尖峰 |
| 冬季周末及节假日 | 冬季周末及节假日 | season | winter |
| 冬季周末及节假日 | 冬季周末及节假日 | status | active |
| 冬季工作日 | 冬季工作日 | blocks |  |
| 冬季工作日 | 冬季工作日 | code | winter_weekday |

**判据**：五个时段键齐全。峰谷合计 ≠ 台账用量是正常的（按小时切片 vs 按抄表周期）。
