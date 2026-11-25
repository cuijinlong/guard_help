<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 用能账单

> 菜单位置：运维管理 / 客户 / 能耗分析 / 用能账单

> 看板：**我的账单**　`7431aae0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 用能账单（2 个功能点）|
| 部件 | `energy_management.query_panel`、`energy_management.billing_workspace` |
| 接口 | `/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/deviceProfileInfo/`… |
| 数据表 | `asset`、`attribute_kv`、`billing`、`billing_detail`、`customer`、`key_dictionary` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 账单列表（金额在 asset 属性里，不在 billing 表）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 账单元, a.label,
       max(CASE WHEN kd.key = 'period' THEN ak.str_v END) AS 账期,
       max(CASE WHEN kd.key = 'usage'  THEN ak.dbl_v END) AS 用量,
       max(CASE WHEN kd.key = 'amount' THEN ak.dbl_v END) AS 金额,
       max(CASE WHEN kd.key = 'status' THEN ak.str_v END) AS 状态
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'energy_bill' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name, a.label
ORDER BY 账期 DESC;
SQL
```

**本机实测结果**（显示前 5 行，共可能更多）：

| 账单元 | label | 账期 | 用量 | 金额 | 状态 |
| --- | --- | --- | --- | --- | --- |
| BILL-7CE48900-2026-11-elec-A5DF94F0 | 2026-11 平台演示中心 elec 账单 | 2026-11 |  |  | draft |
| BILL-7CE48900-2026-11-elec-A65A6A40 | 2026-11 平台演示中心 elec 账单 | 2026-11 |  |  | draft |
| BILL-7CE48900-2026-11-elec-D0D19070 | 2026-11 平台演示中心 elec 账单 | 2026-11 |  |  | draft |
| BILL-7CE48900-2026-11-elec-D24DA920 | 2026-11 平台演示中心 elec 账单 | 2026-11 |  |  | draft |
| BILL-7CE48900-2026-11-elec-D6C217A0 | 2026-11 平台演示中心 elec 账单 | 2026-11 |  |  | draft |

### 2. 金额分解：amount 应等于四项之和

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name,
       max(CASE WHEN kd.key = 'amount'        THEN ak.dbl_v END) AS 金额,
       max(CASE WHEN kd.key = 'energyFee'     THEN ak.dbl_v END) AS 电度电费,
       max(CASE WHEN kd.key = 'basicFee'      THEN ak.dbl_v END) AS 基本电费,
       max(CASE WHEN kd.key = 'powerFactorFee' THEN ak.dbl_v END) AS 力调电费,
       max(CASE WHEN kd.key = 'surchargeFee'  THEN ak.dbl_v END) AS 附加费
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = 'energy_bill' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name;
SQL
```

**本机实测结果**（显示前 5 行，共可能更多）：

| name | 金额 | 电度电费 | 基本电费 | 力调电费 | 附加费 |
| --- | --- | --- | --- | --- | --- |
| BILL-7CE48900-2026-11-elec-A5DF94F0 |  |  |  |  |  |
| BILL-7CE48900-2026-11-elec-A65A6A40 |  |  |  |  |  |
| BILL-7CE48900-2026-11-elec-D0D19070 |  |  |  |  |  |
| BILL-7CE48900-2026-11-elec-D24DA920 |  |  |  |  |  |
| BILL-7CE48900-2026-11-elec-D6C217A0 |  |  |  |  |  |

### 3. 确认 billing 表确实是空的（别再白查一次）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT (SELECT count(*) FROM billing)        AS "billing 行数",
       (SELECT count(*) FROM billing_detail) AS "billing_detail 行数";
SQL
```

**本机实测结果**（显示前 1 行，共可能更多）：

| billing 行数 | billing_detail 行数 |
| --- | --- |
| 0 | 0 |

**判据**：金额 = 电度 + 基本 + 力调 + 附加；`billing` / `billing_detail` 为 0 是当前设计，账单落在 `asset(type=energy_bill)` 的属性里。
