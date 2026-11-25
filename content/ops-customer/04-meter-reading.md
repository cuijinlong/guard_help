<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 抄表功能

> 菜单位置：运维管理 / 客户 / 能耗查询 / 抄表功能

> 看板：**抄表功能**　`742ca1d0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 抄表功能（4 个功能点）|
| 部件 | `energy_management.query_panel`、`energy_management.meter_reading_board`、`energy_management.meter_batch_detail`、`energy_management.meter_plan` |
| 接口 | `/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/deviceProfileInfo/`… |
| 数据表 | `customer`、`meter_reading_batch`、`meter_reading_record`、`tenant` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 最近 10 个抄表批次

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT b.period AS 账期, b.status AS 状态, b.trigger_type AS 触发方式,
       b.total AS 应抄, b.normal_count AS 正常,
       b.missing_count AS 缺抄, b.abnormal_count AS 异常,
       to_timestamp(b.reading_time / 1000) AS 抄表时间
FROM meter_reading_batch b
WHERE b.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1)
ORDER BY b.created_time DESC LIMIT 10;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 账期 | 状态 | 触发方式 | 应抄 | 正常 | 缺抄 |
| --- | --- | --- | --- | --- | --- |
| 2026-11 | finished | plan | 0 | 0 | 0 |
| 2026-11 | finished | plan | 0 | 0 | 0 |
| 2026-11 | finished | plan | 0 | 0 | 0 |
| 2026-11 | finished | plan | 0 | 0 | 0 |
| 2026-11 | finished | plan | 0 | 0 | 0 |
| 2026-11 | finished | plan | 0 | 0 | 0 |
| 2026-11 | finished | plan | 0 | 0 | 0 |
| 2026-11 | finished | plan | 0 | 0 | 0 |

> 另 2 列未显示（表格太宽）；在上面的 SQL 里只 SELECT 你要的列即可。

### 2. 明细条数 / 用量按账期汇总

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT period AS 账期, source AS 来源, quality AS 质量,
       count(*) AS 条数, round(sum(usage)::numeric, 2) AS 用量合计
FROM meter_reading_record
WHERE customer_id = (SELECT id FROM c)
GROUP BY 1, 2, 3 ORDER BY 1 DESC;
SQL
```

**本机实测结果**（显示前 3 行，共可能更多）：

| 账期 | 来源 | 质量 | 条数 | 用量合计 |
| --- | --- | --- | --- | --- |
| day | auto | normal | 1 |  |
| 2026-11 | auto | estimated | 2 |  |
| 2026-10 | auto | estimated | 2 |  |

**判据**：批次 `total = normal + missing + abnormal`；明细用量合计 = 页面的「抄表电量」。`source` 的 auto/manual 说明这条是自动读的还是手工填的。
