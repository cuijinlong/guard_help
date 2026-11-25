<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 节能记录

> 菜单位置：运维管理 / 客户 / 节能记录

> 看板：**节能记录**　`7452c770-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 节能记录（1 个功能点）|
| 部件 | `energy_management.saving_records` |
| 接口 | `/api/asset`、`/api/asset/`、`/api/customer/`、`/api/device/`、`/api/energy/meters`、`/api/entitiesQuery/find`… |
| 数据表 | `asset`、`attribute_kv`、`customer`、`key_dictionary` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 节能项目与其核验字段

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT a.name AS 项目,
       max(CASE WHEN kd.key = 'actualSaving'  THEN ak.dbl_v END) AS 实际节约,
       max(CASE WHEN kd.key = 'targetSaving'  THEN ak.dbl_v END) AS 目标节约,
       max(CASE WHEN kd.key = 'verifyStatus'  THEN ak.str_v END) AS 核验状态,
       max(CASE WHEN kd.key = 'implementDate' THEN ak.str_v END) AS 实施日期
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'saving_record' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name ORDER BY 1;
SQL
```

**本机实测结果**（显示前 3 行，共可能更多）：

| 项目 | 实际节约 | 目标节约 | 核验状态 | 实施日期 |
| --- | --- | --- | --- | --- |
| 节能项目·办公区照明 LED 改造·平台演示中心 | 0 | 8760 | pending | 2026-10-19 |
| 节能项目·空压机组错峰启停·平台演示中心 | 12480 | 12000 | verified | 2026-10-04 |
| 节能项目·车床组变频改造·平台演示中心 | 5550 | 9000 | shortfall | 2026-10-06 |

**判据**：每条都有 `actualSaving`。核验期内没有实际节约数据 = 设备在核验窗口内没数。
