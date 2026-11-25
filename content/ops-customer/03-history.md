<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 历史能耗

> 菜单位置：运维管理 / 客户 / 能耗查询 / 历史能耗

> 看板：**历史能耗**　`73e6bf30-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 历史能耗（2 个功能点）|
| 部件 | `energy_management.query_panel`、`energy_management.timeseries_chart` |
| 接口 | `/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/deviceProfileInfo/`… |
| 数据表 | `customer`、`device`、`key_dictionary`、`now`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 区间用量 = 末值 − 初值（表底差，不是求和）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1),
w AS (SELECT (extract(epoch FROM now() - interval '7 day') * 1000)::bigint AS f,
             (extract(epoch FROM now()) * 1000)::bigint AS e)
SELECT d.name AS 设备,
       round(min(k.dbl_v)::numeric, 2) AS 初值,
       round(max(k.dbl_v)::numeric, 2) AS 末值,
       round((max(k.dbl_v) - min(k.dbl_v))::numeric, 2) AS 用量,
       count(*) AS 点数
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
JOIN device d ON d.id = k.entity_id
CROSS JOIN w
WHERE kd.key = 'energy_reading'
  AND d.customer_id = (SELECT id FROM c)
  AND k.ts BETWEEN w.f AND w.e
GROUP BY d.name ORDER BY 用量 DESC NULLS LAST;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 设备 | 初值 | 末值 | 用量 | 点数 |
| --- | --- | --- | --- | --- |
| WaterMeter-SIM·平台演示中心 | 4177.70 | 10027.32 | 5849.61 | 1897 |
| PowerMeter-3P-CHINT·平台演示中心 | 12710.55 | 17313.49 | 4602.95 | 1918 |
| PowerMeter-3P-YADA·平台演示中心 | 12179.96 | 16748.34 | 4568.38 | 1917 |
| 质量示范站-1#进线总表·平台演示中心 | 1.33 | 3081.32 | 3079.99 | 1025 |
| GasMeter-SIM·平台演示中心 | 2207.38 | 4892.69 | 2685.31 | 1931 |
| PowerMeter-1P-SIM·平台演示中心 | 3297.79 | 3931.05 | 633.26 | 1917 |
| 办公园区-1#进线总表·平台演示中心 | 0.48 | 568.50 | 568.03 | 1024 |
| C栋 新风机组·平台演示中心 | 2117.12 | 2584.08 | 466.96 | 121 |

**判据**：末值 ≥ 初值（表底单调递增）。出现 7777.7 / 8888.8 是哨兵读数，见 ⑧ §6.3。
