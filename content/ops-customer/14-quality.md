<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 用能质量

> 菜单位置：运维管理 / 客户 / 能耗优化 / 用能质量

> 看板：**用能质量**　`1d661390-da6f-11f1-aec2-1192e109281d`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 用能质量（1 个功能点）|
| 部件 | `energy_management.diagnosis_brief` |
| 接口 | `/api/energy/diagnosis/brief`、`/api/energy/diagnosis/forecast`、`/api/energy/diagnosis/sites`、`/api/plugins/telemetry/DEVICE/` |
| 数据表 | `customer`、`energy_analysis_finding` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 电能质量结论（intent=power_quality）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH t AS (SELECT tenant_id FROM customer WHERE title = '平台演示中心')
SELECT intent AS 类别, kind AS 类型, severity AS 级别, metric AS 指标,
       site_id AS 场站, count(*) AS 条数, max(run_at) AS 最近运行
FROM energy_analysis_finding
WHERE tenant_id = (SELECT tenant_id FROM t) AND intent = 'power_quality'
GROUP BY 1, 2, 3, 4, 5 ORDER BY 6 DESC;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 类别 | 类型 | 级别 | 指标 | 场站 | 条数 |
| --- | --- | --- | --- | --- | --- |
| power_quality | limit | warn | current_unbalance | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 44 |
| power_quality | limit | crit | voltage_unbalance | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 44 |
| power_quality | limit | crit | voltage_thd_a | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 44 |
| power_quality | limit | warn | load_rate | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 44 |
| power_quality | limit | crit | voltage_dev_a | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 44 |
| power_quality | limit | warn | power_factor_total | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 43 |
| power_quality | limit | crit | current_thd_a | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 5 |
| power_quality | trend | crit | voltage_unbalance | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 2 |

> 另 1 列未显示（表格太宽）；在上面的 SQL 里只 SELECT 你要的列即可。

**判据**：`limit` 是越限、`trend` 是趋势。一个指标都没有 = 设备没上报对应键（voltage_thd_* / unbalance / flicker_*），见 ⑧ §4。
